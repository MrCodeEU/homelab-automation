// build-deploy-status builds deployment status data and HTML from an
// OpenVox/Ansible deployment log.
//
// Port of scripts/build_deploy_status.py + scripts/generate_deploy_page.py
// (the latter only ever imported by the former, never run standalone).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/MrCodeEU/homelab-automation/tools/internal/deploystatus"
)

func loadJSONArray(path string) []map[string]any {
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 {
		return nil
	}
	var out []map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil
	}
	return out
}

func loadJSONObject(path string, def map[string]any) map[string]any {
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 {
		return def
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return def
	}
	return out
}

func asList(m map[string]any, key string) []map[string]any {
	raw, _ := m[key].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		if im, ok := item.(map[string]any); ok {
			out = append(out, im)
		}
	}
	return out
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func run() error {
	existingJSON := flag.String("existing-json", "", "")
	servicesJSON := flag.String("services-json", "", "")
	ansibleLog := flag.String("ansible-log", "", "")
	outputJSON := flag.String("output-json", "", "")
	outputHTML := flag.String("output-html", "", "")
	startTime := flag.String("start-time", "", "")
	durationSeconds := flag.Int("duration-seconds", 0, "")
	status := flag.String("status", "", "")
	trigger := flag.String("trigger", "", "")
	branch := flag.String("branch", "", "")
	commitSHA := flag.String("commit-sha", "", "")
	commitMessage := flag.String("commit-message", "", "")
	actor := flag.String("actor", "", "")
	checkMode := flag.Bool("check-mode", false, "")
	isStaging := flag.Bool("is-staging", false, "")
	limit := flag.String("limit", "all", "")
	tags := flag.String("tags", "all", "")
	runURL := flag.String("run-url", "", "")
	araArtifact := flag.String("ara-artifact", "", "")
	targetedService := flag.String("targeted-service", "", "")
	targetEnvironment := flag.String("target-environment", "", "")
	flag.Parse()

	required := map[string]string{
		"existing-json": *existingJSON, "services-json": *servicesJSON, "ansible-log": *ansibleLog,
		"output-json": *outputJSON, "output-html": *outputHTML, "start-time": *startTime,
		"status": *status, "trigger": *trigger, "branch": *branch, "actor": *actor,
	}
	for name, val := range required {
		if val == "" {
			return fmt.Errorf("--%s is required", name)
		}
	}

	servicesConfig := loadJSONArray(*servicesJSON)
	existing := loadJSONObject(*existingJSON, map[string]any{
		"deployments": []any{}, "services": []any{}, "last_updated": "",
	})

	var logLines []string
	if raw, err := os.ReadFile(*ansibleLog); err == nil {
		logLines = splitLines(string(raw))
	}
	failedServices := deploystatus.ParseFailedServices(logLines, servicesConfig)

	var serviceResults []map[string]any
	for _, service := range servicesConfig {
		if enabled, ok := service["enabled"].(bool); ok && !enabled {
			continue
		}
		name, _ := service["name"].(string)
		result := map[string]any{
			"name":   name,
			"host":   orDefaultAny(service["host"], "unknown"),
			"status": "ok",
		}
		if errMsg, failed := failedServices[name]; failed {
			result["status"] = "failed"
			result["error"] = errMsg
		}
		serviceResults = append(serviceResults, result)
	}
	if serviceResults == nil {
		serviceResults = []map[string]any{}
	}

	okCount, failedCount := 0, 0
	for _, r := range serviceResults {
		if r["status"] == "ok" {
			okCount++
		} else {
			failedCount++
		}
	}
	summary := map[string]any{
		"total_services": len(serviceResults),
		"ok":             okCount,
		"failed":         failedCount,
	}

	commitShort := truncate(*commitSHA, 7)
	deployment := map[string]any{
		"id":               *startTime + "-" + commitShort,
		"timestamp":        *startTime,
		"duration_seconds": *durationSeconds,
		"status":           *status,
		"trigger":          *trigger,
		"branch":           *branch,
		"commit_sha":       commitShort,
		"commit_message":   truncate(*commitMessage, 100),
		"actor":            *actor,
		"check_mode":       *checkMode,
		"is_staging":       *isStaging,
		"limit":            *limit,
		"tags":             *tags,
		"run_url":          *runURL,
		"ara_artifact":     *araArtifact,
		"services":         serviceResults,
		"summary":          summary,
	}
	if *targetedService != "" {
		deployment["targeted_service"] = *targetedService
	}
	if *targetEnvironment != "" {
		deployment["target_environment"] = *targetEnvironment
	}

	deployments := asList(existing, "deployments")
	deployments = append([]map[string]any{deployment}, deployments...)
	if len(deployments) > 500 {
		deployments = deployments[:500]
	}

	data := map[string]any{
		"deployments":  deployments,
		"services":     deploystatus.ServiceList(servicesConfig),
		"last_updated": time.Now().UTC().Format("2006-01-02T15:04:05Z"),
	}

	if err := os.MkdirAll(dirOf(*outputJSON), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(dirOf(*outputHTML), 0o755); err != nil {
		return err
	}

	jsonOut, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(*outputJSON, jsonOut, 0o644); err != nil {
		return err
	}

	htmlOut, err := deploystatus.GenerateHTML(data)
	if err != nil {
		return err
	}
	if err := os.WriteFile(*outputHTML, []byte(htmlOut), 0o644); err != nil {
		return err
	}

	fmt.Printf("Generated deployment status: %s (%s, services=%d, failed=%d)\n",
		deployment["id"], *status, len(serviceResults), failedCount)
	return nil
}

func splitLines(s string) []string {
	var lines []string
	start := 0
	for i, r := range s {
		if r == '\n' {
			lines = append(lines, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

func dirOf(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return "."
}

func orDefaultAny(v any, def string) any {
	if v == nil {
		return def
	}
	if s, ok := v.(string); ok && s == "" {
		return def
	}
	return v
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
