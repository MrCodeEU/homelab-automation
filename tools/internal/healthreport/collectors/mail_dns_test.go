package collectors

import (
	"context"
	"net"
	"strings"
	"testing"
)

type fakeDNS struct {
	mx   []*net.MX
	txt  map[string][]string
	host map[string][]string
	ptr  map[string][]string
}

func nf(name string) error { return &net.DNSError{Err: "no such host", Name: name, IsNotFound: true} }

func (f fakeDNS) LookupMX(_ context.Context, n string) ([]*net.MX, error) {
	if f.mx == nil {
		return nil, nf(n)
	}
	return f.mx, nil
}
func (f fakeDNS) LookupTXT(_ context.Context, n string) ([]string, error) {
	if v, ok := f.txt[n]; ok {
		return v, nil
	}
	return nil, nf(n)
}
func (f fakeDNS) LookupHost(_ context.Context, n string) ([]string, error) {
	if v, ok := f.host[n]; ok {
		return v, nil
	}
	return nil, nf(n)
}
func (f fakeDNS) LookupAddr(_ context.Context, a string) ([]string, error) {
	if v, ok := f.ptr[a]; ok {
		return v, nil
	}
	return nil, nf(a)
}

func goodDNS() fakeDNS {
	return fakeDNS{
		mx: []*net.MX{{Host: "mail.mljr.eu.", Pref: 5}},
		txt: map[string][]string{
			"mljr.eu":                 {"v=spf1 mx a -all"},
			"_dmarc.mljr.eu":          {"v=DMARC1; p=quarantine"},
			"dkim._domainkey.mljr.eu": {"v=DKIM1;k=rsa;t=s;s=email;p=MIIBIjANBgkq"},
		},
		host: map[string][]string{"mail.mljr.eu": {"203.0.113.9"}},
		ptr:  map[string][]string{"203.0.113.9": {"mail.mljr.eu."}},
	}
}

func problems(f fakeDNS) string {
	var rec []string
	for _, p := range mailDNSProblems(context.Background(), f, "mljr.eu", "mail.mljr.eu", "dkim") {
		rec = append(rec, p.record)
	}
	return strings.Join(rec, ",")
}

func TestMailDNSHealthy(t *testing.T) {
	if got := problems(goodDNS()); got != "" {
		t.Fatalf("healthy DNS reported problems: %s", got)
	}
}

func TestMailDNSDetectsEachBrokenRecord(t *testing.T) {
	f := goodDNS()
	f.mx = []*net.MX{{Host: "other.example.", Pref: 5}}
	delete(f.txt, "mljr.eu")
	delete(f.txt, "dkim._domainkey.mljr.eu")
	delete(f.txt, "_dmarc.mljr.eu")
	f.ptr["203.0.113.9"] = []string{"vmi1.contaboserver.net."}
	if got := problems(f); got != "MX,SPF,DMARC,DKIM,PTR" {
		t.Fatalf("got %q, want all five records flagged", got)
	}
}

func TestMailDNSEmptyDKIMKey(t *testing.T) {
	f := goodDNS()
	f.txt["dkim._domainkey.mljr.eu"] = []string{"v=DKIM1;k=rsa;p="}
	if got := problems(f); got != "DKIM" {
		t.Fatalf("got %q, want DKIM", got)
	}
}

func TestMailDNSResolverErrorIsNotAMissingRecord(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a SERVFAIL must panic (collector_failed), not report records missing")
		}
	}()
	collectMailDNS(brokenDNS{goodDNS()}, "mljr.eu", "mail.mljr.eu", "dkim")
}

type brokenDNS struct{ fakeDNS }

func (brokenDNS) LookupMX(context.Context, string) ([]*net.MX, error) {
	return nil, &net.DNSError{Err: "server misbehaving", IsTemporary: true}
}
