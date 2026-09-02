package collectors

import "testing"

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
