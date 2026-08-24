package backupdashboard

import (
	_ "embed"
	"fmt"
	"html/template"
	"sort"
	"strings"
	"time"
)

//go:embed template.html
var templateSource string

var page = template.Must(template.New("page").Parse(templateSource))

type hostCard struct {
	Name     string
	State    string
	Reason   string
	AgeLabel string
	HasAge   bool
}

type destCard struct {
	Name        string
	UsedLabel   string
	FreeLabel   string
	UsedPercent float64
	GaugeClass  string
}

type entryRow struct {
	Name         string
	TypeLabel    string
	IsFolder     bool
	Host         string
	Source       string
	Destinations []string
	State        string
}

type errorRow struct {
	Host   string
	Reason string
}

type pageData struct {
	GeneratedAt        string
	CatalogGeneratedAt string
	Hosts              []hostCard
	Destinations       []destCard
	Entries            []entryRow
	Errors             []errorRow
	SummaryOK          int
	SummaryDegraded    int
	SummaryUnknown     int
	SummaryTotal       int
}

func formatTimestamp(iso string) string {
	if iso == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339, iso)
	if err != nil {
		return iso
	}
	return t.UTC().Format("2006-01-02 15:04 UTC")
}

func formatAge(seconds *float64) (string, bool) {
	if seconds == nil {
		return "", false
	}
	d := time.Duration(*seconds * float64(time.Second))
	hours := d.Hours()
	if hours < 1 {
		return fmt.Sprintf("%dm ago", int(d.Minutes())), true
	}
	if hours < 48 {
		return fmt.Sprintf("%.1fh ago", hours), true
	}
	return fmt.Sprintf("%.1fd ago", hours/24), true
}

func titleCase(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func gaugeClass(percent float64) string {
	switch {
	case percent > 90:
		return "fill-crit"
	case percent > 80:
		return "fill-warn"
	default:
		return "fill-ok"
	}
}

func buildPageData(snap *Snapshot) pageData {
	pd := pageData{
		GeneratedAt:        formatTimestamp(snap.GeneratedAt),
		CatalogGeneratedAt: formatTimestamp(snap.CatalogGeneratedAt),
	}

	for _, name := range snap.HostOrder {
		status := snap.Hosts[name]
		ageLabel, hasAge := formatAge(status.AgeSeconds)
		pd.Hosts = append(pd.Hosts, hostCard{
			Name:     name,
			State:    status.State,
			Reason:   status.Reason,
			AgeLabel: ageLabel,
			HasAge:   hasAge,
		})
		switch status.State {
		case "ok":
			pd.SummaryOK++
		case "degraded":
			pd.SummaryDegraded++
		default:
			pd.SummaryUnknown++
		}
	}
	pd.SummaryTotal = len(pd.Hosts)

	for _, name := range snap.DestinationOrder {
		usage := snap.Destinations[name]
		pd.Destinations = append(pd.Destinations, destCard{
			Name:        name,
			UsedLabel:   fmt.Sprintf("%.1f%%", usage.UsedPercent),
			FreeLabel:   fmt.Sprintf("%.1f GiB free", usage.FreeGiB),
			UsedPercent: usage.UsedPercent,
			GaugeClass:  gaugeClass(usage.UsedPercent),
		})
	}

	for _, entry := range snap.Entries {
		pd.Entries = append(pd.Entries, entryRow{
			Name:         entry.Name,
			TypeLabel:    titleCase(entry.Type),
			IsFolder:     entry.Type == "folder",
			Host:         entry.Host,
			Source:       entry.SourceDisplay(),
			Destinations: entry.Destinations,
			State:        entry.Badge,
		})
	}

	var errHosts []string
	for host := range snap.Errors {
		errHosts = append(errHosts, host)
	}
	sort.Strings(errHosts)
	for _, host := range errHosts {
		pd.Errors = append(pd.Errors, errorRow{Host: host, Reason: snap.Errors[host]})
	}

	return pd
}

func Render(snap *Snapshot) (string, error) {
	var buf strings.Builder
	if err := page.Execute(&buf, buildPageData(snap)); err != nil {
		return "", err
	}
	return buf.String(), nil
}
