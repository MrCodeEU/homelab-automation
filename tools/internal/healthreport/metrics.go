package healthreport

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

// severityLevel is the value of healthreport_observation: crit 2, warn 1,
// an info notice 0. Plain info observations are not exported - there are
// hundreds of them and the dashboard only lists what needs a look.
var severityLevel = map[string]float64{"crit": 2, "warn": 1, "info": 0}

// RenderMetrics formats one run in the Prometheus text format, every sample
// stamped with now, for VictoriaMetrics' /api/v1/import/prometheus. mode is
// "report" (the daily run) or "metrics" (the runs in between, --metrics-only).
//
// The message is a label so the dashboard can list findings without a
// second store. It can carry a value ("2884 request(s)"), so a changing
// finding starts a new series; at ~50 findings every 6h that is cheap.
func RenderMetrics(facts *Facts, mode string, now time.Time) string {
	ts := now.UnixMilli()
	var b strings.Builder
	sample := func(name, labels string, v float64) {
		fmt.Fprintf(&b, "%s{%s} %g %d\n", name, labels, v, ts)
	}
	modeLabel := fmt.Sprintf(`mode="%s"`, mode)

	sample("healthreport_last_run_timestamp_seconds", modeLabel, float64(now.Unix()))
	for sev, count := range map[string]int{"crit": facts.Summary.Crit, "warn": facts.Summary.Warn, "info": facts.Summary.Info} {
		sample("healthreport_observations", fmt.Sprintf(`%s,severity="%s"`, modeLabel, sev), float64(count))
	}

	names := make([]string, 0, len(facts.Collectors))
	for name := range facts.Collectors {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		result := facts.Collectors[name]
		labels := fmt.Sprintf(`collector="%s"`, metricEscape(name))
		up := 0.0
		if result.Status == "ok" {
			up = 1
		}
		sample("healthreport_collector_up", fmt.Sprintf(`%s,status="%s"`, labels, metricEscape(result.Status)), up)
		sample("healthreport_collector_duration_seconds", labels, result.DurationS)
	}

	for _, obs := range facts.Observations {
		if obs.Severity == "info" && !obs.Notice {
			continue
		}
		labels := fmt.Sprintf(`id="%s",collector="%s",subject="%s",kind="%s",severity="%s"`,
			metricEscape(obs.ID), metricEscape(obs.Collector), metricEscape(obs.Subject),
			metricEscape(obs.Kind), metricEscape(obs.Severity))
		sample("healthreport_observation", fmt.Sprintf(`%s,message="%s"`, labels, metricEscape(obs.Message)),
			severityLevel[obs.Severity])
		if first, err := time.Parse(time.RFC3339, fmt.Sprint(obs.FirstSeen)); err == nil {
			sample("healthreport_observation_first_seen_timestamp_seconds", labels, float64(first.Unix()))
		}
	}
	return b.String()
}

// metricEscape escapes a Prometheus label value.
func metricEscape(s string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(s)
}

// PushMetrics posts body to VictoriaMetrics' Prometheus import endpoint.
func PushMetrics(cfg Config, body string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	url := strings.TrimRight(cfg.VictoriaURL, "/") + "/api/v1/import/prometheus"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBufferString(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return fmt.Errorf("victoriametrics: %s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	return nil
}
