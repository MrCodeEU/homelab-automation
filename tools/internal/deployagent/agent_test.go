package deployagent

import (
	"bytes"
	"context"
	"encoding/json"
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

	"github.com/MrCodeEU/homelab-automation/tools/internal/maintwindow"
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
	data, err := json.Marshal(r)
	if err != nil {
		o.t.Fatal(err)
	}
	o.commit("deploy/test", plumbing.ZeroHash, map[string]string{RequestPath: string(data)}, unsigned)
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

const driftScript = "#!/bin/bash\n[ \"$2\" = noop ] || { echo applied $DEPLOY_COMMIT >> \"$APPLY_LOG\"; exit 0; }\n" +
	"[ -z \"$NOOP_BUSY\" ] || { echo 'ERROR: another deploy holds /run/homelab-deploy.lock'; exit 1; }\n" +
	"[ -z \"$NOOP_FAIL\" ] || { echo 'Error: noop boom'; exit 1; }\n" +
	"echo \"Notice: /Stage[main]/Roles::X/Exec[up]/returns: current_value 'notrun', should be ['0'] (noop)\"\n" +
	"echo \"Notice: /Stage[main]/Roles::X/Docker_compose[up]/ensure: created (noop)\"\n" +
	"echo \"Notice: /Stage[main]/Roles::X/File[/stamp]/content: content changed '{sha256}a' to '{sha256}b'\"\n" +
	"[ -z \"$NOOP_DRIFT\" ] || echo \"Notice: /Stage[main]/Roles::X/File[$NOOP_DRIFT]/content: content changed '{sha256}a' to '{sha256}b'\"\n"

func TestDrift(t *testing.T) {
	o := newOrigin(t)
	c := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": driftScript}, false)
	o.request(c, nil, false)
	rec := &recorder{}
	a, _ := newAgent(t, o, rec)
	a.cfg.DriftAt = "03:17"
	a.cfg.DriftIgnore = []string{"File[/stamp]"}
	clock := time.Date(2026, 11, 16, 2, 0, 0, 0, time.Local)
	a.now = func() time.Time { return clock }
	ctx := context.Background()

	// Before anything is applied: no drift check.
	if err := a.MaybeDrift(ctx); err != nil || !a.state.Drift.Time.IsZero() {
		t.Fatalf("drift before apply: %v %+v", err, a.state.Drift)
	}
	if r := a.mustPoll(t); r.Outcome != "success" {
		t.Fatalf("apply: %+v", r)
	}
	rec.got = nil

	check := func(env map[string]string) {
		t.Helper()
		for _, k := range []string{"NOOP_BUSY", "NOOP_FAIL", "NOOP_DRIFT"} {
			t.Setenv(k, env[k])
		}
		if err := a.MaybeDrift(ctx); err != nil {
			t.Fatal(err)
		}
	}
	notified := func() []string {
		var out []string
		for _, r := range rec.got {
			out = append(out, r.Outcome)
		}
		rec.got = nil
		return out
	}

	// First check runs right away; clean, nothing to tell (an unguarded Exec
	// or a docker_compose "created (noop)" is no drift).
	check(nil)
	if d := a.state.Drift; !d.OK || d.Changes != 0 || d.Commit != c.String() {
		t.Fatalf("clean: %+v", d)
	}
	if n := notified(); len(n) != 0 {
		t.Fatalf("clean notified: %v", n)
	}
	// Same day, slot not yet reached: no new run.
	before := a.state.Drift.Time
	clock = clock.Add(time.Hour)
	check(map[string]string{"NOOP_DRIFT": "/etc/a"})
	if a.state.Drift.Time != before {
		t.Fatal("ran before the slot")
	}
	// Past 03:17: drift, notified once, not again for the same drift.
	clock = clock.Add(time.Hour)
	check(map[string]string{"NOOP_DRIFT": "/etc/a"})
	if d := a.state.Drift; d.Changes != 1 || d.Fingerprint == "" {
		t.Fatalf("drift: %+v", d)
	}
	if n := notified(); len(n) != 1 || n[0] != "drift" {
		t.Fatalf("drift notified: %v", n)
	}
	clock = clock.Add(24 * time.Hour)
	check(map[string]string{"NOOP_DRIFT": "/etc/a"})
	if n := notified(); len(n) != 0 {
		t.Fatalf("same drift notified again: %v", n)
	}
	// Other drift: notified.
	clock = clock.Add(24 * time.Hour)
	check(map[string]string{"NOOP_DRIFT": "/etc/b"})
	if n := notified(); len(n) != 1 || n[0] != "drift" {
		t.Fatalf("new drift notified: %v", n)
	}
	// Lock busy: postponed, no state change, retried on the next call.
	clock = clock.Add(24 * time.Hour)
	last := a.state.Drift.Time
	check(map[string]string{"NOOP_BUSY": "1"})
	if a.state.Drift.Time != last {
		t.Fatal("busy lock recorded as a run")
	}
	// Failure, then clean again: both notified.
	check(map[string]string{"NOOP_FAIL": "1"})
	if d := a.state.Drift; d.OK || d.Errors != 1 {
		t.Fatalf("failure: %+v", d)
	}
	if n := notified(); len(n) != 1 || n[0] != "failure" {
		t.Fatalf("failure notified: %v", n)
	}
	clock = clock.Add(24 * time.Hour)
	check(nil)
	if n := notified(); len(n) != 1 || n[0] != "clean" {
		t.Fatalf("clean again notified: %v", n)
	}

	data, err := os.ReadFile(a.cfg.MetricsFile)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`homelab_deploy_drift_success{host="test"} 1`,
		`homelab_deploy_drift_resource_changes{host="test"} 0`,
		`homelab_deploy_drift_last_run_timestamp_seconds{host="test"} ` + fmt.Sprint(clock.Unix()),
	} {
		if !strings.Contains(string(data), want) {
			t.Errorf("metrics lack %q:\n%s", want, data)
		}
	}
	// A noop agent never runs the drift check.
	a.cfg.Mode = "noop"
	a.state.Drift = DriftState{}
	check(nil)
	if !a.state.Drift.Time.IsZero() {
		t.Error("noop agent ran the drift check")
	}
}

func TestDriftSlot(t *testing.T) {
	loc := time.FixedZone("x", 3600)
	s, _ := driftSlot(time.Date(2026, 11, 16, 3, 16, 0, 0, loc), "03:17")
	if !s.Equal(time.Date(2026, 11, 15, 3, 17, 0, 0, loc)) {
		t.Errorf("before slot: %v", s)
	}
	s, _ = driftSlot(time.Date(2026, 11, 16, 3, 17, 0, 0, loc), "03:17")
	if !s.Equal(time.Date(2026, 11, 16, 3, 17, 0, 0, loc)) {
		t.Errorf("at slot: %v", s)
	}
	if _, err := driftSlot(time.Now(), "3:17pm"); err == nil {
		t.Error("bad time accepted")
	}
}

// maintScript applies like applyScript and prints what roles::base would:
// the maintenance env, and the reboot line when MAINT_REBOOT is set.
const maintScript = "#!/bin/bash\n[ \"$2\" = apply ] || exit 3\n" +
	"[ -z \"$MAINT_BUSY\" ] || { echo 'another deploy holds /run/homelab-deploy.lock'; exit 1; }\n" +
	"echo \"applied $DEPLOY_COMMIT maint=$OPENVOX_WEEKLY_MAINTENANCE\" >> \"$APPLY_LOG\"\n" +
	"[ -z \"$MAINT_REBOOT\" ] || echo 'Notice: /Stage[main]/Roles::Base/Reboot[base-reboot-after-run]: Scheduling system reboot'\n" +
	"[ -z \"$APPLY_FAIL\" ] || { echo 'Error: boom'; exit 1; }\n"

func TestMaintenance(t *testing.T) {
	o := newOrigin(t)
	c := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": maintScript}, false)
	o.request(c, nil, false)
	rec := &recorder{}
	a, log := newAgent(t, o, rec)
	w, _ := maintwindow.Parse("Sun 01:20 40m")
	a.cfg.Maintenance = &w
	clock := time.Date(2026, 11, 22, 1, 25, 0, 0, time.Local) // a Sunday, in the window
	a.now = func() time.Time { return clock }
	ctx := context.Background()
	run := func(env map[string]string) {
		t.Helper()
		for _, k := range []string{"MAINT_BUSY", "MAINT_REBOOT", "APPLY_FAIL"} {
			t.Setenv(k, env[k])
		}
		if err := a.MaybeMaintenance(ctx); err != nil {
			t.Fatal(err)
		}
	}
	notified := func() []string {
		var out []string
		for _, r := range rec.got {
			out = append(out, r.Mode+":"+r.Outcome)
		}
		rec.got = nil
		return out
	}

	// Nothing applied yet: no maintenance.
	run(nil)
	if a.state.Maintenance.RequestID != "" {
		t.Fatalf("ran before any apply: %+v", a.state.Maintenance)
	}
	if r := a.mustPoll(t); r.Outcome != "success" {
		t.Fatalf("apply: %+v", r)
	}
	rec.got = nil
	os.Remove(log)

	// Busy lock: postponed, retried on the next call.
	run(map[string]string{"MAINT_BUSY": "1"})
	if a.state.Maintenance.RequestID != "" || len(notified()) != 0 {
		t.Fatalf("busy lock recorded: %+v", a.state.Maintenance)
	}
	// In the window: applies the last applied commit with maintenance on.
	run(map[string]string{"MAINT_REBOOT": "1"})
	m := a.state.Maintenance
	if m.Outcome != "success" || m.Commit != c.String() || !strings.HasPrefix(m.Detail, "rebooting") {
		t.Fatalf("maintenance: %+v", m)
	}
	if n := notified(); len(n) != 1 || n[0] != "maintenance:success" {
		t.Fatalf("notified: %v", n)
	}
	data, _ := os.ReadFile(log)
	if got := string(data); got != "applied "+c.String()+" maint=true\n" {
		t.Fatalf("apply log: %q", got)
	}
	// Once per window.
	clock = clock.Add(10 * time.Minute)
	run(nil)
	if a.state.Maintenance.Time != m.Time {
		t.Fatal("ran twice in one window")
	}
	// After the window (the host was down during it): not run late.
	clock = time.Date(2026, 11, 29, 2, 5, 0, 0, time.Local)
	run(nil)
	if a.state.Maintenance.Time != m.Time {
		t.Fatal("ran after the window")
	}
	// Next week: runs again; a failure is reported.
	clock = time.Date(2026, 12, 6, 1, 21, 0, 0, time.Local)
	run(map[string]string{"APPLY_FAIL": "1"})
	if a.state.Maintenance.Outcome != "failure" {
		t.Fatalf("failure: %+v", a.state.Maintenance)
	}
	if n := notified(); len(n) != 1 || n[0] != "maintenance:failure" {
		t.Fatalf("failure notified: %v", n)
	}
	// An agent that stopped mid-apply reports it once on the next call.
	a.state.Maintenance.Outcome = "running"
	run(nil)
	if n := notified(); len(n) != 1 || n[0] != "maintenance:interrupted" {
		t.Fatalf("interrupted notified: %v", n)
	}

	metrics, _ := os.ReadFile(a.cfg.MetricsFile)
	if want := `homelab_deploy_maintenance_success{host="test"} 0`; !strings.Contains(string(metrics), want) {
		t.Errorf("metrics lack %q:\n%s", want, metrics)
	}
	// A deploy request no longer turns maintenance on by its trigger.
	for _, e := range (Request{Trigger: "schedule"}).Env() {
		if e == "OPENVOX_WEEKLY_MAINTENANCE=true" {
			t.Error("schedule trigger still sets maintenance")
		}
	}
}
