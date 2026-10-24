package main

// Everything besides the monitors themselves that used to live only in Kuma's
// database: the ntfy notification, maintenance windows and status pages. Kept
// as data so a fresh Kuma (new database, new volume) is rebuilt from the repo.

import (
	"context"
	"fmt"
	"sort"

	kuma "github.com/breml/go-uptime-kuma-client"
	"github.com/breml/go-uptime-kuma-client/maintenance"
	"github.com/breml/go-uptime-kuma-client/notification"
	"github.com/breml/go-uptime-kuma-client/statuspage"
)

const (
	// ntfyName is "Default" because that is what the hand-made notification
	// on the existing instance is called: provisioning adopts it instead of
	// adding a second one (which would alert twice on the monitors that
	// already have it).
	ntfyName   = "Default"
	ntfyServer = "https://ntfy.mljr.eu"
	ntfyTopic  = "uptime"
)

// window is one maintenance window. Cron is evaluated in Timezone ("UTC",
// "SAME_AS_SERVER" or an IANA name), so a UTC-defined job keeps its slot
// across DST changes.
type window struct {
	Title       string
	Description string
	Cron        string
	Minutes     int
	Timezone    string
	// Services are catalog service names; Hosts selects every enabled catalog
	// service running on that host. Both are matched against monitor names.
	Services []string
	Hosts    []string
}

// windows mirror the real jobs that restart or stop things:
//   - Unraid CA auto-update plugin: docker + plugin updates, daily 00:00.
//   - Unraid appdata.backup plugin: Sundays 05:00, stops the containers listed
//     below for the duration of the backup (nextcloud-aio-* are skipped there).
//   - Nextcloud AIO's own backup: daily 02:00 UTC, stops the whole AIO stack.
var windows = []window{
	{
		Title:       "Unraid container update",
		Description: "ca.update.applications: docker and plugin auto-update, daily 00:00",
		Cron:        "0 0 * * *",
		Minutes:     20,
		Timezone:    "SAME_AS_SERVER",
		Hosts:       []string{"nas"},
	},
	{
		Title:       "Unraid appdata backup",
		Description: "appdata.backup plugin, Sundays 05:00; stops these containers while it runs",
		Cron:        "0 5 * * 0",
		Minutes:     180,
		Timezone:    "SAME_AS_SERVER",
		Services:    []string{"dawarich", "immich", "dockhand", "ollama", "syncthing", "netronome-agent-nas"},
	},
	{
		Title:       "Nextcloud AIO backup",
		Description: "AIO daily backup at 02:00 UTC; the whole AIO stack is stopped",
		Cron:        "0 2 * * *",
		Minutes:     60,
		Timezone:    "UTC",
		Services:    []string{"nextcloud"},
	},
}

// windowMonitorNames resolves a window to monitor names present in the catalog.
func windowMonitorNames(w window, services []service) []string {
	want := map[string]bool{}
	for _, name := range w.Services {
		want[name] = true
	}
	hosts := map[string]bool{}
	for _, h := range w.Hosts {
		hosts[h] = true
	}
	var out []string
	for _, svc := range services {
		if !svc.isEnabled() || firstDomain(svc.Domain) == "" {
			continue
		}
		if want[svc.Name] || hosts[svc.Host] {
			out = append(out, svc.Name)
		}
	}
	sort.Strings(out)
	return out
}

// page is one status page. A monitor named in Groups that has no monitor in
// Kuma is skipped, so the lists may name optional or disabled services.
type page struct {
	Slug   string
	Title  string
	Groups []group
}

type group struct {
	Name     string
	Monitors []string
}

// pages. "all" is read by mljr-web (/api/status-page/all and
// /api/status-page/heartbeat/all): keep its slug and monitor names stable.
var pages = []page{
	{
		Slug: "all", Title: "MLJR",
		Groups: []group{{Name: "Dienste", Monitors: []string{
			"authelia", "cglab", "gameoflife", "glance", "goaccess", "homeassistant", "homepage",
			"immich", "kuma", "mailcow", "nas", "nextcloud", "ntfy", "nuc-webui", "projects",
			smtpPrefix + mailcowSMTPHost, "sudoku", "syncthing", "ui-showcase", "wordwiz",
		}}},
	},
	{
		Slug: "infra", Title: "MLJR Infrastruktur",
		Groups: []group{
			{Name: "Hosts", Monitors: []string{
				pingPrefix + "mljr", pingPrefix + "nuc", pingPrefix + "nas", pingPrefix + "ugreen",
				pingPrefix + "wd-mycloud", pingPrefix + "homeassistant",
			}},
			{Name: "Netzwerk", Monitors: []string{
				tcpPrefix + "crowdsec LAPI (mljr)", tcpPrefix + "defectdojo (nuc)", "cockpit", "nuc-webui", "nas",
			}},
		},
	},
	{
		Slug: "apps", Title: "MLJR Apps",
		Groups: []group{
			{Name: "Cloud und Medien", Monitors: []string{"nextcloud", "immich", "syncthing", "opencloud", "dawarich", "projects"}},
			{Name: "Alltag", Monitors: []string{"actual-budget", "sure", "glucava", "homeassistant", "homepage", "glance", "weather-cli", "newsletter"}},
			{Name: "Entwicklung", Monitors: []string{"forgejo", "wordwiz", "cglab", "codec", "regex", "cron", "ui-showcase", "gameoflife", "sudoku"}},
		},
	},
	{
		Slug: "mail", Title: "MLJR Mail",
		Groups: []group{{Name: "Mail", Monitors: []string{
			"mailcow", smtpPrefix + mailcowSMTPHost, "mail-archiver", "dmarc-monitor", "newsletter",
		}}},
	},
	{
		Slug: "security", Title: "MLJR Sicherheit",
		Groups: []group{{Name: "Sicherheit", Monitors: []string{
			"authelia", "crowdsec", "crowdsec-nuc", "crowdsec-nas", "canarytokens", "defectdojo", "csp-reports",
			tcpPrefix + "crowdsec LAPI (mljr)", tcpPrefix + "defectdojo (nuc)",
		}}},
	},
}

func monitorIDs(ctx context.Context, client *kuma.Client) (map[string]int64, error) {
	monitors, err := client.GetMonitors(ctx)
	if err != nil {
		return nil, err
	}
	ids := make(map[string]int64, len(monitors))
	for _, m := range monitors {
		ids[m.Name] = m.ID
	}
	return ids, nil
}

// syncNotification makes sure the ntfy notification exists and sits on every
// monitor, including ones created later: applyExisting is re-applied on every
// run, and Kuma only adds the monitors that are still missing.
func syncNotification(ctx context.Context, client *kuma.Client, st *stats) {
	desired := notification.Ntfy{
		Base: notification.Base{Name: ntfyName, IsActive: true, IsDefault: true, ApplyExisting: true},
		NtfyDetails: notification.NtfyDetails{
			AuthenticationMethod: "none",
			Priority:             1,
			PriorityDown:         3,
			ServerURL:            ntfyServer,
			Topic:                ntfyTopic,
		},
	}
	for _, n := range client.GetNotifications(ctx) {
		if n.Name != ntfyName {
			continue
		}
		desired.ID = n.ID
		if err := client.UpdateNotification(ctx, desired); err != nil {
			fmt.Printf("  Failed to update notification %s: %v\n", ntfyName, err)
			st.failed = append(st.failed, "notification "+ntfyName)
		}
		return
	}
	fmt.Printf("  Creating notification %s -> %s/%s\n", ntfyName, ntfyServer, ntfyTopic)
	if _, err := client.CreateNotification(ctx, desired); err != nil {
		fmt.Printf("  Failed to create notification %s: %v\n", ntfyName, err)
		st.failed = append(st.failed, "notification "+ntfyName)
		return
	}
	st.created = append(st.created, "notification "+ntfyName)
}

func syncMaintenance(ctx context.Context, client *kuma.Client, services []service, ids map[string]int64, st *stats) {
	existing, err := client.GetMaintenances(ctx)
	if err != nil {
		fmt.Printf("  Failed to list maintenance windows: %v\n", err)
		st.failed = append(st.failed, "maintenance list")
		return
	}
	byTitle := map[string]maintenance.Maintenance{}
	for _, m := range existing {
		byTitle[m.Title] = m
	}

	for _, w := range windows {
		var monIDs []int64
		for _, name := range windowMonitorNames(w, services) {
			if id, ok := ids[name]; ok {
				monIDs = append(monIDs, id)
			}
		}
		desired := &maintenance.Maintenance{
			Title:           w.Title,
			Description:     w.Description,
			Strategy:        "cron",
			Active:          true,
			Cron:            w.Cron,
			DurationMinutes: w.Minutes,
			TimezoneOption:  w.Timezone,
			DateRange:       []*maintenance.KumaDate{nil},
		}
		label := "maintenance " + w.Title
		if cur, ok := byTitle[w.Title]; ok {
			desired.ID = cur.ID
			if err := client.UpdateMaintenance(ctx, desired); err != nil {
				fmt.Printf("  Failed to update %s: %v\n", label, err)
				st.failed = append(st.failed, label)
				continue
			}
		} else {
			fmt.Printf("  Creating %s (%s, %d min, %s) for %d monitors\n", label, w.Cron, w.Minutes, w.Timezone, len(monIDs))
			created, err := client.CreateMaintenance(ctx, desired)
			if err != nil {
				fmt.Printf("  Failed to create %s: %v\n", label, err)
				st.failed = append(st.failed, label)
				continue
			}
			desired.ID = created.ID
			st.created = append(st.created, label)
		}
		if err := client.SetMonitorMaintenance(ctx, desired.ID, monIDs); err != nil {
			fmt.Printf("  Failed to assign monitors to %s: %v\n", label, err)
			st.failed = append(st.failed, label)
		}
	}

	known := map[string]bool{}
	for _, w := range windows {
		known[w.Title] = true
	}
	for _, m := range existing {
		if known[m.Title] {
			continue
		}
		fmt.Printf("  Deleting unmanaged maintenance window %q\n", m.Title)
		if err := client.DeleteMaintenance(ctx, m.ID); err != nil {
			fmt.Printf("  Failed to delete maintenance window %q: %v\n", m.Title, err)
			st.failed = append(st.failed, "maintenance "+m.Title)
		} else {
			st.deleted = append(st.deleted, "maintenance "+m.Title)
		}
	}
}

func syncStatusPages(ctx context.Context, client *kuma.Client, ids map[string]int64, st *stats) {
	existing, err := client.GetStatusPages(ctx)
	if err != nil {
		fmt.Printf("  Failed to list status pages: %v\n", err)
		st.failed = append(st.failed, "status page list")
		return
	}
	have := map[string]bool{}
	for _, p := range existing {
		have[p.Slug] = true
	}

	for _, p := range pages {
		label := "status page " + p.Slug
		if !have[p.Slug] {
			fmt.Printf("  Creating %s (%s)\n", label, p.Title)
			if err := client.AddStatusPage(ctx, p.Title, p.Slug); err != nil {
				fmt.Printf("  Failed to create %s: %v\n", label, err)
				st.failed = append(st.failed, label)
				continue
			}
			st.created = append(st.created, label)
		}

		sp := &statuspage.StatusPage{
			Slug: p.Slug, Title: p.Title, Theme: "auto", Published: true,
			ShowPoweredBy: false, DomainNameList: []string{},
		}
		for i, g := range p.Groups {
			pg := statuspage.PublicGroup{Name: g.Name, Weight: i + 1}
			for _, name := range g.Monitors {
				if id, ok := ids[name]; ok {
					pg.MonitorList = append(pg.MonitorList, statuspage.PublicMonitor{ID: id})
				}
			}
			if len(pg.MonitorList) > 0 {
				sp.PublicGroupList = append(sp.PublicGroupList, pg)
			}
		}
		if _, err := client.SaveStatusPage(ctx, sp); err != nil {
			fmt.Printf("  Failed to save %s: %v\n", label, err)
			st.failed = append(st.failed, label)
		}
	}
}
