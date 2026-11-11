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

	tcpPrefix  = "TCP: "
	httpPrefix = "HTTP: "

	// Mail ports besides 587. The HTTP monitor only proves Caddy and the
	// webmail; each of these proves the port itself answers.
	mailSMTPInName = smtpPrefix + "mail 25"
	mailSMTPSName  = tcpPrefix + "mail SMTPS 465"
	mailIMAPSName  = tcpPrefix + "mail IMAPS 993"

	crowdsecLAPIName = httpPrefix + "crowdsec LAPI"
	defectdojoName   = tcpPrefix + "defectdojo"

	// Kuma's own `ziti tunnel proxy` sidecar (services/kuma). A TCP check
	// through it proves nothing: the proxy accepts every connection itself
	// and only then dials the service. Checks over Ziti therefore speak the
	// protocol (HTTP, SMTP EHLO), so an answer must come from the far end.
	kumaZitiProxy = "kuma-ziti-proxy"

	// A single failed check is not an outage: Kuma reports DOWN only after
	// this many failed retries (RetryInterval apart), PENDING until then.
	maxRetries = 3
)

// displayName is a monitor's name in Kuma: the logical name plus the
// catalog host in brackets ("nextcloud [nas]"), so a run of alerts shows at
// a glance whether one host or several are affected. Status pages and
// maintenance windows keep using the logical name (monitorIDs indexes both).
func displayName(name, host string) string {
	if host == "" {
		return name
	}
	return name + " [" + host + "]"
}

// logicalName strips displayName's " [host]" suffix.
func logicalName(display string) string {
	if i := strings.LastIndex(display, " ["); i > 0 && strings.HasSuffix(display, "]") {
		return display[:i]
	}
	return display
}

// Kinds of fixed monitor besides a plain TCP port.
const (
	kindTCP  = ""
	kindSMTP = "smtp" // connect and EHLO, no STARTTLS (the name is the proxy's)
	kindHTTP = "http" // GET url, 2xx
)

// tcpTarget is a fixed monitor that is not derived from services.yml: a TCP
// port, an SMTP server (host, port) or an HTTP URL.
type tcpTarget struct {
	name   string // logical name
	on     string // host running it, shown as " [on]"
	kind   string
	host   string
	port   int
	url    string // kindHTTP only
	legacy string // name before " [host]" was added, renamed in place
}

// monitorType is Kuma's type name for t.
func (t tcpTarget) monitorType() string {
	switch t.kind {
	case kindSMTP:
		return "smtp"
	case kindHTTP:
		return "http"
	}
	return "port"
}

// tcpTargets lists the fixed TCP checks. The CrowdSec LAPI is bound to mljr's
// tailnet IP by docker; after the 2026-10-18 reboot that bind failed and the
// container stayed down for ~23h while the crowdsec.mljr.eu HTTP monitor (which
// only proves Caddy + the web UI) stayed green. A TCP check on the bind itself
// catches exactly that.
var tcpTargets = []tcpTarget{
	{name: smtpPrefix + mailcowSMTPHost, on: "mljr", host: mailcowSMTPHost, port: mailcowSMTPPort, legacy: smtpPrefix + mailcowSMTPHost},
	// Over Ziti (crowdsec-lapi, the LAPI's own health endpoint). The old
	// TCP check on the tailnet bind is gone with the bind's purpose.
	{name: crowdsecLAPIName, on: "mljr", kind: kindHTTP, url: "http://" + kumaZitiProxy + ":8088/health"},
	// Port 25 goes over Ziti (mail-smtp-mljr): Kuma runs on nuc, whose home
	// network cannot reach port 25 on the public IP (checked 2026-10-24 from
	// three outside networks: fine), so a public check would be permanently
	// red.
	{name: mailSMTPInName, on: "mljr", kind: kindSMTP, host: kumaZitiProxy, port: 2525},
	{name: mailSMTPSName, on: "mljr", host: mailcowSMTPHost, port: 465, legacy: mailSMTPSName},
	{name: mailIMAPSName, on: "mljr", host: mailcowSMTPHost, port: 993, legacy: mailIMAPSName},
	// DefectDojo has no Caddy route (tailnet-only), so no HTTP monitor is derived
	// from the catalog. nginx publishes on nuc's Tailscale IP; Kuma runs on
	// nuc too, so this never leaves the host. Moves with the catalog bind
	// addresses (bind_addr, docs/ZERO_TRUST_PLAN.md Phase 8).
	{name: defectdojoName, on: "nuc", host: "100.100.10.1", port: 8101, legacy: tcpPrefix + "defectdojo (nuc)"},
}

type service struct {
	Name    string `yaml:"name"`
	Enabled *bool  `yaml:"enabled"`
	Domain  any    `yaml:"domain"`
	// MonitorPath is appended to the monitor URL for services that do not
	// serve 2xx on "/" (e.g. csp-reports is POST-only and 404s there).
	MonitorPath string `yaml:"monitor_path"`
	// Host is the catalog host running the service; maintenance windows
	// select monitors by it.
	Host string `yaml:"host"`
	// Monitor: false keeps the service in the catalog (Caddy route, DNS) but
	// gives it no Kuma monitor, e.g. a stopped service or a third-party page
	// the Kuma host cannot reach. An existing monitor is deleted as orphaned.
	Monitor *bool `yaml:"monitor"`
}

func (s service) isEnabled() bool { return s.Enabled == nil || *s.Enabled }

func (s service) isMonitored() bool {
	return s.isEnabled() && (s.Monitor == nil || *s.Monitor)
}

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
	// claimed holds the IDs of existing monitors a sync matched, by their
	// current or their legacy name. A monitor renamed in place this run
	// still has its old name in the fetched list; it is not an orphan.
	claimed map[int64]bool

	created []string
	updated []string
	deleted []string
	skipped int
	failed  []string
}

func getExpectedMonitorNames(services []service, hosts []host) map[string]bool {
	expected := map[string]bool{}
	for _, svc := range services {
		if svc.isMonitored() && firstDomain(svc.Domain) != "" {
			expected[displayName(svc.Name, svc.Host)] = true
		}
	}
	for _, h := range hosts {
		if h.NodeName != "" {
			expected[pingPrefix+h.NodeName] = true
		}
	}
	for _, t := range tcpTargets {
		expected[displayName(t.name, t.on)] = true
	}
	return expected
}

func targetURLFor(domain string) string {
	if strings.HasPrefix(domain, "http://") || strings.HasPrefix(domain, "https://") {
		return domain
	}
	return "https://" + domain
}

// createAndStart creates a monitor and resumes it: the client creates monitors
// paused, so without this every new monitor sits inactive and checks nothing
// (found live 2026-10-19: 13 freshly provisioned monitors with active=0).
func createAndStart(ctx context.Context, client *kuma.Client, m monitor.Monitor) error {
	id, err := client.CreateMonitor(ctx, m)
	if err != nil {
		return err
	}
	if err := client.ResumeMonitor(ctx, id); err != nil {
		return fmt.Errorf("created (id %d) but could not resume: %w", id, err)
	}
	return nil
}

// lookup finds a monitor by its display name, or by its name from before
// the " [host]" suffix (it is then renamed in place, keeping its history).
func lookup(existing map[string]monitor.Base, name, legacy string) (monitor.Base, bool) {
	if b, ok := existing[name]; ok {
		return b, true
	}
	b, ok := existing[legacy]
	return b, ok
}

func (st *stats) claim(id int64) {
	if st.claimed == nil {
		st.claimed = map[int64]bool{}
	}
	st.claimed[id] = true
}

func syncServiceMonitors(ctx context.Context, client *kuma.Client, services []service, existing map[string]monitor.Base, st *stats) {
	for _, svc := range services {
		if !svc.isMonitored() {
			continue
		}
		domain := firstDomain(svc.Domain)
		if domain == "" {
			continue
		}
		targetURL := targetURLFor(domain) + svc.MonitorPath
		name := displayName(svc.Name, svc.Host)

		if base, ok := lookup(existing, name, svc.Name); ok {
			st.claim(base.ID)
			var httpMon monitor.HTTP
			_ = base.As(&httpMon)
			if httpMon.URL != targetURL || base.Name != name || base.MaxRetries != maxRetries {
				fmt.Printf("  Updating %s: %s -> %s, maxretries=%d\n", base.Name, httpMon.URL, targetURL, maxRetries)
				httpMon.Base = base
				httpMon.URL = targetURL
				httpMon.Base.Name = name
				httpMon.Base.MaxRetries = maxRetries
				if err := client.UpdateMonitor(ctx, &httpMon); err != nil {
					fmt.Printf("  Failed to update %s: %v\n", name, err)
					st.failed = append(st.failed, name)
				} else {
					st.updated = append(st.updated, name)
				}
			} else {
				st.skipped++
			}
		} else {
			fmt.Printf("  Creating %s (%s)\n", name, targetURL)
			// Kuma v2 (2.5.6) rejects the client's zero values: nil
			// AcceptedStatusCodes marshals to null ("Cannot read properties
			// of null (reading 'every')"), so every create failed and
			// services added since the upgrade had no monitor.
			m := &monitor.HTTP{
				Base: monitor.Base{Name: name, Interval: 60, RetryInterval: 60, MaxRetries: maxRetries},
				HTTPDetails: monitor.HTTPDetails{
					URL:                 targetURL,
					Timeout:             48,
					MaxRedirects:        10,
					Method:              "GET",
					AcceptedStatusCodes: []string{"200-299"},
				},
			}
			if err := createAndStart(ctx, client, m); err != nil {
				fmt.Printf("  Failed to create %s: %v\n", name, err)
				st.failed = append(st.failed, name)
			} else {
				st.created = append(st.created, name)
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
			if pingMon.Hostname != h.NodeHost || pingMon.MaxRetries != maxRetries {
				fmt.Printf("  Updating %s: hostname=%s, maxretries=%d\n", monitorName, h.NodeHost, maxRetries)
				pingMon.Base = base
				pingMon.Hostname = h.NodeHost
				pingMon.Base.Name = monitorName
				pingMon.Base.MaxRetries = maxRetries
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
				Base:        monitor.Base{Name: monitorName, Interval: 60, RetryInterval: 60, MaxRetries: maxRetries},
				PingDetails: monitor.PingDetails{Hostname: h.NodeHost, Timeout: &pingTimeout},
			}
			if err := createAndStart(ctx, client, m); err != nil {
				fmt.Printf("  Failed to create %s: %v\n", monitorName, err)
				st.failed = append(st.failed, monitorName)
			} else {
				st.created = append(st.created, monitorName)
			}
		}
	}
}

// syncTCPMonitors keeps one monitor per tcpTargets entry. "SMTP:
// mail.mljr.eu" stays a TCP check on 587 - kept as-is rather than silently
// changing an existing production monitor's type as a side effect.
func syncTCPMonitors(ctx context.Context, client *kuma.Client, existing map[string]monitor.Base, st *stats) {
	for _, t := range tcpTargets {
		syncTCPMonitor(ctx, client, t, existing, st)
	}
}

func syncTCPMonitor(ctx context.Context, client *kuma.Client, t tcpTarget, existing map[string]monitor.Base, st *stats) {
	name := displayName(t.name, t.on)
	if base, ok := lookup(existing, name, t.legacy); ok {
		st.claim(base.ID)
		if base.Type() == t.monitorType() {
			m, changed := t.update(base)
			if !changed && base.Name == name && base.MaxRetries == maxRetries {
				st.skipped++
				return
			}
			fmt.Printf("  Updating %s -> %s, maxretries=%d\n", base.Name, name, maxRetries)
			b := m.base()
			b.Name = name
			b.MaxRetries = maxRetries
			if err := client.UpdateMonitor(ctx, m); err != nil {
				fmt.Printf("  Failed to update %s: %v\n", name, err)
				st.failed = append(st.failed, name)
			} else {
				st.updated = append(st.updated, name)
			}
			return
		}
		// Kuma cannot change a monitor's type: replace it.
		fmt.Printf("  Replacing %s (%s -> %s)\n", base.Name, base.Type(), t.monitorType())
		if err := client.DeleteMonitor(ctx, base.ID); err != nil {
			fmt.Printf("  Failed to delete %s: %v\n", base.Name, err)
			st.failed = append(st.failed, name)
			return
		}
		st.deleted = append(st.deleted, base.Name)
	}
	fmt.Printf("  Creating %s (%s)\n", name, t.monitorType())
	m := t.fresh(monitor.Base{Name: name, Interval: 60, RetryInterval: 60, MaxRetries: maxRetries})
	if err := createAndStart(ctx, client, m); err != nil {
		fmt.Printf("  Failed to create %s: %v\n", name, err)
		st.failed = append(st.failed, name)
	} else {
		st.created = append(st.created, name)
	}
}

// fixedMonitor is a typed monitor whose Base can be edited in place.
type fixedMonitor interface {
	monitor.Monitor
	base() *monitor.Base
}

type tcpMonitor struct{ *monitor.TCPPort }
type smtpMonitor struct{ *monitor.SMTP }
type httpMonitor struct{ *monitor.HTTP }

func (m tcpMonitor) base() *monitor.Base  { return &m.TCPPort.Base }
func (m smtpMonitor) base() *monitor.Base { return &m.SMTP.Base }
func (m httpMonitor) base() *monitor.Base { return &m.HTTP.Base }

const smtpNoSTARTTLS = "nostarttls"

// fresh builds a new monitor for t on base.
func (t tcpTarget) fresh(base monitor.Base) fixedMonitor {
	switch t.kind {
	case kindSMTP:
		port, sec := int64(t.port), smtpNoSTARTTLS
		return smtpMonitor{&monitor.SMTP{Base: base, SMTPDetails: monitor.SMTPDetails{
			Hostname: t.host, Port: &port, SMTPSecurity: &sec}}}
	case kindHTTP:
		// Same defaults as the catalog's HTTP monitors (syncServiceMonitors).
		return httpMonitor{&monitor.HTTP{Base: base, HTTPDetails: monitor.HTTPDetails{
			URL: t.url, Timeout: 48, MaxRedirects: 10, Method: "GET",
			AcceptedStatusCodes: []string{"200-299"}}}}
	}
	return tcpMonitor{&monitor.TCPPort{Base: base, TCPPortDetails: monitor.TCPPortDetails{
		Hostname: t.host, Port: t.port}}}
}

// update loads the existing monitor (same type as t), sets what t defines
// and reports whether that changed anything. Other settings are kept.
func (t tcpTarget) update(base monitor.Base) (fixedMonitor, bool) {
	switch t.kind {
	case kindSMTP:
		var m monitor.SMTP
		_ = base.As(&m)
		m.Base = base
		port, sec := int64(t.port), smtpNoSTARTTLS
		changed := m.Hostname != t.host || m.Port == nil || *m.Port != port ||
			m.SMTPSecurity == nil || *m.SMTPSecurity != sec
		m.Hostname, m.Port, m.SMTPSecurity = t.host, &port, &sec
		return smtpMonitor{&m}, changed
	case kindHTTP:
		var m monitor.HTTP
		_ = base.As(&m)
		m.Base = base
		changed := m.URL != t.url
		m.URL = t.url
		return httpMonitor{&m}, changed
	}
	var m monitor.TCPPort
	_ = base.As(&m)
	m.Base = base
	changed := m.Hostname != t.host || m.Port != t.port
	m.Hostname, m.Port = t.host, t.port
	return tcpMonitor{&m}, changed
}

func deleteOrphanedMonitors(ctx context.Context, client *kuma.Client, expected map[string]bool, existing map[string]monitor.Base, st *stats) {
	for name, base := range existing {
		if !expected[name] && !st.claimed[base.ID] {
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
	// WithAutosetup creates the database and the admin user on a fresh
	// server (new volume), so a rebuild needs no manual first-run setup.
	client, err := kuma.New(ctx, url, username, password, kuma.WithAutosetup())
	if err != nil {
		fmt.Printf("Login failed: %v\n", err)
		fmt.Println("This may happen if:")
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

	// State around the monitors: notification, maintenance windows, status
	// pages. Needs the monitor IDs, including those created just above.
	ids, err := monitorIDs(ctx, client)
	if err != nil {
		fmt.Printf("Error fetching monitors: %v\n", err)
		return 1
	}
	syncSettings(ctx, client, password, st)
	syncNotification(ctx, client, st)
	syncMaintenance(ctx, client, cat.Services, ids, st)
	syncStatusPages(ctx, client, ids, st)
	checkAPIKey(url, os.Getenv("KUMA_API_KEY"), st)

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
