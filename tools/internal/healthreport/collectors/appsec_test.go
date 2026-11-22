package collectors

import (
	"fmt"
	"testing"
	"time"
)

func TestAppSecUnavailableQueryExcludesThePoCListener(t *testing.T) {
	// The PoC container logs the same line during its fail-open tests.
	for _, want := range []string{`host="mljr"`, `container!="caddy-poc"`, "appsec component unavailable"} {
		if !contains(appsecUnavailableQuery, want) {
			t.Fatalf("query %q does not contain %q", appsecUnavailableQuery, want)
		}
	}
}

func TestSplitAppSecLinesUsesTheLoggedTime(t *testing.T) {
	windows := parseMaintenanceWindows([]string{"sun 01:00-02:00"})
	reboot := at(2026, time.November, 22, 1, 33)  // Sunday, mljr's maintenance reboot
	shipped := at(2026, time.November, 22, 8, 37) // when Loki received it (ingest delayed)
	later := at(2026, time.November, 22, 10, 0)
	line := func(ts time.Time) string {
		return fmt.Sprintf(`Nov 22 01:33:12 vmi2945702 caddy-crowdsec[1068]: {"level":"error","ts":%d.1393197,"logger":"crowdsec.appsec","msg":"appsec component unavailable"}`, ts.Unix())
	}
	nanos := func(ts time.Time) string { return fmt.Sprint(ts.UnixNano()) }
	streams := []lokiStream{{Values: [][2]string{
		{nanos(shipped), line(reboot)},      // in the window by its own ts, not by Loki's
		{nanos(later), line(later)},         // outside: counted
		{nanos(reboot), "no ts field here"}, // falls back to the Loki timestamp: in the window
		{nanos(later), "no ts field here"},  // fallback, outside: counted
	}}}
	kept, suppressed := splitAppSecLines(streams, windows)
	if kept != 2 || suppressed != 2 {
		t.Fatalf("kept=%d suppressed=%d, want 2 and 2", kept, suppressed)
	}
	if kept, suppressed := splitAppSecLines(streams, nil); kept != 4 || suppressed != 0 {
		t.Fatalf("no windows: kept=%d suppressed=%d, want 4 and 0", kept, suppressed)
	}
}
