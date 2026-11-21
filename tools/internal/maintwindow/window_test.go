package maintwindow

import (
	"testing"
	"time"
)

func TestParse(t *testing.T) {
	w, err := Parse("Sun 01:20 40m")
	if err != nil {
		t.Fatal(err)
	}
	if w != (Weekly{Day: time.Sunday, Hour: 1, Minute: 20, Length: 40 * time.Minute}) {
		t.Fatalf("got %+v", w)
	}
	for _, bad := range []string{"", "Sun 01:20", "Son 01:20 40m", "Sun 1:2x 40m", "Sun 01:20 30s", "Sun 01:20 24h", "Sun 01:20 40m x"} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("Parse(%q): want an error", bad)
		}
	}
}

func TestStartContains(t *testing.T) {
	vienna, err := time.LoadLocation("Europe/Vienna")
	if err != nil {
		t.Skip(err)
	}
	w, _ := Parse("Sun 01:20 40m")
	at := func(s string) time.Time {
		v, err := time.ParseInLocation("2006-01-02 15:04", s, vienna)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	for _, c := range []struct {
		now, start string
		in         bool
	}{
		{"2026-11-22 01:19", "2026-11-15 01:20", false}, // Sunday, just before
		{"2026-11-22 01:20", "2026-11-22 01:20", true},
		{"2026-11-22 01:59", "2026-11-22 01:20", true},
		{"2026-11-22 02:00", "2026-11-22 01:20", false},
		{"2026-11-25 12:00", "2026-11-22 01:20", false}, // Wednesday
		{"2026-11-21 23:00", "2026-11-15 01:20", false}, // Saturday
		{"2027-03-28 01:30", "2027-03-28 01:20", true},  // DST starts at 02:00
	} {
		now := at(c.now)
		if got := w.Start(now); !got.Equal(at(c.start)) {
			t.Errorf("Start(%s) = %s, want %s", c.now, got, c.start)
		}
		if got := w.Contains(now); got != c.in {
			t.Errorf("Contains(%s) = %t, want %t", c.now, got, c.in)
		}
	}
}
