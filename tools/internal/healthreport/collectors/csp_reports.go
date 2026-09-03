// Watches csp-reports' logs (tools/cmd/csp-reports, fed by the
// Content-Security-Policy report-uri/report-to headers every public domain
// gets via Caddy's shared security_headers snippet) for CSP violations. A
// violation is normal noise the first time a new app ships (its own policy
// still settling) but otherwise means something is either broken or being
// probed - surfaced once per distinct (directive, document) pair rather
// than every occurrence, same shape as ntfy_denied.go.
package collectors

import (
	"encoding/json"
	"fmt"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

var cspReportsQuery = `{job="docker", container="csp-reports"} |= "csp_violation"`

// The collector's own log line is a single flat JSON object (see
// tools/cmd/csp-reports/main.go's violation struct) - no `| json` label
// extraction needed, just decode the raw line.
type cspViolationLine struct {
	DocumentURI string `json:"document_uri"`
	Directive   string `json:"directive"`
	BlockedURI  string `json:"blocked_uri"`
}

func init() {
	hr.RegisterCollector("csp_reports", collectCSPReports)
}

func collectCSPReports(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("csp_reports")

	streams, err := lokiQueryRange(cfg, cspReportsQuery, cfg.LookbackHours, 1000)
	if err != nil {
		panic(err)
	}

	type key struct{ directive, documentURI string }
	byKey := map[key]int{}
	var order []key
	examples := map[key]cspViolationLine{}

	for _, stream := range streams {
		for _, pair := range stream.Values {
			var v cspViolationLine
			if err := json.Unmarshal([]byte(pair[1]), &v); err != nil {
				continue
			}
			k := key{v.Directive, v.DocumentURI}
			if _, ok := byKey[k]; !ok {
				order = append(order, k)
				examples[k] = v
			}
			byKey[k]++
		}
	}

	for _, k := range order {
		count := byKey[k]
		v := examples[k]
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "csp_violation." + k.directive + "|" + k.documentURI, Collector: "csp_reports", Subject: k.documentURI, Kind: "csp_violation",
			Value: count, Unit: "reports",
			Message:  fmt.Sprintf("CSP violation on %s: %s blocked %q (%d report(s))", k.documentURI, k.directive, v.BlockedURI, count),
			Evidence: map[string]any{"directive": k.directive, "document_uri": k.documentURI, "blocked_uri": v.BlockedURI}, Severity: "info",
		})
	}
	return result
}
