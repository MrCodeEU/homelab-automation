package collectors

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

func dojoPage(results any, count int) string {
	raw, _ := json.Marshal(map[string]any{"count": count, "results": results})
	return string(raw)
}

// fakeDojo serves the handful of DefectDojo endpoints the collector reads.
func fakeDojo(t *testing.T, now time.Time, lastScan time.Time) *httptest.Server {
	t.Helper()
	today := now.Format("2006-01-02")
	old := now.AddDate(0, 0, -10).Format("2006-01-02")
	vuln := func(id string) []map[string]string { return []map[string]string{{"vulnerability_id": id}} }

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v2/api-token-auth/" {
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["username"] != "admin" || body["password"] != "secret" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_, _ = w.Write([]byte(`{"token":"tok"}`))
			return
		}
		if r.Header.Get("Authorization") != "Token tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		q := r.URL.Query()
		switch strings.TrimPrefix(r.URL.Path, "/api/v2/") {
		case "products/":
			_, _ = w.Write([]byte(dojoPage([]map[string]any{{"id": 1, "name": "nuc"}}, 1)))
		case "engagements/":
			_, _ = w.Write([]byte(dojoPage([]map[string]any{{"id": 1, "name": "trivy-nightly", "product": 1}}, 1)))
		case "tests/":
			_, _ = w.Write([]byte(dojoPage([]map[string]any{
				{"id": 1, "title": "nginx:1.19", "engagement": 1, "updated": lastScan.Format(time.RFC3339Nano)},
				{"id": 2, "title": "host packages", "engagement": 1, "updated": lastScan.Add(-time.Hour).Format(time.RFC3339Nano)},
			}, 2)))
		case "findings/":
			switch {
			case q.Get("known_exploited") == "true":
				_, _ = w.Write([]byte(dojoPage([]map[string]any{
					{"title": "t", "severity": "High", "date": old, "test": 2, "known_exploited": true, "vulnerability_ids": vuln("CVE-2024-0001")},
				}, 1)))
			case q.Get("severity") == "Critical":
				_, _ = w.Write([]byte(dojoPage([]map[string]any{
					// new + fixable: counts
					{"title": "a", "severity": "Critical", "date": today, "test": 1, "fix_available": true, "vulnerability_ids": vuln("CVE-2026-1111")},
					{"title": "b", "severity": "Critical", "date": today, "test": 1, "fix_available": true, "vulnerability_ids": vuln("CVE-2026-2222")},
					// new but no fix: must not count
					{"title": "c", "severity": "Critical", "date": today, "test": 1, "fix_available": false, "vulnerability_ids": vuln("CVE-2026-3333")},
					// fixable but old (already known): must not count
					{"title": "d", "severity": "Critical", "date": old, "test": 1, "fix_available": true, "vulnerability_ids": vuln("CVE-2020-4444")},
				}, 4)))
			default:
				_, _ = w.Write([]byte(dojoPage([]map[string]any{}, 0)))
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func dojoConfig(url string) hr.Config {
	return hr.Config{DojoURL: url, DojoPassword: "secret", LookbackHours: 24}
}

func byKind(obs []*hr.Observation) map[string][]*hr.Observation {
	out := map[string][]*hr.Observation{}
	for _, o := range obs {
		out[o.Kind] = append(out[o.Kind], o)
	}
	return out
}

func TestDefectDojoReportsOnlyActionableFindings(t *testing.T) {
	now := time.Now()
	srv := fakeDojo(t, now, now.Add(-2*time.Hour))
	result := collectDefectDojo(dojoConfig(srv.URL), hr.RulesFile{})
	kinds := byKind(result.Observations)

	fixable := kinds["vuln_new_fixable"]
	if len(fixable) != 1 || fixable[0].Value != 2 {
		t.Fatalf("vuln_new_fixable = %+v, want one observation counting 2 (new+fixable only)", fixable)
	}
	if fixable[0].ID != "vuln_new_fixable.nuc: nginx:1.19." {
		t.Fatalf("id = %q", fixable[0].ID)
	}
	exploited := kinds["vuln_known_exploited"]
	if len(exploited) != 1 || exploited[0].Subject != "nuc: host packages" || exploited[0].Value != 1 {
		t.Fatalf("vuln_known_exploited = %+v, want the KEV finding in host packages", exploited)
	}
	if len(kinds["vuln_scan_stale"]) != 0 {
		t.Fatalf("fresh scan reported stale: %+v", kinds["vuln_scan_stale"])
	}
}

func TestDefectDojoFlagsStaleScan(t *testing.T) {
	now := time.Now()
	srv := fakeDojo(t, now, now.Add(-48*time.Hour))
	result := collectDefectDojo(dojoConfig(srv.URL), hr.RulesFile{})
	stale := byKind(result.Observations)["vuln_scan_stale"]
	if len(stale) != 1 || stale[0].Subject != "nuc/trivy-nightly" {
		t.Fatalf("vuln_scan_stale = %+v, want one for nuc/trivy-nightly", stale)
	}
}

func TestDefectDojoUnconfiguredIsUnavailable(t *testing.T) {
	result := collectDefectDojo(hr.Config{}, hr.RulesFile{})
	if result.Status != "unavailable" || len(result.Observations) != 0 {
		t.Fatalf("status %q with %d observations, want unavailable and none", result.Status, len(result.Observations))
	}
}

func TestDefectDojoBadPasswordPanicsForCollectorFailed(t *testing.T) {
	now := time.Now()
	srv := fakeDojo(t, now, now)
	cfg := dojoConfig(srv.URL)
	cfg.DojoPassword = "wrong"
	defer func() {
		if recover() == nil {
			t.Fatal("want a panic (recorded as collector_failed), got a clean result")
		}
	}()
	collectDefectDojo(cfg, hr.RulesFile{})
}

func TestDojoFirstSeenSince(t *testing.T) {
	since := time.Date(2026, 10, 22, 6, 0, 0, 0, time.UTC)
	cases := map[string]bool{"2026-10-22": true, "2026-10-23": true, "2026-10-21": false, "garbage": false}
	for date, want := range cases {
		if got := dojoFirstSeenSince(date, since); got != want {
			t.Errorf("dojoFirstSeenSince(%q) = %v, want %v", date, got, want)
		}
	}
}
