// Markdown rendering for the report body and the ntfy headline.
package healthreport

import (
	"fmt"
	"strings"
)

func obsByID(facts *Facts) map[string]*Observation {
	out := map[string]*Observation{}
	for _, obs := range facts.Observations {
		out[obs.ID] = obs
	}
	return out
}

func SummaryCounts(facts *Facts) string {
	var parts []string
	if facts.Summary.Crit > 0 {
		parts = append(parts, fmt.Sprintf("%d crit", facts.Summary.Crit))
	}
	if facts.Summary.Warn > 0 {
		parts = append(parts, fmt.Sprintf("%d warn", facts.Summary.Warn))
	}
	if len(parts) == 0 {
		parts = append(parts, "all clear")
	}
	parts = append(parts, fmt.Sprintf("%d new", len(facts.Diff.New)))
	if len(facts.Diff.Resolved) > 0 {
		parts = append(parts, fmt.Sprintf("%d resolved", len(facts.Diff.Resolved)))
	}
	return strings.Join(parts, " · ")
}

func worstNew(facts *Facts, byID map[string]*Observation) *Observation {
	var best *Observation
	for _, id := range facts.Diff.New {
		obs, ok := byID[id]
		if !ok {
			continue
		}
		if best == nil || SeverityRank(obs.Severity) > SeverityRank(best.Severity) {
			best = obs
		}
	}
	return best
}

// renderFallback is the mechanical narrative used whenever the LLM is off,
// unreachable or returned something unusable. The report must always be
// sendable without it.
func renderFallback(facts *Facts, worst *Observation) string {
	var b strings.Builder
	switch {
	case facts.Summary.Crit > 0:
		b.WriteString(fmt.Sprintf("**%d critical**", facts.Summary.Crit))
		if facts.Summary.Warn > 0 {
			b.WriteString(fmt.Sprintf(", %d warnings", facts.Summary.Warn))
		}
		b.WriteString(".\n")
	case facts.Summary.Warn > 0:
		b.WriteString(fmt.Sprintf("**%d warnings**, nothing critical.\n", facts.Summary.Warn))
	default:
		b.WriteString("**All clear** — nothing above informational.\n")
	}

	switch {
	case len(facts.Diff.New) > 0:
		b.WriteString(fmt.Sprintf("%d new since the last run", len(facts.Diff.New)))
		if worst != nil {
			b.WriteString(fmt.Sprintf(", worst: `%s` — %s", worst.ID, worst.Message))
		}
		b.WriteString(".\n")
	case len(facts.Diff.Persisting) > 0:
		plural := "s"
		if len(facts.Diff.Persisting) == 1 {
			plural = ""
		}
		b.WriteString(fmt.Sprintf("Nothing new; %d issue%s still open.\n", len(facts.Diff.Persisting), plural))
	default:
		b.WriteString("Nothing new and nothing open.\n")
	}

	if len(facts.Summary.CollectorsFailed) > 0 {
		plural := "s"
		if len(facts.Summary.CollectorsFailed) == 1 {
			plural = ""
		}
		b.WriteString(fmt.Sprintf("%d collector%s failed, so this report is incomplete.\n", len(facts.Summary.CollectorsFailed), plural))
	}

	return strings.TrimSpace(b.String())
}

func obsLine(obs *Observation, showAge bool, persisting map[string]bool) string {
	line := fmt.Sprintf("- **%s** `%s` — %s", strings.ToUpper(obs.Severity), obs.ID, obs.Message)
	if fs, ok := obs.FirstSeen.(string); ok && fs != "" && persisting[obs.ID] {
		date := fs
		if len(date) > 10 {
			date = date[:10]
		}
		line += fmt.Sprintf(" _(since %s)_", date)
	}
	return line
}

func dateOnly(id string) string {
	if len(id) > 10 {
		return id[:10]
	}
	return id
}

func runDate(facts *Facts) string {
	return dateOnly(facts.Run.ID)
}

// Render produces the plain-text/Markdown report body and its mechanical
// fallback narrative.
func Render(facts *Facts, narrative *Narrative) (body string, fallback string) {
	byID := obsByID(facts)
	fallback = renderFallback(facts, worstNew(facts, byID))

	persisting := map[string]bool{}
	for _, id := range facts.Diff.Persisting {
		persisting[id] = true
	}

	var b strings.Builder
	fmt.Fprintf(&b, "# Homelab health — %s\n\n", runDate(facts))

	if narrative != nil {
		fmt.Fprintf(&b, "**%s**\n\n%s\n", narrative.Headline, narrative.Assessment)
	} else {
		b.WriteString(fallback + "\n")
	}
	b.WriteString("\n" + SummaryCounts(facts) + "\n\n")

	if len(facts.Diff.New) > 0 {
		fmt.Fprintf(&b, "## New today (%d)\n", len(facts.Diff.New))
		for _, id := range facts.Diff.New {
			if obs, ok := byID[id]; ok {
				b.WriteString(obsLine(obs, false, persisting) + "\n")
			}
		}
		b.WriteString("\n")
	}

	if len(facts.Diff.Worsened) > 0 {
		fmt.Fprintf(&b, "## Worsened (%d)\n", len(facts.Diff.Worsened))
		for _, w := range facts.Diff.Worsened {
			msg := ""
			if obs, ok := byID[w.ID]; ok {
				msg = obs.Message
			}
			fmt.Fprintf(&b, "- **%s → %s** `%s` — %s\n", strings.ToUpper(w.From), strings.ToUpper(w.To), w.ID, msg)
		}
		b.WriteString("\n")
	}

	if len(facts.Diff.Reopened) > 0 {
		fmt.Fprintf(&b, "## Reopened (%d)\n", len(facts.Diff.Reopened))
		for _, id := range facts.Diff.Reopened {
			if obs, ok := byID[id]; ok {
				b.WriteString(obsLine(obs, true, persisting) + "\n")
			}
		}
		b.WriteString("\n")
	}

	if narrative != nil && len(narrative.TopIssues) > 0 {
		b.WriteString("## What to look at first\n")
		for i, issue := range narrative.TopIssues {
			fmt.Fprintf(&b, "%d. `%s` — %s\n", i+1, issue.ObservationID, issue.WhyItMatters)
		}
		b.WriteString("\n")
	}

	if narrative != nil && len(narrative.SuggestedActions) > 0 {
		b.WriteString("### Suggested actions\n")
		for _, a := range narrative.SuggestedActions {
			b.WriteString("- " + a + "\n")
		}
		b.WriteString("\n")
	}

	if narrative != nil && len(narrative.Correlations) > 0 {
		b.WriteString("### Possible correlations\n")
		for _, c := range narrative.Correlations {
			b.WriteString("- " + c + "\n")
		}
		b.WriteString("\n")
	}

	if len(facts.Diff.Resolved) > 0 {
		fmt.Fprintf(&b, "## Resolved since last run (%d)\n", len(facts.Diff.Resolved))
		for _, id := range facts.Diff.Resolved {
			b.WriteString("- `" + id + "`\n")
		}
		b.WriteString("\n")
	}

	if len(facts.Diff.Persisting) > 0 {
		fmt.Fprintf(&b, "## Still open (%d)\n", len(facts.Diff.Persisting))
		for _, id := range facts.Diff.Persisting {
			if obs, ok := byID[id]; ok {
				b.WriteString(obsLine(obs, true, persisting) + "\n")
			}
		}
		b.WriteString("\n")
	}

	if len(facts.Summary.CollectorsFailed) > 0 {
		b.WriteString("## Collectors that did not run\n")
		for _, name := range facts.Summary.CollectorsFailed {
			errMsg := ""
			if c, ok := facts.Collectors[name]; ok {
				errMsg = c.Error
			}
			fmt.Fprintf(&b, "- `%s` — %s\n", name, errMsg)
		}
		b.WriteString("\n")
	}

	b.WriteString("---\n")
	fmt.Fprintf(&b, "Run %s on %s · LLM: %s · %d observations from %d collectors.\n",
		facts.Run.ID, facts.Run.Host, facts.LLMStatus, len(facts.Observations), len(facts.Collectors))

	return b.String(), fallback
}

func Headline(facts *Facts, narrative *Narrative, fallback string) string {
	if narrative != nil && narrative.Headline != "" {
		return narrative.Headline
	}
	// First line of the mechanical summary, stripped of Markdown emphasis.
	if fallback == "" {
		return "Homelab health"
	}
	lines := strings.SplitN(fallback, "\n", 2)
	return strings.ReplaceAll(lines[0], "**", "")
}

func NtfyBody(facts *Facts, narrative *Narrative, fallback string, limit int) string {
	byID := obsByID(facts)
	lines := []string{SummaryCounts(facts)}

	highlights := facts.Diff.New
	if len(highlights) == 0 {
		highlights = facts.Diff.Persisting
	}
	if len(highlights) > limit {
		highlights = highlights[:limit]
	}
	for _, id := range highlights {
		if obs, ok := byID[id]; ok {
			lines = append(lines, strings.ToUpper(obs.Severity)+" "+obs.Message)
		}
	}

	if len(facts.Summary.CollectorsFailed) > 0 {
		lines = append(lines, "collectors failed: "+strings.Join(facts.Summary.CollectorsFailed, ", "))
	}

	out := strings.Join(lines, "\n")
	if len(out) > 3800 {
		out = out[:3800]
	}
	return out
}
