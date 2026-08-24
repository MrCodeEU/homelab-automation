package healthreport

import (
	"fmt"
	"sort"
)

// Mounts that exist on every box and never say anything useful. /boot/efi
// and /efi are the same partition seen twice, and both sit at a permanent
// ~11%.
var boringMounts = map[string]bool{
	"/boot/efi": true, "/efi": true, "/dev/shm": true, "/run": true,
	"/var/lib/docker/overlay2": true,
}

// Below this a filesystem is not worth a row of its own in a summary that
// is meant to be skimmed.
const interestingUsedPercent = 50.0

// Fewer than this many days left on a credential is worth saying out loud,
// since nothing else in the estate will mention it until it breaks.
const tokenWarnDays = 30

func collectorData(facts *Facts, name string) *CollectorResult {
	if facts.Collectors == nil {
		return nil
	}
	return facts.Collectors[name]
}

func hostMetricsData(facts *Facts) *HostMetricsData {
	r := collectorData(facts, "host_metrics")
	if r == nil {
		return &HostMetricsData{}
	}
	d, _ := r.Data.(*HostMetricsData)
	if d == nil {
		return &HostMetricsData{}
	}
	return d
}

func humanizeUptime(seconds int64, ok bool) string {
	if !ok {
		return "?"
	}
	days := seconds / 86400
	if days >= 1 {
		return fmt.Sprintf("%dd", days)
	}
	return fmt.Sprintf("%dh", seconds/3600)
}

type StateFilesystem struct {
	Mountpoint  string  `json:"mountpoint"`
	UsedPercent float64 `json:"used_percent"`
}

type StateHost struct {
	Name          string            `json:"name"`
	MemoryPercent *float64          `json:"memory_percent"`
	LoadPerCore   *float64          `json:"load_per_core"`
	Uptime        string            `json:"uptime"`
	Filesystems   []StateFilesystem `json:"filesystems"`
}

// StateHosts returns per-host vitals, worst filesystem first.
func StateHosts(facts *Facts) []StateHost {
	metrics := hostMetricsData(facts)

	memory := map[string]float64{}
	var order []string
	seenName := map[string]bool{}
	addName := func(name string) {
		if !seenName[name] {
			seenName[name] = true
			order = append(order, name)
		}
	}
	for _, m := range metrics.Memory {
		memory[m.Instance] = m.UsedPercent
		addName(m.Instance)
	}
	load := map[string]float64{}
	for _, l := range metrics.LoadPerCore {
		load[l.Instance] = l.Load15PerCore
		addName(l.Instance)
	}
	uptime := map[string]int64{}
	for _, u := range metrics.UptimeSeconds {
		uptime[u.Instance] = u.Uptime
		addName(u.Instance)
	}
	filesystems := map[string][]StateFilesystem{}
	for _, fs := range metrics.Filesystems {
		if fs.Mountpoint == "" || boringMounts[fs.Mountpoint] {
			continue
		}
		filesystems[fs.Instance] = append(filesystems[fs.Instance], StateFilesystem{
			Mountpoint: fs.Mountpoint, UsedPercent: fs.UsedPercent,
		})
		addName(fs.Instance)
	}

	sort.Strings(order)

	out := make([]StateHost, 0, len(order))
	for _, name := range order {
		mounts := append([]StateFilesystem{}, filesystems[name]...)
		sort.SliceStable(mounts, func(i, j int) bool { return mounts[i].UsedPercent > mounts[j].UsedPercent })

		var notable []StateFilesystem
		for _, m := range mounts {
			if m.UsedPercent >= interestingUsedPercent {
				notable = append(notable, m)
			}
		}
		display := notable
		if len(display) == 0 && len(mounts) > 0 {
			display = mounts[:1]
		}
		if len(display) > 4 {
			display = display[:4]
		}

		var memPct, loadPct *float64
		if v, ok := memory[name]; ok {
			memPct = &v
		}
		if v, ok := load[name]; ok {
			loadPct = &v
		}
		u, hasUptime := uptime[name]

		out = append(out, StateHost{
			Name: name, MemoryPercent: memPct, LoadPerCore: loadPct,
			Uptime: humanizeUptime(u, hasUptime), Filesystems: display,
		})
	}
	return out
}

type StateCount struct {
	Label string `json:"label"`
	Value int    `json:"value"`
}

// StateCounts is the one-line totals row, the "is the shape of the estate
// still what I expect" row.
func StateCounts(facts *Facts) []StateCount {
	var out []StateCount
	if r := collectorData(facts, "containers"); r != nil {
		if d, ok := r.Data.(*ContainersData); ok {
			out = append(out, StateCount{"Containers", d.CurrentCount})
		}
	}
	if r := collectorData(facts, "uptime_kuma"); r != nil {
		if d, ok := r.Data.(*KumaData); ok {
			out = append(out, StateCount{"Monitors", d.MonitorCount})
		}
	}
	if r := collectorData(facts, "github"); r != nil {
		if d, ok := r.Data.(*GithubData); ok {
			out = append(out, StateCount{"Repos", d.RepoCount})
		}
	}
	if r := collectorData(facts, "homeassistant"); r != nil {
		if d, ok := r.Data.(*HomeAssistantData); ok {
			out = append(out, StateCount{"HA entities", d.EntityCount})
		}
	}
	return out
}

type BackupTargetState struct {
	Host        string   `json:"host"`
	Name        string   `json:"name"`
	Kind        string   `json:"kind"`
	UsedPercent *float64 `json:"used_percent"`
	FreeGiB     *int64   `json:"free_gib"`
	TotalGiB    *int64   `json:"total_gib"`
	Note        string   `json:"note,omitempty"`
}

func sshFactsPayloads(facts *Facts) map[string]map[string]any {
	r := collectorData(facts, "ssh_facts")
	if r == nil {
		return nil
	}
	d, _ := r.Data.(*SSHFactsData)
	if d == nil {
		return nil
	}
	return d.Payloads
}

// StateBackupTargets returns where backups land, and how much room is left
// there. Sourced from the per-host facts payload rather than a collector of
// its own, because only the NAS holds the rclone config and the backup
// share.
func StateBackupTargets(facts *Facts) []BackupTargetState {
	payloads := sshFactsPayloads(facts)
	hosts := make([]string, 0, len(payloads))
	for h := range payloads {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)

	var out []BackupTargetState
	for _, host := range hosts {
		data, ok := factsSection(payloads[host], "backup_targets")
		if !ok {
			continue
		}
		targets, _ := data["targets"].([]any)
		for _, raw := range targets {
			target, _ := raw.(map[string]any)
			if target == nil {
				continue
			}
			entry := BackupTargetState{Host: host}
			entry.Name, _ = target["name"].(string)
			entry.Kind, _ = target["kind"].(string)
			if v, ok := numeric(target["used_percent"]); ok {
				entry.UsedPercent = &v
			}
			if free, ok := numeric(target["free_bytes"]); ok && free != 0 {
				g := int64(free / (1024.0 * 1024.0 * 1024.0))
				entry.FreeGiB = &g
			}
			if total, ok := numeric(target["total_bytes"]); ok && total != 0 {
				g := int64(total / (1024.0 * 1024.0 * 1024.0))
				entry.TotalGiB = &g
			}
			if !truthy(target["quota_supported"]) {
				entry.Note = "no quota API"
			} else if truthy(target["error"]) {
				entry.Note = "unreachable"
			}
			out = append(out, entry)
		}
	}
	return out
}

// StateNotes returns short informational lines that have no home in the
// severity table.
func StateNotes(facts *Facts) []string {
	var out []string

	if r := collectorData(facts, "github"); r != nil {
		if d, ok := r.Data.(*GithubData); ok && d.TokenExpiresInDays != nil && *d.TokenExpiresInDays <= tokenWarnDays {
			out = append(out, fmt.Sprintf("GitHub token expires in %d days", *d.TokenExpiresInDays))
		}
	}

	// CrowdSec throughput, purely informational: what the edge actually
	// stopped. unparsed_percent is the one worth watching over time - a
	// parser that stops understanding its log silently stops protecting
	// anything.
	payloads := sshFactsPayloads(facts)
	hosts := make([]string, 0, len(payloads))
	for h := range payloads {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	for _, host := range hosts {
		data, ok := factsSection(payloads[host], "crowdsec")
		if !ok {
			continue
		}
		metrics, _ := data["metrics"].(map[string]any)
		if len(metrics) == 0 {
			continue
		}
		droppedBytes, _ := numeric(metrics["dropped_bytes"])
		droppedGiB := droppedBytes / (1024.0 * 1024.0 * 1024.0)
		activeDecisions, _ := numeric(metrics["active_decisions"])
		droppedPackets, _ := numeric(metrics["dropped_packets"])
		unparsedPercent, _ := numeric(metrics["unparsed_percent"])
		out = append(out, fmt.Sprintf(
			"CrowdSec on %s: %s active decisions, %s packets dropped (%.1f GiB), %.1f%% of log lines unparsed",
			host, formatThousands(activeDecisions), formatThousands(droppedPackets), droppedGiB, unparsedPercent,
		))
	}

	if r := collectorData(facts, "homeassistant"); r != nil {
		if d, ok := r.Data.(*HomeAssistantData); ok {
			if d.Version != "" {
				out = append(out, "Home Assistant "+d.Version)
			}
			for _, u := range d.UpdatesAvailable {
				out = append(out, fmt.Sprintf("Update available: %s %s → %s", u.Name, u.Installed, u.Latest))
			}
		}
	}

	return out
}
