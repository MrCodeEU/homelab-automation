package healthreport

import (
	"strings"
	"testing"
	"time"
)

func loadTestRules(t *testing.T) RulesFile {
	t.Helper()
	rf, err := LoadRules("../../../services/healthreport/rules.yml")
	if err != nil {
		t.Fatalf("load rules: %v", err)
	}
	return rf
}

func testObs(kind string, value any, subject string) *Observation {
	return &Observation{
		ID: kind + "." + subject + ".", Collector: "test", Subject: subject, Kind: kind,
		Value: value, Message: "x", Evidence: map[string]any{},
	}
}

func check(t *testing.T, rules RulesFile, kind string, value any, expected string, subject string) {
	t.Helper()
	obs := testObs(kind, value, subject)
	got := Classify(obs, rules.Rules[kind], false, nil)
	if got != expected {
		t.Errorf("%s=%v expected %s, got %s", kind, value, expected, got)
	}
}

func TestThresholdsAbove(t *testing.T) {
	rules := loadTestRules(t)
	check(t, rules, "disk_usage", 50.0, "info", "mljr")
	check(t, rules, "disk_usage", 86.0, "warn", "mljr")
	check(t, rules, "disk_usage", 91.0, "crit", "mljr")
	check(t, rules, "disk_usage", 85.0, "info", "mljr")
	check(t, rules, "disk_usage", 90.0, "warn", "mljr")
}

func TestThresholdsBelow(t *testing.T) {
	rules := loadTestRules(t)
	check(t, rules, "cert_expiry", 60.0, "info", "mljr")
	check(t, rules, "cert_expiry", 20.0, "warn", "mljr")
	check(t, rules, "cert_expiry", 3.0, "crit", "mljr")
}

func TestEqualsAndNotEquals(t *testing.T) {
	rules := loadTestRules(t)
	check(t, rules, "monitor_status", "up", "info", "mljr")
	check(t, rules, "monitor_status", "down", "crit", "mljr")
	check(t, rules, "monitor_status", "pending", "warn", "mljr")
	check(t, rules, "array_state", "STARTED", "info", "mljr")
	check(t, rules, "array_state", "STOPPED", "crit", "mljr")
}

func TestFalsyEscalates(t *testing.T) {
	rules := loadTestRules(t)
	check(t, rules, "smart_health", true, "info", "mljr")
	check(t, rules, "smart_health", false, "crit", "mljr")
	check(t, rules, "smart_health", "false", "crit", "mljr")
}

func TestZeroToleranceCounters(t *testing.T) {
	rules := loadTestRules(t)
	check(t, rules, "parity_sync_errors", 0.0, "info", "mljr")
	check(t, rules, "parity_sync_errors", 1.0, "crit", "mljr")
	check(t, rules, "pending_sectors", 0.0, "info", "mljr")
	check(t, rules, "pending_sectors", 4.0, "crit", "mljr")
}

func TestSubjectScoping(t *testing.T) {
	rules := loadTestRules(t)
	check(t, rules, "crowdsec_absent", "not running", "crit", "mljr")
	check(t, rules, "crowdsec_absent", "not running", "info", "nuc")
}

func TestNewOnlyNeedsTheDiff(t *testing.T) {
	rules := loadTestRules(t)
	rule := rules.Rules["log_signature"]
	sig := testObs("log_signature", 5.0, "mljr")
	if got := Classify(sig, rule, false, nil); got != "info" {
		t.Errorf("got %s want info", got)
	}
	sig2 := testObs("log_signature", 5.0, "mljr")
	if got := Classify(sig2, rule, true, nil); got != "warn" {
		t.Errorf("got %s want warn", got)
	}
}

func rateSeverity(t *testing.T, rules RulesFile, value float64, previous any) string {
	t.Helper()
	o := testObs("log_error_rate", value, "nuc")
	o.PreviousValue = previous
	return Classify(o, rules.Rules["log_error_rate"], false, nil)
}

func TestSpikeAbsoluteThresholdStillApplies(t *testing.T) {
	rules := loadTestRules(t)
	if got := rateSeverity(t, rules, 6000, nil); got != "warn" {
		t.Errorf("got %s", got)
	}
	if got := rateSeverity(t, rules, 4999, nil); got != "info" {
		t.Errorf("got %s", got)
	}
}

func TestSpikeEscalatesBelowTheAbsoluteThreshold(t *testing.T) {
	rules := loadTestRules(t)
	if got := rateSeverity(t, rules, 3000, 800.0); got != "warn" {
		t.Errorf("got %s", got)
	}
}

func TestSpikeNeedsABaseline(t *testing.T) {
	rules := loadTestRules(t)
	if got := rateSeverity(t, rules, 3000, nil); got != "info" {
		t.Errorf("got %s", got)
	}
	if got := rateSeverity(t, rules, 3000, 0.0); got != "info" {
		t.Errorf("got %s", got)
	}
}

func TestSpikeRespectsTheFloor(t *testing.T) {
	rules := loadTestRules(t)
	if got := rateSeverity(t, rules, 100, 10.0); got != "info" {
		t.Errorf("got %s", got)
	}
	if got := rateSeverity(t, rules, 500, 100.0); got != "warn" {
		t.Errorf("got %s", got)
	}
}

func TestSpikeBoundaryIsInclusive(t *testing.T) {
	rules := loadTestRules(t)
	if got := rateSeverity(t, rules, 3000, 1000.0); got != "warn" {
		t.Errorf("got %s", got)
	}
	if got := rateSeverity(t, rules, 2999, 1000.0); got != "info" {
		t.Errorf("got %s", got)
	}
}

func TestSpikeNeverFiresOnADrop(t *testing.T) {
	rules := loadTestRules(t)
	if got := rateSeverity(t, rules, 600, 50000.0); got != "info" {
		t.Errorf("got %s", got)
	}
}

func TestSpikeAnnotatesTheMessage(t *testing.T) {
	rules := loadTestRules(t)
	o := testObs("log_error_rate", 3000.0, "nuc")
	o.PreviousValue = 600.0
	Classify(o, rules.Rules["log_error_rate"], false, nil)
	if !strings.Contains(o.Message, "up 5.0x from 600") {
		t.Errorf("message = %q", o.Message)
	}
}

func TestUnknownKindStaysInfo(t *testing.T) {
	rules := loadTestRules(t)
	if got := Classify(testObs("something_invented", 999.0, "mljr"), rules.Rules["something_invented"], false, nil); got != "info" {
		t.Errorf("got %s", got)
	}
}

func TestApplySetsSeverityAndThreshold(t *testing.T) {
	rules := loadTestRules(t)
	items := []*Observation{testObs("disk_usage", 95.0, "mljr"), testObs("disk_usage", 10.0, "nuc")}
	Apply(items, rules, map[string]bool{}, nil)
	if items[0].Severity != "crit" {
		t.Errorf("severity = %s", items[0].Severity)
	}
	if items[0].Threshold != 90.0 {
		t.Errorf("threshold = %v", items[0].Threshold)
	}
	if items[1].Severity != "info" {
		t.Errorf("severity = %s", items[1].Severity)
	}
}

func TestMinAgeDaysHoldsAFreshBreachAtInfo(t *testing.T) {
	rules := loadTestRules(t)
	now := time.Date(2026, 8, 19, 0, 0, 0, 0, time.UTC)

	o := testObs("security_updates", 3.0, "mljr")
	o.FirstSeen = now.Format(time.RFC3339)
	if got := Classify(o, rules.Rules["security_updates"], false, &now); got != "info" {
		t.Errorf("got %s", got)
	}

	o2 := testObs("security_updates", 3.0, "mljr")
	o2.FirstSeen = now.AddDate(0, 0, -6).Format(time.RFC3339)
	if got := Classify(o2, rules.Rules["security_updates"], false, &now); got != "info" {
		t.Errorf("got %s", got)
	}
}

func TestMinAgeDaysEscalatesOnceTheWindowPasses(t *testing.T) {
	rules := loadTestRules(t)
	now := time.Date(2026, 8, 19, 0, 0, 0, 0, time.UTC)
	o := testObs("security_updates", 3.0, "mljr")
	o.FirstSeen = now.Add(-7*24*time.Hour - time.Minute).Format(time.RFC3339)
	if got := Classify(o, rules.Rules["security_updates"], false, &now); got != "warn" {
		t.Errorf("got %s", got)
	}
}

func TestMinAgeDaysWithNoFirstSeenStaysInfo(t *testing.T) {
	rules := loadTestRules(t)
	now := time.Date(2026, 8, 19, 0, 0, 0, 0, time.UTC)
	o := testObs("security_updates", 3.0, "mljr")
	if got := Classify(o, rules.Rules["security_updates"], false, &now); got != "info" {
		t.Errorf("got %s", got)
	}
}
