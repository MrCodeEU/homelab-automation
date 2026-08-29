// provision-kuma syncs Uptime Kuma monitors from a services.yml catalog
// dump (services + hosts), matching what Uptime Kuma already has.
//
// Port of services/kuma/hooks/provision-kuma.py. Uses
// github.com/breml/go-uptime-kuma-client instead of the Python
// uptime-kuma-api-v2 package (both talk Socket.IO to the same server).
//
// Usage: provision-kuma [services.yml path, default /opt/kuma/services.yml]
// Env: KUMA_URL (default http://localhost:3001), KUMA_USERNAME, KUMA_PASSWORD
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	kuma "github.com/breml/go-uptime-kuma-client"
	"github.com/breml/go-uptime-kuma-client/monitor"
	"gopkg.in/yaml.v3"
)

const (
	pingPrefix = "Ping: "
	smtpPrefix = "SMTP: "

	mailcowSMTPHost = "mail.mljr.eu"
	mailcowSMTPPort = 587
)

type service struct {
	Name    string `yaml:"name"`
	Enabled *bool  `yaml:"enabled"`
	Domain  any    `yaml:"domain"`
}

func (s service) isEnabled() bool { return s.Enabled == nil || *s.Enabled }

// firstDomain mirrors the Python original's domain handling: a list uses
// its first element, a plain string is used as-is, anything absent is "".
func firstDomain(d any) string {
	switch v := d.(type) {
	case string:
		return v
	case []any:
		if len(v) == 0 {
			return ""
		}
		if s, ok := v[0].(string); ok {
			return s
		}
		return ""
	default:
		return ""
	}
}

type host struct {
	NodeName string `yaml:"node_name"`
	NodeHost string `yaml:"node_host"`
}

type catalog struct {
	Services []service `yaml:"services"`
	Hosts    []host    `yaml:"hosts"`
}

type stats struct {
	created []string
	updated []string
	deleted []string
	skipped int
	failed  []string
}

func getExpectedMonitorNames(services []service, hosts []host) map[string]bool {
	expected := map[string]bool{}
	for _, svc := range services {
		if svc.isEnabled() && firstDomain(svc.Domain) != "" {
			expected[svc.Name] = true
		}
	}
	for _, h := range hosts {
		if h.NodeName != "" {
			expected[pingPrefix+h.NodeName] = true
		}
	}
	expected[smtpPrefix+mailcowSMTPHost] = true
	return expected
}

func targetURLFor(domain string) string {
	if strings.HasPrefix(domain, "http://") || strings.HasPrefix(domain, "https://") {
		return domain
	}
	return "https://" + domain
}

func syncServiceMonitors(ctx context.Context, client *kuma.Client, services []service, existing map[string]monitor.Base, st *stats) {
	for _, svc := range services {
		if !svc.isEnabled() {
			continue
		}
		domain := firstDomain(svc.Domain)
		if domain == "" {
			continue
		}
		targetURL := targetURLFor(domain)

		if base, ok := existing[svc.Name]; ok {
			var httpMon monitor.HTTP
			_ = base.As(&httpMon)
			if httpMon.URL != targetURL {
				fmt.Printf("  Updating %s: %s -> %s\n", svc.Name, httpMon.URL, targetURL)
				httpMon.Base = base
				httpMon.URL = targetURL
				httpMon.Base.Name = svc.Name
				if err := client.UpdateMonitor(ctx, &httpMon); err != nil {
					fmt.Printf("  Failed to update %s: %v\n", svc.Name, err)
					st.failed = append(st.failed, svc.Name)
				} else {
					st.updated = append(st.updated, svc.Name)
				}
			} else {
				st.skipped++
			}
		} else {
			fmt.Printf("  Creating %s (%s)\n", svc.Name, targetURL)
			m := &monitor.HTTP{
				Base:        monitor.Base{Name: svc.Name, Interval: 60, RetryInterval: 60},
				HTTPDetails: monitor.HTTPDetails{URL: targetURL},
			}
			if _, err := client.CreateMonitor(ctx, m); err != nil {
				fmt.Printf("  Failed to create %s: %v\n", svc.Name, err)
				st.failed = append(st.failed, svc.Name)
			} else {
				st.created = append(st.created, svc.Name)
			}
		}
	}
}

func syncPingMonitors(ctx context.Context, client *kuma.Client, hosts []host, existing map[string]monitor.Base, st *stats) {
	for _, h := range hosts {
		if h.NodeName == "" || h.NodeHost == "" {
			continue
		}
		monitorName := pingPrefix + h.NodeName

		if base, ok := existing[monitorName]; ok {
			var pingMon monitor.Ping
			_ = base.As(&pingMon)
			if pingMon.Hostname != h.NodeHost || pingMon.MaxRetries != 3 {
				fmt.Printf("  Updating %s: hostname=%s, maxretries=3\n", monitorName, h.NodeHost)
				pingMon.Base = base
				pingMon.Hostname = h.NodeHost
				pingMon.Base.Name = monitorName
				pingMon.Base.MaxRetries = 3
				if err := client.UpdateMonitor(ctx, &pingMon); err != nil {
					fmt.Printf("  Failed to update %s: %v\n", monitorName, err)
					st.failed = append(st.failed, monitorName)
				} else {
					st.updated = append(st.updated, monitorName)
				}
			} else {
				st.skipped++
			}
		} else {
			fmt.Printf("  Creating %s (%s)\n", monitorName, h.NodeHost)
			m := &monitor.Ping{
				Base:        monitor.Base{Name: monitorName, Interval: 60, RetryInterval: 60, MaxRetries: 3},
				PingDetails: monitor.PingDetails{Hostname: h.NodeHost},
			}
			if _, err := client.CreateMonitor(ctx, m); err != nil {
				fmt.Printf("  Failed to create %s: %v\n", monitorName, err)
				st.failed = append(st.failed, monitorName)
			} else {
				st.created = append(st.created, monitorName)
			}
		}
	}
}

// syncSMTPMonitor checks mailcow's SMTP port via a TCP port monitor.
// Uptime Kuma's own SMTP monitor type exists in this client library, but
// the original used a TCP port check (no native SMTP type at the time it
// was written) - kept as-is rather than silently changing an existing
// production monitor's type as a side effect of this port.
func syncSMTPMonitor(ctx context.Context, client *kuma.Client, existing map[string]monitor.Base, st *stats) {
	monitorName := smtpPrefix + mailcowSMTPHost

	if base, ok := existing[monitorName]; ok {
		var tcpMon monitor.TCPPort
		_ = base.As(&tcpMon)
		if tcpMon.Hostname != mailcowSMTPHost || tcpMon.Port != mailcowSMTPPort {
			fmt.Printf("  Updating %s\n", monitorName)
			tcpMon.Base = base
			tcpMon.Hostname = mailcowSMTPHost
			tcpMon.Port = mailcowSMTPPort
			tcpMon.Base.Name = monitorName
			if err := client.UpdateMonitor(ctx, &tcpMon); err != nil {
				fmt.Printf("  Failed to update %s: %v\n", monitorName, err)
				st.failed = append(st.failed, monitorName)
			} else {
				st.updated = append(st.updated, monitorName)
			}
		} else {
			st.skipped++
		}
	} else {
		fmt.Printf("  Creating %s (TCP port %d)\n", monitorName, mailcowSMTPPort)
		m := &monitor.TCPPort{
			Base:           monitor.Base{Name: monitorName, Interval: 60, RetryInterval: 60},
			TCPPortDetails: monitor.TCPPortDetails{Hostname: mailcowSMTPHost, Port: mailcowSMTPPort},
		}
		if _, err := client.CreateMonitor(ctx, m); err != nil {
			fmt.Printf("  Failed to create SMTP monitor: %v\n", err)
			st.failed = append(st.failed, monitorName)
		} else {
			st.created = append(st.created, monitorName)
		}
	}
}

func deleteOrphanedMonitors(ctx context.Context, client *kuma.Client, expected map[string]bool, existing map[string]monitor.Base, st *stats) {
	for name, base := range existing {
		if !expected[name] {
			fmt.Printf("  Deleting orphaned monitor: %s\n", name)
			if err := client.DeleteMonitor(ctx, base.ID); err != nil {
				fmt.Printf("  Failed to delete %s: %v\n", name, err)
				st.failed = append(st.failed, "delete:"+name)
			} else {
				st.deleted = append(st.deleted, name)
			}
		}
	}
}

func run() int {
	fmt.Println("Uptime Kuma provisioning started")

	url := os.Getenv("KUMA_URL")
	if url == "" {
		url = "http://localhost:3001"
	}
	username := os.Getenv("KUMA_USERNAME")
	password := os.Getenv("KUMA_PASSWORD")
	servicesFile := "/opt/kuma/services.yml"
	if len(os.Args) > 1 {
		servicesFile = os.Args[1]
	}

	if username == "" || password == "" {
		fmt.Println("Error: KUMA_USERNAME and KUMA_PASSWORD must be set")
		return 1
	}

	fmt.Printf("Connecting to Uptime Kuma at %s\n", url)
	ctx := context.Background()

	fmt.Printf("Attempting login with username: %s\n", username)
	client, err := kuma.New(ctx, url, username, password)
	if err != nil {
		fmt.Printf("Login failed: %v\n", err)
		fmt.Println("This may happen if:")
		fmt.Println("  - First-time setup: Please complete initial setup via web UI first")
		fmt.Println("  - Wrong credentials: Check KUMA_USERNAME and KUMA_PASSWORD in secrets")
		fmt.Println("  - API not ready: Kuma may still be starting up")
		return 1
	}
	fmt.Println("Login successful")

	if _, err := os.Stat(servicesFile); err != nil {
		fmt.Printf("Error: %s not found\n", servicesFile)
		if abs, absErr := filepath.Abs(servicesFile); absErr == nil {
			fmt.Printf("Expected path: %s\n", abs)
		}
		return 1
	}

	fmt.Printf("Reading services from %s\n", servicesFile)
	raw, err := os.ReadFile(servicesFile)
	if err != nil {
		fmt.Printf("Error reading %s: %v\n", servicesFile, err)
		return 1
	}
	var cat catalog
	if err := yaml.Unmarshal(raw, &cat); err != nil {
		fmt.Printf("Error parsing %s: %v\n", servicesFile, err)
		return 1
	}

	monitors, err := client.GetMonitors(ctx)
	if err != nil {
		fmt.Printf("Error fetching monitors: %v\n", err)
		return 1
	}
	existingMonitors := map[string]monitor.Base{}
	for _, m := range monitors {
		existingMonitors[m.Name] = m
	}

	expectedNames := getExpectedMonitorNames(cat.Services, cat.Hosts)

	fmt.Printf("Config: %d services, %d hosts | Kuma: %d monitors | Expected: %d\n",
		len(cat.Services), len(cat.Hosts), len(existingMonitors), len(expectedNames))

	st := &stats{}
	syncServiceMonitors(ctx, client, cat.Services, existingMonitors, st)
	syncPingMonitors(ctx, client, cat.Hosts, existingMonitors, st)
	syncSMTPMonitor(ctx, client, existingMonitors, st)
	deleteOrphanedMonitors(ctx, client, expectedNames, existingMonitors, st)

	var summaryParts []string
	if len(st.created) > 0 {
		summaryParts = append(summaryParts, fmt.Sprintf("created %d", len(st.created)))
	}
	if len(st.updated) > 0 {
		summaryParts = append(summaryParts, fmt.Sprintf("updated %d", len(st.updated)))
	}
	if len(st.deleted) > 0 {
		summaryParts = append(summaryParts, fmt.Sprintf("deleted %d", len(st.deleted)))
	}
	if st.skipped > 0 {
		summaryParts = append(summaryParts, fmt.Sprintf("unchanged %d", st.skipped))
	}
	if len(st.failed) > 0 {
		summaryParts = append(summaryParts, fmt.Sprintf("failed %d", len(st.failed)))
	}

	if len(summaryParts) > 0 {
		fmt.Printf("Summary: %s\n", strings.Join(summaryParts, ", "))
	} else {
		fmt.Println("Summary: no changes")
	}

	client.Disconnect()

	if len(st.failed) > 0 {
		fmt.Printf("\nFailed operations: %v\n", st.failed)
		fmt.Println("Check the errors above for details")
		return 1
	}

	fmt.Println("Provisioning completed successfully")
	return 0
}

func main() {
	os.Exit(run())
}
