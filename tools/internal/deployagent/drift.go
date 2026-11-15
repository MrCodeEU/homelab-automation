package deployagent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// DriftState is the last daily drift check: a noop of the last applied
// commit, which shows what changed on the host since (by hand, by a package
// update, ...). It replaced the openvox-drift.yml noop over SSH.
type DriftState struct {
	Time    time.Time `json:"time"`
	Commit  string    `json:"commit"`
	Changes int       `json:"resource_changes"`
	Errors  int       `json:"error_lines"`
	OK      bool      `json:"ok"`
	// Fingerprint names what drifted ("" when nothing did); Notified is the
	// fingerprint last notified, so the same drift is reported once.
	Fingerprint string `json:"fingerprint"`
	Notified    string `json:"notified"`
}

var (
	// Only attributes that report a real before/after value. Execs without
	// a guard "would run" on every noop and are no drift (same filter as
	// the former openvox-drift.yml).
	driftLine = regexp.MustCompile(`/(ensure|content|mode|owner|group): .* changed `)
	// The resource and attribute of a drift line, without the values.
	driftKey = regexp.MustCompile(`^Notice: (\S+/(?:ensure|content|mode|owner|group)):`)
)

// lockBusy is what openvox-apply.sh prints when a deploy holds the host lock.
const lockBusy = "another deploy holds /run/homelab-deploy.lock"

// driftSlot is the newest daily slot at or before now ("HH:MM", local time).
func driftSlot(now time.Time, at string) (time.Time, error) {
	t, err := time.Parse("15:04", at)
	if err != nil {
		return time.Time{}, fmt.Errorf("drift time %q: want HH:MM", at)
	}
	slot := time.Date(now.Year(), now.Month(), now.Day(), t.Hour(), t.Minute(), 0, 0, now.Location())
	if slot.After(now) {
		slot = slot.AddDate(0, 0, -1)
	}
	return slot, nil
}

// MaybeDrift runs the drift check when its daily slot (Config.DriftAt) has
// passed since the last one, and right away when there was none yet. Only
// on an agent that applies and has applied something. A busy host lock
// leaves it for the next poll.
func (a *Agent) MaybeDrift(ctx context.Context) error {
	if a.cfg.DriftAt == "" || a.cfg.Mode != "apply" || a.state.LastApplied == "" {
		return nil
	}
	slot, err := driftSlot(a.now(), a.cfg.DriftAt)
	if err != nil {
		return err
	}
	if !a.state.Drift.Time.IsZero() && !a.state.Drift.Time.Before(slot) {
		return nil
	}
	defer a.writeMetrics()
	defer a.flushOutbox(ctx)

	commit := a.state.LastApplied
	out, runErr := a.noop(ctx, commit)
	if runErr != nil && strings.Contains(out, lockBusy) {
		a.cfg.Log.Info("drift check postponed: host lock busy")
		return nil
	}
	var lines, keys []string
	errs := 0
	for _, l := range strings.Split(out, "\n") {
		if driftLine.MatchString(l) && !a.driftIgnored(l) {
			lines = append(lines, l)
			if m := driftKey.FindStringSubmatch(l); m != nil {
				keys = append(keys, m[1])
			} else {
				keys = append(keys, l)
			}
		}
		if errorLine.MatchString(l) {
			errs++
		}
	}
	d := DriftState{
		Time: a.now(), Commit: commit, Changes: len(lines), Errors: errs,
		OK: runErr == nil && errs == 0, Notified: a.state.Drift.Notified,
	}
	if !d.OK {
		d.Fingerprint = "noop failed"
	} else if len(keys) > 0 {
		sort.Strings(keys)
		sum := sha256.Sum256([]byte(strings.Join(keys, "\n")))
		d.Fingerprint = hex.EncodeToString(sum[:8])
	}
	a.cfg.Log.Info("drift check", "commit", commit, "changes", d.Changes, "errors", d.Errors, "ok", d.OK)

	var queued *Result
	if d.Fingerprint != d.Notified {
		res := Result{
			RequestID: "drift-" + d.Time.Format("20060102T150405"), Host: a.cfg.Host, Commit: commit,
			Mode: "drift", Time: d.Time,
		}
		switch {
		case !d.OK:
			res.Outcome, res.Detail = "failure", tail(out, 15)
		case d.Fingerprint == "":
			res.Outcome, res.Detail = "clean", "no drift any more"
		default:
			res.Outcome, res.Detail = "drift", tail(strings.Join(lines, "\n"), 15)
		}
		queued = &res
		d.Notified = d.Fingerprint
	}
	a.state.Drift = d
	if err := a.saveState(); err != nil {
		return err
	}
	if queued != nil {
		return a.queue(*queued)
	}
	return nil
}

func (a *Agent) driftIgnored(line string) bool {
	for _, r := range a.cfg.DriftIgnore {
		if r != "" && strings.Contains(line, "/"+r+"/") {
			return true
		}
	}
	return false
}

// noop exports commit (kept between checks) and runs the apply script on
// it in noop mode.
func (a *Agent) noop(ctx context.Context, commit string) (string, error) {
	dir := filepath.Join(a.cfg.StateDir, "drift", commit)
	if _, err := os.Stat(dir); err != nil {
		c, err := a.repo.Commit(commit)
		if err != nil {
			return "", err
		}
		os.RemoveAll(filepath.Join(a.cfg.StateDir, "drift"))
		if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
			return "", err
		}
		if err := Export(c, dir); err != nil {
			os.RemoveAll(dir)
			return "", fmt.Errorf("export: %w", err)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, a.cfg.ApplyTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/bash", filepath.Join(dir, a.cfg.Apply), dir, "noop")
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}
