package deployagent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// rebootLine is what the apply prints when roles::base schedules the gated
// reboot (needs-restarting -r found updates that need one).
const rebootLine = "Reboot[base-reboot-after-run]"

// MaybeMaintenance runs the weekly maintenance (Config.Maintenance): an
// apply of the last applied commit with docker prune and the gated reboot
// on (roles::base's $docker_prune_enabled and $reboot_if_needed), once per
// window and only while the window is open, so a host that was down never
// reboots late. A busy host lock leaves it for the next poll. Only on an
// agent that applies and has applied something.
func (a *Agent) MaybeMaintenance(ctx context.Context) error {
	if a.state.Maintenance.Outcome == "running" {
		// The agent stopped during the apply: the reboot came before the
		// apply script returned, or the agent was killed.
		m := &a.state.Maintenance
		m.Outcome, m.Detail = "interrupted", "the agent stopped during the maintenance apply (reboot?)"
		if err := a.saveState(); err != nil {
			return err
		}
		if err := a.queue(*m); err != nil {
			return err
		}
		a.flushOutbox(ctx)
	}
	w := a.cfg.Maintenance
	if w == nil || a.cfg.Mode != "apply" || a.state.LastApplied == "" {
		return nil
	}
	now := a.now()
	if !w.Contains(now) || !a.state.Maintenance.Time.Before(w.Start(now)) {
		return nil
	}
	if _, err := os.Stat(a.cfg.SuspendFile); err == nil {
		a.cfg.Log.Info("maintenance skipped: suspended", "file", a.cfg.SuspendFile)
		return nil
	}
	defer a.writeMetrics()
	defer a.flushOutbox(ctx)

	req := Request{
		ID: now.UTC().Format("20060102T150405Z") + "-maintenance", Host: a.cfg.Host,
		Commit: a.state.LastApplied, Trigger: "maintenance", DockerPrune: true, RebootIfNeeded: true,
	}
	prev := a.state.Maintenance
	// Recorded before the apply: it may end in a reboot.
	a.state.Maintenance = Result{
		RequestID: req.ID, Host: a.cfg.Host, Commit: req.Commit, Mode: "maintenance", Outcome: "running", Time: now,
	}
	if err := a.saveState(); err != nil {
		return err
	}
	out, err := a.apply(ctx, req, "")
	if err != nil && strings.Contains(out, lockBusy) {
		a.cfg.Log.Info("maintenance postponed: host lock busy")
		os.RemoveAll(filepath.Join(a.cfg.StateDir, "releases", req.ID))
		a.state.Maintenance = prev
		return a.saveState()
	}
	m := &a.state.Maintenance
	m.Duration = time.Since(now).Seconds()
	m.Changes, m.Errors = countApplyLines(out)
	switch {
	case err != nil:
		m.Outcome, m.Detail = "failure", fmt.Sprintf("%v\n%s", err, tail(out, 40))
	case strings.Contains(out, rebootLine):
		m.Outcome, m.Detail = "success", "rebooting to activate updates\n"+tail(out, 15)
	default:
		m.Outcome, m.Detail = "success", "no reboot needed\n"+tail(out, 15)
	}
	a.cfg.Log.Info("maintenance", "commit", m.Commit, "outcome", m.Outcome, "changes", m.Changes, "errors", m.Errors)
	if err := a.saveState(); err != nil {
		return err
	}
	return a.queue(*m)
}
