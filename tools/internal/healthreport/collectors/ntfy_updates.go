// Pending container image updates. Diun already watches every image and
// publishes to ntfy on a 6h schedule (services/diun/diun.yml). Reading its
// topic back costs nothing and avoids a second registry-polling
// implementation.
package collectors

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

func init() {
	hr.RegisterCollector("updates", collectUpdates)
}

func collectUpdates(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("updates")

	target := fmt.Sprintf("%s/docker-updates/json?%s", strings.TrimRight(cfg.NtfyURL, "/"), url.Values{
		"poll": {"1"}, "since": {fmt.Sprintf("%dh", cfg.LookbackHours)},
	}.Encode())
	resp, err := httpGet(target, 30*time.Second, nil)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()

	// ntfy streams newline-delimited JSON, one message per line.
	var messages []hr.UpdateMessage
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var msg map[string]any
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			continue
		}
		if event, _ := msg["event"].(string); event != "message" {
			continue
		}
		title, _ := msg["title"].(string)
		body, _ := msg["message"].(string)
		if len(body) > 300 {
			body = body[:300]
		}
		messages = append(messages, hr.UpdateMessage{Title: title, Message: body, Time: msg["time"]})
	}

	sample := messages
	if len(sample) > 50 {
		sample = sample[:50]
	}
	result.Data = &hr.UpdatesData{Count: len(messages), Messages: sample}
	result.Observations = append(result.Observations, &hr.Observation{
		ID: "image_updates..", Collector: "updates", Subject: "homelab", Kind: "image_updates",
		Value: len(messages), Unit: "images",
		Message:  fmt.Sprintf("%d container image update notifications in the last %dh", len(messages), cfg.LookbackHours),
		Evidence: map[string]any{"topic": "docker-updates"}, Severity: "info",
	})
	return result
}
