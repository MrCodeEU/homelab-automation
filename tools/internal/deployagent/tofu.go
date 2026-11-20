package deployagent

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// The Ziti services and policies (ziti/tofu/) are applied by the agent on
// the controller host after each successful apply, with the same
// commit's tree: `bash <tree>/<Config.Tofu> auto` (scripts/ziti-tofu.sh).
// The script applies additions and in-place changes and holds a plan that
// deletes or replaces anything (exit 3) for a person. The daily drift
// check runs its `check` (a plan) next to the noop.

// tofuHeld is the script's exit code for a plan that waits for a person.
const tofuHeld = 3

var (
	// "  # ziti_service.x will be updated in-place", "... must be replaced"
	tofuPlanLine = regexp.MustCompile(`^\s*# (\S+) (?:will|must) be (.+)$`)
	tofuApplied  = regexp.MustCompile(`Apply complete! Resources: (\d+) added, (\d+) changed, (\d+) destroyed`)
)

// runTofu runs the tofu script of tree with one command.
func (a *Agent) runTofu(ctx context.Context, tree, command string) (string, int, error) {
	ctx, cancel := context.WithTimeout(ctx, a.cfg.ApplyTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/bash", filepath.Join(tree, a.cfg.Tofu), command)
	cmd.Dir = tree
	cmd.Env = append(os.Environ(), "ZITI_TOFU_LOCAL=1")
	out, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return string(out), exit.ExitCode(), err
	}
	if err != nil {
		return string(out), -1, err
	}
	return string(out), 0, nil
}

// tofuApply runs `auto` for an applied request. The result is nil when the
// plan had no changes: nothing to report.
func (a *Agent) tofuApply(ctx context.Context, applied Result) *Result {
	tree := filepath.Join(a.cfg.StateDir, "releases", applied.RequestID)
	start := a.now()
	out, code, err := a.runTofu(ctx, tree, "auto")
	res := Result{
		RequestID: applied.RequestID, Host: a.cfg.Host, Commit: applied.Commit, Mode: "ziti-tofu",
		Time: start, Duration: a.now().Sub(start).Seconds(),
	}
	planned := tofuPlanned(out)
	switch {
	case err == nil && strings.Contains(out, "No changes."):
		a.cfg.Log.Info("ziti tofu: no changes", "commit", applied.Commit)
		return nil
	case err == nil:
		res.Outcome = "success"
		if m := tofuApplied.FindStringSubmatch(out); m != nil {
			for _, n := range m[1:] {
				v, _ := strconv.Atoi(n)
				res.Changes += v
			}
		}
		res.Detail = strings.Join(planned, "\n")
		if m := tofuApplied.FindString(out); m != "" {
			res.Detail += "\n" + m
		}
	case code == tofuHeld:
		res.Outcome = "held"
		res.Changes = len(planned)
		res.Detail = tail(out, 20)
	default:
		res.Outcome = "failure"
		res.Errors = 1
		res.Detail = fmt.Sprintf("%v\n%s", err, tail(out, 20))
	}
	a.cfg.Log.Info("ziti tofu", "commit", applied.Commit, "outcome", res.Outcome, "changes", res.Changes)
	return &res
}

// tofuPlanned lists the plan's resource lines ("x will be created").
func tofuPlanned(out string) []string {
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if m := tofuPlanLine.FindStringSubmatch(l); m != nil {
			lines = append(lines, m[1]+" "+m[2])
		}
	}
	return lines
}

// tofuDrift runs `check` on tree. It returns the drifted resources as
// drift lines and keys, and whether the check itself failed.
func (a *Agent) tofuDrift(ctx context.Context, tree string) (lines []string, failed bool, out string) {
	out, code, err := a.runTofu(ctx, tree, "check")
	switch {
	case err == nil:
		return nil, false, out
	case code == 2: // plan -detailed-exitcode: there are changes
		for _, l := range tofuPlanned(out) {
			lines = append(lines, "Ziti tofu: "+l)
		}
		return lines, false, out
	default:
		return nil, true, out
	}
}
