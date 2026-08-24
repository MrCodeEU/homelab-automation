package backupdashboard

import (
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
			{CatalogEntry: CatalogEntry{Name: "fotos", Type: "folder", Host: "nas", Source: "/mnt/user/Fotos", Destinations: []string{"pcloud", "ugreen"}}, Badge: "ok"},
			{CatalogEntry: CatalogEntry{Name: "forgejo", Type: "service", Host: "nuc", Source: []any{"forgejo-data", "forgejo-db-data"}, Destinations: []string{"pcloud"}}, Badge: "failed"},
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
	} {
		if !strings.Contains(html, want) {
			t.Errorf("rendered HTML missing %q", want)
		}
	}

	if strings.Count(html, "<html") != 1 || !strings.Contains(html, "</html>") {
		t.Error("rendered HTML doesn't look well-formed")
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
