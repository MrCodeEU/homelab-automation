package backupdashboard

import (
	_ "embed"
	"encoding/json"
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
	Name              string
	State             string
	Reason            string
	AgeLabel          string
	HasAge            bool
	VerificationLabel string
}

type destCard struct {
	Name        string
	UsedLabel   string
	FreeLabel   string
	UsedPercent float64
	GaugeClass  string
}

type historyCard struct {
	Name    string
	State   string
	Details string
}

type entryRow struct {
	Name         string
	TypeLabel    string
	IsFolder     bool
	Host         string
	Source       string
	Destinations []string
	State        string
	HasStats     bool
	SizeLabel    string
	FileCount    int64
}

// formatBytes renders a byte count as a human-readable size, matching the
// GiB/MiB scale the rest of the dashboard already uses for destination
// capacity (destCard.FreeLabel).
func formatBytes(n int64) string {
	const unit = 1024.0
	f := float64(n)
	if f < unit {
		return fmt.Sprintf("%d B", n)
	}
	units := []string{"KiB", "MiB", "GiB", "TiB", "PiB"}
	div, exp := unit, 0
	for f/div >= unit && exp < len(units)-1 {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %s", f/div, units[exp])
}

type errorRow struct {
	Host   string
	Reason string
}

// graphNode is one node in the flow-diagram's node-link graph - hosts,
// catalog entries, and destinations all become nodes, rendered client-side
// with a force layout (see the inline script in template.html). Positions
// are computed in the browser, not here: a server-computed static layout
// would need to be recomputed on window resize anyway, and the simulation
// itself is cheap for the graph sizes this dashboard ever has (a few dozen
// nodes).
type graphNode struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Kind  string `json:"kind"`            // "host" | "entry" | "dest"
	State string `json:"state,omitempty"` // entry nodes only: ok/degraded/failed/unknown
	Sub   string `json:"sub,omitempty"`   // host nodes: next-run label; entry nodes: size/file count
}

type graphLink struct {
	Source string `json:"source"`
	Target string `json:"target"`
}

type flowGraph struct {
	Nodes []graphNode `json:"nodes"`
	Links []graphLink `json:"links"`
}

// buildFlowGraph turns the catalog into a host -> entry -> destination
// graph. Host and destination nodes are deduplicated (many entries share a
// host or a destination); entry nodes are one per catalog entry.
func buildFlowGraph(snap *Snapshot) flowGraph {
	var g flowGraph
	seenHost := map[string]bool{}
	seenDest := map[string]bool{}

	for _, entry := range snap.Entries {
		hostID := "host:" + entry.Host
		if !seenHost[entry.Host] {
			seenHost[entry.Host] = true
			sub := ""
			if label, ok := NextRun(entry.Schedule, time.Now()); ok {
				sub = "Next run: " + label
			}
			g.Nodes = append(g.Nodes, graphNode{ID: hostID, Label: entry.Host, Kind: "host", Sub: sub})
		}

		entrySub := ""
		if entry.HasStats {
			entrySub = fmt.Sprintf("%s, %d files", formatBytes(entry.SizeBytes), entry.FileCount)
		}
		entryID := "entry:" + entry.Host + ":" + entry.Name
		g.Nodes = append(g.Nodes, graphNode{ID: entryID, Label: entry.Name, Kind: "entry", State: entry.Badge, Sub: entrySub})
		g.Links = append(g.Links, graphLink{Source: hostID, Target: entryID})

		for _, dest := range entry.Destinations {
			destID := "dest:" + dest
			if !seenDest[dest] {
				seenDest[dest] = true
				g.Nodes = append(g.Nodes, graphNode{ID: destID, Label: dest, Kind: "dest"})
			}
			g.Links = append(g.Links, graphLink{Source: entryID, Target: destID})
		}
	}

	return g
}

type pageData struct {
	GeneratedAt        string
	CatalogGeneratedAt string
	Hosts              []hostCard
	Destinations       []destCard
	History            []historyCard
	Entries            []entryRow
	HasFlowGraph       bool
	FlowGraphJSON      template.JS
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
		verification := "verification: not run"
		if status.VerificationAt != "" {
			verification = fmt.Sprintf("verification: %s (%s, %s)", status.VerificationState, status.VerificationMode, formatTimestamp(status.VerificationAt))
		}
		if status.RestoreAt != "" {
			verification += fmt.Sprintf("; restore: %s (%s)", status.RestoreState, formatTimestamp(status.RestoreAt))
		}
		pd.Hosts = append(pd.Hosts, hostCard{
			Name:              name,
			State:             status.State,
			Reason:            status.Reason,
			AgeLabel:          ageLabel,
			HasAge:            hasAge,
			VerificationLabel: verification,
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

	for _, history := range snap.History {
		details := fmt.Sprintf("%d snapshots", history.SnapshotCount)
		if history.FreePercent != nil {
			details += fmt.Sprintf(" · %.1f%% free (floor %d%%)", *history.FreePercent, history.FloorPercent)
		}
		if history.LatestSnapshot != nil {
			details += " · latest " + *history.LatestSnapshot
		}
		if history.Reason != "" {
			details += " · " + history.Reason
		}
		pd.History = append(pd.History, historyCard{Name: history.Name, State: history.State, Details: details})
	}

	for _, entry := range snap.Entries {
		row := entryRow{
			Name:         entry.Name,
			TypeLabel:    titleCase(entry.Type),
			IsFolder:     entry.Type == "folder",
			Host:         entry.Host,
			Source:       entry.SourceDisplay(),
			Destinations: entry.Destinations,
			State:        entry.Badge,
			HasStats:     entry.HasStats,
			FileCount:    entry.FileCount,
		}
		if entry.HasStats {
			row.SizeLabel = formatBytes(entry.SizeBytes)
		}
		pd.Entries = append(pd.Entries, row)
	}

	graph := buildFlowGraph(snap)
	pd.HasFlowGraph = len(graph.Nodes) > 0
	if graphJSON, err := json.Marshal(graph); err == nil {
		pd.FlowGraphJSON = template.JS(graphJSON)
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
