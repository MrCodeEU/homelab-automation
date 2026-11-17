// Compares the public IP this host egresses from against the IPv4 address
// in CrowdSec's "home" allowlist on mljr, as home-ip sync reports it
// (roles::home_ip, homelab_home_ip_* metrics). The agent runs on nuc with
// host networking, so its egress IP is the home connection's. A mismatch
// means the sync did not catch a new address, and CrowdSec can ban the
// owner; a stale sync means it stopped running.
package collectors

import (
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// The sync runs every 5 minutes.
const homeIPSyncStale = 30 * time.Minute

// Tried in order. Plain-text IP echo services, so no parsing beyond trim.
// Only to check the sync: the allowlist itself comes from the FRITZ!Box.
var homeIPLookupURLs = []string{
	"https://api.ipify.org",
	"https://ifconfig.me/ip",
}

func init() {
	hr.RegisterCollector("home_ip", collectHomeIP)
}

func collectHomeIP(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("home_ip")
	if cfg.VictoriaURL == "" {
		return result
	}
	last, err := vmQuery(cfg, "max(homelab_home_ip_last_sync_timestamp_seconds)")
	if err != nil {
		panic(err)
	}
	listed, err := vmQuery(cfg, `homelab_home_ip_allowlisted_info{family="ipv4"}`)
	if err != nil {
		panic(err)
	}
	var lastSync time.Time
	if len(last) > 0 && last[0].value > 0 {
		lastSync = time.Unix(int64(last[0].value), 0)
	}
	allowlisted := ""
	if len(listed) > 0 {
		allowlisted = listed[0].metric["value"]
	}

	current, err := lookupPublicIP(homeIPLookupURLs, 10*time.Second)
	if err != nil {
		// A failed lookup is not evidence the IP changed. Panic so the
		// runner records collector_failed ("unknown") instead of a false
		// crit.
		panic(err)
	}
	result.Observations = evaluateHomeIP(time.Now(), current, allowlisted, lastSync)
	return result
}

func evaluateHomeIP(now time.Time, current, allowlisted string, lastSync time.Time) []*hr.Observation {
	var out []*hr.Observation
	if lastSync.IsZero() || now.Sub(lastSync) > homeIPSyncStale {
		msg := "home-ip sync on mljr has never reported"
		if !lastSync.IsZero() {
			msg = fmt.Sprintf("home-ip sync on mljr last succeeded %s ago", now.Sub(lastSync).Round(time.Minute))
		}
		out = append(out, &hr.Observation{
			ID: "home_ip_sync_stale..", Collector: "home_ip", Subject: "home", Kind: "home_ip_sync_stale",
			Message: msg + " (journalctl -u home-ip-sync on mljr, home-ip on nuc)", Severity: "info",
		})
	}
	if allowlisted != "" && current != allowlisted {
		out = append(out, &hr.Observation{
			ID: "home_ip_mismatch..", Collector: "home_ip", Subject: "home", Kind: "home_ip_mismatch",
			Value: current,
			Message: fmt.Sprintf("home public IP is %s, but CrowdSec allowlists %s - check home-ip sync on mljr",
				current, allowlisted),
			Evidence: map[string]any{"current": current, "allowlisted": allowlisted}, Severity: "info",
		})
	}
	return out
}

func lookupPublicIP(urls []string, timeout time.Duration) (string, error) {
	var errs []string
	for _, u := range urls {
		resp, err := httpGet(u, timeout, nil)
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 128))
		resp.Body.Close()
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		ip := strings.TrimSpace(string(body))
		if net.ParseIP(ip) == nil {
			errs = append(errs, fmt.Sprintf("%s: not an IP: %q", u, ip))
			continue
		}
		return ip, nil
	}
	return "", fmt.Errorf("public IP lookup failed: %s", strings.Join(errs, "; "))
}
