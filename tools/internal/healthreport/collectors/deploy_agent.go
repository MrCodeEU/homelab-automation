// Checks the pull deploy agents (docs/DEPLOY_AGENT.md) by comparing what was
// requested with what each agent reports. The request is the head of the
// branch deploy/<host> on GitHub; the agent's view is its metrics textfile,
// scraped by Alloy into VictoriaMetrics. The agent notifies about its own
// results; this is the second, independent path that notices when it did
// not (agent dead, outbox stuck, request never picked up).
package collectors

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

const (
	// An agent polls every minute; a few missed polls are a restart, not a
	// dead agent.
	deployPollStale = 10 * time.Minute
	// A request this old that the agent has not reported on was not handled.
	deployRequestGrace = 15 * time.Minute
)

func init() {
	hr.RegisterCollector("deploy_agent", collectDeployAgent)
}

// deployRequest is the part of .deploy/request.json this check needs.
type deployRequest struct {
	ID     string `json:"id"`
	Commit string `json:"commit"`
}

// deployAgentView is what one agent last reported.
type deployAgentView struct {
	lastPoll  time.Time // zero: no poll metric at all
	requestID string    // last result; empty: none yet
	outcome   string
	mode      string
}

func collectDeployAgent(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("deploy_agent")
	if len(cfg.DeployHosts) == 0 {
		return result
	}

	views := map[string]*deployAgentView{}
	view := func(host string) *deployAgentView {
		if views[host] == nil {
			views[host] = &deployAgentView{}
		}
		return views[host]
	}
	polls, err := vmQuery(cfg, "max by (host) (homelab_deploy_last_poll_timestamp_seconds)")
	if err != nil {
		panic(err)
	}
	for _, s := range polls {
		if s.value > 0 {
			view(s.metric["host"]).lastPoll = time.Unix(int64(s.value), 0)
		}
	}
	// One series per request id; the newest result timestamp wins.
	results, err := vmQuery(cfg, "homelab_deploy_last_result_timestamp_seconds")
	if err != nil {
		panic(err)
	}
	newest := map[string]float64{}
	for _, s := range results {
		h := s.metric["host"]
		if s.value <= newest[h] {
			continue
		}
		newest[h] = s.value
		v := view(h)
		v.requestID, v.outcome, v.mode = s.metric["request_id"], s.metric["outcome"], s.metric["mode"]
	}

	now := time.Now()
	for _, host := range cfg.DeployHosts {
		req, err := fetchDeployRequest(cfg.DeployRepo, host)
		if err != nil {
			panic(err)
		}
		result.Observations = append(result.Observations, evaluateDeploy(host, now, req, views[host])...)
	}
	return result
}

// fetchDeployRequest reads the head request of deploy/<host>. The repository
// is public, so no token. nil, nil: the branch does not exist yet.
func fetchDeployRequest(repo, host string) (*deployRequest, error) {
	u := fmt.Sprintf("https://raw.githubusercontent.com/%s/deploy/%s/.deploy/request.json", repo, host)
	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", u, resp.StatusCode)
	}
	var r deployRequest
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&r); err != nil {
		return nil, fmt.Errorf("%s: %w", u, err)
	}
	return &r, nil
}

// evaluateDeploy turns one host's request and agent view into observations.
func evaluateDeploy(host string, now time.Time, req *deployRequest, v *deployAgentView) []*hr.Observation {
	obs := func(kind, detail, msg string, value any, evidence map[string]any) *hr.Observation {
		return &hr.Observation{
			ID: kind + "." + host + "." + detail, Collector: "deploy_agent", Subject: host, Kind: kind,
			Value: value, Message: msg, Evidence: evidence, Severity: "info",
		}
	}
	if v == nil || v.lastPoll.IsZero() {
		return []*hr.Observation{obs("deploy_agent_missing", "",
			"no poll metric from the deploy agent: not running, or its textfile is not scraped", nil, nil)}
	}
	var out []*hr.Observation
	if age := now.Sub(v.lastPoll); age > deployPollStale {
		out = append(out, obs("deploy_agent_stale", "",
			fmt.Sprintf("deploy agent last polled %s ago", age.Round(time.Minute)),
			int64(age.Minutes()), map[string]any{"last_poll": v.lastPoll.UTC().Format(time.RFC3339)}))
	}
	if req == nil || req.ID == "" {
		return out
	}
	evidence := map[string]any{"request_id": req.ID, "commit": req.Commit, "seen_request_id": v.requestID, "outcome": v.outcome, "mode": v.mode}
	if req.ID != v.requestID {
		requested, err := time.Parse("20060102T150405Z", strings.SplitN(req.ID, "-", 2)[0])
		if err == nil && now.Sub(requested) > deployRequestGrace {
			out = append(out, obs("deploy_request_unhandled", req.ID,
				fmt.Sprintf("deploy request %s is %s old and the agent has not reported on it", req.ID, now.Sub(requested).Round(time.Minute)),
				req.ID, evidence))
		}
		return out
	}
	switch v.outcome {
	case "success":
	case "suspended":
		out = append(out, obs("deploy_request_suspended", req.ID,
			fmt.Sprintf("deploy request %s was not applied: the agent is suspended", req.ID), v.outcome, evidence))
	default:
		out = append(out, obs("deploy_request_failed", req.ID,
			fmt.Sprintf("deploy request %s (%s) ended %s", req.ID, v.mode, v.outcome), v.outcome, evidence))
	}
	return out
}
