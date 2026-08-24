package healthreport

import (
	"strings"
	"testing"
)

func sampleFacts() *Facts {
	obsA := &Observation{ID: "disk_usage.nas./mnt", Collector: "host_metrics", Subject: "nas", Kind: "disk_usage",
		Message: "nas /mnt at 92.0% used", Severity: "crit", Value: 92.0, Evidence: map[string]any{}}
	obsB := &Observation{ID: "backup_age.mljr.", Collector: "ssh_facts", Subject: "mljr", Kind: "backup_age",
		Message: "mljr last backup ran 40.0 hours ago", Severity: "warn", Value: 40.0, FirstSeen: "2026-08-01T06:00:00Z", Evidence: map[string]any{}}
	facts := &Facts{
		SchemaVersion: 1,
		Run:           RunInfo{ID: "2026-08-24T06:00", StartedAt: "2026-08-24T06:00:00Z", Host: "nuc"},
		Collectors: map[string]*CollectorResult{
			"host_metrics": {Status: "ok"},
			"ssh_facts":    {Status: "ok"},
			"logs":         {Status: "error", Error: "loki timeout"},
		},
		Observations: []*Observation{obsA, obsB},
		Diff: DiffResult{
			New: []string{"disk_usage.nas./mnt"}, Persisting: []string{"backup_age.mljr."},
			Worsened: []SeverityTransition{}, Improved: []SeverityTransition{}, Reopened: []string{}, Resolved: []string{},
		},
		Summary:   Summary{Crit: 1, Warn: 1, Info: 0, CollectorsFailed: []string{"logs"}},
		LLMStatus: "disabled",
	}
	return facts
}

func TestRenderMarkdownProducesExpectedSections(t *testing.T) {
	facts := sampleFacts()
	body, fallback := Render(facts, nil)

	for _, want := range []string{
		"# Homelab health — 2026-08-24",
		"## New today (1)",
		"CRIT",
		"disk_usage.nas./mnt",
		"## Still open (1)",
		"backup_age.mljr.",
		"(since 2026-08-01)",
		"## Collectors that did not run",
		"`logs` — loki timeout",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("body missing %q\n---\n%s", want, body)
		}
	}
	if !strings.Contains(fallback, "1 critical") {
		t.Errorf("fallback = %q", fallback)
	}
}

func TestHeadlineFallsBackToFirstFallbackLine(t *testing.T) {
	facts := sampleFacts()
	_, fallback := Render(facts, nil)
	headline := Headline(facts, nil, fallback)
	if strings.Contains(headline, "**") {
		t.Errorf("headline should have markdown stripped: %q", headline)
	}
	if headline == "" {
		t.Error("headline should not be empty")
	}
}

func TestHeadlinePrefersNarrative(t *testing.T) {
	facts := sampleFacts()
	narrative := &Narrative{Headline: "nas filling up", Assessment: "x"}
	headline := Headline(facts, narrative, "")
	if headline != "nas filling up" {
		t.Errorf("headline = %q", headline)
	}
}

func TestRenderHTMLProducesWellFormedPage(t *testing.T) {
	facts := sampleFacts()
	narrative := &Narrative{
		Headline: "nas filling up", Assessment: "disk usage crossed 90%",
		TopIssues: []TopIssue{{ObservationID: "disk_usage.nas./mnt", WhyItMatters: "will fail writes soon"}},
		SuggestedActions: []string{"free up space on nas"},
	}
	html, err := RenderHTML(facts, narrative, "nas filling up", "/nonexistent-state-dir")
	if err != nil {
		t.Fatalf("RenderHTML: %v", err)
	}
	for _, want := range []string{
		"nas filling up", "disk usage crossed 90%", "will fail writes soon",
		"free up space on nas", "disk_usage.nas./mnt", "backup_age.mljr.",
		"This report is incomplete", "loki timeout",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("html missing %q", want)
		}
	}
}

func TestRenderHTMLEscapesObservationMessages(t *testing.T) {
	// Normalized log signatures contain literal <ts>/<path>/<n> placeholders,
	// which must render as text, not be swallowed as unknown HTML tags.
	facts := sampleFacts()
	facts.Observations[0].Message = "container x logged <ts> <path> errors"
	facts.Diff.New = []string{facts.Observations[0].ID}
	html, err := RenderHTML(facts, nil, "x", "/nonexistent-state-dir")
	if err != nil {
		t.Fatalf("RenderHTML: %v", err)
	}
	if strings.Contains(html, "<ts>") || strings.Contains(html, "<path>") {
		t.Error("raw angle brackets leaked into HTML output unescaped")
	}
	if !strings.Contains(html, "&lt;ts&gt;") {
		t.Error("expected escaped placeholder in HTML output")
	}
}
