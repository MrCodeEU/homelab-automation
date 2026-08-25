package backupdashboard

import (
	"testing"
	"time"
)

func mustLoadVienna(t *testing.T) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(hostTZ)
	if err != nil {
		t.Fatalf("LoadLocation(%q): %v", hostTZ, err)
	}
	return loc
}

func TestNextRunBeforeToday(t *testing.T) {
	loc := mustLoadVienna(t)
	now := time.Date(2026, 8, 25, 1, 0, 0, 0, loc) // 01:00, before 03:00
	label, ok := NextRun("03:00:00", now)
	if !ok {
		t.Fatal("expected ok")
	}
	if label != "03:00 (in 2h 0m)" {
		t.Errorf("got %q", label)
	}
}

func TestNextRunAfterToday(t *testing.T) {
	loc := mustLoadVienna(t)
	now := time.Date(2026, 8, 25, 5, 0, 0, 0, loc) // 05:00, after 03:00
	label, ok := NextRun("03:00:00", now)
	if !ok {
		t.Fatal("expected ok")
	}
	if label != "03:00 (in 22h 0m)" {
		t.Errorf("got %q", label)
	}
}

func TestNextRunExactBoundary(t *testing.T) {
	loc := mustLoadVienna(t)
	now := time.Date(2026, 8, 25, 3, 0, 0, 0, loc) // exactly 03:00 - already happened
	label, ok := NextRun("03:00:00", now)
	if !ok {
		t.Fatal("expected ok")
	}
	if label != "03:00 (in 24h 0m)" {
		t.Errorf("got %q", label)
	}
}

func TestNextRunEmptySchedule(t *testing.T) {
	if _, ok := NextRun("", time.Now()); ok {
		t.Error("expected ok=false for empty schedule")
	}
}

func TestNextRunInvalidSchedule(t *testing.T) {
	if _, ok := NextRun("not-a-time", time.Now()); ok {
		t.Error("expected ok=false for invalid schedule")
	}
	if _, ok := NextRun("25:00:00", time.Now()); ok {
		t.Error("expected ok=false for out-of-range hour")
	}
}
