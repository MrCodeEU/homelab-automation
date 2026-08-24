// GitHub repository health across the whole account. Covers every repo
// owned by the configured user, not just this one: workflow run
// conclusions, open Dependabot alerts and open code scanning alerts.
//
// Needs a fine-grained PAT with Metadata/Actions/Dependabot alerts/Code
// scanning alerts read access. Repos with a feature disabled answer
// 403/404; that is "unavailable", not an error, and must not colour the
// report.
package collectors

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

const githubAPI = "https://api.github.com"
const githubPage = 100

func githubSession(cfg hr.Config) func(*http.Request) {
	return func(r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+cfg.GithubToken)
		r.Header.Set("Accept", "application/vnd.github+json")
		r.Header.Set("X-GitHub-Api-Version", "2022-11-28")
		r.Header.Set("User-Agent", "homelab-healthreport")
	}
}

// githubGet returns (nil, response, nil) for 403/404 (feature disabled or
// no access - not a failure), and an error otherwise.
func githubGet(auth func(*http.Request), rawURL string, params url.Values) (any, *http.Response, error) {
	full := rawURL
	if len(params) > 0 {
		full += "?" + params.Encode()
	}
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest(http.MethodGet, full, nil)
	if err != nil {
		return nil, nil, err
	}
	auth(req)
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	if resp.StatusCode == 403 || resp.StatusCode == 404 {
		resp.Body.Close()
		return nil, resp, nil
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 500))
		return nil, resp, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
	}
	var payload any
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, resp, err
	}
	return payload, resp, nil
}

func init() {
	hr.RegisterCollector("github", collectGithub)
}

func collectGithub(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("github")

	if cfg.GithubToken == "" {
		result.Status = "unavailable"
		result.Error = "no GitHub token configured (secrets.github_readonly.token)"
		return result
	}

	auth := githubSession(cfg)
	data := &hr.GithubData{}
	var unavailable []string

	// The token warns about its own expiry, so the report never dies
	// quietly when the credential lapses.
	client := &http.Client{Timeout: 30 * time.Second}
	probeReq, _ := http.NewRequest(http.MethodGet, githubAPI+"/user", nil)
	auth(probeReq)
	probeResp, err := client.Do(probeReq)
	if err != nil {
		panic(err)
	}
	defer probeResp.Body.Close()
	if probeResp.StatusCode < 200 || probeResp.StatusCode >= 300 {
		body, _ := io.ReadAll(probeResp.Body)
		panic(fmt.Errorf("github /user: HTTP %d: %s", probeResp.StatusCode, string(body)))
	}
	var probeUser map[string]any
	probeBody, _ := io.ReadAll(probeResp.Body)
	json.Unmarshal(probeBody, &probeUser)

	expiry := probeResp.Header.Get("github-authentication-token-expiration")
	if expiry != "" && len(expiry) >= 10 {
		if expiresAt, err := time.Parse("2006-01-02", expiry[:10]); err == nil {
			days := int(time.Until(expiresAt.UTC()).Hours() / 24)
			data.TokenExpiresInDays = &days
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "github_token_expiry..", Collector: "github", Subject: "github",
				Kind: "github_token_expiry", Value: days, Unit: "days",
				Message:  fmt.Sprintf("GitHub token expires in %d days", days),
				Evidence: map[string]any{"expires_at": expiry}, Severity: "info",
			})
		}
	}

	owner := cfg.GithubOwner
	if owner == "" {
		if login, ok := probeUser["login"].(string); ok {
			owner = login
		}
	}

	var repos []map[string]any
	page := 1
	for {
		batch, _, err := githubGet(auth, githubAPI+"/user/repos", url.Values{
			"affiliation": {"owner"}, "per_page": {fmt.Sprint(githubPage)}, "page": {fmt.Sprint(page)},
		})
		if err != nil {
			panic(err)
		}
		items, _ := batch.([]any)
		if len(items) == 0 {
			break
		}
		for _, r := range items {
			if m, ok := r.(map[string]any); ok {
				repos = append(repos, m)
			}
		}
		if len(items) < githubPage {
			break
		}
		page++
	}

	since := time.Now().UTC().Add(-time.Duration(cfg.LookbackHours) * time.Hour).Format("2006-01-02T15:04:05Z")

	for _, repo := range repos {
		name, _ := repo["name"].(string)
		full, _ := repo["full_name"].(string)
		defaultBranch, _ := repo["default_branch"].(string)
		if defaultBranch == "" {
			defaultBranch = "main"
		}
		if archived, _ := repo["archived"].(bool); archived {
			continue
		}
		entry := hr.GithubRepoEntry{Repo: full, DefaultBranch: defaultBranch}

		runsRaw, _, err := githubGet(auth, fmt.Sprintf("%s/repos/%s/actions/runs", githubAPI, full), url.Values{
			"created": {">=" + since[:10]}, "per_page": {"50"},
		})
		if err != nil {
			panic(err)
		}
		if runsRaw == nil {
			unavailable = append(unavailable, full+":actions")
		} else {
			runs, _ := runsRaw.(map[string]any)
			workflowRuns, _ := runs["workflow_runs"].([]any)
			failures := 0
			for _, r := range workflowRuns {
				run, _ := r.(map[string]any)
				concl, _ := run["conclusion"].(string)
				if concl == "failure" || concl == "timed_out" || concl == "startup_failure" {
					failures++
				}
			}
			entry.FailedRuns = failures

			// Alert on a workflow's CURRENT state (its latest run), not on
			// "did it fail at any point in the lookback window" - a run
			// that failed at 2am and passed cleanly at 3am is not a live
			// problem. Group all runs by (workflow, branch), and only
			// alert if the MOST RECENT run in that group failed.
			type latestKey struct{ workflow, branch string }
			latestByKey := map[latestKey]map[string]any{}
			var order []latestKey
			for _, r := range workflowRuns {
				run, _ := r.(map[string]any)
				workflow, _ := run["name"].(string)
				if workflow == "" {
					workflow = "workflow"
				}
				branch, _ := run["head_branch"].(string)
				if branch == "" {
					branch = "?"
				}
				key := latestKey{workflow, branch}
				existing, ok := latestByKey[key]
				createdAt, _ := run["created_at"].(string)
				existingCreated, _ := existing["created_at"].(string)
				if !ok || createdAt > existingCreated {
					if !ok {
						order = append(order, key)
					}
					latestByKey[key] = run
				}
			}
			for _, key := range order {
				run := latestByKey[key]
				concl, _ := run["conclusion"].(string)
				if concl != "failure" && concl != "timed_out" && concl != "startup_failure" {
					continue
				}
				onDefault := key.branch == defaultBranch
				if !onDefault {
					// A feature branch's one-time failure stays "the
					// latest run for that branch" forever once the branch
					// itself is deleted after merge - there is never a
					// newer run to supersede it. Confirm the branch still
					// exists before alerting.
					branchInfo, _, err := githubGet(auth, fmt.Sprintf("%s/repos/%s/branches/%s", githubAPI, full, key.branch), nil)
					if err != nil {
						panic(err)
					}
					if branchInfo == nil {
						continue
					}
				}
				kind := "workflow_failed"
				if onDefault {
					kind = "workflow_failed_default_branch"
				}
				htmlURL, _ := run["html_url"].(string)
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("%s.%s.%s", kind, name, key.workflow), Collector: "github",
					Subject: name, Kind: kind, Value: concl,
					Message:  fmt.Sprintf("%s: workflow %s currently failing on %s (latest run)", full, key.workflow, key.branch),
					Evidence: map[string]any{"url": htmlURL, "branch": key.branch}, Severity: "info",
				})
			}
		}

		alertsRaw, _, err := githubGet(auth, fmt.Sprintf("%s/repos/%s/dependabot/alerts", githubAPI, full), url.Values{
			"state": {"open"}, "per_page": {fmt.Sprint(githubPage)},
		})
		if err != nil {
			panic(err)
		}
		if alertsRaw == nil {
			unavailable = append(unavailable, full+":dependabot")
		} else {
			alerts, _ := alertsRaw.([]any)
			entry.DependabotOpen = len(alerts)
			for _, a := range alerts {
				alert, _ := a.(map[string]any)
				advisory, _ := alert["security_advisory"].(map[string]any)
				severity := "unknown"
				if advisory != nil {
					if s, _ := advisory["severity"].(string); s != "" {
						severity = strings.ToLower(s)
					}
				}
				dep, _ := alert["dependency"].(map[string]any)
				pkg, _ := dep["package"].(map[string]any)
				pkgName, _ := pkg["name"].(string)
				if pkgName == "" {
					pkgName = "?"
				}
				summary, _ := advisory["summary"].(string)
				if len(summary) > 120 {
					summary = summary[:120]
				}
				htmlURL, _ := alert["html_url"].(string)
				number := jsonNumberString(alert["number"])
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("dependabot_alert.%s.%s", name, number), Collector: "github",
					Subject: name, Kind: "dependabot_alert", Value: severity,
					Message:  fmt.Sprintf("%s: %s Dependabot alert in %s - %s", full, severity, pkgName, summary),
					Evidence: map[string]any{"url": htmlURL, "package": pkgName}, Severity: "info",
				})
			}
		}

		scanningRaw, _, err := githubGet(auth, fmt.Sprintf("%s/repos/%s/code-scanning/alerts", githubAPI, full), url.Values{
			"state": {"open"}, "per_page": {fmt.Sprint(githubPage)},
		})
		if err != nil {
			panic(err)
		}
		if scanningRaw == nil {
			unavailable = append(unavailable, full+":code-scanning")
		} else {
			scanning, _ := scanningRaw.([]any)
			entry.CodeScanningOpen = len(scanning)
			for _, a := range scanning {
				alert, _ := a.(map[string]any)
				rule, _ := alert["rule"].(map[string]any)
				severity := "unknown"
				if s, _ := rule["security_severity_level"].(string); s != "" {
					severity = strings.ToLower(s)
				} else if s, _ := rule["severity"].(string); s != "" {
					severity = strings.ToLower(s)
				}
				desc, _ := rule["description"].(string)
				if desc == "" {
					desc, _ = rule["id"].(string)
				}
				if len(desc) > 120 {
					desc = desc[:120]
				}
				htmlURL, _ := alert["html_url"].(string)
				number := jsonNumberString(alert["number"])
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("code_scanning_alert.%s.%s", name, number), Collector: "github",
					Subject: name, Kind: "code_scanning_alert", Value: severity,
					Message:  fmt.Sprintf("%s: %s code scanning alert - %s", full, severity, desc),
					Evidence: map[string]any{"url": htmlURL}, Severity: "info",
				})
			}
		}

		data.Repos = append(data.Repos, entry)
	}

	data.Unavailable = unavailable
	data.RepoCount = len(data.Repos)
	data.Owner = owner
	result.Data = data
	return result
}

func jsonNumberString(v any) string {
	switch n := v.(type) {
	case float64:
		return fmt.Sprintf("%d", int64(n))
	default:
		return fmt.Sprint(v)
	}
}
