package healthreport

import (
	"fmt"
	"os"
	"sort"
	"time"
)

type RunInfo struct {
	ID        string `json:"id"`
	StartedAt string `json:"started_at"`
	Host      string `json:"host"`
}

type Summary struct {
	Crit             int      `json:"crit"`
	Warn             int      `json:"warn"`
	Info             int      `json:"info"`
	CollectorsFailed []string `json:"collectors_failed"`
	SeenPruned       int      `json:"seen_pruned,omitempty"`
}

type Facts struct {
	SchemaVersion  int                          `json:"schema_version"`
	Run            RunInfo                      `json:"run"`
	Collectors     map[string]*CollectorResult  `json:"collectors"`
	Observations   []*Observation               `json:"observations"`
	Diff           DiffResult                   `json:"diff"`
	Summary        Summary                      `json:"summary"`
	LLMStatus      string                       `json:"llm_status"`
	DeliveryErrors []string                     `json:"delivery_errors,omitempty"`
}

// CollectorFn is the signature every collector implements.
type CollectorFn func(cfg Config, rules RulesFile) *CollectorResult

var Registry = map[string]CollectorFn{}

func RegisterCollector(name string, fn CollectorFn) {
	Registry[name] = fn
}

// RunCollector wraps a collector so that a panic or error is recorded as a
// CollectorResult rather than killing the run - a broken collector is
// itself something the report must say out loud.
func RunCollector(name string, fn CollectorFn, cfg Config, rules RulesFile) (result *CollectorResult) {
	started := time.Now()
	defer func() {
		if r := recover(); r != nil {
			result = &CollectorResult{
				Name: name, Status: "error",
				Error:     fmt.Sprintf("panic: %v", r),
				DurationS: time.Since(started).Seconds(),
			}
		}
	}()
	result = fn(cfg, rules)
	result.Name = name
	result.DurationS = time.Since(started).Seconds()
	return result
}

func RunCollectors(cfg Config, rules RulesFile, names []string) map[string]*CollectorResult {
	results := map[string]*CollectorResult{}
	for _, name := range names {
		fn, ok := Registry[name]
		if !ok {
			continue
		}
		results[name] = RunCollector(name, fn, cfg, rules)
	}
	return results
}

// CollectorHealth: a collector that did not run is itself a finding.
// Without this, a broken collector looks exactly like a clean bill of
// health - which is the failure mode this whole report exists to prevent.
func CollectorHealth(results map[string]*CollectorResult) []*Observation {
	var out []*Observation
	names := make([]string, 0, len(results))
	for name := range results {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		result := results[name]
		if result.Status == "ok" {
			continue
		}
		out = append(out, &Observation{
			ID: "collector_failed." + name + ".", Collector: "collector_health",
			Subject: name, Kind: "collector_failed", Value: result.Status,
			Message:  fmt.Sprintf("collector %s did not complete: %s", name, result.Error),
			Severity: "info",
			Evidence: map[string]any{"status": result.Status, "error": result.Error},
		})
	}
	return out
}

// WdCloudBackupTargetUsage is a cross-collector correlation: give wd-cloud
// a real backup_target_usage. ssh_facts's backup_target_usage loop skips
// wd-cloud outright - rclone about has no quota API over SFTP, a real and
// permanent protocol limitation. But the same disk is separately monitored
// via wd-mycloud-node-exporter -> victoria's disk_usage query, collected in
// the same report run. Synthesize the missing observation from that
// instead of leaving the report silent on it.
func WdCloudBackupTargetUsage(observations []*Observation) []*Observation {
	var diskUsage *Observation
	for _, obs := range observations {
		if obs.ID == "disk_usage.wd-mycloud./mnt/HD/HD_a2" {
			diskUsage = obs
			break
		}
	}
	if diskUsage == nil {
		return nil
	}
	for _, obs := range observations {
		if obs.Kind == "backup_target_usage" && obs.Subject == "nas" {
			if kind, ok := obs.Evidence["kind"]; ok && kind == "wd_cloud" {
				return nil
			}
		}
	}
	return []*Observation{{
		ID: "backup_target_usage.nas.wd-cloud", Collector: "ssh_facts",
		Subject: "nas", Kind: "backup_target_usage", Value: diskUsage.Value,
		Unit: "percent", Severity: "info",
		Message: fmt.Sprintf("backup target wd-cloud is %.1f%% full (derived from wd-mycloud's own "+
			"disk usage - rclone has no quota API over SFTP)", asFloat(diskUsage.Value)),
		Evidence: map[string]any{"kind": "wd_cloud", "source": diskUsage.ID},
	}}
}

func asFloat(v any) float64 {
	f, _ := numeric(v)
	return f
}

// Assemble runs classification and diffing over collected results and
// returns the facts payload plus the seen-state to persist.
func Assemble(cfg Config, rules RulesFile, results map[string]*CollectorResult, now time.Time) (*Facts, map[string]*SeenRecord) {
	observations := []*Observation{}
	for _, result := range results {
		observations = append(observations, result.Observations...)
	}
	observations = append(observations, CollectorHealth(results)...)
	observations = append(observations, WdCloudBackupTargetUsage(observations)...)

	stateDir := cfg.StateDir
	previous := LoadPrevious(stateDir)
	seen := LoadSeen(stateDir)

	// First run: nothing is known, so every log signature would look new
	// and the report would be pure noise. Suppress new_only escalation
	// instead.
	candidateNew := map[string]bool{}
	if len(seen) > 0 {
		for _, obs := range observations {
			if _, known := seen[obs.ID]; !known {
				candidateNew[obs.ID] = true
			}
		}
	}

	// Spike rules compare against the last run, so the previous values
	// must be attached before classification. The full diff runs after,
	// because it diffs the severities classification produces.
	AttachPreviousValues(observations, seen)
	Apply(observations, rules, candidateNew, &now)

	nowISO := now.Format(time.RFC3339)
	diffResult := Compute(observations, previous, seen, nowISO)

	counts := map[string]int{"crit": 0, "warn": 0, "info": 0}
	for _, obs := range observations {
		counts[obs.Severity]++
	}

	failed := []string{}
	for name, result := range results {
		if result.Status != "ok" {
			failed = append(failed, name)
		}
	}
	sort.Strings(failed)

	hostname, _ := os.Hostname()
	facts := &Facts{
		SchemaVersion: 1,
		Run: RunInfo{
			ID:        now.Format("2006-01-02T15:04"),
			StartedAt: nowISO,
			Host:      hostname,
		},
		Collectors:   results,
		Observations: observations,
		Diff:         diffResult,
		Summary: Summary{
			Crit: counts["crit"], Warn: counts["warn"], Info: counts["info"],
			CollectorsFailed: failed,
		},
		LLMStatus: "not_run",
	}
	return facts, seen
}
