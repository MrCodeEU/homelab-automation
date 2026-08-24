package healthreport

import (
	"encoding/json"
	"os"
	"testing"
)

func loadFixture(t *testing.T, name string) any {
	t.Helper()
	raw, err := os.ReadFile("../../../services/healthreport/tests/fixtures/" + name)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var parsed any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	return parsed
}

func TestValidateGoodFixtureDropsHallucinatedIDAndStripsSeverity(t *testing.T) {
	payload := loadFixture(t, "good-llm.json")
	validIDs := map[string]bool{"caddy_5xx.mljr.": true}

	narrative, err := ValidateNarrative(payload, validIDs)
	if err != nil {
		t.Fatalf("ValidateNarrative: %v", err)
	}
	if narrative.Headline != "One host is low on disk, everything else steady" {
		t.Errorf("headline = %q", narrative.Headline)
	}
	if len(narrative.TopIssues) != 1 || narrative.TopIssues[0].ObservationID != "caddy_5xx.mljr." {
		t.Fatalf("expected the hallucinated id dropped, got %+v", narrative.TopIssues)
	}
	if len(narrative.SuggestedActions) != 2 {
		t.Errorf("suggested_actions = %v", narrative.SuggestedActions)
	}
	if len(narrative.Correlations) != 1 {
		t.Errorf("correlations = %v", narrative.Correlations)
	}
}

func TestValidateBadFixtureIsRejected(t *testing.T) {
	payload := loadFixture(t, "bad-llm.json")
	if _, err := ValidateNarrative(payload, map[string]bool{}); err == nil {
		t.Fatal("expected the empty headline to be rejected")
	}
}
