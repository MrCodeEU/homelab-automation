// Compares the public IP this host egresses from against the home IP that
// CrowdSec's mljr-local-allowlist.yaml trusts. The agent runs on nuc with
// host networking, so its egress IP is the home connection's. If the ISP
// hands out a new address, the allowlist silently stops covering the owner
// and CrowdSec can ban them - this surfaces the drift instead.
package collectors

import (
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// Tried in order. Plain-text IP echo services, so no parsing beyond trim.
var homeIPLookupURLs = []string{
	"https://api.ipify.org",
	"https://ifconfig.me/ip",
}

func init() {
	hr.RegisterCollector("home_ip", collectHomeIP)
}

func collectHomeIP(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("home_ip")
	if cfg.HomeIP == "" {
		// Optional, same skip pattern as Kuma/SMTP/DMARC: no expected IP
		// configured means nothing to compare against.
		return result
	}

	current, err := lookupPublicIP(homeIPLookupURLs, 10*time.Second)
	if err != nil {
		// A failed lookup is not evidence the IP changed. Panic so the
		// runner records collector_failed ("unknown") instead of a false
		// crit.
		panic(err)
	}

	if current != cfg.HomeIP {
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "home_ip_mismatch..", Collector: "home_ip", Subject: "home", Kind: "home_ip_mismatch",
			Value: current,
			Message: fmt.Sprintf("home public IP is %s, but CrowdSec allowlists %s - update "+
				"mljr-local-allowlist.yaml and home_public_ip in common.yaml", current, cfg.HomeIP),
			Evidence: map[string]any{"current": current, "expected": cfg.HomeIP}, Severity: "info",
		})
	}
	return result
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
