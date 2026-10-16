package healthreport

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSendNtfyEmailFailure(t *testing.T) {
	var gotTitle, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotTitle, gotBody = r.Header.Get("Title"), string(b)
	}))
	defer srv.Close()

	cfg := Config{NtfyURL: srv.URL, NtfyTopic: "t"}
	if e := SendNtfyEmailFailure(cfg, &Facts{}, "email: 454", "REPORT"); e != "" {
		t.Fatalf("unexpected error: %s", e)
	}
	if !strings.Contains(gotTitle, "FAILED") || !strings.Contains(gotBody, "454") || !strings.Contains(gotBody, "REPORT") {
		t.Errorf("title=%q body=%q", gotTitle, gotBody)
	}
}

func TestSendEmailNoRelayConfigured(t *testing.T) {
	if e := SendEmail(Config{EmailTo: "a@b.c"}, &Facts{}, "s", "b", ""); !strings.HasPrefix(e, "skipped") {
		t.Errorf("got %q", e)
	}
}

func TestSendEmailAllRelaysFail(t *testing.T) {
	cfg := Config{EmailTo: "a@b.c", SMTPHost: "127.0.0.1", SMTPPort: 1, SMTP2Host: "127.0.0.1", SMTP2Port: 2}
	e := SendEmail(cfg, &Facts{}, "s", "b", "")
	if !strings.Contains(e, "relay 1") || !strings.Contains(e, "relay 2") {
		t.Errorf("both relays should be reported, got %q", e)
	}
}
