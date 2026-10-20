// Downtime summary per Uptime Kuma monitor, from monitor_status history in
// VictoriaMetrics (Grafana Alloy on nuc scrapes Kuma's /metrics). The
// uptime_kuma collector only sees the current state, so an outage that
// started and ended between two daily runs was invisible.
package collectors

import (
	"fmt"
	"math"
	"sort"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

func init() {
	hr.RegisterCollector("monitor_availability", collectMonitorAvailability)
}

// Kuma reports 1=up, 0=down, 2=pending, 3=maintenance; only 1 counts as up.
func availabilityQuery(window string) string {
	return fmt.Sprintf("100 * avg_over_time((monitor_status == bool 1)[%s:1m])", window)
}

func downtimeMinutes(availabilityPct float64, windowMinutes float64) float64 {
	if availabilityPct >= 100 {
		return 0
	}
	return math.Round((100 - availabilityPct) / 100 * windowMinutes)
}

func availabilityMessage(name string, pct24, pct7 float64, has7 bool) string {
	msg := fmt.Sprintf("%s was %.2f%% available over 24h (~%.0f min down)", name, pct24, downtimeMinutes(pct24, 24*60))
	if has7 {
		msg += fmt.Sprintf(", %.2f%% over 7d (~%.0f min down)", pct7, downtimeMinutes(pct7, 7*24*60))
	}
	return msg
}

func collectMonitorAvailability(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("monitor_availability")

	q24 := availabilityQuery("24h")
	rows24, err := vmQuery(cfg, q24)
	if err != nil {
		panic(err)
	}
	if len(rows24) == 0 {
		// Not an error: Kuma may simply not be scraped yet.
		result.Status = "unavailable"
		result.Error = "no monitor_status series in VictoriaMetrics (Kuma scrape missing?)"
		return result
	}
	q7 := availabilityQuery("7d")
	rows7, err := vmQuery(cfg, q7)
	if err != nil {
		panic(err)
	}
	pct7 := map[string]float64{}
	for _, s := range rows7 {
		pct7[s.metric["monitor_name"]] = s.value
	}

	sort.Slice(rows24, func(i, j int) bool { return rows24[i].metric["monitor_name"] < rows24[j].metric["monitor_name"] })
	for _, s := range rows24 {
		name := s.metric["monitor_name"]
		if name == "" {
			continue
		}
		p7, has7 := pct7[name]
		evidence := map[string]any{"promql_24h": q24, "grafana_url": cfg.GrafanaURL}
		if has7 {
			evidence["availability_7d_percent"] = round2(p7)
			evidence["downtime_minutes_7d"] = downtimeMinutes(p7, 7*24*60)
		}
		evidence["downtime_minutes_24h"] = downtimeMinutes(s.value, 24*60)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "monitor_availability." + name + ".", Collector: "monitor_availability",
			Subject: name, Kind: "monitor_availability", Value: round2(s.value), Unit: "percent",
			Message: availabilityMessage(name, s.value, p7, has7), Evidence: evidence, Severity: "info",
		})
	}
	return result
}
