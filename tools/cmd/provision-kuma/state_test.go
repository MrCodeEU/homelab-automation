package main

import (
	"reflect"
	"testing"
)

func bptr(b bool) *bool { return &b }

func TestWindowMonitorNames(t *testing.T) {
	services := []service{
		{Name: "immich", Domain: "immich.example", Host: "nas"},
		{Name: "dawarich", Domain: "d.example", Host: "nas"},
		{Name: "off", Domain: "o.example", Host: "nas", Enabled: bptr(false)},
		{Name: "nodomain", Host: "nas"},
		{Name: "grafana", Domain: "g.example", Host: "nuc"},
		{Name: "nextcloud", Domain: "c.example", Host: "nas"},
	}
	got := windowMonitorNames(window{Hosts: []string{"nas"}}, services)
	if want := []string{"dawarich", "immich", "nextcloud"}; !reflect.DeepEqual(got, want) {
		t.Errorf("host selector = %v, want %v", got, want)
	}
	got = windowMonitorNames(window{Services: []string{"nextcloud", "grafana", "missing"}}, services)
	if want := []string{"grafana", "nextcloud"}; !reflect.DeepEqual(got, want) {
		t.Errorf("service selector = %v, want %v", got, want)
	}
}

// mljr-web reads /api/status-page/all; its slug and published state are part of
// that contract.
func TestAllPageKeepsContract(t *testing.T) {
	if pages[0].Slug != "all" || pages[0].Title != "MLJR" {
		t.Errorf("first page = %q/%q, want all/MLJR", pages[0].Slug, pages[0].Title)
	}
	seen := map[string]bool{}
	for _, p := range pages {
		if seen[p.Slug] {
			t.Errorf("duplicate status page slug %q", p.Slug)
		}
		seen[p.Slug] = true
	}
	titles := map[string]bool{}
	for _, w := range windows {
		if titles[w.Title] {
			t.Errorf("duplicate maintenance window %q", w.Title)
		}
		titles[w.Title] = true
	}
}
