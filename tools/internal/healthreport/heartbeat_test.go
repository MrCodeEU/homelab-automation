package healthreport

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPingHeartbeat(t *testing.T) {
	if got := PingHeartbeat(Config{}); !strings.HasPrefix(got, "skipped") {
		t.Errorf("no URL: %q", got)
	}

	hits := 0
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++ }))
	defer ok.Close()
	if got := PingHeartbeat(Config{HeartbeatURL: ok.URL + "/hb/?s=tok"}); got != "" || hits != 1 {
		t.Errorf("ok server: %q, %d hits", got, hits)
	}

	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }))
	defer bad.Close()
	if got := PingHeartbeat(Config{HeartbeatURL: bad.URL + "/hb/?s=tok"}); !strings.Contains(got, "500") {
		t.Errorf("500 server: %q", got)
	}

	// An unreachable monitor must not leak its token into the report.
	got := PingHeartbeat(Config{HeartbeatURL: "http://127.0.0.1:1/hb/?s=secret-token"})
	if got == "" || strings.Contains(got, "secret-token") {
		t.Errorf("unreachable: %q", got)
	}
}
