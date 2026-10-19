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

	tcpPrefix = "TCP: "
)

// tcpTarget is a plain TCP-port monitor that is not derived from services.yml.
type tcpTarget struct {
	name string
	host string
	port int
}

// tcpTargets lists the fixed TCP checks. The CrowdSec LAPI is bound to mljr's
// tailnet IP by docker; after the 2026-10-18 reboot that bind failed and the
// container stayed down for ~23h while the crowdsec.mljr.eu HTTP monitor (which
// only proves Caddy + the web UI) stayed green. A TCP check on the bind itself
// catches exactly that.
var tcpTargets = []tcpTarget{
	{name: smtpPrefix + mailcowSMTPHost, host: mailcowSMTPHost, port: mailcowSMTPPort},
	{name: tcpPrefix + "crowdsec LAPI (mljr)", host: "100.100.20.1", port: 8088},
}

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
	for _, t := range tcpTargets {
		expected[t.name] = true
	}
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
			// Kuma v2 (2.5.6) rejects the client's zero values: nil
			// AcceptedStatusCodes marshals to null ("Cannot read properties
			// of null (reading 'every')"), so every create failed and
			// services added since the upgrade had no monitor.
			m := &monitor.HTTP{
				Base: monitor.Base{Name: svc.Name, Interval: 60, RetryInterval: 60},
				HTTPDetails: monitor.HTTPDetails{
					URL:                 targetURL,
					Timeout:             48,
					MaxRedirects:        10,
					Method:              "GET",
					AcceptedStatusCodes: []string{"200-299"},
				},
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
			// Kuma v2: a nil Timeout is sent as NULL into a NOT NULL column.
			pingTimeout := int64(10)
			m := &monitor.Ping{
				Base:        monitor.Base{Name: monitorName, Interval: 60, RetryInterval: 60, MaxRetries: 3},
				PingDetails: monitor.PingDetails{Hostname: h.NodeHost, Timeout: &pingTimeout},
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

// syncTCPMonitors keeps one TCP port monitor per tcpTargets entry. The SMTP
// check stays a TCP check (no native SMTP type at the time it was written) -
// kept as-is rather than silently changing an existing production monitor's
// type as a side effect.
func syncTCPMonitors(ctx context.Context, client *kuma.Client, existing map[string]monitor.Base, st *stats) {
	for _, t := range tcpTargets {
		syncTCPMonitor(ctx, client, t, existing, st)
	}
}

func syncTCPMonitor(ctx context.Context, client *kuma.Client, t tcpTarget, existing map[string]monitor.Base, st *stats) {
	if base, ok := existing[t.name]; ok {
		var tcpMon monitor.TCPPort
		_ = base.As(&tcpMon)
		if tcpMon.Hostname != t.host || tcpMon.Port != t.port {
			fmt.Printf("  Updating %s\n", t.name)
			tcpMon.Base = base
			tcpMon.Hostname = t.host
			tcpMon.Port = t.port
			tcpMon.Base.Name = t.name
			if err := client.UpdateMonitor(ctx, &tcpMon); err != nil {
				fmt.Printf("  Failed to update %s: %v\n", t.name, err)
				st.failed = append(st.failed, t.name)
			} else {
				st.updated = append(st.updated, t.name)
			}
		} else {
			st.skipped++
		}
		return
	}
	fmt.Printf("  Creating %s (TCP port %d)\n", t.name, t.port)
	m := &monitor.TCPPort{
		Base:           monitor.Base{Name: t.name, Interval: 60, RetryInterval: 60},
		TCPPortDetails: monitor.TCPPortDetails{Hostname: t.host, Port: t.port},
	}
	if _, err := client.CreateMonitor(ctx, m); err != nil {
		fmt.Printf("  Failed to create %s: %v\n", t.name, err)
		st.failed = append(st.failed, t.name)
	} else {
		st.created = append(st.created, t.name)
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
	syncTCPMonitors(ctx, client, existingMonitors, st)
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
