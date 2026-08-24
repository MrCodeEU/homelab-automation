package backupdashboard

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

var sshOptions = []string{
	"-o", "BatchMode=yes",
	"-o", "ConnectTimeout=10",
	"-o", "StrictHostKeyChecking=accept-new",
	"-o", "IdentitiesOnly=yes",
}

// FactsPayload is the subset of homelab-facts' JSON output this collector
// reads. Unknown fields are ignored, matching the Python original's loose
// dict access.
type FactsPayload struct {
	Sections struct {
		Backup struct {
			Data struct {
				Available        bool     `json:"available"`
				Reason           string   `json:"reason"`
				Completed        bool     `json:"completed"`
				CriticalFailures int      `json:"critical_failures"`
				FailedServices   []string `json:"failed_services"`
				AgeSeconds       *float64 `json:"age_seconds"`
			} `json:"data"`
		} `json:"backup"`
		BackupTargets struct {
			Data struct {
				Targets []BackupTarget `json:"targets"`
			} `json:"data"`
		} `json:"backup_targets"`
	} `json:"sections"`
}

type BackupTarget struct {
	Name           string   `json:"name"`
	Kind           string   `json:"kind"`
	QuotaSupported bool     `json:"quota_supported"`
	UsedPercent    *float64 `json:"used_percent"`
	FreeBytes      *float64 `json:"free_bytes"`
}

func fetchFacts(ctx context.Context, cfg Config, address string) (*FactsPayload, error) {
	ctx, cancel := context.WithTimeout(ctx, 180*time.Second)
	defer cancel()

	args := append(append([]string{}, sshOptions...), "-i", cfg.SSHKeyPath, "root@"+address, cfg.LocalFactsBin)
	cmd := exec.CommandContext(ctx, "ssh", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return nil, fmt.Errorf("%s: %w: %s", address, err, msg)
	}

	var payload FactsPayload
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		return nil, fmt.Errorf("%s: decode facts: %w", address, err)
	}
	return &payload, nil
}

// FetchAll fetches facts for every configured host, best-effort: one
// unreachable host must not blank the page.
func FetchAll(ctx context.Context, cfg Config) (payloads map[string]*FactsPayload, errs map[string]string) {
	payloads = map[string]*FactsPayload{}
	errs = map[string]string{}
	for _, h := range cfg.SSHHosts {
		payload, err := fetchFacts(ctx, cfg, h.Address)
		if err != nil {
			errs[h.Name] = err.Error()
			continue
		}
		payloads[h.Name] = payload
	}
	return payloads, errs
}
