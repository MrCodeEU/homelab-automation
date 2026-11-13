package deployagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Config is what one agent needs; cmd/deploy-agent fills it from the
// environment.
type Config struct {
	Host       string
	RepoURL    string
	MainBranch string // the protected branch commits must be on
	StateDir   string // repo/, releases/, outbox/, state.json
	// MetricsFile is written after every poll, for Alloy's textfile
	// collector; default StateDir/metrics.prom.
	MetricsFile string
	Keyring     string // armored public keys trusted to sign commits
	// Apply is the path, inside the applied commit's tree, of the
	// host-side apply script (scripts/openvox-apply.sh). It runs as
	// `bash <script> <tree> <Mode>` with the request as environment
	// (Request.Env) and must exit 0 on success. The script holds the
	// per-host deploy lock it shares with the laptop push.
	Apply        string
	ApplyTimeout time.Duration
	// Mode is apply, or noop for the rollout phase where the agent runs
	// next to the push (docs/DEPLOY_AGENT.md "Rollout"). A noop result
	// never becomes the last applied commit.
	Mode        string
	SuspendFile string
	Notifiers   []Notifier
	Log         *slog.Logger
}

// DeployBranch is the request branch of a host.
func DeployBranch(host string) string { return "deploy/" + host }

// State survives restarts in StateDir/state.json.
type State struct {
	// LastRequestRef is the deploy branch head handled last, applied or
	// not: the agent acts once per request commit.
	LastRequestRef string `json:"last_request_ref"`
	LastRequestID  string `json:"last_request_id"`
	// LastApplied is the main commit applied last with success: the
	// base of the rollback check.
	LastApplied string `json:"last_applied"`
	LastResult  Result `json:"last_result"`
	// Applying is the request id while its apply runs. Still set at the
	// next start means the agent died mid-apply (a reboot): reported as
	// interrupted, not applied again.
	Applying string `json:"applying,omitempty"`
	// LastSuccess is the newest result with outcome success, for the
	// last-success metric (LastResult may be a later failure).
	LastSuccess Result `json:"last_success"`
}

// Result of one request, for state, outbox and metrics.
type Result struct {
	RequestID string    `json:"request_id"`
	Host      string    `json:"host"`
	Commit    string    `json:"commit"`
	Mode      string    `json:"mode"`
	Outcome   string    `json:"outcome"` // success, failure, rejected, suspended, interrupted
	Detail    string    `json:"detail"`
	Time      time.Time `json:"time"`
	Duration  float64   `json:"duration_seconds"`
	// Changes and Errors count the apply output's resource change and
	// "Error:" lines, as deploy.yml does for the push.
	Changes int `json:"resource_changes"`
	Errors  int `json:"error_lines"`
}

// Agent polls one host's deploy branch.
type Agent struct {
	cfg      Config
	repo     *Repo
	state    State
	lastPoll time.Time
}

func New(cfg Config) (*Agent, error) {
	if cfg.Log == nil {
		cfg.Log = slog.Default()
	}
	if cfg.MetricsFile == "" {
		cfg.MetricsFile = filepath.Join(cfg.StateDir, "metrics.prom")
	}
	if cfg.Mode != "apply" && cfg.Mode != "noop" {
		return nil, fmt.Errorf("mode %q: want apply or noop", cfg.Mode)
	}
	for _, d := range []string{"releases", "outbox"} {
		if err := os.MkdirAll(filepath.Join(cfg.StateDir, d), 0o700); err != nil {
			return nil, err
		}
	}
	repo, err := OpenRepo(filepath.Join(cfg.StateDir, "repo"), cfg.RepoURL)
	if err != nil {
		return nil, err
	}
	a := &Agent{cfg: cfg, repo: repo}
	data, err := os.ReadFile(a.path("state.json"))
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(data, &a.state); err != nil {
			return nil, fmt.Errorf("state.json: %w", err)
		}
	}
	return a, nil
}

func (a *Agent) path(name string) string { return filepath.Join(a.cfg.StateDir, name) }

// Poll handles at most one new request. Errors are infrastructure errors
// (network, disk); a refused or failed request is a Result, not an error.
func (a *Agent) Poll(ctx context.Context) error {
	// Deferred calls run last first: flush, then metrics (outbox count).
	defer a.writeMetrics()
	defer a.flushOutbox(ctx)

	if a.state.Applying != "" {
		res := Result{
			RequestID: a.state.Applying, Host: a.cfg.Host, Mode: a.cfg.Mode, Outcome: "interrupted", Time: time.Now(),
			Detail: "the agent stopped during this apply (reboot?); state unknown, not applied again",
		}
		a.state.Applying, a.state.LastResult = "", res
		if err := a.saveState(); err != nil {
			return err
		}
		if err := a.queue(res); err != nil {
			return err
		}
	}

	branch := DeployBranch(a.cfg.Host)
	head, err := a.repo.RemoteHead(ctx, branch)
	if errors.Is(err, ErrNoBranch) {
		a.lastPoll = time.Now()
		return nil
	}
	if err != nil {
		return err
	}
	a.lastPoll = time.Now()
	if head.String() == a.state.LastRequestRef {
		return nil
	}
	if err := a.repo.Fetch(ctx, a.cfg.MainBranch, branch); err != nil {
		return err
	}
	res := a.handle(ctx, branch, head.String())
	a.cfg.Log.Info("request handled", "id", res.RequestID, "commit", res.Commit, "outcome", res.Outcome, "detail", res.Detail)
	a.state.LastRequestRef = head.String()
	a.state.LastResult = res
	if res.RequestID != "" && res.Outcome != "rejected" {
		a.state.LastRequestID = res.RequestID
	}
	if res.Outcome == "success" && a.cfg.Mode == "apply" {
		a.state.LastApplied = res.Commit
	}
	if res.Outcome == "success" {
		a.state.LastSuccess = res
		a.state.LastSuccess.Detail = ""
	}
	if err := a.saveState(); err != nil {
		return err
	}
	return a.queue(res)
}

// handle checks the request at the head of the deploy branch and applies
// it. Every check from docs/DEPLOY_AGENT.md "What the agent checks".
func (a *Agent) handle(ctx context.Context, branch, head string) Result {
	start := time.Now()
	res := Result{Host: a.cfg.Host, Mode: a.cfg.Mode, Time: start}
	refuse := func(format string, args ...any) Result {
		res.Outcome, res.Detail = "rejected", fmt.Sprintf(format, args...)
		return res
	}

	reqCommit, err := a.repo.Head(branch)
	if err != nil {
		return refuse("%v", err)
	}
	if _, err := Verify(reqCommit, a.cfg.Keyring); err != nil {
		return refuse("request: %v", err)
	}
	data, err := ReadFile(reqCommit, RequestPath)
	if err != nil {
		return refuse("%v", err)
	}
	req, err := ParseRequest(data)
	res.RequestID, res.Commit = req.ID, req.Commit
	if err != nil {
		return refuse("%v", err)
	}
	if req.Host != a.cfg.Host {
		return refuse("request is for host %q", req.Host)
	}
	if !req.After(a.state.LastRequestID) {
		return refuse("request id %s is not after %s (replay)", req.ID, a.state.LastRequestID)
	}

	// Only main and the deploy branch are fetched: a commit that is not
	// there is not on main.
	target, err := a.repo.Commit(req.Commit)
	if err != nil {
		return refuse("commit %s is not on %s (%v)", req.Commit, a.cfg.MainBranch, err)
	}
	if _, err := Verify(target, a.cfg.Keyring); err != nil {
		return refuse("target: %v", err)
	}
	main, err := a.repo.Head(a.cfg.MainBranch)
	if err != nil {
		return refuse("%v", err)
	}
	if ok, err := Reachable(target, main); err != nil || !ok {
		return refuse("commit %s is not on %s", req.Commit, a.cfg.MainBranch)
	}
	if a.state.LastApplied != "" {
		last, err := a.repo.Commit(a.state.LastApplied)
		if err != nil {
			return refuse("last applied: %v", err)
		}
		if ok, err := Reachable(last, target); err != nil || !ok {
			return refuse("commit %s does not descend from the last applied %s (rollback)", req.Commit, a.state.LastApplied)
		}
	}

	if _, err := os.Stat(a.cfg.SuspendFile); err == nil {
		res.Outcome, res.Detail = "suspended", a.cfg.SuspendFile+" exists"
		return res
	}

	// Mark the request handled before running it, so a reboot during the
	// apply cannot make it run twice.
	a.state.LastRequestRef, a.state.LastRequestID, a.state.Applying = head, req.ID, req.ID
	if err := a.saveState(); err != nil {
		res.Outcome, res.Detail = "failure", fmt.Sprintf("save state: %v", err)
		return res
	}
	out, err := a.apply(ctx, req)
	a.state.Applying = ""
	res.Duration = time.Since(start).Seconds()
	res.Changes, res.Errors = countApplyLines(out)
	out = tail(out, 40)
	if err != nil {
		res.Outcome, res.Detail = "failure", fmt.Sprintf("%v\n%s", err, out)
		return res
	}
	res.Outcome, res.Detail = "success", out
	return res
}

// apply exports the target commit and runs the apply script. It returns
// the script's output.
func (a *Agent) apply(ctx context.Context, req Request) (string, error) {
	target, err := a.repo.Commit(req.Commit)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(a.cfg.StateDir, "releases", req.ID)
	if err := Export(target, dir); err != nil {
		return "", fmt.Errorf("export: %w", err)
	}
	a.pruneReleases(3)

	ctx, cancel := context.WithTimeout(ctx, a.cfg.ApplyTimeout)
	defer cancel()
	// Through bash, not exec: the exec bit is not reliable
	// (createCommitOnBranch cannot set it, core.fileMode=false loses it).
	cmd := exec.CommandContext(ctx, "/bin/bash", filepath.Join(dir, a.cfg.Apply), dir, a.cfg.Mode)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), req.Env()...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

var (
	changeLine = regexp.MustCompile(`/(ensure|content|returns|mode|owner|group):`)
	errorLine  = regexp.MustCompile(`^Error:`)
)

// countApplyLines counts the resource change and error lines of a puppet
// apply output, with deploy.yml's patterns for the push.
func countApplyLines(out string) (changes, errs int) {
	for _, l := range strings.Split(out, "\n") {
		if changeLine.MatchString(l) {
			changes++
		}
		if errorLine.MatchString(l) {
			errs++
		}
	}
	return changes, errs
}

func (a *Agent) pruneReleases(keep int) {
	entries, _ := os.ReadDir(a.path("releases"))
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() > entries[j].Name() })
	for i, e := range entries {
		if i >= keep {
			os.RemoveAll(filepath.Join(a.path("releases"), e.Name()))
		}
	}
}

func (a *Agent) saveState() error {
	data, _ := json.MarshalIndent(a.state, "", "  ")
	return writeAtomic(a.path("state.json"), data, 0o600)
}

// queue puts a result into the outbox; flushOutbox sends it.
func (a *Agent) queue(res Result) error {
	data, _ := json.Marshal(res)
	name := fmt.Sprintf("%d-%s.json", res.Time.UnixNano(), res.Outcome)
	return writeAtomic(filepath.Join(a.path("outbox"), name), data, 0o600)
}

// flushOutbox sends every queued result through the first notifier that
// accepts it; an entry stays until one did.
func (a *Agent) flushOutbox(ctx context.Context) {
	entries, _ := os.ReadDir(a.path("outbox"))
	for _, e := range entries {
		p := filepath.Join(a.path("outbox"), e.Name())
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var res Result
		if err := json.Unmarshal(data, &res); err != nil {
			a.cfg.Log.Error("outbox entry unreadable, kept", "file", p, "err", err)
			continue
		}
		for _, n := range a.cfg.Notifiers {
			if err := n.Notify(ctx, res); err != nil {
				a.cfg.Log.Warn("notify failed", "via", n.Name(), "err", err)
				continue
			}
			os.Remove(p)
			break
		}
	}
}

// writeMetrics writes StateDir/metrics.prom for Alloy's textfile
// collector.
func (a *Agent) writeMetrics() {
	entries, _ := os.ReadDir(a.path("outbox"))
	r := a.state.LastResult
	var b strings.Builder
	fmt.Fprintf(&b, "homelab_deploy_last_poll_timestamp_seconds{host=%q} %d\n", a.cfg.Host, a.lastPoll.Unix())
	if r.RequestID != "" {
		fmt.Fprintf(&b, "homelab_deploy_last_result_timestamp_seconds{host=%q,request_id=%q,mode=%q,outcome=%q} %d\n", a.cfg.Host, r.RequestID, r.Mode, r.Outcome, r.Time.Unix())
	}
	if r.RequestID != "" {
		// The same values deploy.yml records for the push
		// (homelab_openvox_*), for the Grafana deploy panels.
		success := 0
		if r.Outcome == "success" {
			success = 1
		}
		fmt.Fprintf(&b, "homelab_deploy_run_success{host=%q,mode=%q} %d\n", a.cfg.Host, r.Mode, success)
		fmt.Fprintf(&b, "homelab_deploy_run_duration_seconds{host=%q,mode=%q} %.0f\n", a.cfg.Host, r.Mode, r.Duration)
		fmt.Fprintf(&b, "homelab_deploy_resource_changes{host=%q,mode=%q} %d\n", a.cfg.Host, r.Mode, r.Changes)
		fmt.Fprintf(&b, "homelab_deploy_error_lines{host=%q,mode=%q} %d\n", a.cfg.Host, r.Mode, r.Errors)
	}
	if s := a.state.LastSuccess; s.RequestID != "" {
		fmt.Fprintf(&b, "homelab_deploy_last_success_timestamp_seconds{host=%q,mode=%q} %d\n", a.cfg.Host, s.Mode, s.Time.Unix())
	}
	fmt.Fprintf(&b, "homelab_deploy_applied_info{host=%q,commit=%q} 1\n", a.cfg.Host, a.state.LastApplied)
	fmt.Fprintf(&b, "homelab_deploy_outbox_entries{host=%q} %d\n", a.cfg.Host, len(entries))
	if err := writeAtomic(a.cfg.MetricsFile, []byte(b.String()), 0o644); err != nil {
		a.cfg.Log.Error("metrics", "err", err)
	}
}

func writeAtomic(path string, data []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func tail(s string, lines int) string {
	parts := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(parts) > lines {
		parts = parts[len(parts)-lines:]
	}
	return strings.Join(parts, "\n")
}
