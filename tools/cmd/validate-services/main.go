// validate-services checks the services_catalog in openvox/data/common.yaml
// for port/domain/name uniqueness, valid hosts, required fields, and the
// staging (+10000) port convention.
//
// Port of .githooks/validate_services.py, repointed at
// openvox/data/common.yaml's services_catalog (the current source of
// truth) instead of the now-frozen ansible/inventory/*.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const red = "\033[0;31m"
const green = "\033[0;32m"
const yellow = "\033[1;33m"
const blue = "\033[0;34m"
const nc = "\033[0m"

// The OpenVox fleet has no inventory file (masterless, no Ansible-style
// hosts.yml groups) - this is the fleet's real host list, cross-checked
// against openvox/manifests/site.pp's node blocks + proxy-exec roles.
var validHosts = map[string]bool{
	"mljr":          true,
	"nuc":           true,
	"ugreen":        true,
	"nas":           true,
	"wd_mycloud":    true,
	"homeassistant": true,
}

type serviceEntry struct {
	Name       string `yaml:"name"`
	Enabled    *bool  `yaml:"enabled"`
	Managed    *bool  `yaml:"managed"`
	SkipDeploy bool   `yaml:"skip_deploy"`
	Host       string `yaml:"host"`
	Port       *int   `yaml:"port"`
	Domain     any    `yaml:"domain"`
}

func (s serviceEntry) isEnabled() bool { return s.Enabled == nil || *s.Enabled }
func (s serviceEntry) isManaged() bool { return s.Managed == nil || *s.Managed }

func domainsOf(s serviceEntry) []string {
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

func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not find repo root (.git) above %s", dir)
		}
		dir = parent
	}
}

// extractStagingPort ports extract_staging_port(): parses a dev
// docker-compose.yml's port mappings for the host-side port of the
// first "host:container[/proto]" entry it finds.
func extractStagingPort(path string) (int, bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	var compose struct {
		Services map[string]struct {
			Ports []any `yaml:"ports"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal(raw, &compose); err != nil {
		return 0, false
	}
	for _, svc := range compose.Services {
		for _, p := range svc.Ports {
			portStr := fmt.Sprintf("%v", p)
			portStr = strings.SplitN(portStr, "/", 2)[0]
			if idx := strings.Index(portStr, ":"); idx >= 0 {
				hostPort := portStr[:idx]
				if n, err := strconv.Atoi(hostPort); err == nil {
					return n, true
				}
			}
		}
	}
	return 0, false
}

func validateServices(repoRoot string) ([]string, []string, error) {
	var errors, warnings []string

	catalogPath := filepath.Join(repoRoot, "openvox", "data", "common.yaml")
	raw, err := os.ReadFile(catalogPath)
	if err != nil {
		return []string{fmt.Sprintf("Failed to load %s", catalogPath)}, nil, nil
	}
	var doc struct {
		ServicesCatalog []serviceEntry `yaml:"services_catalog"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return []string{fmt.Sprintf("YAML syntax error in %s: %v", catalogPath, err)}, nil, nil
	}
	services := doc.ServicesCatalog
	if len(services) == 0 {
		warnings = append(warnings, "No services defined in common.yaml's services_catalog")
	}

	servicesDir := filepath.Join(repoRoot, "services")

	portsByHost := map[string][][2]any{} // host -> [(port, name)]
	type domainOwner struct{ domain, name string }
	var allDomains []domainOwner
	seenNames := map[string]bool{}

	for _, svc := range services {
		name := svc.Name
		if name == "" {
			errors = append(errors, "Service found without a 'name' field")
			continue
		}

		if seenNames[name] {
			errors = append(errors, fmt.Sprintf("Duplicate service name: '%s'", name))
		}
		seenNames[name] = true

		if !svc.isEnabled() {
			continue
		}

		if svc.Host != "" && !validHosts[svc.Host] {
			var valid []string
			for h := range validHosts {
				valid = append(valid, h)
			}
			sort.Strings(valid)
			errors = append(errors, fmt.Sprintf("Service '%s': host '%s' not found in inventory. Valid hosts: %v", name, svc.Host, valid))
		}
		if svc.Host == "" {
			errors = append(errors, fmt.Sprintf("Service '%s': missing required field 'host'", name))
		}

		if svc.Port == nil && svc.isManaged() {
			errors = append(errors, fmt.Sprintf("Service '%s': missing required field 'port'", name))
		}

		if svc.Host != "" && svc.Port != nil && *svc.Port > 0 {
			portsByHost[svc.Host] = append(portsByHost[svc.Host], [2]any{*svc.Port, name})
		}

		for _, d := range domainsOf(svc) {
			allDomains = append(allDomains, domainOwner{d, name})
		}

		if svc.isManaged() && !svc.SkipDeploy {
			composePath := filepath.Join(servicesDir, name, "docker-compose.yml")
			devComposePath := filepath.Join(servicesDir, name, "dev", "docker-compose.yml")
			if !fileExists(composePath) && !fileExists(devComposePath) {
				errors = append(errors, fmt.Sprintf("Service '%s': docker-compose.yml not found at %s", name, composePath))
			}
		}

		devComposePath := filepath.Join(servicesDir, name, "dev", "docker-compose.yml")
		if fileExists(devComposePath) && svc.Port != nil && *svc.Port > 0 {
			if stagingPort, ok := extractStagingPort(devComposePath); ok {
				expected := *svc.Port + 10000
				if stagingPort != expected {
					warnings = append(warnings, fmt.Sprintf(
						"Service '%s': staging port %d doesn't follow +10000 convention (expected %d based on production port %d)",
						name, stagingPort, expected, *svc.Port))
				}
			}
		}
	}

	for host, portList := range portsByHost {
		byPort := map[int][]string{}
		for _, pn := range portList {
			byPort[pn[0].(int)] = append(byPort[pn[0].(int)], pn[1].(string))
		}
		ports := make([]int, 0, len(byPort))
		for p := range byPort {
			ports = append(ports, p)
		}
		sort.Ints(ports)
		for _, p := range ports {
			names := byPort[p]
			if len(names) > 1 {
				errors = append(errors, fmt.Sprintf("Port conflict on host '%s': port %d used by multiple services: %s", host, p, strings.Join(names, ", ")))
			}
		}
	}

	byDomain := map[string][]string{}
	var domainOrder []string
	for _, do := range allDomains {
		if _, seen := byDomain[do.domain]; !seen {
			domainOrder = append(domainOrder, do.domain)
		}
		byDomain[do.domain] = append(byDomain[do.domain], do.name)
	}
	for _, d := range domainOrder {
		names := byDomain[d]
		if len(names) > 1 {
			errors = append(errors, fmt.Sprintf("Domain conflict: '%s' used by multiple services: %s", d, strings.Join(names, ", ")))
		}
	}

	return errors, warnings, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func main() {
	repoRoot, err := findRepoRoot()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	fmt.Printf("%sValidating service configurations...%s\n", blue, nc)

	errors, warnings, err := validateServices(repoRoot)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	for _, w := range warnings {
		fmt.Printf("%s⚠ Warning: %s%s\n", yellow, w, nc)
	}

	if len(errors) > 0 {
		fmt.Printf("\n%sFound %d error(s):%s\n", red, len(errors), nc)
		for _, e := range errors {
			fmt.Printf("  %s✗%s %s\n", red, nc, e)
		}
		os.Exit(1)
	}

	fmt.Printf("%s✓ All service validations passed!%s\n", green, nc)
}
