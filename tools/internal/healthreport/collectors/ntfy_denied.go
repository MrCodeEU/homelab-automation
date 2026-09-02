// Watches Caddy's access log for denied ntfy requests. ntfy's server.yml
// sets auth-default-access: deny-all and only grants read-write to the
// topics in ntfy_topic_whitelist (openvox/data/common.yaml) - a topic
// missing from that list otherwise fails silently for whoever publishes or
// subscribes to it. This surfaces the denial instead, so a forgotten topic
// gets caught rather than just quietly stopping.
package collectors

import (
	"encoding/json"
	"fmt"
	"regexp"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

const ntfyHost = "ntfy.mljr.eu"

var ntfyDenied = fmt.Sprintf(`{job="caddy"} | json | request_host="%s" and status = 403`, ntfyHost)

// Denied subscribes and path-based publishes carry the topic in the URL
// (e.g. /docker-updates/json); ntfy also accepts JSON-body publishes to
// "/" (Uptime-Kuma, diun both do this), where the topic lives in the body,
// not the path - Caddy's access log never sees it. Those denials still
// count toward ntfy_denied_unknown below, just without a topic name.
var ntfyTopicFromURI = regexp.MustCompile(`^/([^/?]+)`)

// `| json` in the LogQL query only adds extracted labels for filtering; the
// stream's line text stays the original raw Caddy access-log JSON object,
// so the topic still has to be pulled out of it here.
type caddyAccessLine struct {
	Request struct {
		URI string `json:"uri"`
	} `json:"request"`
}

func init() {
	hr.RegisterCollector("ntfy_access", collectNtfyDenied)
}

func collectNtfyDenied(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("ntfy_access")

	streams, err := lokiQueryRange(cfg, ntfyDenied, cfg.LookbackHours, 1000)
	if err != nil {
		panic(err)
	}

	byTopic := map[string]int{}
	var topicOrder []string
	unknown := 0
	for _, stream := range streams {
		for _, pair := range stream.Values {
			topic := topicFromDeniedLine(pair[1])
			if topic == "" {
				unknown++
				continue
			}
			if _, ok := byTopic[topic]; !ok {
				topicOrder = append(topicOrder, topic)
			}
			byTopic[topic]++
		}
	}

	for _, topic := range topicOrder {
		count := byTopic[topic]
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "ntfy_denied_topic." + topic, Collector: "ntfy_access", Subject: topic, Kind: "ntfy_denied_topic",
			Value: count, Unit: "denied_requests",
			Message:  fmt.Sprintf("ntfy topic %q was denied %d time(s) - missing from ntfy_topic_whitelist?", topic, count),
			Evidence: map[string]any{"topic": topic}, Severity: "info",
		})
	}
	if unknown > 0 {
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "ntfy_denied_unknown..", Collector: "ntfy_access", Subject: ntfyHost, Kind: "ntfy_denied_unknown",
			Value: unknown, Unit: "denied_requests",
			Message: fmt.Sprintf("%d ntfy request(s) denied without a topic in the URL (JSON-body publish) - "+
				"check `docker logs ntfy` on mljr for the topic name", unknown),
			Evidence: map[string]any{}, Severity: "info",
		})
	}
	return result
}

func topicFromDeniedLine(line string) string {
	var parsed caddyAccessLine
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return ""
	}
	m := ntfyTopicFromURI.FindStringSubmatch(parsed.Request.URI)
	if m == nil {
		return ""
	}
	return m[1]
}
