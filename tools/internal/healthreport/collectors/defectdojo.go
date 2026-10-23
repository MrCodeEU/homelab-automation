// Reads the nightly Trivy/Nuclei results from DefectDojo (services/defectdojo)
// so the daily report can say what needs attention without anyone opening
// DefectDojo. DefectDojo holds everything, including the unfixable noise;
// this collector surfaces only what is actionable:
//
//   - vuln_known_exploited: an active finding is on the CISA KEV list.
//   - vuln_new_fixable: Critical/High findings first seen within the
//     lookback window that already have a fix available.
//   - vuln_scan_stale: an engagement's newest scan is old, i.e. the nightly
//     timer stopped. Without this, silence would look like a clean bill.
//
// One observation per scan target (DefectDojo test), not per finding, so a
// day-one import of an unpatched estate is a few dozen lines, not thousands.
package collectors

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// The timers run nightly; a day and a half without an update means a
// missed run, not just a late one.
const dojoScanStaleAfter = 36 * time.Hour

func init() {
	hr.RegisterCollector("defectdojo", collectDefectDojo)
}

type dojoFinding struct {
	Title           string `json:"title"`
	Severity        string `json:"severity"`
	Date            string `json:"date"`
	Test            int    `json:"test"`
	FixAvailable    bool   `json:"fix_available"`
	KnownExploited  bool   `json:"known_exploited"`
	VulnerabilityID []struct {
		ID string `json:"vulnerability_id"`
	} `json:"vulnerability_ids"`
}

type dojoTest struct {
	ID         int    `json:"id"`
	Title      string `json:"title"`
	Engagement int    `json:"engagement"`
	Updated    string `json:"updated"`
}

type dojoEngagement struct {
	ID      int    `json:"id"`
	Name    string `json:"name"`
	Product int    `json:"product"`
}

type dojoProduct struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type dojoClient struct {
	base  string
	token string
}

func collectDefectDojo(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("defectdojo")
	if cfg.DojoURL == "" || cfg.DojoPassword == "" {
		result.Status = "unavailable"
		result.Error = "no HEALTHREPORT_DOJO_URL / HEALTHREPORT_DOJO_PASSWORD configured"
		return result
	}

	client, err := dojoLogin(cfg.DojoURL, cfg.DojoPassword)
	if err != nil {
		panic(err)
	}

	var tests []dojoTest
	var engagements []dojoEngagement
	var products []dojoProduct
	must(dojoList(client, "tests", nil, &tests))
	must(dojoList(client, "engagements", nil, &engagements))
	must(dojoList(client, "products", nil, &products))

	// Critical and High only; Medium/Low are in DefectDojo for whoever
	// wants to browse them, not for a daily report.
	var findings []dojoFinding
	for _, severity := range []string{"Critical", "High"} {
		var page []dojoFinding
		must(dojoList(client, "findings", url.Values{"active": {"true"}, "severity": {severity}}, &page))
		findings = append(findings, page...)
	}
	// Known-exploited findings of any severity.
	var kev []dojoFinding
	must(dojoList(client, "findings", url.Values{"active": {"true"}, "known_exploited": {"true"}}, &kev))

	labels := dojoTargetLabels(tests, engagements, products)
	since := time.Now().Add(-time.Duration(cfg.LookbackHours) * time.Hour)
	result.Observations = append(result.Observations, dojoFindingObservations(findings, kev, labels, since)...)
	result.Observations = append(result.Observations, dojoStaleObservations(tests, engagements, products, time.Now())...)
	return result
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// dojoTargetLabels maps a test id to "product: target title".
func dojoTargetLabels(tests []dojoTest, engagements []dojoEngagement, products []dojoProduct) map[int]string {
	productName := map[int]string{}
	for _, p := range products {
		productName[p.ID] = p.Name
	}
	engagementProduct := map[int]string{}
	for _, e := range engagements {
		engagementProduct[e.ID] = productName[e.Product]
	}
	labels := map[int]string{}
	for _, t := range tests {
		labels[t.ID] = engagementProduct[t.Engagement] + ": " + t.Title
	}
	return labels
}

func dojoFindingObservations(findings, kev []dojoFinding, labels map[int]string, since time.Time) []*hr.Observation {
	type group struct {
		count int
		ids   []string
	}
	fresh := map[int]*group{}
	for _, f := range findings {
		if !f.FixAvailable || !dojoFirstSeenSince(f.Date, since) {
			continue
		}
		g := fresh[f.Test]
		if g == nil {
			g = &group{}
			fresh[f.Test] = g
		}
		g.count++
		g.ids = append(g.ids, dojoFindingName(f))
	}
	exploited := map[int]*group{}
	for _, f := range kev {
		g := exploited[f.Test]
		if g == nil {
			g = &group{}
			exploited[f.Test] = g
		}
		g.count++
		g.ids = append(g.ids, dojoFindingName(f))
	}

	var out []*hr.Observation
	emit := func(groups map[int]*group, kind, format string) {
		tests := make([]int, 0, len(groups))
		for id := range groups {
			tests = append(tests, id)
		}
		sort.Ints(tests)
		for _, id := range tests {
			g := groups[id]
			label := labels[id]
			if label == "" {
				label = fmt.Sprintf("test %d", id)
			}
			sort.Strings(g.ids)
			out = append(out, &hr.Observation{
				ID: kind + "." + label + ".", Collector: "defectdojo", Subject: label, Kind: kind,
				Value:    g.count,
				Unit:     "findings",
				Message:  fmt.Sprintf(format, g.count, label, strings.Join(dojoFirstN(g.ids, 3), ", ")),
				Evidence: map[string]any{"examples": dojoFirstN(g.ids, 3)}, Severity: "info",
			})
		}
	}
	emit(exploited, "vuln_known_exploited", "%d actively exploited (CISA KEV) finding(s) in %s, e.g. %s")
	emit(fresh, "vuln_new_fixable", "%d new Critical/High finding(s) with a fix available in %s, e.g. %s")
	return out
}

func dojoStaleObservations(tests []dojoTest, engagements []dojoEngagement, products []dojoProduct, now time.Time) []*hr.Observation {
	productName := map[int]string{}
	for _, p := range products {
		productName[p.ID] = p.Name
	}
	newest := map[int]time.Time{}
	for _, t := range tests {
		updated, err := time.Parse(time.RFC3339Nano, t.Updated)
		if err != nil {
			continue
		}
		if updated.After(newest[t.Engagement]) {
			newest[t.Engagement] = updated
		}
	}
	var out []*hr.Observation
	for _, e := range engagements {
		last, ok := newest[e.ID]
		if !ok {
			continue
		}
		age := now.Sub(last)
		if age <= dojoScanStaleAfter {
			continue
		}
		subject := productName[e.Product] + "/" + e.Name
		out = append(out, &hr.Observation{
			ID: "vuln_scan_stale." + subject + ".", Collector: "defectdojo", Subject: subject, Kind: "vuln_scan_stale",
			Value: int(age.Hours()), Unit: "hours",
			Message:  fmt.Sprintf("last %s scan was %d hours ago - the nightly timer may have stopped", subject, int(age.Hours())),
			Evidence: map[string]any{"last_scan": last.Format(time.RFC3339)}, Severity: "info",
		})
	}
	return out
}

func dojoFindingName(f dojoFinding) string {
	if len(f.VulnerabilityID) > 0 && f.VulnerabilityID[0].ID != "" {
		return f.VulnerabilityID[0].ID
	}
	return f.Title
}

// dojoFirstSeenSince reports whether a finding's date (YYYY-MM-DD, the day it
// was first imported) is on or after the day `since` falls on. Day
// granularity is all DefectDojo records.
func dojoFirstSeenSince(date string, since time.Time) bool {
	day, err := time.Parse("2006-01-02", date)
	if err != nil {
		return false
	}
	return !day.Before(time.Date(since.Year(), since.Month(), since.Day(), 0, 0, 0, 0, time.UTC))
}

func dojoFirstN(in []string, n int) []string {
	if len(in) <= n {
		return in
	}
	return in[:n]
}

func dojoLogin(base, password string) (*dojoClient, error) {
	body, _ := json.Marshal(map[string]string{"username": "admin", "password": password})
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Post(strings.TrimRight(base, "/")+"/api/v2/api-token-auth/", "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("defectdojo login: HTTP %d", resp.StatusCode)
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.Token == "" {
		return nil, fmt.Errorf("defectdojo login: no token in response")
	}
	return &dojoClient{base: strings.TrimRight(base, "/"), token: out.Token}, nil
}

// dojoList pages through a DRF list endpoint, appending every result to out
// (a pointer to a slice of the element type).
func dojoList[T any](c *dojoClient, resource string, filter url.Values, out *[]T) error {
	const pageSize = 500
	for offset := 0; ; offset += pageSize {
		q := url.Values{}
		for k, v := range filter {
			q[k] = v
		}
		q.Set("limit", fmt.Sprint(pageSize))
		q.Set("offset", fmt.Sprint(offset))
		resp, err := httpGet(fmt.Sprintf("%s/api/v2/%s/?%s", c.base, resource, q.Encode()), 60*time.Second,
			func(r *http.Request) { r.Header.Set("Authorization", "Token "+c.token) })
		if err != nil {
			return err
		}
		var page struct {
			Count   int `json:"count"`
			Results []T `json:"results"`
		}
		err = json.NewDecoder(resp.Body).Decode(&page)
		resp.Body.Close()
		if err != nil {
			return fmt.Errorf("defectdojo %s: %w", resource, err)
		}
		*out = append(*out, page.Results...)
		if len(page.Results) == 0 || offset+pageSize >= page.Count {
			return nil
		}
	}
}
