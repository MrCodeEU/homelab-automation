package deployagent

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ProtonMail/go-crypto/openpgp"
	"github.com/ProtonMail/go-crypto/openpgp/armor"
	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// origin is a local repository standing in for GitHub: main with an
// apply script, and an orphan deploy/test branch of requests.
type origin struct {
	t       *testing.T
	dir     string
	r       *git.Repository
	signer  *openpgp.Entity
	keyring string
	n       int
}

func newOrigin(t *testing.T) *origin {
	signer, err := openpgp.NewEntity("GitHub", "", "noreply@github.com", nil)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	w, _ := armor.Encode(&buf, openpgp.PublicKeyType, nil)
	signer.Serialize(w)
	w.Close()
	dir := t.TempDir()
	r, err := git.PlainInit(dir, false)
	if err != nil {
		t.Fatal(err)
	}
	return &origin{t: t, dir: dir, r: r, signer: signer, keyring: buf.String()}
}

// commit writes files on branch (created from parent, or orphan when
// parent is zero) and commits, signed unless unsigned.
func (o *origin) commit(branch string, parent plumbing.Hash, files map[string]string, unsigned bool) plumbing.Hash {
	o.t.Helper()
	wt, _ := o.r.Worktree()
	ref := plumbing.NewBranchReferenceName(branch)
	if _, err := o.r.Reference(ref, false); err != nil {
		// New branch: point HEAD at it, start from parent's tree or empty.
		o.r.Storer.SetReference(plumbing.NewSymbolicReference(plumbing.HEAD, ref))
		if !parent.IsZero() {
			o.r.Storer.SetReference(plumbing.NewHashReference(ref, parent))
			wt.Reset(&git.ResetOptions{Commit: parent, Mode: git.HardReset})
		} else {
			os.RemoveAll(filepath.Join(o.dir, "scripts"))
			os.RemoveAll(filepath.Join(o.dir, ".deploy"))
			wt.Filesystem.Remove(".git/index")
			idx, _ := o.r.Storer.Index()
			idx.Entries = nil
			o.r.Storer.SetIndex(idx)
		}
	} else {
		wt.Checkout(&git.CheckoutOptions{Branch: ref, Force: true})
	}
	for name, content := range files {
		p := filepath.Join(o.dir, name)
		os.MkdirAll(filepath.Dir(p), 0o755)
		mode := os.FileMode(0o644)
		if strings.HasSuffix(name, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(p, []byte(content), mode); err != nil {
			o.t.Fatal(err)
		}
		wt.Add(name)
	}
	o.n++
	opts := &git.CommitOptions{
		Author:            &object.Signature{Name: "t", Email: "t@example.org", When: time.Now()},
		AllowEmptyCommits: true,
	}
	if !unsigned {
		opts.SignKey = o.signer
	}
	h, err := wt.Commit(fmt.Sprintf("commit %d", o.n), opts)
	if err != nil {
		o.t.Fatal(err)
	}
	return h
}

const applyScript = "#!/bin/bash\n[ \"$2\" = apply ] || exit 3\necho applied $DEPLOY_COMMIT >> \"$APPLY_LOG\"\n" +
	"echo 'Notice: /Stage[main]/Roles::X/File[/a]/content: content changed'\n" +
	"[ -z \"$APPLY_FAIL\" ] || { echo 'Error: boom'; exit 1; }\n"

var reqSeq = 0

func (o *origin) request(target plumbing.Hash, mutate func(*Request), unsigned bool) {
	reqSeq++
	r := Request{
		ID:      fmt.Sprintf("20261111T1800%02dZ", reqSeq),
		Host:    "test",
		Commit:  target.String(),
		Trigger: "manual",
	}
	if mutate != nil {
		mutate(&r)
	}
	data := fmt.Sprintf(`{"id":%q,"host":%q,"commit":%q,"trigger":%q}`, r.ID, r.Host, r.Commit, r.Trigger)
	o.commit("deploy/test", plumbing.ZeroHash, map[string]string{RequestPath: data}, unsigned)
}

type recorder struct{ got []Result }

func (r *recorder) Name() string { return "rec" }
func (r *recorder) Notify(_ context.Context, res Result) error {
	r.got = append(r.got, res)
	return nil
}

func newAgent(t *testing.T, o *origin, rec *recorder) (*Agent, string) {
	state := t.TempDir()
	log := filepath.Join(state, "apply.log")
	t.Setenv("APPLY_LOG", log)
	a, err := New(Config{
		Host: "test", RepoURL: o.dir, MainBranch: "main", StateDir: state,
		Keyring: o.keyring, Apply: "scripts/apply.sh", ApplyTimeout: time.Minute, Mode: "apply",
		SuspendFile: filepath.Join(state, "suspend"),
		Notifiers:   []Notifier{rec},
	})
	if err != nil {
		t.Fatal(err)
	}
	return a, log
}

func (a *Agent) mustPoll(t *testing.T) Result {
	t.Helper()
	if err := a.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	return a.state.LastResult
}

func TestAgent(t *testing.T) {
	o := newOrigin(t)
	m1 := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": applyScript}, false)
	rec := &recorder{}
	a, applyLog := newAgent(t, o, rec)

	o.request(m1, nil, false)
	if r := a.mustPoll(t); r.Outcome != "success" {
		t.Fatalf("first request: %+v", r)
	}
	if b, _ := os.ReadFile(applyLog); !strings.Contains(string(b), m1.String()) {
		t.Fatalf("apply log %q lacks %s", b, m1)
	}

	// Same head again: nothing new, no second notification.
	a.mustPoll(t)
	if len(rec.got) != 1 {
		t.Fatalf("want 1 notification, got %d", len(rec.got))
	}

	// A redeploy of the same commit is a new request and applies.
	o.request(m1, nil, false)
	if r := a.mustPoll(t); r.Outcome != "success" {
		t.Fatalf("redeploy: %+v", r)
	}

	m2 := o.commit("main", plumbing.ZeroHash, map[string]string{"README": "two"}, false)
	unsignedMain := o.commit("main", plumbing.ZeroHash, map[string]string{"README": "three"}, true)
	side := o.commit("side", m1, map[string]string{"README": "side"}, false)

	cases := []struct {
		name     string
		target   plumbing.Hash
		mutate   func(*Request)
		unsigned bool
		want     string
		detail   string
	}{
		{"unsigned request", m2, nil, true, "rejected", "not signed"},
		{"other host", m2, func(r *Request) { r.Host = "nuc" }, false, "rejected", "for host"},
		{"replay", m2, func(r *Request) { r.ID = "20261111T000000Z" }, false, "rejected", "replay"},
		{"bad param", m2, func(r *Request) { r.Trigger = "push" }, false, "rejected", "trigger"},
		{"not on main", side, nil, false, "rejected", "not on main"},
		{"unsigned target", unsignedMain, nil, false, "rejected", "target"},
		{"forward", m2, nil, false, "success", ""},
		{"rollback", m1, nil, false, "rejected", "rollback"},
	}
	for _, c := range cases {
		o.request(c.target, c.mutate, c.unsigned)
		r := a.mustPoll(t)
		if r.Outcome != c.want || !strings.Contains(r.Detail, c.detail) {
			t.Errorf("%s: got %s %q", c.name, r.Outcome, r.Detail)
		}
	}

	os.WriteFile(a.cfg.SuspendFile, nil, 0o644)
	o.request(m2, nil, false)
	if r := a.mustPoll(t); r.Outcome != "suspended" {
		t.Errorf("suspend: %+v", r)
	}
	os.Remove(a.cfg.SuspendFile)

	t.Setenv("APPLY_FAIL", "1")
	o.request(m2, nil, false)
	if r := a.mustPoll(t); r.Outcome != "failure" {
		t.Errorf("failing apply: %+v", r)
	}
	if a.state.LastApplied != m2.String() {
		t.Errorf("last applied %s, want %s", a.state.LastApplied, m2)
	}
	b, _ := os.ReadFile(a.cfg.MetricsFile)
	for _, want := range []string{
		`outcome="failure"`,
		`homelab_deploy_run_success{host="test",mode="apply"} 0`,
		`homelab_deploy_resource_changes{host="test",mode="apply"} 1`,
		`homelab_deploy_error_lines{host="test",mode="apply"} 1`,
		`homelab_deploy_last_success_timestamp_seconds{host="test",mode="apply"} `,
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("metrics lack %s:\n%s", want, b)
		}
	}
}

// A notifier that fails keeps the result in the outbox until a later
// flush succeeds.
func TestOutboxKeepsUntilDelivered(t *testing.T) {
	o := newOrigin(t)
	m1 := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": applyScript}, false)
	fail := &flaky{}
	a, _ := newAgent(t, o, &recorder{})
	a.cfg.Notifiers = []Notifier{fail}
	o.request(m1, nil, false)
	a.mustPoll(t)
	if n := countDir(t, a.path("outbox")); n != 1 {
		t.Fatalf("outbox after failed notify: %d", n)
	}
	fail.ok = true
	a.mustPoll(t)
	if n := countDir(t, a.path("outbox")); n != 0 || len(fail.got) != 1 {
		t.Fatalf("outbox %d, delivered %d", n, len(fail.got))
	}
}

type flaky struct {
	ok  bool
	got []Result
}

func (f *flaky) Name() string { return "flaky" }
func (f *flaky) Notify(_ context.Context, r Result) error {
	if !f.ok {
		return fmt.Errorf("down")
	}
	f.got = append(f.got, r)
	return nil
}

func countDir(t *testing.T, dir string) int {
	e, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	return len(e)
}

// An apply cut off by a reboot is reported once as interrupted and not run
// again.
func TestInterruptedApply(t *testing.T) {
	o := newOrigin(t)
	m1 := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": applyScript}, false)
	a, applyLog := newAgent(t, o, &recorder{})
	o.request(m1, nil, false)
	a.mustPoll(t)

	// The agent died while applying the next request.
	o.request(m1, nil, false)
	head, err := a.repo.RemoteHead(context.Background(), DeployBranch("test"))
	if err != nil {
		t.Fatal(err)
	}
	a.state.LastRequestRef, a.state.Applying = head.String(), "20261111T235959Z"
	if err := a.saveState(); err != nil {
		t.Fatal(err)
	}
	b, err := New(a.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if r := b.mustPoll(t); r.Outcome != "interrupted" {
		t.Fatalf("got %+v", r)
	}
	if n := strings.Count(mustRead(t, applyLog), "applied"); n != 1 {
		t.Errorf("applied %d times, want 1", n)
	}
}

func mustRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// A noop agent runs the script in noop mode and never moves the rollback
// base, so a later apply agent is not blocked by noop history.
func TestNoopMode(t *testing.T) {
	o := newOrigin(t)
	m1 := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": noopScript}, false)
	a, applyLog := newAgent(t, o, &recorder{})
	a.cfg.Mode = "noop"
	o.request(m1, nil, false)
	if r := a.mustPoll(t); r.Outcome != "success" || r.Mode != "noop" {
		t.Fatalf("got %+v", r)
	}
	if a.state.LastApplied != "" {
		t.Errorf("noop set last applied to %s", a.state.LastApplied)
	}
	if !strings.Contains(mustRead(t, applyLog), "noop") {
		t.Errorf("script did not run in noop mode")
	}
}

const noopScript = "#!/bin/bash\n[ \"$2\" = noop ] || exit 3\necho noop $DEPLOY_COMMIT >> \"$APPLY_LOG\"\n"

// Before the first request the branch does not exist: a normal poll, not
// an error, and the poll metric is set.
func TestNoBranchYet(t *testing.T) {
	o := newOrigin(t)
	o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": applyScript}, false)
	a, _ := newAgent(t, o, &recorder{})
	if err := a.Poll(context.Background()); err != nil {
		t.Fatalf("poll without deploy branch: %v", err)
	}
	if m := mustRead(t, a.cfg.MetricsFile); strings.Contains(m, "seconds{host=\"test\"} -") {
		t.Errorf("poll timestamp not set:\n%s", m)
	}
}
