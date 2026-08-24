package collectors

import (
	"testing"
	"time"
)

// at builds a local-time timestamp for a fixed civil date/time, so these
// tests do not depend on the host's TZ in the same way the Python
// time.mktime-based fixtures did (Go uses time.Local explicitly instead).
func at(year int, month time.Month, day, hour, minute int) time.Time {
	return time.Date(year, month, day, hour, minute, 0, 0, time.Local)
}

func TestParseValidWindows(t *testing.T) {
	got := parseMaintenanceWindows([]string{"daily 00:00-00:10", "sun 04:55-08:00"})
	want := []maintenanceWindow{{day: -1, start: 0, end: 10}, {day: 6, start: 295, end: 480}}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
}

func TestParseDropsGarbageWithoutRaising(t *testing.T) {
	got := parseMaintenanceWindows([]string{"nonsense", "sun 25:00", "", "mon 01:00-02:00"})
	want := []maintenanceWindow{{day: 0, start: 60, end: 120}}
	if len(got) != 1 || got[0] != want[0] {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestDailyWindowMatchesAnyWeekday(t *testing.T) {
	windows := parseMaintenanceWindows([]string{"daily 00:00-00:10"})
	if !inWindow(at(2026, 7, 29, 0, 5), windows) {
		t.Error("expected match")
	}
	if !inWindow(at(2026, 8, 2, 0, 5), windows) {
		t.Error("expected match")
	}
	if inWindow(at(2026, 7, 29, 0, 30), windows) {
		t.Error("expected no match")
	}
}

func TestWeekdayWindowOnlyMatchesThatDay(t *testing.T) {
	// 2026-08-02 is a Sunday.
	windows := parseMaintenanceWindows([]string{"sun 04:55-08:00"})
	if !inWindow(at(2026, 8, 2, 6, 0), windows) {
		t.Error("expected match on Sunday")
	}
	if inWindow(at(2026, 8, 1, 6, 0), windows) {
		t.Error("expected no match on Saturday")
	}
}

func TestWindowEndIsExclusive(t *testing.T) {
	windows := parseMaintenanceWindows([]string{"sun 04:55-08:00"})
	if !inWindow(at(2026, 8, 2, 7, 59), windows) {
		t.Error("expected match just before end")
	}
	if inWindow(at(2026, 8, 2, 8, 0), windows) {
		t.Error("expected no match at end")
	}
}

func TestWindowWrappingMidnight(t *testing.T) {
	windows := parseMaintenanceWindows([]string{"sat 23:00-01:00"})
	if !inWindow(at(2026, 8, 1, 23, 30), windows) {
		t.Error("expected match Sat late")
	}
	if !inWindow(at(2026, 8, 2, 0, 30), windows) {
		t.Error("expected match Sun early")
	}
	if inWindow(at(2026, 8, 2, 1, 30), windows) {
		t.Error("expected no match")
	}
}

func TestSplitJudgesBucketByTheHourItCovers(t *testing.T) {
	// count_over_time([1h]) stamps a bucket at the END of the hour it
	// covers, so the 06:00 sample is the 05:00-06:00 traffic and must be
	// suppressed.
	windows := parseMaintenanceWindows([]string{"sun 04:55-08:00"})
	series := []sample{
		{at(2026, 8, 2, 5, 0).Unix(), 10.0},   // covers 04:00-05:00 -> outside
		{at(2026, 8, 2, 6, 0).Unix(), 2619.0}, // covers 05:00-06:00 -> inside
		{at(2026, 8, 2, 8, 0).Unix(), 3071.0}, // covers 07:00-08:00 -> inside
		{at(2026, 8, 2, 9, 0).Unix(), 182.0},  // covers 08:00-09:00 -> outside
	}
	kept, suppressed := splitMaintenance(series, windows)
	if len(kept) != 2 || kept[0].value != 10.0 || kept[1].value != 182.0 {
		t.Fatalf("kept = %v", kept)
	}
	if len(suppressed) != 2 || suppressed[0].value != 2619.0 || suppressed[1].value != 3071.0 {
		t.Fatalf("suppressed = %v", suppressed)
	}
}

func TestNoWindowsKeepsEverything(t *testing.T) {
	series := []sample{{at(2026, 8, 2, 6, 0).Unix(), 5.0}, {at(2026, 8, 2, 7, 0).Unix(), 7.0}}
	kept, suppressed := splitMaintenance(series, nil)
	if len(kept) != 2 || len(suppressed) != 0 {
		t.Fatalf("kept=%v suppressed=%v", kept, suppressed)
	}
}

func TestRealSundayShapeIsNoLongerAnIncident(t *testing.T) {
	// Observed 07-26: baseline ~180/h, three bad hours during the backup.
	windows := parseMaintenanceWindows([]string{"sun 04:55-08:00"})
	raw := []struct {
		hour  int
		value float64
	}{{3, 195.0}, {4, 180.0}, {5, 183.0}, {6, 2619.0}, {7, 3063.0}, {8, 3071.0}, {9, 182.0}, {10, 184.0}}
	var series []sample
	for _, r := range raw {
		series = append(series, sample{at(2026, 7, 26, r.hour, 0).Unix(), r.value})
	}
	kept, suppressed := splitMaintenance(series, windows)
	total := 0.0
	for _, s := range suppressed {
		total += s.value
	}
	if int(total) != 8753 {
		t.Fatalf("suppressed total = %d, want 8753", int(total))
	}
	max := 0.0
	for _, s := range kept {
		if s.value >= 100 && s.value > max {
			max = s.value
		}
	}
	if max >= 200 {
		t.Fatalf("bad hour max = %v, want < 200 (everything left is the flat baseline)", max)
	}
}

// --- normalize ---

// Real bichon output: the tracing crate colours its level and target fields.
const bichonLine = "\x1b[2m2026-07-29T08:05:31.371+00:00\x1b[0m \x1b[31mERROR\x1b[0m " +
	"\x1b[2mbichon_server\x1b[0m\x1b[2m:\x1b[0m Documentation: " +
	"https://github.com/rustmailer/bichon/wiki"

func TestAnsiIsStripped(t *testing.T) {
	got := normalize(bichonLine)
	if contains(got, "\x1b") || contains(got, "[31m") {
		t.Fatalf("got %q", got)
	}
}

func TestTimestampMaskedBehindAnsi(t *testing.T) {
	// The regression this guards: \x1b[2m ends in a word character, so a
	// timestamp glued to it has no word boundary and the <ts> rule misses.
	got := normalize(bichonLine)
	if got[:len("<ts> ERROR")] != "<ts> ERROR" {
		t.Fatalf("got %q", got)
	}
	if contains(got, "2026") {
		t.Fatalf("got %q", got)
	}
}

func TestSameEventDifferentTimestampsIsOneSignature(t *testing.T) {
	later := replaceOnce(bichonLine, "08:05:31.371", "09:17:02.884")
	if normalize(bichonLine) != normalize(later) {
		t.Fatal("expected same signature")
	}
}

func TestPlainLinesAreUnaffected(t *testing.T) {
	line := "2026-07-29T08:05:31Z ERROR could not connect to 10.0.0.5:5432"
	got := normalize(line)
	want := "<ts> ERROR could not connect to <ip>"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestUncolouredAndColouredCollapseTogether(t *testing.T) {
	plain := "2026-07-29T08:05:31.371+00:00 ERROR bichon_server: Documentation: https://github.com/rustmailer/bichon/wiki"
	if normalize(bichonLine) != normalize(plain) {
		t.Fatalf("normalize(bichon)=%q normalize(plain)=%q", normalize(bichonLine), normalize(plain))
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && indexOf(s, substr) >= 0
}

func indexOf(s, substr string) int {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}

func replaceOnce(s, old, new string) string {
	i := indexOf(s, old)
	if i < 0 {
		return s
	}
	return s[:i] + new + s[i+len(old):]
}
