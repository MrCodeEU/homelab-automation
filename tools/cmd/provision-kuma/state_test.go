package main

import (
	"net/http"
	"net/http/httptest"
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

func TestCheckAPIKey(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pass, ok := r.BasicAuth(); !ok || pass != "uk2_good" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	st := &stats{}
	checkAPIKey(srv.URL, "uk2_good", st)
	checkAPIKey(srv.URL, "", st) // no key configured: nothing to check
	if len(st.failed) != 0 {
		t.Errorf("valid or absent key reported failures: %v", st.failed)
	}
	checkAPIKey(srv.URL, "uk2_bad", st)
	if len(st.failed) != 1 {
		t.Errorf("rejected key not reported: %v", st.failed)
	}
}

func TestMonitorOptOut(t *testing.T) {
	services := []service{
		{Name: "a", Domain: "a.example"},
		{Name: "b", Domain: "b.example", Monitor: bptr(false)},
		{Name: "c", Domain: "c.example", Monitor: bptr(true)},
		{Name: "d", Domain: "d.example", Enabled: bptr(false)},
	}
	got := getExpectedMonitorNames(services, nil)
	for name, want := range map[string]bool{"a": true, "b": false, "c": true, "d": false} {
		if got[name] != want {
			t.Errorf("monitor %q expected=%v, want %v", name, got[name], want)
		}
	}
}
