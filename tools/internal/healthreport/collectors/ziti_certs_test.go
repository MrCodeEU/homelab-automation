package collectors

import (
	"testing"
	"time"
)

func TestEvaluateZitiCerts(t *testing.T) {
	now := time.Date(2027, 10, 20, 12, 0, 0, 0, time.UTC)
	certs := []zitiCert{
		{"mljr", "caddy-mljr", "/etc/caddy/ziti/caddy-mljr.json", now.Add(200 * 24 * time.Hour)},
		{"nuc", "kuma-nuc", "/opt/kuma/ziti/kuma-nuc.json", now.Add(12 * 24 * time.Hour)},
	}
	fails := []zitiCert{{host: "nuc", name: "kuma-nuc", file: "/opt/kuma/ziti/kuma-nuc.json"}}
	runs := map[string]time.Time{"mljr": now.Add(-3 * time.Hour), "ugreen": now.Add(-72 * time.Hour)}
	got := evaluateZitiCerts(now, certs, fails, runs)
	var kinds []string
	for _, o := range got {
		kinds = append(kinds, o.Kind+":"+o.Subject)
	}
	want := []string{"ziti_cert_expiring:nuc/kuma-nuc", "ziti_cert_renew_failed:nuc/kuma-nuc", "ziti_cert_renew_stale:ugreen"}
	if len(kinds) != len(want) {
		t.Fatalf("got %v, want %v", kinds, want)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Errorf("got %v, want %v", kinds, want)
		}
	}
	if got[0].Value != int64(12) {
		t.Errorf("days left %v", got[0].Value)
	}
}
