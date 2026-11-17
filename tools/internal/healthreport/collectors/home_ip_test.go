package collectors

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func ipServer(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestLookupPublicIPTrimsAndValidates(t *testing.T) {
	srv := ipServer(t, 200, "203.0.113.7\n")
	got, err := lookupPublicIP([]string{srv.URL}, time.Second)
	if err != nil || got != "203.0.113.7" {
		t.Fatalf("got %q, %v; want 203.0.113.7", got, err)
	}
}

func TestLookupPublicIPFallsBackToNextURL(t *testing.T) {
	bad := ipServer(t, 500, "boom")
	garbage := ipServer(t, 200, "<html>captive portal</html>")
	good := ipServer(t, 200, "203.0.113.7")
	got, err := lookupPublicIP([]string{bad.URL, garbage.URL, good.URL}, time.Second)
	if err != nil || got != "203.0.113.7" {
		t.Fatalf("got %q, %v; want fallback to the good URL", got, err)
	}
}

func TestLookupPublicIPAllFailIsError(t *testing.T) {
	bad := ipServer(t, 503, "down")
	if _, err := lookupPublicIP([]string{bad.URL}, time.Second); err == nil {
		t.Fatal("want error when every lookup fails, not a guessed IP")
	}
}

func TestEvaluateHomeIP(t *testing.T) {
	now := time.Date(2026, 11, 17, 20, 0, 0, 0, time.UTC)
	fresh := now.Add(-5 * time.Minute)
	for _, c := range []struct {
		name, current, listed string
		last                  time.Time
		want                  []string
	}{
		{"in sync", "203.0.113.7", "203.0.113.7", fresh, nil},
		{"new IP not synced", "203.0.113.8", "203.0.113.7", fresh, []string{"home_ip_mismatch"}},
		{"sync stopped", "203.0.113.7", "203.0.113.7", now.Add(-time.Hour), []string{"home_ip_sync_stale"}},
		{"never synced", "203.0.113.7", "", time.Time{}, []string{"home_ip_sync_stale"}},
	} {
		var kinds []string
		for _, o := range evaluateHomeIP(now, c.current, c.listed, c.last) {
			kinds = append(kinds, o.Kind)
		}
		if strings.Join(kinds, ",") != strings.Join(c.want, ",") {
			t.Errorf("%s: got %v, want %v", c.name, kinds, c.want)
		}
	}
}

// The owner IP must not come back as a static entry: the "home" allowlist
// (home-ip sync) is the only place it lives.
func TestCrowdSecParserHasNoStaticHomeIP(t *testing.T) {
	var allowlist struct {
		Whitelist struct {
			IP []string `yaml:"ip"`
		} `yaml:"whitelist"`
	}
	readYAML(t, "../../../../services/crowdsec/parsers/s02-enrich/mljr-local-allowlist.yaml", &allowlist)
	if len(allowlist.Whitelist.IP) != 0 {
		t.Fatalf("static IPs in mljr-local-allowlist.yaml: %v; the home IP is synced by roles::home_ip", allowlist.Whitelist.IP)
	}
}

func readYAML(t *testing.T, path string, out any) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal(data, out); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
}
