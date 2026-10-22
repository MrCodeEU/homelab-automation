package collectors

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"gopkg.in/yaml.v3"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
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

func TestCollectHomeIPDisabledWithoutExpectedIP(t *testing.T) {
	result := collectHomeIP(hr.Config{}, hr.RulesFile{})
	if len(result.Observations) != 0 {
		t.Fatalf("got %d observations, want none when HomeIP is unset", len(result.Observations))
	}
}

// The expected IP exists in two places on purpose (hiera for healthreport,
// the parser file for CrowdSec). Fail the build if they drift, so the
// alert always compares against what CrowdSec really trusts.
func TestHomePublicIPMatchesCrowdSecAllowlist(t *testing.T) {
	var hiera struct {
		HomePublicIP string `yaml:"home_public_ip"`
	}
	readYAML(t, "../../../../openvox/data/common.yaml", &hiera)
	if hiera.HomePublicIP == "" {
		t.Fatal("home_public_ip missing from openvox/data/common.yaml")
	}

	var allowlist struct {
		Whitelist struct {
			IP []string `yaml:"ip"`
		} `yaml:"whitelist"`
	}
	readYAML(t, "../../../../services/crowdsec/parsers/s02-enrich/mljr-local-allowlist.yaml", &allowlist)
	for _, ip := range allowlist.Whitelist.IP {
		if ip == hiera.HomePublicIP {
			return
		}
	}
	t.Fatalf("home_public_ip %q is not in mljr-local-allowlist.yaml ip list %v",
		hiera.HomePublicIP, allowlist.Whitelist.IP)
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
