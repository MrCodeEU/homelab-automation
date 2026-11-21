// Package maintwindow parses the weekly maintenance window, written as
// "<weekday> <HH:MM> <length>" in local time, e.g. "Sun 01:20 40m". The
// deploy agent applies its weekly maintenance (docker prune, reboot when
// needed) in it; ziti-notify and the alerting stay quiet during it.
package maintwindow

import (
	"fmt"
	"strings"
	"time"
)

// Weekly is one window per week.
type Weekly struct {
	Day    time.Weekday
	Hour   int
	Minute int
	Length time.Duration
}

var days = map[string]time.Weekday{
	"sun": time.Sunday, "mon": time.Monday, "tue": time.Tuesday, "wed": time.Wednesday,
	"thu": time.Thursday, "fri": time.Friday, "sat": time.Saturday,
}

// Parse reads "Sun 01:20 40m". The length is at least a minute and less
// than a day.
func Parse(s string) (Weekly, error) {
	f := strings.Fields(s)
	if len(f) != 3 {
		return Weekly{}, fmt.Errorf("window %q: want \"<weekday> <HH:MM> <length>\"", s)
	}
	day, ok := days[strings.ToLower(f[0])]
	if !ok {
		return Weekly{}, fmt.Errorf("window %q: weekday %q, want Sun..Sat", s, f[0])
	}
	t, err := time.Parse("15:04", f[1])
	if err != nil {
		return Weekly{}, fmt.Errorf("window %q: time %q, want HH:MM", s, f[1])
	}
	length, err := time.ParseDuration(f[2])
	if err != nil || length < time.Minute || length >= 24*time.Hour {
		return Weekly{}, fmt.Errorf("window %q: length %q, want 1m to under 24h", s, f[2])
	}
	return Weekly{Day: day, Hour: t.Hour(), Minute: t.Minute(), Length: length}, nil
}

// Start is the newest window start at or before t, in t's location.
func (w Weekly) Start(t time.Time) time.Time {
	start := time.Date(t.Year(), t.Month(), t.Day(), w.Hour, w.Minute, 0, 0, t.Location())
	start = start.AddDate(0, 0, -int((t.Weekday()-w.Day+7)%7))
	if start.After(t) {
		start = start.AddDate(0, 0, -7)
	}
	return start
}

// Contains reports whether t is inside a window.
func (w Weekly) Contains(t time.Time) bool {
	return t.Before(w.Start(t).Add(w.Length))
}
