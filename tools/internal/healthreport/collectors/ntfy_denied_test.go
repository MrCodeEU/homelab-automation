package collectors

import (
	"encoding/json"
	"testing"
)

func TestTopicFromDeniedLineExtractsPathBasedTopic(t *testing.T) {
	line := `{"request":{"uri":"/docker-updates/json?poll=1","method":"GET","host":"ntfy.mljr.eu"},"status":403}`
	got := topicFromDeniedLine(line)
	if got != "docker-updates" {
		t.Fatalf("got %q, want docker-updates", got)
	}
}

func TestTopicFromDeniedLineRootPublishHasNoTopic(t *testing.T) {
	// Uptime-Kuma/diun publish JSON-body to "/" - topic lives in the body,
	// invisible to the access log. Must fall back to unknown, not panic
	// or misreport "/" as a topic name.
	line := `{"request":{"uri":"/","method":"POST","host":"ntfy.mljr.eu"},"status":403}`
	got := topicFromDeniedLine(line)
	if got != "" {
		t.Fatalf("got %q, want empty (undeterminable)", got)
	}
}

func TestTopicFromDeniedLineHandlesGarbage(t *testing.T) {
	if got := topicFromDeniedLine("not json"); got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

func TestIsScannerNoise(t *testing.T) {
	cases := map[string]bool{
		`{"request":{"uri":"/api","headers":{"User-Agent":["Mozilla/5.0 (X11; Linux x86_64)"]}}}`: true,
		`{"request":{"uri":"/cgi/logout","headers":{}}}`:                                          true,
		`{"request":{"uri":"/backup","headers":{"User-Agent":["curl/8.6.0"]}}}`:                   false,
		`{"request":{"uri":"/","headers":{"User-Agent":["axios/1.7.2"]}}}`:                        false,
	}
	for line, want := range cases {
		var parsed caddyAccessLine
		if err := json.Unmarshal([]byte(line), &parsed); err != nil {
			t.Fatal(err)
		}
		if got := isScannerNoise(parsed); got != want {
			t.Errorf("%s: got %v, want %v", line, got, want)
		}
	}
}
