package healthreport

import (
	"bytes"
	_ "embed"
	"fmt"
	"html/template"
	"math"
)

//go:embed report.html.tmpl
var reportHTMLSource string

var reportHTMLTemplate = template.Must(template.New("report").Funcs(template.FuncMap{
	"add": func(a, b int) int { return a + b },
}).Parse(reportHTMLSource))

type htmlTile struct {
	Label string
	Value int
	Color string
}

type htmlTrendPoint struct {
	Date        string
	Total       int
	WarnHeight  int
	CritHeight  int
	HasWarn     bool
	HasCrit     bool
}

type htmlHostRow struct {
	Subject  string
	Crit     int
	Warn     int
	CritPct  float64
	WarnPct  float64
	CritText string
}

type htmlFilesystem struct {
	Mountpoint  string
	UsedPercent float64
	BarColor    string
}

type htmlStateHost struct {
	Name           string
	Uptime         string
	MemoryLabel    string
	LoadLabel      string
	Filesystems    []htmlFilesystem
}

type htmlBackupTarget struct {
	Name        string
	HasPercent  bool
	UsedPercent float64
	BarColor    string
	Detail      string
}

type htmlObsRow struct {
	Severity      string
	SeverityColor string
	Message       string
	ID            string
	ShowAge       bool
	FirstSeenDate string
}

type htmlSection struct {
	Title string
	Rows  []htmlObsRow
}

type htmlCollectorFailure struct {
	Name  string
	Error string
}

type htmlTopIssue struct {
	ObservationID string
	WhyItMatters  string
}

type htmlPageData struct {
	Headline         string
	RunID            string
	RunDate          string
	RunHost          string
	ObservationCount int
	Tiles            []htmlTile
	HasNarrative     bool
	Assessment       string
	Trend            []htmlTrendPoint
	ByHost           []htmlHostRow
	TopIssues        []htmlTopIssue
	SuggestedActions []string
	HasStateHosts    bool
	StateCounts      []StateCount
	StateHosts       []htmlStateHost
	BackupTargets    []htmlBackupTarget
	Notes            []string
	Sections         []htmlSection
	Resolved         []string
	CollectorsFailed []htmlCollectorFailure
	LLMStatus        string
	CollectorCount   int
}

func severityColor(severity string) string {
	switch severity {
	case "crit":
		return "#d03b3b"
	case "warn":
		return "#fab219"
	default:
		return "#0ca30c"
	}
}

func mountBarColor(percent float64) string {
	switch {
	case percent >= 85:
		return "#d03b3b"
	case percent >= 70:
		return "#fab219"
	default:
		return "#0ca30c"
	}
}

func targetBarColor(percent float64) string {
	switch {
	case percent >= 93:
		return "#d03b3b"
	case percent >= 85:
		return "#fab219"
	default:
		return "#0ca30c"
	}
}

func round1f(v float64) float64 { return math.Round(v*10) / 10 }

func buildHTMLPageData(facts *Facts, narrative *Narrative, headline, stateDir string) htmlPageData {
	summary := facts.Summary
	diff := facts.Diff
	byID := obsByID(facts)

	rows := func(ids []string) []*Observation {
		out := make([]*Observation, 0, len(ids))
		for _, id := range ids {
			if obs, ok := byID[id]; ok {
				out = append(out, obs)
			}
		}
		return out
	}
	toRows := func(obs []*Observation, showAge bool) []htmlObsRow {
		out := make([]htmlObsRow, 0, len(obs))
		for _, o := range obs {
			date := ""
			if fs, ok := o.FirstSeen.(string); ok && fs != "" {
				date = dateOnly(fs)
			}
			out = append(out, htmlObsRow{
				Severity: o.Severity, SeverityColor: severityColor(o.Severity), Message: o.Message,
				ID: o.ID, ShowAge: showAge, FirstSeenDate: date,
			})
		}
		return out
	}

	sections := []htmlSection{
		{Title: fmt.Sprintf("New today (%d)", len(diff.New)), Rows: toRows(rows(diff.New), false)},
		{Title: fmt.Sprintf("Reopened (%d)", len(diff.Reopened)), Rows: toRows(rows(diff.Reopened), true)},
		{Title: fmt.Sprintf("Still open (%d)", len(diff.Persisting)), Rows: toRows(rows(diff.Persisting), true)},
	}
	var nonEmptySections []htmlSection
	for _, s := range sections {
		if len(s.Rows) > 0 {
			nonEmptySections = append(nonEmptySections, s)
		}
	}

	byHost := ByHost(facts)
	hostMax := 1
	for _, r := range byHost {
		if r.Total > hostMax {
			hostMax = r.Total
		}
	}
	hostRows := make([]htmlHostRow, 0, len(byHost))
	for i, r := range byHost {
		if i >= 8 {
			break
		}
		critText := ""
		if r.Crit > 0 {
			critText = fmt.Sprintf("%d crit", r.Crit)
		}
		if r.Crit > 0 && r.Warn > 0 {
			critText += ", "
		}
		if r.Warn > 0 {
			critText += fmt.Sprintf("%d warn", r.Warn)
		}
		hostRows = append(hostRows, htmlHostRow{
			Subject: r.Subject, Crit: r.Crit, Warn: r.Warn,
			CritPct: round1f(float64(r.Crit) / float64(hostMax) * 100),
			WarnPct: round1f(float64(r.Warn) / float64(hostMax) * 100),
			CritText: critText,
		})
	}

	trendPoints := Trend(stateDir, 10)
	trendMax := 1
	for _, p := range trendPoints {
		if p.Crit+p.Warn > trendMax {
			trendMax = p.Crit + p.Warn
		}
	}
	const trendHeight = 90
	trend := make([]htmlTrendPoint, 0, len(trendPoints))
	for _, p := range trendPoints {
		total := p.Crit + p.Warn
		warnH := int(math.Round(float64(p.Warn) / float64(trendMax) * float64(trendHeight-18)))
		critH := int(math.Round(float64(p.Crit) / float64(trendMax) * float64(trendHeight-18)))
		trend = append(trend, htmlTrendPoint{
			Date: p.Date, Total: total, WarnHeight: warnH, CritHeight: critH,
			HasWarn: p.Warn > 0, HasCrit: p.Crit > 0,
		})
	}

	stateHosts := StateHosts(facts)
	htmlHosts := make([]htmlStateHost, 0, len(stateHosts))
	for _, h := range stateHosts {
		memLabel := "?"
		if h.MemoryPercent != nil {
			memLabel = fmt.Sprintf("%.1f", round1f(*h.MemoryPercent))
		}
		loadLabel := "?"
		if h.LoadPerCore != nil {
			loadLabel = fmt.Sprintf("%v", *h.LoadPerCore)
		}
		fsRows := make([]htmlFilesystem, 0, len(h.Filesystems))
		for _, m := range h.Filesystems {
			fsRows = append(fsRows, htmlFilesystem{
				Mountpoint: m.Mountpoint, UsedPercent: round1f(m.UsedPercent), BarColor: mountBarColor(m.UsedPercent),
			})
		}
		htmlHosts = append(htmlHosts, htmlStateHost{
			Name: h.Name, Uptime: h.Uptime, MemoryLabel: memLabel, LoadLabel: loadLabel, Filesystems: fsRows,
		})
	}

	backupTargets := StateBackupTargets(facts)
	htmlTargets := make([]htmlBackupTarget, 0, len(backupTargets))
	for _, t := range backupTargets {
		bt := htmlBackupTarget{Name: t.Name}
		if t.UsedPercent != nil {
			bt.HasPercent = true
			bt.UsedPercent = round1f(*t.UsedPercent)
			bt.BarColor = targetBarColor(*t.UsedPercent)
			free := "?"
			if t.FreeGiB != nil {
				free = fmt.Sprint(*t.FreeGiB)
			}
			bt.Detail = fmt.Sprintf("%.1f%% · %s GiB free", bt.UsedPercent, free)
		} else {
			note := t.Note
			if note == "" {
				note = "unknown"
			}
			bt.Detail = note
		}
		htmlTargets = append(htmlTargets, bt)
	}

	var topIssues []htmlTopIssue
	var suggestedActions []string
	assessment := ""
	hasNarrative := narrative != nil
	if hasNarrative {
		assessment = narrative.Assessment
		suggestedActions = narrative.SuggestedActions
		for _, issue := range narrative.TopIssues {
			topIssues = append(topIssues, htmlTopIssue{ObservationID: issue.ObservationID, WhyItMatters: issue.WhyItMatters})
		}
	}

	var collectorsFailed []htmlCollectorFailure
	for _, name := range summary.CollectorsFailed {
		errMsg := ""
		if c, ok := facts.Collectors[name]; ok {
			errMsg = c.Error
		}
		collectorsFailed = append(collectorsFailed, htmlCollectorFailure{Name: name, Error: errMsg})
	}

	return htmlPageData{
		Headline: headline, RunID: facts.Run.ID, RunDate: dateOnly(facts.Run.ID), RunHost: facts.Run.Host,
		ObservationCount: len(facts.Observations),
		Tiles: []htmlTile{
			{"Critical", summary.Crit, "#d03b3b"},
			{"Warnings", summary.Warn, "#fab219"},
			{"New", len(diff.New), "#0b0b0b"},
			{"Resolved", len(diff.Resolved), "#0ca30c"},
		},
		HasNarrative: hasNarrative, Assessment: assessment,
		Trend: trend, ByHost: hostRows,
		TopIssues: topIssues, SuggestedActions: suggestedActions,
		HasStateHosts: len(htmlHosts) > 0, StateCounts: StateCounts(facts), StateHosts: htmlHosts,
		BackupTargets: htmlTargets, Notes: StateNotes(facts),
		Sections: nonEmptySections, Resolved: diff.Resolved, CollectorsFailed: collectorsFailed,
		LLMStatus: facts.LLMStatus, CollectorCount: len(facts.Collectors),
	}
}

// RenderHTML is the HTML part of the email. Charts are table cells with
// background colours, because email clients have no JavaScript and several
// strip SVG.
func RenderHTML(facts *Facts, narrative *Narrative, headline, stateDir string) (string, error) {
	data := buildHTMLPageData(facts, narrative, headline, stateDir)
	var buf bytes.Buffer
	if err := reportHTMLTemplate.Execute(&buf, data); err != nil {
		return "", err
	}
	return buf.String(), nil
}
