// check-services tests that all enabled production services are
// reachable. Skips services that are disabled, have no domain, or are in
// skipNames.
//
// Port of tests/scripts/check_services.py, repointed at
// openvox/data/common.yaml's services_catalog (the current source of
// truth) instead of the now-frozen ansible/inventory/group_vars/all/all.yml.
//
// Usage: check-services [--timeout N] [--verbose] [--workers N]
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

// Services to skip entirely (require special auth flows, not
// HTTP-testable, or are complex infrastructure that handles its own
// probes).
var skipNames = map[string]bool{
	"mailcow": true, // SMTP/IMAP, complex web auth
	"nas":     true, // NAS UI, requires LAN or specific auth
}

// Services where 401/302/403 is expected (auth wall = service is up).
// Not read anywhere below - ACCEPTABLE_STATUS already covers 401/403
// generically - kept for parity with the Python original, which defined
// this same set and never referenced it either.
var authServices = map[string]bool{
	"authelia": true, // SSO redirect
	"goaccess": true, // auth protected
}

var acceptableStatus = map[int]bool{
	200: true, 201: true, 204: true,
	301: true, 302: true, 303: true, 307: true, 308: true,
	401: true, 403: true,
}

type service struct {
	Name    string `yaml:"name"`
	Enabled *bool  `yaml:"enabled"`
	Domain  any    `yaml:"domain"`
}

func (s service) isEnabled() bool {
	return s.Enabled == nil || *s.Enabled
}

func domainsOf(s service) []string {
	switch d := s.Domain.(type) {
	case string:
		if d == "" {
			return nil
		}
		return []string{d}
	case []any:
		out := make([]string, 0, len(d))
		for _, v := range d {
			if str, ok := v.(string); ok {
				out = append(out, str)
			}
		}
		return out
	default:
		return nil
	}
}

type checkResult struct {
	name, url string
	ok        bool
	detail    string
}

func checkURL(client *http.Client, name, url string) checkResult {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return checkResult{name, url, false, err.Error()}
	}
	req.Header.Set("User-Agent", "homelab-test/1.0")

	resp, err := client.Do(req)
	if err != nil {
		return checkResult{name, url, false, fmt.Sprintf("URLError: %v", err)}
	}
	defer resp.Body.Close()
	ok := acceptableStatus[resp.StatusCode]
	return checkResult{name, url, ok, fmt.Sprintf("HTTP %d", resp.StatusCode)}
}

func run() int {
	timeout := flag.Int("timeout", 10, "")
	verbose := flag.Bool("verbose", false, "")
	flag.BoolVar(verbose, "v", false, "")
	workers := flag.Int("workers", 8, "")
	catalogPath := flag.String("catalog", "", "path to common.yaml (default: openvox/data/common.yaml under the repo root)")
	flag.Parse()

	path := *catalogPath
	if path == "" {
		root, err := findRepoRoot()
		if err != nil {
			fmt.Fprintln(os.Stderr, "ERROR:", err)
			return 1
		}
		path = filepath.Join(root, "openvox", "data", "common.yaml")
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		return 1
	}
	var doc struct {
		ServicesCatalog []service `yaml:"services_catalog"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		return 1
	}
	services := doc.ServicesCatalog

	type task struct{ name, url string }
	var tasks []task
	for _, svc := range services {
		name := svc.Name
		if name == "" {
			name = "?"
		}
		if !svc.isEnabled() {
			continue
		}
		if skipNames[name] {
			if *verbose {
				fmt.Printf("SKIP  [%s] (in skip list)\n", name)
			}
			continue
		}
		domains := domainsOf(svc)
		if len(domains) == 0 {
			continue
		}
		tasks = append(tasks, task{name, "https://" + domains[0]})
	}

	if len(tasks) == 0 {
		fmt.Println("No services to test")
		return 0
	}

	client := &http.Client{
		Timeout: time.Duration(*timeout) * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // same as the Python original's ssl.CERT_NONE
		},
	}

	sem := make(chan struct{}, *workers)
	results := make([]checkResult, len(tasks))
	var wg sync.WaitGroup
	for i, t := range tasks {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int, t task) {
			defer wg.Done()
			defer func() { <-sem }()
			results[i] = checkURL(client, t.name, t.url)
		}(i, t)
	}
	wg.Wait()

	// Python's as_completed() prints in completion order, not task order -
	// not worth replicating exactly (non-deterministic even run to run in
	// the original); sort by name instead for stable, readable output.
	sort.Slice(results, func(i, j int) bool { return results[i].name < results[j].name })

	passed, failures := 0, 0
	for _, r := range results {
		if r.ok {
			if *verbose {
				fmt.Printf("OK    [%s] %s — %s\n", r.name, r.url, r.detail)
			} else {
				fmt.Printf("OK    [%s]\n", r.name)
			}
			passed++
		} else {
			fmt.Printf("FAIL  [%s] %s — %s\n", r.name, r.url, r.detail)
			failures++
		}
	}

	fmt.Printf("\n%d passed, %d failed, %d skipped\n", passed, failures, len(services)-len(tasks))
	if failures > 0 {
		return 1
	}
	return 0
}

func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "openvox", "data", "common.yaml")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not find repo root (openvox/data/common.yaml) above %s", dir)
		}
		dir = parent
	}
}

func main() {
	os.Exit(run())
}
