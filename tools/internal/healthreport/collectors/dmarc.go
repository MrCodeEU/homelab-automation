// Reads parsedmarc's own Postgres directly (services/dmarc-monitor, same
// host as this collector runs on via network_mode: host, so 127.0.0.1
// reaches it without crossing the tailnet). Two failure modes matter for a
// mail server: the DMARC pipeline silently stopping (IMAP watch dies, no
// new aggregate report shows up) and mail actually failing DMARC for a
// domain this fleet owns (misconfigured SPF/DKIM, a new sending source not
// yet authorized).
package collectors

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "github.com/lib/pq"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// Major providers (Google, Microsoft) send daily; smaller ones can lag
// several days. 5 days catches a genuinely dead IMAP watch without flagging
// normal reporting jitter.
const dmarcReportStaleAfter = 5 * 24 * time.Hour

func init() {
	hr.RegisterCollector("dmarc", collectDMARC)
}

func collectDMARC(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("dmarc")
	if cfg.DMARCDBURL == "" {
		result.Status = "unavailable"
		result.Error = "no HEALTHREPORT_DMARC_DB_URL configured"
		return result
	}

	db, err := sql.Open("postgres", cfg.DMARCDBURL)
	if err != nil {
		panic(err)
	}
	defer db.Close()
	db.SetConnMaxLifetime(30 * time.Second)

	var lastReport sql.NullTime
	if err := db.QueryRow(`SELECT max(end_date) FROM dmarc_aggregate_report`).Scan(&lastReport); err != nil {
		panic(err)
	}
	if !lastReport.Valid {
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "dmarc_report_stale.", Collector: "dmarc", Subject: "dmarc-monitor", Kind: "dmarc_report_stale",
			Value: "never", Message: "dmarc-monitor has never ingested an aggregate report",
			Severity: "info",
		})
		return result
	}
	if age := time.Since(lastReport.Time); age > dmarcReportStaleAfter {
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "dmarc_report_stale.", Collector: "dmarc", Subject: "dmarc-monitor", Kind: "dmarc_report_stale",
			Value: lastReport.Time.Format(time.RFC3339),
			Message: fmt.Sprintf("dmarc-monitor's last aggregate report ended %s ago (%s) - IMAP watch may be dead",
				age.Round(time.Hour), lastReport.Time.Format("2006-01-02")),
			Severity: "info",
		})
	}

	if len(cfg.DMARCDomains) == 0 {
		return result
	}

	rows, err := db.Query(`
		SELECT r.header_from, sum(r.message_count) AS total, sum(r.message_count) FILTER (WHERE r.dmarc_passed) AS passed
		FROM dmarc_aggregate_record r
		JOIN dmarc_aggregate_report rep ON rep.id = r.report_id
		WHERE rep.begin_date > now() - interval '7 days'
		GROUP BY r.header_from`)
	if err != nil {
		panic(err)
	}
	defer rows.Close()

	for rows.Next() {
		var headerFrom string
		var total, passed sql.NullInt64
		if err := rows.Scan(&headerFrom, &total, &passed); err != nil {
			panic(err)
		}
		owned := false
		for _, domain := range cfg.DMARCDomains {
			if headerFrom == domain || strings.HasSuffix(headerFrom, "."+domain) {
				owned = true
				break
			}
		}
		if !owned {
			continue
		}
		failed := total.Int64 - passed.Int64
		if failed <= 0 {
			continue
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "dmarc_fail_count." + headerFrom + ".", Collector: "dmarc", Subject: headerFrom, Kind: "dmarc_fail_count",
			Value: failed, Unit: "messages",
			Message:  fmt.Sprintf("%s: %d of %d messages failed DMARC in the last 7 days", headerFrom, failed, total.Int64),
			Evidence: map[string]any{"total": total.Int64, "passed": passed.Int64},
			Severity: "info",
		})
	}
	if err := rows.Err(); err != nil {
		panic(err)
	}
	return result
}
