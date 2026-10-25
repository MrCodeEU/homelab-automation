// Checks the DNS records mail delivery depends on: MX, SPF, DKIM, DMARC and
// the reverse DNS of the mail host. Mailcow keeps the DKIM private key in
// redis, so a rebuilt or restored mail host can silently sign with a key the
// published TXT record no longer matches; this catches the cheap half of that
// (record missing or malformed) and the PTR/MX drift that gets mail rejected.
package collectors

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

const (
	mailDomain       = "mljr.eu"
	mailHost         = "mail.mljr.eu"
	mailDKIMSelector = "dkim"
)

// resolver is the part of net.Resolver the checks use, so tests can fake DNS.
type resolver interface {
	LookupMX(ctx context.Context, name string) ([]*net.MX, error)
	LookupTXT(ctx context.Context, name string) ([]string, error)
	LookupHost(ctx context.Context, host string) ([]string, error)
	LookupAddr(ctx context.Context, addr string) ([]string, error)
}

func init() {
	hr.RegisterCollector("mail_dns", func(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
		return collectMailDNS(net.DefaultResolver, mailDomain, mailHost, mailDKIMSelector)
	})
}

func collectMailDNS(r resolver, domain, host, selector string) *hr.CollectorResult {
	result := hr.NewCollectorResult("mail_dns")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	for _, problem := range mailDNSProblems(ctx, r, domain, host, selector) {
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "mail_dns_problem." + problem.record + ".", Collector: "mail_dns", Subject: problem.record, Kind: "mail_dns_problem",
			Value: problem.record, Message: problem.msg,
			Evidence: map[string]any{"record": problem.record}, Severity: "info",
		})
	}
	return result
}

type dnsProblem struct{ record, msg string }

func trimDot(s string) string { return strings.ToLower(strings.TrimSuffix(s, ".")) }

func mailDNSProblems(ctx context.Context, r resolver, domain, host, selector string) []dnsProblem {
	var out []dnsProblem
	add := func(record, format string, a ...any) {
		out = append(out, dnsProblem{record: record, msg: fmt.Sprintf(format, a...)})
	}

	// A lookup that errors is a resolver problem, not proof the record is
	// gone; NXDOMAIN-style "not found" is the only error reported as missing.
	notFound := func(err error) bool {
		var dnsErr *net.DNSError
		return err != nil && asDNSError(err, &dnsErr) && dnsErr.IsNotFound
	}

	mx, err := r.LookupMX(ctx, domain)
	switch {
	case err != nil && !notFound(err):
		panic(fmt.Errorf("MX lookup: %w", err))
	case len(mx) == 0:
		add("MX", "%s has no MX record", domain)
	default:
		found := false
		for _, m := range mx {
			if trimDot(m.Host) == host {
				found = true
			}
		}
		if !found {
			add("MX", "%s MX does not point at %s", domain, host)
		}
	}

	txt := func(name string) ([]string, bool) {
		v, err := r.LookupTXT(ctx, name)
		if err != nil && !notFound(err) {
			panic(fmt.Errorf("TXT lookup %s: %w", name, err))
		}
		return v, err == nil
	}
	has := func(records []string, prefix string) (string, bool) {
		for _, rec := range records {
			if strings.HasPrefix(strings.ToLower(strings.TrimSpace(rec)), prefix) {
				return rec, true
			}
		}
		return "", false
	}

	spf, _ := txt(domain)
	if _, ok := has(spf, "v=spf1"); !ok {
		add("SPF", "%s has no SPF record", domain)
	}
	if _, ok := has(mustTXT(txt, "_dmarc."+domain), "v=dmarc1"); !ok {
		add("DMARC", "_dmarc.%s has no DMARC record", domain)
	}
	dkimName := selector + "._domainkey." + domain
	if rec, ok := has(mustTXT(txt, dkimName), "v=dkim1"); !ok {
		add("DKIM", "%s has no DKIM record - outgoing mail will fail DKIM", dkimName)
	} else if !strings.Contains(strings.ReplaceAll(rec, " ", ""), "p=MI") {
		add("DKIM", "%s has an empty or malformed public key", dkimName)
	}

	// Reverse DNS of the mail host must name the host, or large receivers
	// reject or junk the mail.
	addrs, err := r.LookupHost(ctx, host)
	if err != nil || len(addrs) == 0 {
		if err != nil && !notFound(err) {
			panic(fmt.Errorf("A lookup %s: %w", host, err))
		}
		add("PTR", "%s does not resolve", host)
		return out
	}
	names, err := r.LookupAddr(ctx, addrs[0])
	ok := false
	for _, n := range names {
		if trimDot(n) == host {
			ok = true
		}
	}
	if err != nil && !notFound(err) {
		panic(fmt.Errorf("PTR lookup %s: %w", addrs[0], err))
	}
	if !ok {
		add("PTR", "reverse DNS of %s is %v, expected %s", addrs[0], names, host)
	}
	return out
}

func mustTXT(txt func(string) ([]string, bool), name string) []string {
	v, _ := txt(name)
	return v
}

func asDNSError(err error, target **net.DNSError) bool { return errors.As(err, target) }
