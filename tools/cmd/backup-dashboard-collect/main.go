// backup-dashboard-collect gathers backup state over SSH and from
// VictoriaMetrics, and renders the static status page served by nginx.
//
// Port of services/backup-dashboard/app/collect.py. One-shot, invoked by
// a systemd timer via `docker compose run` - see hooks/post-deploy.sh.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"

	bd "github.com/MrCodeEU/homelab-automation/tools/internal/backupdashboard"
)

func main() {
	log.SetFlags(log.LstdFlags)

	cfg := bd.ConfigFromEnv()

	snapshot, err := bd.BuildSnapshot(context.Background(), cfg)
	if err != nil {
		log.Fatalf("backup-dashboard: %v", err)
	}

	if err := os.MkdirAll(cfg.StateDir, 0o755); err != nil {
		log.Fatalf("backup-dashboard: create state dir: %v", err)
	}
	snapshotJSON, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		log.Fatalf("backup-dashboard: marshal snapshot: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cfg.StateDir, "snapshot.json"), snapshotJSON, 0o644); err != nil {
		log.Fatalf("backup-dashboard: write snapshot: %v", err)
	}

	html, err := bd.Render(snapshot)
	if err != nil {
		log.Fatalf("backup-dashboard: render: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(cfg.OutputPath), 0o755); err != nil {
		log.Fatalf("backup-dashboard: create output dir: %v", err)
	}
	if err := os.WriteFile(cfg.OutputPath, []byte(html), 0o644); err != nil {
		log.Fatalf("backup-dashboard: write output: %v", err)
	}

	reachable := 0
	for _, status := range snapshot.Hosts {
		if status.State != "unknown" {
			reachable++
		}
	}
	fmt.Printf(
		"backup-dashboard: done: %d entries, %d/%d hosts reachable\n",
		len(snapshot.Entries), reachable, len(snapshot.Hosts),
	)
}
