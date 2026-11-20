package deployagent

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/go-git/go-git/v5/plumbing"
)

// tofuScript fakes scripts/ziti-tofu.sh: TOFU_RESULT picks what auto
// does; check reports drift when TOFU_DRIFT is set.
const tofuScript = `#!/bin/bash
[ "$ZITI_TOFU_LOCAL" = 1 ] || { echo not local; exit 9; }
case $1 in
  auto)
    case $TOFU_RESULT in
      none) echo "No changes." ;;
      apply) echo "  # ziti_identity.phone will be created"; echo "  # ziti_service.kuma will be updated in-place"
             echo "Apply complete! Resources: 1 added, 1 changed, 0 destroyed." ;;
      held) echo "  # ziti_identity.phone must be replaced"; echo "HELD: the plan deletes or replaces resources"; exit 3 ;;
      *) echo "Error: boom"; exit 1 ;;
    esac ;;
  check)
    [ -n "$TOFU_DRIFT" ] || { echo "No changes."; exit 0; }
    echo "  # ziti_service.$TOFU_DRIFT will be updated in-place"; exit 2 ;;
esac
`

func TestTofuAfterApply(t *testing.T) {
	o := newOrigin(t)
	files := map[string]string{"scripts/apply.sh": applyScript, "scripts/ziti-tofu.sh": tofuScript}
	parent := plumbing.ZeroHash
	rec := &recorder{}
	var a *Agent
	for i, tc := range []struct {
		result, outcome string
		changes         int
	}{
		{"none", "", 0},
		{"apply", "success", 2},
		{"held", "held", 1},
		{"fail", "failure", 0},
	} {
		files["n"] = tc.result // a new commit per round
		c := o.commit("main", parent, files, false)
		parent = c
		o.request(c, nil, false)
		if a == nil {
			a, _ = newAgent(t, o, rec)
			a.cfg.Tofu = "scripts/ziti-tofu.sh"
		}
		t.Setenv("TOFU_RESULT", tc.result)
		rec.got = nil
		if r := a.mustPoll(t); r.Outcome != "success" {
			t.Fatalf("%d: apply %+v", i, r)
		}
		var tofu []Result
		for _, r := range rec.got {
			if r.Mode == "ziti-tofu" {
				tofu = append(tofu, r)
			}
		}
		if tc.outcome == "" {
			if len(tofu) != 0 {
				t.Fatalf("%s: notified %+v", tc.result, tofu)
			}
			continue
		}
		if len(tofu) != 1 || tofu[0].Outcome != tc.outcome || tofu[0].Changes != tc.changes || tofu[0].Commit != c.String() {
			t.Fatalf("%s: got %+v", tc.result, tofu)
		}
		if a.state.Tofu.Outcome != tc.outcome {
			t.Fatalf("%s: state %+v", tc.result, a.state.Tofu)
		}
		title, _ := summary(tofu[0])
		if !strings.HasPrefix(title, "Ziti tofu ") {
			t.Errorf("title %q", title)
		}
	}
	if !strings.Contains(a.state.Tofu.Detail, "boom") {
		t.Errorf("failure detail %q", a.state.Tofu.Detail)
	}
}

func TestTofuNotInNoopMode(t *testing.T) {
	o := newOrigin(t)
	c := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": noopScript, "scripts/ziti-tofu.sh": tofuScript}, false)
	o.request(c, nil, false)
	rec := &recorder{}
	a, _ := newAgent(t, o, rec)
	a.cfg.Mode, a.cfg.Tofu = "noop", "scripts/ziti-tofu.sh"
	t.Setenv("TOFU_RESULT", "apply")
	a.mustPoll(t)
	for _, r := range rec.got {
		if r.Mode == "ziti-tofu" {
			t.Fatalf("tofu ran in noop mode: %+v", r)
		}
	}
}

func TestTofuDrift(t *testing.T) {
	o := newOrigin(t)
	c := o.commit("main", plumbing.ZeroHash, map[string]string{"scripts/apply.sh": driftScript, "scripts/ziti-tofu.sh": tofuScript}, false)
	o.request(c, nil, false)
	rec := &recorder{}
	a, _ := newAgent(t, o, rec)
	a.cfg.DriftAt, a.cfg.Tofu = "03:17", "scripts/ziti-tofu.sh"
	a.cfg.DriftIgnore = []string{"File[/stamp]"}
	clock := time.Date(2026, 11, 16, 4, 0, 0, 0, time.Local)
	a.now = func() time.Time { return clock }
	t.Setenv("TOFU_RESULT", "none")
	a.mustPoll(t)
	rec.got = nil

	t.Setenv("TOFU_DRIFT", "kuma")
	if err := a.MaybeDrift(context.Background()); err != nil {
		t.Fatal(err)
	}
	d := a.state.Drift
	if !d.OK || d.Changes != 1 || len(rec.got) != 1 || rec.got[0].Outcome != "drift" ||
		!strings.Contains(rec.got[0].Detail, "Ziti tofu: ziti_service.kuma updated in-place") {
		t.Fatalf("drift %+v, notified %+v", d, rec.got)
	}
}
