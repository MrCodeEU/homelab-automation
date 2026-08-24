// Package backupdashboard collects backup-state facts over SSH and from
// VictoriaMetrics, and renders the static status page served by nginx.
//
// Port of services/backup-dashboard/app/*.py.
package backupdashboard

import (
	"os"
	"strings"
)

// Host is one entry from BACKUP_DASHBOARD_SSH_HOSTS, in the order it
// appeared in the env var - this order drives the fleet-card layout on
// the page, so (unlike Python's dict, which preserves insertion order
// for free) it must be tracked explicitly rather than left to Go's
// randomized map iteration.
type Host struct {
	Name    string
	Address string
}

type Config struct {
	StateDir      string
	CatalogPath   string
	OutputPath    string
	VictoriaURL   string
	SSHHosts      []Host
	SSHKeyPath    string
	LocalFactsBin string
}

func defaultConfig() Config {
	return Config{
		StateDir:      "/state",
		CatalogPath:   "/catalog/backup_catalog.json",
		OutputPath:    "/output/index.html",
		VictoriaURL:   "http://127.0.0.1:19090",
		SSHKeyPath:    "/ssh/id_ed25519",
		LocalFactsBin: "/usr/local/bin/homelab-facts",
	}
}

// parseHosts parses "mljr=100.100.20.1,nas=100.100.10.2" preserving order.
func parseHosts(raw string) []Host {
	var out []Host
	for _, chunk := range strings.Split(raw, ",") {
		chunk = strings.TrimSpace(chunk)
		if chunk == "" {
			continue
		}
		name, addr, ok := strings.Cut(chunk, "=")
		if !ok {
			continue
		}
		out = append(out, Host{Name: strings.TrimSpace(name), Address: strings.TrimSpace(addr)})
	}
	return out
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func ConfigFromEnv() Config {
	c := defaultConfig()
	c.StateDir = envOr("BACKUP_DASHBOARD_STATE_DIR", c.StateDir)
	c.CatalogPath = envOr("BACKUP_DASHBOARD_CATALOG_PATH", c.CatalogPath)
	c.OutputPath = envOr("BACKUP_DASHBOARD_OUTPUT_PATH", c.OutputPath)
	c.VictoriaURL = envOr("BACKUP_DASHBOARD_VICTORIA_URL", c.VictoriaURL)
	c.SSHHosts = parseHosts(os.Getenv("BACKUP_DASHBOARD_SSH_HOSTS"))
	c.SSHKeyPath = envOr("BACKUP_DASHBOARD_SSH_KEY_PATH", c.SSHKeyPath)
	c.LocalFactsBin = envOr("BACKUP_DASHBOARD_LOCAL_FACTS_BIN", c.LocalFactsBin)
	return c
}
