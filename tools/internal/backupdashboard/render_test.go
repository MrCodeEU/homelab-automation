package backupdashboard

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRenderProducesWellFormedPage(t *testing.T) {
	age := 3600.0
	snap := &Snapshot{
		GeneratedAt:        "2026-08-24T09:00:00Z",
		CatalogGeneratedAt: "2026-08-24T08:00:00Z",
		HostOrder:          []string{"mljr", "nuc", "nas"},
		Hosts: map[string]HostStatus{
			"mljr": {State: "ok", AgeSeconds: &age, FailedServices: []string{}},
			"nuc":  {State: "degraded", FailedServices: []string{"forgejo"}},
			"nas":  {State: "unknown", Reason: "ssh timed out", FailedServices: []string{}},
		},
		DestinationOrder: []string{"pcloud", "ugreen"},
		Destinations: map[string]DestUsage{
			"pcloud": {UsedPercent: 67.1, FreeGiB: 412.3},
			"ugreen": {UsedPercent: 93.5, FreeGiB: 12.1},
		},
		Entries: []EntryWithBadge{
			{CatalogEntry: CatalogEntry{Name: "fotos", Type: "folder", Host: "nas", Source: "/mnt/user/Fotos", Destinations: []string{"pcloud", "ugreen"}, Schedule: "04:40:00"}, Badge: "ok"},
			{CatalogEntry: CatalogEntry{Name: "forgejo", Type: "service", Host: "nuc", Source: []any{"forgejo-data", "forgejo-db-data"}, Destinations: []string{"pcloud"}, Schedule: "03:00:00"}, Badge: "failed"},
		},
		Errors: map[string]string{"nas": "ssh timed out"},
	}

	html, err := Render(snap)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}

	for _, want := range []string{
		"<title>Backup Dashboard</title>",
		"mljr", "nuc", "nas",
		"pcloud", "ugreen",
		"fotos", "forgejo",
		"ssh timed out",
		"pill-ok", "pill-degraded", "pill-unknown", "pill-failed",
		"fill-crit", // ugreen at 93.5% must hit the critical gauge class
		"Backup flow", "flow-graph", "flow-graph-data",
		"Next run:",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("rendered HTML missing %q", want)
		}
	}

	if strings.Count(html, "<html") != 1 || !strings.Contains(html, "</html>") {
		t.Error("rendered HTML doesn't look well-formed")
	}
}

func TestRenderFlowGraphJSONShape(t *testing.T) {
	snap := &Snapshot{
		Hosts:        map[string]HostStatus{},
		Destinations: map[string]DestUsage{},
		Errors:       map[string]string{},
		Entries: []EntryWithBadge{
			{CatalogEntry: CatalogEntry{Name: "fotos", Type: "folder", Host: "nas", Source: "/mnt/user/Fotos", Destinations: []string{"pcloud", "ugreen"}, Schedule: "04:40:00"}, Badge: "ok"},
			{CatalogEntry: CatalogEntry{Name: "forgejo", Type: "service", Host: "nuc", Source: []any{"forgejo-data"}, Destinations: []string{"pcloud"}}, Badge: "failed"},
		},
	}
	html, err := Render(snap)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}

	start := strings.Index(html, `id="flow-graph-data">`)
	if start == -1 {
		t.Fatal("flow-graph-data script tag not found")
	}
	start += len(`id="flow-graph-data">`)
	end := strings.Index(html[start:], "</script>")
	if end == -1 {
		t.Fatal("flow-graph-data script tag not closed")
	}
	raw := html[start : start+end]

	var g flowGraph
	if err := json.Unmarshal([]byte(raw), &g); err != nil {
		t.Fatalf("embedded flow graph is not valid JSON: %v\nraw: %s", err, raw)
	}

	// nas host + fotos entry + pcloud dest + ugreen dest + nuc host + forgejo entry = 6,
	// pcloud shared across both entries so it appears once.
	if len(g.Nodes) != 6 {
		t.Errorf("expected 6 nodes, got %d: %+v", len(g.Nodes), g.Nodes)
	}
	// host->entry (x2) + fotos->pcloud + fotos->ugreen + forgejo->pcloud = 5
	if len(g.Links) != 5 {
		t.Errorf("expected 5 links, got %d: %+v", len(g.Links), g.Links)
	}

	var sawHostWithSub, sawHostWithoutSub, sawFailedEntry bool
	for _, n := range g.Nodes {
		if n.Kind == "host" && n.ID == "host:nas" && n.Sub != "" {
			sawHostWithSub = true
		}
		if n.Kind == "host" && n.ID == "host:nuc" && n.Sub == "" {
			sawHostWithoutSub = true
		}
		if n.Kind == "entry" && n.State == "failed" {
			sawFailedEntry = true
		}
	}
	if !sawHostWithSub {
		t.Error("expected nas host node to carry a next-run Sub label")
	}
	if !sawHostWithoutSub {
		t.Error("expected nuc host node to have no Sub label (no schedule set)")
	}
	if !sawFailedEntry {
		t.Error("expected forgejo entry node to carry state=failed")
	}
}

func TestFormatBytes(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KiB"},
		{1536, "1.5 KiB"},
		{1024 * 1024, "1.0 MiB"},
		{1024 * 1024 * 1024, "1.0 GiB"},
		{5 * 1024 * 1024 * 1024, "5.0 GiB"},
		{1024 * 1024 * 1024 * 1024, "1.0 TiB"},
	}
	for _, c := range cases {
		if got := formatBytes(c.in); got != c.want {
			t.Errorf("formatBytes(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRenderEntryStatsInTable(t *testing.T) {
	snap := &Snapshot{
		Hosts:        map[string]HostStatus{},
		Destinations: map[string]DestUsage{},
		Errors:       map[string]string{},
		Entries: []EntryWithBadge{
			{CatalogEntry: CatalogEntry{Name: "fotos", Type: "folder", Host: "nas", Source: "/mnt/user/Fotos", Destinations: []string{"pcloud"}}, Badge: "ok", HasStats: true, SizeBytes: 2147483648, FileCount: 4200},
			{CatalogEntry: CatalogEntry{Name: "musik", Type: "folder", Host: "nas", Source: "/mnt/user/Musik", Destinations: []string{"pcloud"}}, Badge: "ok"},
		},
	}
	html, err := Render(snap)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	if !strings.Contains(html, "2.0 GiB") {
		t.Error("expected formatted size for the entry with stats")
	}
	if !strings.Contains(html, "4200") {
		t.Error("expected file count for the entry with stats")
	}
	if !strings.Contains(html, "&ndash;") {
		t.Error("expected a placeholder dash for the entry without stats")
	}
}

func TestRenderFlowDiagramOmittedWhenNoEntries(t *testing.T) {
	snap := &Snapshot{Hosts: map[string]HostStatus{}, Destinations: map[string]DestUsage{}, Errors: map[string]string{}}
	html, err := Render(snap)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	if strings.Contains(html, "Backup flow") {
		t.Error("flow diagram section should be omitted when there are no entries")
	}
}

func TestRenderEmptySnapshot(t *testing.T) {
	snap := &Snapshot{Hosts: map[string]HostStatus{}, Destinations: map[string]DestUsage{}, Errors: map[string]string{}}
	html, err := Render(snap)
	if err != nil {
		t.Fatalf("Render on empty snapshot: %v", err)
	}
	if !strings.Contains(html, "Backup Dashboard") {
		t.Error("empty-snapshot render missing title")
	}
}
