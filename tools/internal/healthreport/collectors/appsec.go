// CrowdSec AppSec (WAF) in front of mljr's Caddy (docs/APPSEC_POC_PLAN.md).
// Two things are worth a line in the report:
//
//   - how many requests the rule set matched in 24h. A baseline is normal
//     (scanners), a jump means either a campaign against us or a rule that
//     started matching real traffic, which in block mode means 403s for users.
//   - AppSec being unreachable. Caddy fails open on purpose, so an outage
//     never takes a site down, but it also means the WAF silently stopped
//     inspecting; the only trace is this log line.
package collectors

import (
	"fmt"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// The PoC listener (caddy-poc) logs the same message during the fail-open
// tests, so it is excluded; production Caddy logs to the journal.
const appsecUnavailableQuery = `{host="mljr", container!="caddy-poc"} |= "appsec component unavailable"`

// Loki caps a range query at 5000 lines; the rule thresholds sit far below.
const appsecUnavailableLimit = 5000

func init() {
	hr.RegisterCollector("appsec", collectAppSec)
}

func countLokiLines(streams []lokiStream) int {
	n := 0
	for _, s := range streams {
		n += len(s.Values)
	}
	return n
}

func collectAppSec(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("appsec")

	promql := "sum by(host) (increase(cs_appsec_block_total[24h]))"
	rows, err := vmQuery(cfg, promql)
	if err != nil {
		panic(err)
	}
	for _, s := range rows {
		if s.value < 1 {
			continue
		}
		host := smartHost(s.metric)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "appsec_matches_24h." + host + ".", Collector: "appsec", Subject: host,
			Kind: "appsec_matches_24h", Value: int64(s.value), Unit: "requests",
			Message:  fmt.Sprintf("%s: AppSec matched %d request(s) in the last 24h", host, int64(s.value)),
			Evidence: map[string]any{"promql": promql, "grafana_url": cfg.GrafanaURL}, Severity: "info",
		})
	}

	streams, err := lokiQueryRange(cfg, appsecUnavailableQuery, cfg.LookbackHours, appsecUnavailableLimit)
	if err != nil {
		panic(err)
	}
	if n := countLokiLines(streams); n > 0 {
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "appsec_unavailable.mljr.", Collector: "appsec", Subject: "mljr",
			Kind: "appsec_unavailable_24h", Value: int64(n), Unit: "requests",
			Message:  fmt.Sprintf("mljr: Caddy could not reach AppSec for %d request(s) (failing open, those were not inspected)", n),
			Evidence: map[string]any{"logql": appsecUnavailableQuery}, Severity: "info",
		})
	}
	return result
}
