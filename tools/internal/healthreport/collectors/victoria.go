// Host and container facts from VictoriaMetrics. Grafana Alloy already
// ships node, cadvisor and CrowdSec metrics from mljr and nuc (and nas once
// services/nas-alloy is deployed), so nearly everything here is a PromQL
// query rather than a login to a box.
package collectors

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// Session-scope units flap on every SSH/console login and carry no signal.
var systemdNoise = regexp.MustCompile(`^session-c?\d+\.scope$`)

// Pseudo-filesystems that are always ~100% full or always empty, and say
// nothing about the health of the machine.
const fsExclude = `fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs|fuse.*|iso9660|autofs"`

type diskFillKey struct{ host, mount string }

// Retired-but-kept mounts: not receiving new data, so predict_linear's
// 7-day window keeps extrapolating a one-time historical drop as an
// ongoing trend forever.
var diskFillProjectionExclude = map[diskFillKey]bool{{"nas", "/mnt/cache"}: true}

type vmSample struct {
	metric map[string]string
	value  float64
}

func vmQuery(cfg hr.Config, promql string) ([]vmSample, error) {
	resp, err := httpGet(
		cfg.VictoriaURL+"/api/v1/query?"+url.Values{"query": {promql}}.Encode(),
		30*time.Second, nil,
	)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var payload struct {
		Status string `json:"status"`
		Error  string `json:"error"`
		Data   struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Value  [2]any            `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Status != "success" {
		return nil, fmt.Errorf("query failed: %s", payload.Error)
	}
	out := make([]vmSample, 0, len(payload.Data.Result))
	for _, series := range payload.Data.Result {
		s, ok := series.Value[1].(string)
		if !ok {
			continue
		}
		v, err := strconv.ParseFloat(s, 64)
		if err != nil {
			continue
		}
		out = append(out, vmSample{metric: series.Metric, value: v})
	}
	return out, nil
}

func metricHost(m map[string]string) string {
	if v, ok := m["instance"]; ok {
		return v
	}
	return "unknown"
}

func round2(v float64) float64 { return float64(int64(v*100+sign(v)*0.5)) / 100 }
func sign(v float64) float64 {
	if v < 0 {
		return -1
	}
	return 1
}

func init() {
	hr.RegisterCollector("host_metrics", collectHostMetrics)
	hr.RegisterCollector("containers", collectContainers)
}

func collectHostMetrics(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("host_metrics")
	data := &hr.HostMetricsData{MetricsAgeSeconds: map[string]float64{}}

	grafanaEvidence := func(promql string) map[string]any {
		return map[string]any{"promql": promql, "grafana_url": cfg.GrafanaURL}
	}

	// --- filesystems ---
	promql := fmt.Sprintf(
		"100 - (node_filesystem_avail_bytes{%s} / node_filesystem_size_bytes{%s} * 100)", fsExclude, fsExclude,
	)
	rows, err := vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := metricHost(s.metric)
		mount := s.metric["mountpoint"]
		data.Filesystems = append(data.Filesystems, hr.FilesystemRow{Instance: host, Mountpoint: mount, UsedPercent: round2(s.value)})
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("disk_usage.%s.%s", host, mount), Collector: "host_metrics",
			Subject: host, Kind: "disk_usage", Value: round2(s.value), Unit: "percent",
			Message: fmt.Sprintf("%s %s at %.1f%% used", host, mount, s.value),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- projected exhaustion ---
	promql = fmt.Sprintf("predict_linear(node_filesystem_avail_bytes{%s}[7d], 14 * 86400)", fsExclude)
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		if s.value >= 0 {
			continue
		}
		host := metricHost(s.metric)
		mount := s.metric["mountpoint"]
		if diskFillProjectionExclude[diskFillKey{host, mount}] {
			continue
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("disk_fill_projection.%s.%s", host, mount), Collector: "host_metrics",
			Subject: host, Kind: "disk_fill_projection", Value: round2(s.value / (1024.0 * 1024.0 * 1024.0)),
			Unit:     "gib_projected_free",
			Message:  fmt.Sprintf("%s %s is projected to run out of space within 14 days", host, mount),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- memory ---
	promql = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := metricHost(s.metric)
		data.Memory = append(data.Memory, hr.MemoryRow{Instance: host, UsedPercent: round2(s.value)})
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "memory_usage." + host + ".", Collector: "host_metrics", Subject: host, Kind: "memory_usage",
			Value: round2(s.value), Unit: "percent",
			Message: fmt.Sprintf("%s memory at %.1f%% used", host, s.value),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- load per core ---
	promql = `node_load15 / on(instance) group_left count by(instance) (node_cpu_seconds_total{mode="idle"})`
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := metricHost(s.metric)
		data.LoadPerCore = append(data.LoadPerCore, hr.LoadRow{Instance: host, Load15PerCore: round2(s.value)})
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "load_per_core." + host + ".", Collector: "host_metrics", Subject: host, Kind: "load_per_core",
			Value: round2(s.value), Unit: "ratio",
			Message: fmt.Sprintf("%s 15m load is %.2f per core", host, s.value),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- CPU steal (VPS noisy-neighbour detection) ---
	promql = `100 * avg by(instance) (rate(node_cpu_seconds_total{mode="steal"}[1h]))`
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := metricHost(s.metric)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "cpu_steal." + host + ".", Collector: "host_metrics", Subject: host, Kind: "cpu_steal",
			Value: round2(s.value), Unit: "percent",
			Message: fmt.Sprintf("%s CPU steal at %.1f%% over the last hour", host, s.value),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- unexpected reboot ---
	promql = "time() - node_boot_time_seconds"
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := metricHost(s.metric)
		data.UptimeSeconds = append(data.UptimeSeconds, hr.UptimeRow{Instance: host, Uptime: int64(s.value)})
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "recent_reboot." + host + ".", Collector: "host_metrics", Subject: host, Kind: "recent_reboot",
			Value: int64(s.value), Unit: "seconds_since_boot",
			Message: fmt.Sprintf("%s booted %.1f hours ago", host, s.value/3600.0),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- failed systemd units ---
	promql = `node_systemd_unit_state{state="failed"} == 1`
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := metricHost(s.metric)
		unit := s.metric["name"]
		if unit == "" {
			unit = "unknown"
		}
		if systemdNoise.MatchString(unit) {
			continue
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("systemd_failed.%s.%s", host, unit), Collector: "host_metrics",
			Subject: host, Kind: "systemd_failed", Value: unit,
			Message:  fmt.Sprintf("%s: systemd unit %s is failed", host, unit),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- metric staleness ---
	promql = "time() - max by(instance) (timestamp(node_load1))"
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	seenAge := map[string]float64{}
	for _, s := range rows {
		seenAge[metricHost(s.metric)] = s.value
	}
	for host, age := range seenAge {
		data.MetricsAgeSeconds[host] = round2(age)
	}
	for _, host := range cfg.AllHosts() {
		age, ok := seenAge[host]
		if !ok {
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "metrics_missing." + host + ".", Collector: "host_metrics", Subject: host, Kind: "metrics_missing",
				Value:    nil,
				Message:  fmt.Sprintf("%s is not reporting any metrics", host),
				Evidence: grafanaEvidence(promql), Severity: "info",
			})
		} else {
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "metrics_stale." + host + ".", Collector: "host_metrics", Subject: host, Kind: "metrics_stale",
				Value: round2(age), Unit: "seconds",
				Message:  fmt.Sprintf("%s metrics are %.0f seconds old", host, age),
				Evidence: grafanaEvidence(promql), Severity: "info",
			})
		}
	}

	// --- SMART health/temperature ---
	promql = "smartctl_device_smart_status"
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := smartHost(s.metric)
		device := s.metric["device"]
		if device == "" {
			device = "unknown"
		}
		passed := s.value != 0
		status := "passed"
		if !passed {
			status = "FAILED"
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("smart_health.%s.%s", host, device), Collector: "host_metrics",
			Subject: host, Kind: "smart_health", Value: passed,
			Message:  fmt.Sprintf("%s %s SMART self-assessment %s", host, device, status),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	promql = `smartctl_device_temperature{temperature_type="current"}`
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := smartHost(s.metric)
		device := s.metric["device"]
		if device == "" {
			device = "unknown"
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("disk_temperature.%s.%s", host, device), Collector: "host_metrics",
			Subject: host, Kind: "disk_temperature", Value: int64(s.value), Unit: "celsius",
			Message:  fmt.Sprintf("%s %s at %d C", host, device, int64(s.value)),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- btrfs pool errors ---
	promql = "node_btrfs_device_errors_total"
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	type poolKey struct{ host, device string }
	poolErrors := map[poolKey]map[string]float64{}
	var poolOrder []poolKey
	for _, s := range rows {
		if s.value <= 0 {
			continue
		}
		host := smartHost(s.metric)
		device := s.metric["device"]
		if device == "" {
			device = "unknown"
		}
		errType := s.metric["type"]
		if errType == "" {
			errType = "unknown"
		}
		key := poolKey{host, device}
		entry, ok := poolErrors[key]
		if !ok {
			entry = map[string]float64{}
			poolErrors[key] = entry
			poolOrder = append(poolOrder, key)
		}
		entry[errType] += s.value
	}
	for _, key := range poolOrder {
		errs := poolErrors[key]
		var types []string
		for t := range errs {
			types = append(types, t)
		}
		sort.Strings(types)
		total := 0.0
		var parts []string
		for _, t := range types {
			total += errs[t]
			parts = append(parts, fmt.Sprintf("%s=%d", t, int64(errs[t])))
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("btrfs_pool_errors.%s.%s", key.host, key.device), Collector: "host_metrics",
			Subject: key.host, Kind: "btrfs_pool_errors", Value: int64(total), Unit: "errors",
			Message:  fmt.Sprintf("%s: btrfs device %s has errors: %s", key.host, key.device, joinComma(parts)),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	// --- CrowdSec (mljr only) ---
	promql = "sum by(host) (cs_active_decisions)"
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		host := smartHost(s.metric)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "crowdsec_active_decisions." + host + ".", Collector: "host_metrics", Subject: host,
			Kind: "crowdsec_active_decisions", Value: int64(s.value), Unit: "decisions",
			Message:  fmt.Sprintf("%s: %d active CrowdSec ban decision(s)", host, int64(s.value)),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	promql = "sum by(host) (increase(cs_alerts[24h]))"
	rows, err = vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		if s.value <= 0 {
			continue
		}
		host := smartHost(s.metric)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "crowdsec_alerts_24h." + host + ".", Collector: "host_metrics", Subject: host,
			Kind: "crowdsec_alerts_24h", Value: int64(s.value), Unit: "alerts",
			Message:  fmt.Sprintf("%s: %d CrowdSec alert(s) in the last 24h", host, int64(s.value)),
			Evidence: grafanaEvidence(promql), Severity: "info",
		})
	}

	result.Data = data
	return result
}

func smartHost(m map[string]string) string {
	if v, ok := m["host"]; ok {
		return v
	}
	return metricHost(m)
}

func joinComma(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += ", "
		}
		out += p
	}
	return out
}

// collectContainers: container inventory drift and restart loops. The
// important query is the inventory diff: a container that existed 24h ago
// and does not exist now is exactly the silent failure this report is for.
func collectContainers(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("containers")
	lookback := fmt.Sprintf("%dh", cfg.LookbackHours)

	nowQ := `count by(instance, name) (container_last_seen{name!=""})`
	thenQ := fmt.Sprintf(`count by(instance, name) (container_last_seen{name!=""} offset %s)`, lookback)

	type key struct{ host, name string }
	inventory := func(promql string) map[key]bool {
		rows, err := vmQuery(cfg, promql)
		if err != nil {
			panic(err)
		}
		out := map[key]bool{}
		for _, s := range rows {
			name := s.metric["name"]
			if hr.IsEphemeral(name) {
				continue
			}
			out[key{s.metric["instance"], name}] = true
		}
		return out
	}

	current := inventory(nowQ)
	previous := inventory(thenQ)

	// Only compare hosts present on both sides of the window.
	currentHosts := map[string]bool{}
	for k := range current {
		currentHosts[k.host] = true
	}
	previousHosts := map[string]bool{}
	for k := range previous {
		previousHosts[k.host] = true
	}
	comparable := map[string]bool{}
	for h := range currentHosts {
		if previousHosts[h] {
			comparable[h] = true
		}
	}
	filterComparable := func(m map[key]bool) map[key]bool {
		out := map[key]bool{}
		for k := range m {
			if comparable[k.host] {
				out[k] = true
			}
		}
		return out
	}
	current = filterComparable(current)
	previous = filterComparable(previous)

	var missing, added []key
	for k := range previous {
		if !current[k] {
			missing = append(missing, k)
		}
	}
	for k := range current {
		if !previous[k] {
			added = append(added, k)
		}
	}
	sort.Slice(missing, func(i, j int) bool { return keyLess(missing[i], missing[j]) })
	sort.Slice(added, func(i, j int) bool { return keyLess(added[i], added[j]) })

	for _, k := range missing {
		host := k.host
		if host == "" {
			host = "unknown"
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("container_missing.%s.%s", k.host, k.name), Collector: "containers",
			Subject: host, Kind: "container_missing", Value: k.name,
			Message:  fmt.Sprintf("%s: container %s was running %s ago and is gone now", k.host, k.name, lookback),
			Evidence: map[string]any{"promql": thenQ, "grafana_url": cfg.GrafanaURL}, Severity: "info",
		})
	}
	for _, k := range added {
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("container_new.%s.%s", k.host, k.name), Collector: "containers",
			Subject: k.host, Kind: "container_new", Value: k.name,
			Message:  fmt.Sprintf("%s: container %s appeared in the last %s", k.host, k.name, lookback),
			Evidence: map[string]any{"promql": nowQ}, Severity: "info",
		})
	}

	restartQ := fmt.Sprintf(`changes(container_start_time_seconds{name!=""}[%s])`, lookback)
	rows, err := vmQuery(cfg, restartQ)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		if s.value <= 1 {
			continue
		}
		host := metricHost(s.metric)
		name := s.metric["name"]
		if name == "" {
			name = "unknown"
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("container_restarts.%s.%s", host, name), Collector: "containers",
			Subject: host, Kind: "container_restarts", Value: int64(s.value), Unit: "restarts",
			Message:  fmt.Sprintf("%s: container %s restarted %d times in %s", host, name, int64(s.value), lookback),
			Evidence: map[string]any{"promql": restartQ, "grafana_url": cfg.GrafanaURL}, Severity: "info",
		})
	}

	oomQ := fmt.Sprintf("increase(container_oom_events_total[%s])", lookback)
	rows, err = vmQuery(cfg, oomQ)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		if s.value < 1 {
			continue
		}
		host := metricHost(s.metric)
		name := s.metric["name"]
		if name == "" {
			name = "unknown"
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("container_oom.%s.%s", host, name), Collector: "containers",
			Subject: host, Kind: "container_oom", Value: int64(s.value), Unit: "events",
			Message:  fmt.Sprintf("%s: container %s was OOM-killed %d times in %s", host, name, int64(s.value), lookback),
			Evidence: map[string]any{"promql": oomQ, "grafana_url": cfg.GrafanaURL}, Severity: "info",
		})
	}

	missingNames := make([]string, 0, len(missing))
	for _, k := range missing {
		missingNames = append(missingNames, k.host+"/"+k.name)
	}
	addedNames := make([]string, 0, len(added))
	for _, k := range added {
		addedNames = append(addedNames, k.host+"/"+k.name)
	}
	result.Data = &hr.ContainersData{
		CurrentCount: len(current), PreviousCount: len(previous),
		Missing: missingNames, New: addedNames,
	}
	return result
}

func keyLess(a, b struct{ host, name string }) bool {
	if a.host != b.host {
		return a.host < b.host
	}
	return a.name < b.name
}
