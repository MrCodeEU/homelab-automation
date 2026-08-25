package backupdashboard

import (
	"fmt"
	"time"
)

// hostTZ is the timezone every backup host in this repo runs in
// (roles::base's $timezone default, unoverridden on mljr/nuc/nas) - systemd
// OnCalendar= timers fire in the host's local time, not UTC, so next-run
// math has to happen in this zone even though the rest of the dashboard
// displays UTC timestamps.
const hostTZ = "Europe/Vienna"

// NextRun computes the next occurrence of a daily HH:MM:SS time-of-day
// schedule, relative to now, and a human label like "03:00 (in 4h 12m)".
// Returns ok=false if schedule doesn't parse - callers should omit the
// next-run display rather than show something wrong.
func NextRun(schedule string, now time.Time) (label string, ok bool) {
	if schedule == "" {
		return "", false
	}
	loc, err := time.LoadLocation(hostTZ)
	if err != nil {
		loc = time.UTC
	}
	local := now.In(loc)

	var h, m, s int
	if _, err := fmt.Sscanf(schedule, "%d:%d:%d", &h, &m, &s); err != nil {
		return "", false
	}
	if h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59 {
		return "", false
	}

	next := time.Date(local.Year(), local.Month(), local.Day(), h, m, s, 0, loc)
	if !next.After(local) {
		next = next.AddDate(0, 0, 1)
	}

	until := next.Sub(local)
	hours := int(until.Hours())
	minutes := int(until.Minutes()) % 60

	return fmt.Sprintf("%02d:%02d (in %dh %dm)", h, m, hours, minutes), true
}
