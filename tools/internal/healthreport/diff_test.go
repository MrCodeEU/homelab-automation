package healthreport

import "testing"

const testNow = "2026-07-28T06:00:00+02:00"
const testYesterday = "2026-07-27T06:00:00+02:00"

func diffObs(id, severity string) *Observation {
	if severity == "" {
		severity = "warn"
	}
	return &Observation{ID: id, Collector: "test", Subject: "mljr", Kind: "disk_usage", Message: id, Severity: severity, Evidence: map[string]any{}}
}

func prevFacts(pairs ...[2]string) PreviousFacts {
	var pf PreviousFacts
	for _, p := range pairs {
		pf.Observations = append(pf.Observations, PrevObservation{ID: p[0], Severity: p[1]})
	}
	return pf
}

func strPtr(s string) *string { return &s }

func TestBrandNewIssue(t *testing.T) {
	seen := map[string]*SeenRecord{}
	result := Compute([]*Observation{diffObs("a", "")}, PreviousFacts{}, seen, testNow)
	if len(result.New) != 1 || result.New[0] != "a" {
		t.Fatalf("new = %v", result.New)
	}
	if len(result.Persisting) != 0 {
		t.Fatalf("persisting = %v", result.Persisting)
	}
}

func TestPersistingIssueKeepsFirstSeen(t *testing.T) {
	seen := map[string]*SeenRecord{
		"a": {FirstSeen: testYesterday, LastSeen: testYesterday, Count: 1, LastActionableRun: strPtr(testYesterday), Severity: "warn"},
	}
	item := diffObs("a", "")
	result := Compute([]*Observation{item}, prevFacts([2]string{"a", "warn"}), seen, testNow)
	if len(result.New) != 0 {
		t.Fatalf("new = %v", result.New)
	}
	if len(result.Persisting) != 1 || result.Persisting[0] != "a" {
		t.Fatalf("persisting = %v", result.Persisting)
	}
	if item.FirstSeen != testYesterday {
		t.Fatalf("first_seen = %v, want survival for age derivation", item.FirstSeen)
	}
}

func TestResolvedIsReported(t *testing.T) {
	seen := map[string]*SeenRecord{}
	result := Compute(nil, prevFacts([2]string{"a", "crit"}), seen, testNow)
	if len(result.Resolved) != 1 || result.Resolved[0] != "a" {
		t.Fatalf("resolved = %v", result.Resolved)
	}
}

func TestReopenedIsNotNew(t *testing.T) {
	seen := map[string]*SeenRecord{
		"a": {FirstSeen: "2026-07-01T06:00:00+02:00", LastSeen: testYesterday, Count: 3,
			LastActionableRun: strPtr(testYesterday), Severity: "warn", ResolvedAt: testYesterday},
	}
	result := Compute([]*Observation{diffObs("a", "")}, PreviousFacts{}, seen, testNow)
	if len(result.Reopened) != 1 || result.Reopened[0] != "a" {
		t.Fatalf("reopened = %v", result.Reopened)
	}
	if len(result.New) != 0 {
		t.Fatalf("new = %v", result.New)
	}
}

func TestReopenedResetsFirstSeen(t *testing.T) {
	// security_updates uses a stable per-host id, not per-advisory, so a
	// resolve-then-reopen is a genuinely new occurrence of the problem. If
	// FirstSeen carried over from the original occurrence, min_age_days
	// gates would treat it as already old and let it alert on day one.
	seen := map[string]*SeenRecord{
		"a": {FirstSeen: "2026-07-01T06:00:00+02:00", LastSeen: testYesterday, Count: 3,
			LastActionableRun: strPtr(testYesterday), Severity: "warn", ResolvedAt: testYesterday},
	}
	item := diffObs("a", "")
	Compute([]*Observation{item}, PreviousFacts{}, seen, testNow)
	if item.FirstSeen != testNow {
		t.Fatalf("first_seen = %v, want reset to %v on reopen", item.FirstSeen, testNow)
	}
	if seen["a"].FirstSeen != testNow {
		t.Fatalf("record first_seen = %v, want reset to %v on reopen", seen["a"].FirstSeen, testNow)
	}
	if seen["a"].ResolvedAt != "" {
		t.Fatalf("resolved_at = %v, want cleared on reopen", seen["a"].ResolvedAt)
	}
}

func TestWorsenedAndImproved(t *testing.T) {
	seen := map[string]*SeenRecord{}
	result := Compute([]*Observation{diffObs("a", "crit")}, prevFacts([2]string{"a", "warn"}), seen, testNow)
	if len(result.Worsened) != 1 || result.Worsened[0] != (SeverityTransition{"a", "warn", "crit"}) {
		t.Fatalf("worsened = %v", result.Worsened)
	}

	seen2 := map[string]*SeenRecord{}
	result2 := Compute([]*Observation{diffObs("b", "warn")}, prevFacts([2]string{"b", "crit"}), seen2, testNow)
	if len(result2.Improved) != 1 || result2.Improved[0] != (SeverityTransition{"b", "crit", "warn"}) {
		t.Fatalf("improved = %v", result2.Improved)
	}
}

func TestInfoObservationsAreNotActionable(t *testing.T) {
	// An info-level observation existing yesterday must not stop the same
	// id counting as new when it escalates to warn today.
	seen := map[string]*SeenRecord{}
	result := Compute([]*Observation{diffObs("a", "warn")}, prevFacts([2]string{"a", "info"}), seen, testNow)
	if len(result.New) != 1 || result.New[0] != "a" {
		t.Fatalf("new = %v", result.New)
	}
}

func TestInfoStillRecordedInSeen(t *testing.T) {
	seen := map[string]*SeenRecord{}
	Compute([]*Observation{diffObs("a", "info")}, PreviousFacts{}, seen, testNow)
	record, ok := seen["a"]
	if !ok {
		t.Fatal("new_only rules depend on info observations being tracked")
	}
	if record.LastActionableRun != nil {
		t.Fatalf("last_actionable_run = %v", record.LastActionableRun)
	}
}

func TestLastValueIsRecordedAndReadBack(t *testing.T) {
	seen := map[string]*SeenRecord{}
	item := diffObs("a", "")
	item.Value = 1200.0
	Compute([]*Observation{item}, PreviousFacts{}, seen, testNow)
	if seen["a"].LastValue != 1200.0 {
		t.Fatalf("last_value = %v", seen["a"].LastValue)
	}

	later := diffObs("a", "")
	AttachPreviousValues([]*Observation{later}, seen)
	if later.PreviousValue != 1200.0 {
		t.Fatalf("previous_value = %v", later.PreviousValue)
	}
}

func TestFirstSeenIsReadBackForMinAgeRules(t *testing.T) {
	seen := map[string]*SeenRecord{}
	item := diffObs("a", "")
	Compute([]*Observation{item}, PreviousFacts{}, seen, testNow)
	if seen["a"].FirstSeen != testNow {
		t.Fatalf("first_seen = %v", seen["a"].FirstSeen)
	}

	later := diffObs("a", "")
	AttachPreviousValues([]*Observation{later}, seen)
	if later.FirstSeen != testNow {
		t.Fatalf("first_seen = %v", later.FirstSeen)
	}
}

func TestFirstSeenStaysUnsetForAGenuinelyNewObservation(t *testing.T) {
	later := diffObs("a", "")
	AttachPreviousValues([]*Observation{later}, map[string]*SeenRecord{})
	if later.FirstSeen != nil {
		t.Fatalf("first_seen = %v", later.FirstSeen)
	}
}

func TestLastValueIgnoresNonNumericAndBools(t *testing.T) {
	seen := map[string]*SeenRecord{}
	text := diffObs("t", "")
	text.Value = "DISK_DSBL"
	flag := diffObs("f", "")
	flag.Value = true
	Compute([]*Observation{text, flag}, PreviousFacts{}, seen, testNow)
	// A bool would compare as 1 and read as a rate.
	if seen["t"].LastValue != nil {
		t.Fatalf("last_value = %v", seen["t"].LastValue)
	}
	if seen["f"].LastValue != nil {
		t.Fatalf("last_value = %v", seen["f"].LastValue)
	}
}

func TestPruneDropsStaleEntries(t *testing.T) {
	seen := map[string]*SeenRecord{
		"old":    {LastSeen: "2026-01-01T06:00:00+02:00", LastActionableRun: nil},
		"recent": {LastSeen: "2026-07-27T06:00:00+02:00", LastActionableRun: nil},
	}
	removed := PruneSeen(seen, testNow, 60)
	if removed != 1 {
		t.Fatalf("removed = %d", removed)
	}
	if _, ok := seen["old"]; ok {
		t.Fatal("old should have been pruned")
	}
	if _, ok := seen["recent"]; !ok {
		t.Fatal("recent should survive")
	}
}

func TestPruneNeverDropsACurrentlyActionableEntry(t *testing.T) {
	seen := map[string]*SeenRecord{"a": {LastSeen: "2026-01-01T06:00:00+02:00", LastActionableRun: strPtr(testNow)}}
	if removed := PruneSeen(seen, testNow, 60); removed != 0 {
		t.Fatalf("removed = %d", removed)
	}
	if _, ok := seen["a"]; !ok {
		t.Fatal("a should survive")
	}
}

func TestPruneToleratesMissingOrBadTimestamps(t *testing.T) {
	seen := map[string]*SeenRecord{
		"no_ts":  {LastActionableRun: nil},
		"bad_ts": {LastSeen: "not-a-date", LastActionableRun: nil},
	}
	if removed := PruneSeen(seen, testNow, 60); removed != 0 {
		t.Fatalf("removed = %d", removed)
	}
	if len(seen) != 2 {
		t.Fatalf("len(seen) = %d", len(seen))
	}
}
