// Uptime Kuma monitor state. Kuma exposes a Prometheus endpoint at
// /metrics behind HTTP basic auth: empty username, API key as the
// password. Parsed directly rather than scraped into VictoriaMetrics so a
// Kuma outage is visible as a collector failure instead of silently stale
// data.
package collectors

import (
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// monitor_status{monitor_name="x",...} 1
var kumaSample = regexp.MustCompile(`^(?P<name>[a-z_]+)\{(?P<labels>[^}]*)\}\s+(?P<value>[-\d.eE+]+)\s*$`)
var kumaLabel = regexp.MustCompile(`(\w+)="((?:[^"\\]|\\.)*)"`)

// Kuma status codes: 0 down, 1 up, 2 pending, 3 maintenance.
var kumaStatusNames = map[int]string{0: "down", 1: "up", 2: "pending", 3: "maintenance"}

type kumaSampleLine struct {
	name   string
	labels map[string]string
	value  float64
}

func parseKumaMetrics(text string) []kumaSampleLine {
	var out []kumaSampleLine
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		match := kumaSample.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		labels := map[string]string{}
		for _, lm := range kumaLabel.FindAllStringSubmatch(match[2], -1) {
			labels[lm[1]] = strings.ReplaceAll(lm[2], `\"`, `"`)
		}
		value, err := strconv.ParseFloat(match[3], 64)
		if err != nil {
			continue
		}
		out = append(out, kumaSampleLine{name: match[1], labels: labels, value: value})
	}
	return out
}

func init() {
	hr.RegisterCollector("uptime_kuma", collectKuma)
}

func collectKuma(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("uptime_kuma")

	if cfg.KumaAPIKey == "" {
		result.Status = "unavailable"
		result.Error = "no Kuma API key configured (secrets.kuma.api_key)"
		return result
	}

	resp, err := httpGet(strings.TrimRight(cfg.KumaURL, "/")+"/metrics", 30*time.Second, func(r *http.Request) {
		r.SetBasicAuth("", cfg.KumaAPIKey)
	})
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		panic(err)
	}

	samples := parseKumaMetrics(string(body))

	type monitorEntry struct {
		name        string
		url         *string
		status      *int
		certDays    *int
		responseMs  *float64
	}
	monitors := map[string]*monitorEntry{}
	var order []string
	for _, s := range samples {
		key := s.labels["monitor_name"]
		if key == "" {
			key = s.labels["monitor_url"]
		}
		if key == "" {
			key = "unknown"
		}
		entry, ok := monitors[key]
		if !ok {
			entry = &monitorEntry{name: key}
			if u, ok := s.labels["monitor_url"]; ok {
				entry.url = &u
			}
			monitors[key] = entry
			order = append(order, key)
		}
		switch s.name {
		case "monitor_status":
			v := int(s.value)
			entry.status = &v
		case "monitor_cert_days_remaining":
			v := int(s.value)
			entry.certDays = &v
		case "monitor_response_time":
			v := s.value
			entry.responseMs = &v
		}
	}

	data := &hr.KumaData{MonitorCount: len(monitors)}
	for _, name := range order {
		entry := monitors[name]
		data.Monitors = append(data.Monitors, hr.KumaMonitor{
			Name: entry.name, URL: entry.url, Status: entry.status,
			CertDays: entry.certDays, ResponseMs: entry.responseMs,
		})
	}
	result.Data = data

	for _, name := range order {
		entry := monitors[name]
		if entry.status != nil {
			statusName, ok := kumaStatusNames[*entry.status]
			if !ok {
				statusName = fmt.Sprint(*entry.status)
			}
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "monitor_status." + name + ".", Collector: "uptime_kuma", Subject: name,
				Kind: "monitor_status", Value: statusName,
				Message:  fmt.Sprintf("monitor %s is %s", name, statusName),
				Evidence: map[string]any{"kuma_url": cfg.KumaURL, "monitor_url": derefStr(entry.url)},
				Severity: "info",
			})
		}
		// Kuma reports -1 when it has no certificate information (plain
		// HTTP, TCP monitors). Only real certificates carry signal.
		if entry.certDays != nil && *entry.certDays >= 0 {
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "cert_expiry." + name + ".", Collector: "uptime_kuma", Subject: name,
				Kind: "cert_expiry", Value: *entry.certDays, Unit: "days",
				Message:  fmt.Sprintf("certificate for %s expires in %d days", name, *entry.certDays),
				Evidence: map[string]any{"monitor_url": derefStr(entry.url)}, Severity: "info",
			})
		}
	}

	return result
}

func derefStr(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}
