// Entry point for the homelab health report.
//
//	healthreport --dry-run          # collect, classify, print, send nothing
//	healthreport --send             # the real run (systemd timer)
//	healthreport --collect-only --collector victoria
//
// Exit codes: 0 when a report was produced, even with a dead LLM or a
// failed collector - those are findings, not crashes. Non-zero only when
// the framework itself could not complete.
//
// Port of services/healthreport/app/main.py.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
	// Importing these packages is what populates hr.Registry.
	_ "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport/collectors"
)

var defaultCollectors = []string{
	"host_metrics", "containers", "logs", "uptime_kuma",
	"ssh_facts", "github", "updates", "homeassistant",
}

type stringList []string

func (s *stringList) String() string     { return fmt.Sprint(*s) }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

func main() {
	os.Exit(run())
}

func run() int {
	var (
		send        = flag.Bool("send", false, "deliver via ntfy and email")
		dryRun      = flag.Bool("dry-run", false, "collect and render, deliver nothing, do not rotate state")
		collectOnly = flag.Bool("collect-only", false, "print raw collector output and exit")
		diffOnly    = flag.Bool("diff-only", false, "diff two facts files, no network access")
		factsPath   = flag.String("facts", "", "facts file for --diff-only")
		factsPrev   = flag.String("facts-previous", "", "previous facts file for --diff-only")
		llmFixture  = flag.String("llm-fixture", "", "read the LLM response from this file")
		ollamaURL   = flag.String("ollama-url", "", "override the Ollama endpoint")
		ntfyTopic   = flag.String("ntfy-topic", "", "override the ntfy topic")
		emailTo     = flag.String("email-to", "", "override the email recipient")
		stateDirOv  = flag.String("state-dir", "", "override the state directory")
		noop        = flag.Bool("noop", false, "print the resolved configuration and exit; the compose "+
			"default command, so a deploy never sends a report")
		htmlOut = flag.String("html-out", "", "also write the HTML email body here, for inspecting "+
			"the render without sending mail")
		pretty  = flag.Bool("pretty", false, "indent JSON output")
		verbose = flag.Bool("verbose", false, "")
	)
	var collectorNames stringList
	flag.Var(&collectorNames, "collector", "restrict to this collector (repeatable)")
	flag.Parse()
	_ = verbose

	log.SetFlags(log.LstdFlags)

	cfg := hr.ConfigFromEnv()
	if *ollamaURL != "" {
		cfg.OllamaURL = *ollamaURL
	}
	if *ntfyTopic != "" {
		cfg.NtfyTopic = *ntfyTopic
	}
	if *emailTo != "" {
		cfg.EmailTo = *emailTo
	}
	if *stateDirOv != "" {
		cfg.StateDir = *stateDirOv
	}

	// --- no-op ---------------------------------------------------------
	// What `docker compose up -d` runs at deploy time. Touches nothing.
	if *noop {
		printNoop(cfg)
		return 0
	}

	rules, err := hr.LoadRules(cfg.RulesPath)
	if err != nil {
		log.Printf("healthreport: could not load rules: %v", err)
		return 2
	}

	// --- offline diff ----------------------------------------------------
	if *diffOnly {
		if *factsPath == "" {
			log.Print("--diff-only needs --facts")
			return 2
		}
		return runDiffOnly(*factsPath, *factsPrev, *pretty)
	}

	names := []string(collectorNames)
	if len(names) == 0 {
		names = defaultCollectors
	}
	results := hr.RunCollectors(cfg, rules, names)

	// --- raw collector output --------------------------------------------
	if *collectOnly {
		return printCollectOnly(results, *pretty)
	}

	now := time.Now()
	facts, seen := hr.Assemble(cfg, rules, results, now)

	// --- narrative ---------------------------------------------------------
	var narrative *hr.Narrative
	if *llmFixture != "" {
		// Deliberately routed through the same validator as a live
		// response, so a fixture cannot pass something the model could not.
		raw, err := os.ReadFile(*llmFixture)
		if err != nil {
			log.Printf("healthreport: could not read llm fixture: %v", err)
			return 2
		}
		var parsed any
		if err := json.Unmarshal(raw, &parsed); err != nil {
			log.Printf("healthreport: fixture is not valid JSON: %v", err)
			facts.LLMStatus = "degraded_invalid"
		} else {
			validIDs := map[string]bool{}
			for _, obs := range facts.Observations {
				validIDs[obs.ID] = true
			}
			n, err := hr.ValidateNarrative(parsed, validIDs)
			if err != nil {
				log.Printf("healthreport: fixture rejected: %v", err)
				facts.LLMStatus = "degraded_invalid"
			} else {
				narrative = n
				facts.LLMStatus = "ok"
			}
		}
	} else {
		n, status := hr.Summarize(cfg, facts)
		narrative = n
		facts.LLMStatus = status
	}

	body, fallback := hr.Render(facts, narrative)
	title := hr.Headline(facts, narrative, fallback)
	bodyHTML, err := hr.RenderHTML(facts, narrative, title, cfg.StateDir)
	if err != nil {
		// The HTML part is a presentation nicety. If it fails the report
		// must still go out as text rather than not at all.
		log.Printf("healthreport: HTML rendering failed, sending text only: %v", err)
		bodyHTML = ""
	}

	if *htmlOut != "" && bodyHTML != "" {
		if err := os.WriteFile(*htmlOut, []byte(bodyHTML), 0o644); err != nil {
			log.Printf("healthreport: could not write HTML body: %v", err)
		} else {
			log.Printf("healthreport: HTML body written to %s", *htmlOut)
		}
	}

	// --- delivery ------------------------------------------------------
	if *send {
		var errs []string
		if e := hr.SendNtfy(cfg, facts, title, hr.NtfyBody(facts, narrative, fallback, 5)); e != "" && !hasPrefix(e, "skipped") {
			errs = append(errs, e)
		}
		if e := hr.SendEmail(cfg, facts, hr.SubjectLine(facts), body, bodyHTML); e != "" && !hasPrefix(e, "skipped") {
			errs = append(errs, e)
		}
		facts.DeliveryErrors = errs
		for _, e := range errs {
			log.Printf("healthreport: delivery problem: %s", e)
		}
	} else {
		fmt.Print(body)
	}

	// --- state -----------------------------------------------------------
	if *dryRun {
		path := filepath.Join(cfg.StateDir, "facts-dryrun.json")
		raw, err := json.MarshalIndent(facts, "", "  ")
		if err != nil {
			log.Printf("healthreport: could not marshal dry-run facts: %v", err)
		} else if err := os.WriteFile(path, raw, 0o644); err != nil {
			log.Printf("healthreport: could not write dry-run facts: %v", err)
		} else {
			log.Printf("healthreport: dry run written to %s (state not rotated)", path)
		}
	} else {
		if err := hr.Save(cfg.StateDir, facts, seen, 30); err != nil {
			log.Printf("healthreport: could not save state: %v", err)
		}
	}

	log.Printf("healthreport: done: %d crit, %d warn, %d new, llm=%s",
		facts.Summary.Crit, facts.Summary.Warn, len(facts.Diff.New), facts.LLMStatus)
	return 0
}

func hasPrefix(s, prefix string) bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

func printNoop(cfg hr.Config) {
	fmt.Println("healthreport configuration:")
	kumaKey := "MISSING"
	if cfg.KumaAPIKey != "" {
		kumaKey = "set"
	}
	githubToken := "MISSING"
	if cfg.GithubToken != "" {
		githubToken = "set"
	}
	haToken := "MISSING"
	if cfg.HAToken != "" {
		haToken = "set"
	}
	sshHosts := make([]string, 0, len(cfg.SSHHosts))
	for h := range cfg.SSHHosts {
		sshHosts = append(sshHosts, h)
	}
	sort.Strings(sshHosts)
	sshHostsStr := "NONE"
	if len(sshHosts) > 0 {
		sshHostsStr = joinStrings(sshHosts, ", ")
	}
	emailTo := cfg.EmailTo
	if emailTo == "" {
		emailTo = "MISSING"
	}
	owner := cfg.GithubOwner
	if owner == "" {
		owner = "?"
	}

	rows := [][2]string{
		{"victoria", cfg.VictoriaURL},
		{"loki", cfg.LokiURL},
		{"kuma", fmt.Sprintf("%s (api key %s)", cfg.KumaURL, kumaKey)},
		{"ollama", fmt.Sprintf("%s model=%s enabled=%v", cfg.OllamaURL, cfg.OllamaModel, cfg.LLMEnabled)},
		{"ssh hosts", sshHostsStr},
		{"github", fmt.Sprintf("token %s owner=%s", githubToken, owner)},
		{"homeassistant", fmt.Sprintf("%s (token %s)", cfg.HAURL, haToken)},
		{"ntfy", fmt.Sprintf("%s/%s", cfg.NtfyURL, cfg.NtfyTopic)},
		{"email", emailTo},
		{"state", cfg.StateDir},
	}
	for _, r := range rows {
		fmt.Printf("  %-10s %s\n", r[0], r[1])
	}
	fmt.Println("no-op: nothing collected, nothing sent")
}

func joinStrings(items []string, sep string) string {
	out := ""
	for i, s := range items {
		if i > 0 {
			out += sep
		}
		out += s
	}
	return out
}

func runDiffOnly(factsPath, factsPrevPath string, pretty bool) int {
	raw, err := os.ReadFile(factsPath)
	if err != nil {
		log.Printf("healthreport: %v", err)
		return 2
	}
	var current struct {
		Observations []json.RawMessage `json:"observations"`
	}
	if err := json.Unmarshal(raw, &current); err != nil {
		log.Printf("healthreport: %v", err)
		return 2
	}

	var previous struct {
		Observations []struct {
			ID       string `json:"id"`
			Severity string `json:"severity"`
		} `json:"observations"`
	}
	if factsPrevPath != "" {
		prevRaw, err := os.ReadFile(factsPrevPath)
		if err != nil {
			log.Printf("healthreport: %v", err)
			return 2
		}
		if err := json.Unmarshal(prevRaw, &previous); err != nil {
			log.Printf("healthreport: %v", err)
			return 2
		}
	}

	var observations []*hr.Observation
	for _, raw := range current.Observations {
		var obs hr.Observation
		if err := json.Unmarshal(raw, &obs); err != nil {
			continue
		}
		observations = append(observations, &obs)
	}

	var prevFacts hr.PreviousFacts
	for _, o := range previous.Observations {
		prevFacts.Observations = append(prevFacts.Observations, hr.PrevObservation{ID: o.ID, Severity: o.Severity})
	}
	result := hr.Compute(observations, prevFacts, map[string]*hr.SeenRecord{}, time.Now().Format(time.RFC3339))

	var out []byte
	if pretty {
		out, err = json.MarshalIndent(result, "", "  ")
	} else {
		out, err = json.Marshal(result)
	}
	if err != nil {
		log.Printf("healthreport: %v", err)
		return 2
	}
	fmt.Println(string(out))
	return 0
}

func printCollectOnly(results map[string]*hr.CollectorResult, pretty bool) int {
	payload := map[string]any{}
	for name, result := range results {
		entry := result.ToDict()
		entry["observations"] = result.Observations
		payload[name] = entry
	}
	var out []byte
	var err error
	if pretty {
		out, err = json.MarshalIndent(payload, "", "  ")
	} else {
		out, err = json.Marshal(payload)
	}
	if err != nil {
		log.Printf("healthreport: %v", err)
		return 2
	}
	fmt.Println(string(out))
	return 0
}
