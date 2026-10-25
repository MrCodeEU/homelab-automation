package collectors

import "testing"

func TestCountLokiLinesSumsAllStreams(t *testing.T) {
	streams := []lokiStream{
		{Values: [][2]string{{"1", "a"}, {"2", "b"}}},
		{Values: [][2]string{{"3", "c"}}},
		{},
	}
	if got := countLokiLines(streams); got != 3 {
		t.Fatalf("got %d, want 3", got)
	}
	if got := countLokiLines(nil); got != 0 {
		t.Fatalf("nil streams: got %d, want 0", got)
	}
}

func TestAppSecUnavailableQueryExcludesThePoCListener(t *testing.T) {
	// The PoC container logs the same line during its fail-open tests.
	for _, want := range []string{`host="mljr"`, `container!="caddy-poc"`, "appsec component unavailable"} {
		if !contains(appsecUnavailableQuery, want) {
			t.Fatalf("query %q does not contain %q", appsecUnavailableQuery, want)
		}
	}
}
