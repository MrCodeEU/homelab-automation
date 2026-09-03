// csp-reports is a tiny collector for browser CSP violation reports, fed by
// the `report-uri`/`report-to` directives every public domain gets appended
// (via Caddy's shared security_headers snippet, not per-app config) on top
// of whatever Content-Security-Policy an app already sets. It does not
// enforce or modify anything - it only logs one JSON line per violation to
// stdout, which Loki already ingests like every other container's logs;
// tools/internal/healthreport/collectors/csp_reports.go turns new violation
// signatures into a health report observation.
//
// Deliberately not a database or dashboard: violations are rare by design
// (they mean something is broken or being probed), and the existing
// Loki+healthreport pipeline is already the right place to surface "rare
// but important" signals - see ntfy_denied.go for the same shape.
package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

// legacyReport is the body shape sent for the (still widely supported,
// technically deprecated) `report-uri` directive.
type legacyReport struct {
	CSPReport struct {
		DocumentURI       string `json:"document-uri"`
		ViolatedDirective string `json:"violated-directive"`
		EffectiveDirective string `json:"effective-directive"`
		BlockedURI        string `json:"blocked-uri"`
		SourceFile        string `json:"source-file"`
		Disposition       string `json:"disposition"`
	} `json:"csp-report"`
}

// reportingAPIEntry is one element of the batched array the Reporting API
// (`report-to`) sends - other report types (deprecation, network-error,
// ...) show up on the same endpoint and are skipped.
type reportingAPIEntry struct {
	Type string `json:"type"`
	URL  string `json:"url"`
	Body struct {
		DocumentURL        string `json:"documentURL"`
		ViolatedDirective  string `json:"violatedDirective"`
		EffectiveDirective string `json:"effectiveDirective"`
		BlockedURL         string `json:"blockedURL"`
		SourceFile         string `json:"sourceFile"`
		Disposition        string `json:"disposition"`
	} `json:"body"`
}

// violation is the normalized shape actually logged, regardless of which
// report format it arrived in.
type violation struct {
	Event       string `json:"event"`
	DocumentURI string `json:"document_uri"`
	Directive   string `json:"directive"`
	BlockedURI  string `json:"blocked_uri"`
	SourceFile  string `json:"source_file"`
	Disposition string `json:"disposition"`
}

// isExtensionNoise reports whether a blocked-uri originates from a browser
// extension's own injected content, not the site - extensions routinely
// trip a strict CSP with their own scripts, and that is not signal about
// this site's own security posture.
func isExtensionNoise(blockedURI string) bool {
	for _, prefix := range []string{"chrome-extension:", "moz-extension:", "safari-extension:", "safari-web-extension:", "ms-browser-extension:"} {
		if strings.HasPrefix(blockedURI, prefix) {
			return true
		}
	}
	return false
}

func handleReport(w http.ResponseWriter, r *http.Request) {
	// Every outcome (bad method, oversized/malformed body) still returns
	// 204 - this endpoint exists purely to receive fire-and-forget browser
	// beacons, and any other response code just makes browsers retry.
	defer w.WriteHeader(http.StatusNoContent)

	if r.Method != http.MethodPost {
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 64*1024))
	if err != nil || len(body) == 0 {
		return
	}

	var entries []reportingAPIEntry
	if err := json.Unmarshal(body, &entries); err == nil && len(entries) > 0 {
		for _, e := range entries {
			if e.Type != "csp-violation" {
				continue
			}
			logViolation(violation{
				Event:       "csp_violation",
				DocumentURI: e.Body.DocumentURL,
				Directive:   firstNonEmpty(e.Body.EffectiveDirective, e.Body.ViolatedDirective),
				BlockedURI:  e.Body.BlockedURL,
				SourceFile:  e.Body.SourceFile,
				Disposition: e.Body.Disposition,
			})
		}
		return
	}

	var legacy legacyReport
	if err := json.Unmarshal(body, &legacy); err == nil && legacy.CSPReport.DocumentURI != "" {
		logViolation(violation{
			Event:       "csp_violation",
			DocumentURI: legacy.CSPReport.DocumentURI,
			Directive:   firstNonEmpty(legacy.CSPReport.EffectiveDirective, legacy.CSPReport.ViolatedDirective),
			BlockedURI:  legacy.CSPReport.BlockedURI,
			SourceFile:  legacy.CSPReport.SourceFile,
			Disposition: legacy.CSPReport.Disposition,
		})
	}
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func logViolation(v violation) {
	if isExtensionNoise(v.BlockedURI) {
		return
	}
	line, err := json.Marshal(v)
	if err != nil {
		return
	}
	log.Print(string(line))
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/csp-report", handleReport)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.SetFlags(0) // one clean JSON object per line, no timestamp prefix - Loki timestamps the line itself
	log.Printf("csp-reports listening on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}
