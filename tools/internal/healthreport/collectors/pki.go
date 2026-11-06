// Days left on the OpenZiti overlay's certificates (docs/ZERO_TRUST_PLAN.md
// C12, docs/ZITI_PKI.md). Every certificate that matters is presented in a
// TLS handshake on the overlay's own ports, so this needs no SSH and no new
// listener: the controller's port sends its leaf, the intermediate and the
// root; each router's edge port sends its leaf and the intermediate.
//
// CA certificates (root, intermediate) and leaf certificates are separate
// kinds: leaves live one year and are renewed on every container start, so a
// one-year notice level would list them every day. Only an expiry that gets
// close (a router not restarted for months) is worth a warning for them.
package collectors

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"math"
	"net"
	"sort"
	"strings"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

// pkiTarget is one TLS endpoint and the name its leaf certificate reports
// under. The agent runs on nuc, so nuc's router is reached on the LAN.
type pkiTarget struct {
	Addr       string
	ServerName string
	Leaf       string
}

var pkiTargets = []pkiTarget{
	{Addr: "ctrl.ziti.mljr.eu:8441", ServerName: "ctrl.ziti.mljr.eu", Leaf: "controller-mljr"},
	{Addr: "router.ziti.mljr.eu:8442", ServerName: "router.ziti.mljr.eu", Leaf: "router-mljr"},
	{Addr: "192.168.50.30:8442", ServerName: "192.168.50.30", Leaf: "router-nuc"},
}

func init() {
	hr.RegisterCollector("pki", func(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
		return collectPKI(pkiTargets, fetchPeerCertificates, time.Now())
	})
}

type certFetcher func(t pkiTarget) ([]*x509.Certificate, error)

func collectPKI(targets []pkiTarget, fetch certFetcher, now time.Time) *hr.CollectorResult {
	result := hr.NewCollectorResult("pki")
	seenCA := map[[32]byte]bool{}
	var failed []string

	for _, t := range targets {
		certs, err := fetch(t)
		if err != nil || len(certs) == 0 {
			if err == nil {
				err = fmt.Errorf("no certificate presented")
			}
			failed = append(failed, t.Leaf)
			obs := hr.NewObservation("pki_fetch_failed."+t.Leaf+".", "pki", t.Leaf, "pki_fetch_failed",
				fmt.Sprintf("could not read the certificates of %s (%s): %v", t.Leaf, t.Addr, err))
			obs.Value = true
			obs.Evidence["addr"] = t.Addr
			result.Observations = append(result.Observations, obs)
			continue
		}

		leaf := certs[0]
		result.Observations = append(result.Observations, pkiObservation("pki_leaf_expiry", t.Leaf, leaf, t.Addr, now))

		for _, c := range certs[1:] {
			if !c.IsCA {
				continue
			}
			fp := sha256.Sum256(c.Raw)
			if seenCA[fp] {
				continue
			}
			seenCA[fp] = true
			result.Observations = append(result.Observations, pkiObservation("pki_ca_expiry", caName(c), c, t.Addr, now))
		}
	}

	if len(failed) == len(targets) {
		// Nothing reachable is not evidence that a certificate expired:
		// let the runner record collector_failed instead.
		panic(fmt.Sprintf("no Ziti endpoint reachable: %s", strings.Join(failed, ", ")))
	}

	sort.Slice(result.Observations, func(i, j int) bool { return result.Observations[i].ID < result.Observations[j].ID })
	return result
}

func pkiObservation(kind, subject string, c *x509.Certificate, addr string, now time.Time) *hr.Observation {
	days := int(math.Floor(c.NotAfter.Sub(now).Hours() / 24))
	what := "certificate"
	if kind == "pki_ca_expiry" {
		what = "CA certificate"
	}
	obs := hr.NewObservation(kind+"."+subject+".", "pki", subject, kind,
		fmt.Sprintf("Ziti %s %s expires in %d days (%s)", subject, what, days, c.NotAfter.UTC().Format("2006-01-02")))
	obs.Value = days
	obs.Unit = "days"
	fp := sha256.Sum256(c.Raw)
	obs.Evidence["subject"] = c.Subject.String()
	obs.Evidence["not_after"] = c.NotAfter.UTC().Format(time.RFC3339)
	obs.Evidence["sha256"] = hex.EncodeToString(fp[:])
	obs.Evidence["seen_on"] = addr
	return obs
}

// caName names a CA certificate by its role: the self-signed one is the
// offline root, any other CA is the controller's intermediate.
func caName(c *x509.Certificate) string {
	if bytes.Equal(c.RawSubject, c.RawIssuer) {
		return "root"
	}
	return "intermediate"
}

// fetchPeerCertificates returns the chain the server presents. Verification
// is skipped on purpose: an expired or untrusted certificate is exactly what
// this collector has to be able to read. A router may abort the handshake
// for want of a client certificate; the chain has arrived by then.
func fetchPeerCertificates(t pkiTarget) ([]*x509.Certificate, error) {
	var chain []*x509.Certificate
	conf := &tls.Config{
		ServerName:         t.ServerName,
		InsecureSkipVerify: true, //nolint:gosec // reading expiry, not trusting the peer
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			for _, r := range raw {
				c, err := x509.ParseCertificate(r)
				if err != nil {
					return err
				}
				chain = append(chain, c)
			}
			return nil
		},
	}
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 10 * time.Second}, "tcp", t.Addr, conf)
	if conn != nil {
		conn.Close()
	}
	if len(chain) > 0 {
		return chain, nil
	}
	return nil, err
}
