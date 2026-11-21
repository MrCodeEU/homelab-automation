// Ziti certificates (roles::ziti_renew, ziti_identity_* metrics): every
// watched certificate's expiry, failed renewals, and a renewal check that
// stopped running. The SDK identities are renewed 60 days ahead, so one
// with under 30 days left means the renewal is not working; the routers and
// the controller renew their own, and the CAs need a person.
package collectors

import (
	"fmt"
	"sort"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

const (
	zitiCertWarn   = 30 * 24 * time.Hour
	zitiRenewStale = 50 * time.Hour // the timer runs daily
)

func init() {
	hr.RegisterCollector("ziti_certs", collectZitiCerts)
}

type zitiCert struct {
	host, name, file string
	notAfter         time.Time
}

func collectZitiCerts(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("ziti_certs")
	if cfg.VictoriaURL == "" {
		return result
	}
	exp, err := vmQuery(cfg, "ziti_identity_cert_expiry_timestamp_seconds")
	if err != nil {
		panic(err)
	}
	failed, err := vmQuery(cfg, "ziti_identity_renew_failed == 1")
	if err != nil {
		panic(err)
	}
	runs, err := vmQuery(cfg, "max by (host) (ziti_identity_renew_last_run_timestamp_seconds)")
	if err != nil {
		panic(err)
	}
	var certs, fails []zitiCert
	for _, s := range exp {
		certs = append(certs, zitiCert{s.metric["host"], s.metric["name"], s.metric["file"], time.Unix(int64(s.value), 0)})
	}
	for _, s := range failed {
		fails = append(fails, zitiCert{host: s.metric["host"], name: s.metric["name"], file: s.metric["file"]})
	}
	lastRun := map[string]time.Time{}
	for _, s := range runs {
		lastRun[s.metric["host"]] = time.Unix(int64(s.value), 0)
	}
	result.Observations = evaluateZitiCerts(time.Now(), certs, fails, lastRun)
	return result
}

func evaluateZitiCerts(now time.Time, certs, fails []zitiCert, lastRun map[string]time.Time) []*hr.Observation {
	var out []*hr.Observation
	for _, c := range certs {
		left := c.notAfter.Sub(now)
		if left >= zitiCertWarn {
			continue
		}
		out = append(out, &hr.Observation{
			ID: "ziti_cert_expiring." + c.host + "." + c.name, Collector: "ziti_certs", Subject: c.host + "/" + c.name,
			Kind: "ziti_cert_expiring", Value: int64(left.Hours() / 24), Unit: "days",
			Message: fmt.Sprintf("Ziti certificate %s on %s expires in %d days (%s); ziti-renew -renew %s, or the enrol script's --reenroll",
				c.name, c.host, int(left.Hours()/24), c.notAfter.UTC().Format("2006-01-02"), c.file),
			Severity: "info",
		})
	}
	for _, c := range fails {
		out = append(out, &hr.Observation{
			ID: "ziti_cert_renew_failed." + c.host + "." + c.name, Collector: "ziti_certs", Subject: c.host + "/" + c.name,
			Kind:     "ziti_cert_renew_failed",
			Message:  fmt.Sprintf("ziti-renew failed for %s on %s (journalctl -u ziti-renew on %s)", c.file, c.host, c.host),
			Severity: "info",
		})
	}
	hosts := make([]string, 0, len(lastRun))
	for h := range lastRun {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	for _, h := range hosts {
		if age := now.Sub(lastRun[h]); age > zitiRenewStale {
			out = append(out, &hr.Observation{
				ID: "ziti_cert_renew_stale." + h + ".", Collector: "ziti_certs", Subject: h,
				Kind:     "ziti_cert_renew_stale",
				Message:  fmt.Sprintf("ziti-renew on %s last ran %s ago (systemctl status ziti-renew.timer)", h, age.Round(time.Hour)),
				Severity: "info",
			})
		}
	}
	return out
}
