// Home Assistant health via its Core REST API. No SSH: HAOS restricts
// shell access, and this install's Supervisor API isn't exposed to the
// report. Core's REST API is the stable surface available either way -
// safe_mode tells us the box is limping, and unavailable/unknown entity
// states are the one signal that reliably says "an integration or device
// broke" without needing per-integration knowledge.
package collectors

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// Domains where "unknown" is the resting state, not a fault.
var haUnknownIsNormal = map[string]bool{
	"button": true, "scene": true, "script": true, "input_button": true,
	"notify": true, "tts": true, "conversation": true, "event": true,
	"stt": true, "image": true,
}

// A cluster this size or larger is an integration or device that fell
// over. Below it is almost always a device that is simply switched off.
const haSignificantCluster = 5

func haCluster(entityID string) string {
	obj := entityID
	if idx := strings.Index(entityID, "."); idx >= 0 {
		obj = entityID[idx+1:]
	}
	parts := strings.Split(obj, "_")
	if len(parts) > 2 {
		parts = parts[:2]
	}
	return strings.Join(parts, "_")
}

func haIsRealFault(state map[string]any) bool {
	value, _ := state["state"].(string)
	if value != "unavailable" && value != "unknown" {
		return false
	}
	entityID, _ := state["entity_id"].(string)
	domain := entityID
	if idx := strings.Index(entityID, "."); idx >= 0 {
		domain = entityID[:idx]
	}
	if value == "unknown" && haUnknownIsNormal[domain] {
		return false
	}
	return true
}

func init() {
	hr.RegisterCollector("homeassistant", collectHomeAssistant)
}

func collectHomeAssistant(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("homeassistant")

	if cfg.HAToken == "" {
		result.Status = "unavailable"
		result.Error = "no Home Assistant token configured (secrets.homeassistant.token)"
		return result
	}

	base := strings.TrimRight(cfg.HAURL, "/")
	auth := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+cfg.HAToken) }

	configResp, err := httpGet(base+"/api/config", 20*time.Second, auth)
	if err != nil {
		panic(err)
	}
	defer configResp.Body.Close()
	var haConfig map[string]any
	if err := json.NewDecoder(configResp.Body).Decode(&haConfig); err != nil {
		panic(err)
	}

	statesResp, err := httpGet(base+"/api/states", 20*time.Second, auth)
	if err != nil {
		panic(err)
	}
	defer statesResp.Body.Close()
	var states []map[string]any
	if err := json.NewDecoder(statesResp.Body).Decode(&states); err != nil {
		panic(err)
	}

	state, _ := haConfig["state"].(string)
	safeMode, _ := haConfig["safe_mode"].(bool)
	if safeMode || (state != "" && state != "RUNNING") {
		value := state
		if value == "" {
			value = "safe_mode"
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "ha_safe_mode.homeassistant.", Collector: "homeassistant", Subject: "homeassistant",
			Kind: "ha_safe_mode", Value: value,
			Message:  fmt.Sprintf("Home Assistant is not in a normal running state (state=%s, safe_mode=%v)", state, safeMode),
			Evidence: map[string]any{"version": haConfig["version"]}, Severity: "info",
		})
	}

	// Raw count is kept for the trend line, but the finding is built from
	// real faults only - see haUnknownIsNormal.
	rawUnavailable := 0
	var faults []map[string]any
	for _, s := range states {
		v, _ := s["state"].(string)
		if v == "unavailable" || v == "unknown" {
			rawUnavailable++
		}
		if haIsRealFault(s) {
			faults = append(faults, s)
		}
	}

	// One broken integration can produce hundreds of dead entities.
	// Reporting entities makes that look like 467 problems; reporting
	// clusters makes it one.
	excluded := map[string]bool{}
	for _, name := range cfg.HAExcludedClusters {
		excluded[name] = true
	}

	clusters := map[string]int{}
	var clusterOrder []string
	excludedFaultEntities := 0
	for _, s := range faults {
		entityID, _ := s["entity_id"].(string)
		c := haCluster(entityID)
		if excluded[c] {
			excludedFaultEntities++
			continue
		}
		if _, ok := clusters[c]; !ok {
			clusterOrder = append(clusterOrder, c)
		}
		clusters[c]++
	}
	type clusterCount struct {
		name  string
		count int
	}
	var significant []clusterCount
	for _, name := range clusterOrder {
		if clusters[name] >= haSignificantCluster {
			significant = append(significant, clusterCount{name, clusters[name]})
		}
	}
	sort.SliceStable(significant, func(i, j int) bool { return significant[i].count > significant[j].count })
	worst := significant
	if len(worst) > 10 {
		worst = worst[:10]
	}

	worstLabels := make([]string, 0, len(worst))
	for _, c := range worst {
		worstLabels = append(worstLabels, fmt.Sprintf("%s (%d)", c.name, c.count))
	}
	summaryLabels := worstLabels
	if len(summaryLabels) > 4 {
		summaryLabels = summaryLabels[:4]
	}
	summary := strings.Join(summaryLabels, ", ")
	if summary == "" {
		summary = "none"
	}

	result.Observations = append(result.Observations, &hr.Observation{
		ID: "ha_unavailable_entities.homeassistant.", Collector: "homeassistant", Subject: "homeassistant",
		Kind: "ha_unavailable_entities", Value: len(significant), Unit: "integrations", Threshold: haSignificantCluster,
		Message: fmt.Sprintf("%d Home Assistant integration(s)/device(s) down with %d+ dead entities each: %s",
			len(significant), haSignificantCluster, summary),
		Evidence: map[string]any{
			"clusters":                      worstLabels,
			"total_fault_entities":          len(faults),
			"small_clusters":                len(clusters) - len(significant),
			"excluded_normal_unknown":       rawUnavailable - len(faults),
			"excluded_allowlisted_entities": excludedFaultEntities,
		},
		Severity: "info",
	})

	// Pending updates, informational.
	var pending []hr.HAUpdate
	for _, s := range states {
		entityID, _ := s["entity_id"].(string)
		v, _ := s["state"].(string)
		if strings.HasPrefix(entityID, "update.") && v == "on" {
			attrs, _ := s["attributes"].(map[string]any)
			name, _ := attrs["friendly_name"].(string)
			if name == "" {
				name = entityID
			}
			installed, _ := attrs["installed_version"].(string)
			latest, _ := attrs["latest_version"].(string)
			pending = append(pending, hr.HAUpdate{Name: name, Installed: installed, Latest: latest})
		}
	}
	if len(pending) > 0 {
		names := make([]string, 0, len(pending))
		for _, p := range pending {
			names = append(names, p.Name)
		}
		sample := names
		if len(sample) > 4 {
			sample = sample[:4]
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "ha_updates_available.homeassistant.", Collector: "homeassistant", Subject: "homeassistant",
			Kind: "ha_updates_available", Value: len(pending), Unit: "updates",
			Message:  fmt.Sprintf("%d Home Assistant update(s) available: %s", len(pending), strings.Join(sample, ", ")),
			Evidence: map[string]any{"updates": pending}, Severity: "info",
		})
	}

	version, _ := haConfig["version"].(string)
	coreState, _ := haConfig["state"].(string)
	result.Data = &hr.HomeAssistantData{
		Version: version, CoreState: coreState, EntityCount: len(states),
		UnavailableCount: len(faults), RawUnavailableCount: rawUnavailable,
		Clusters: worstLabels, UpdatesAvailable: pending,
	}
	return result
}
