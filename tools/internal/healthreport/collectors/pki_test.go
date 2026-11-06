package collectors

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"testing"
	"time"
)

func testCert(t *testing.T, cn string, ca bool, notAfter time.Time, parent *x509.Certificate, parentKey *ecdsa.PrivateKey) (*x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: cn},
		NotBefore: notAfter.AddDate(-1, 0, 0), NotAfter: notAfter,
		IsCA: ca, BasicConstraintsValid: true,
	}
	if parent == nil {
		parent, parentKey = tmpl, key
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, &key.PublicKey, parentKey)
	if err != nil {
		t.Fatal(err)
	}
	c, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return c, key
}

func TestCollectPKI(t *testing.T) {
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	root, rootKey := testCert(t, "root", true, now.AddDate(10, 0, 0), nil, nil)
	inter, interKey := testCert(t, "inter", true, now.AddDate(0, 0, 80), root, rootKey)
	ctrl, _ := testCert(t, "ctrl", false, now.AddDate(0, 0, 365), inter, interKey)
	router, _ := testCert(t, "router", false, now.AddDate(0, 0, 20), inter, interKey)

	targets := []pkiTarget{{Addr: "c:1", Leaf: "controller-mljr"}, {Addr: "r:2", Leaf: "router-mljr"}, {Addr: "n:3", Leaf: "router-nuc"}}
	fetch := func(tg pkiTarget) ([]*x509.Certificate, error) {
		switch tg.Leaf {
		case "controller-mljr":
			return []*x509.Certificate{ctrl, inter, root}, nil
		case "router-mljr":
			return []*x509.Certificate{router, inter}, nil
		}
		return nil, errors.New("connection refused")
	}

	res := collectPKI(targets, fetch, now)
	got := map[string]any{}
	for _, o := range res.Observations {
		got[o.ID] = o.Value
	}
	want := map[string]any{
		"pki_ca_expiry.root.":              3653, // three leap days
		"pki_ca_expiry.intermediate.":      80,
		"pki_leaf_expiry.controller-mljr.": 365,
		"pki_leaf_expiry.router-mljr.":     20,
		"pki_fetch_failed.router-nuc.":     true,
	}
	if len(got) != len(want) {
		t.Fatalf("observations = %v, want %v", got, want)
	}
	for id, v := range want {
		if got[id] != v {
			t.Errorf("%s = %v, want %v", id, got[id], v)
		}
	}
}

func TestCollectPKINothingReachablePanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic when no endpoint is reachable")
		}
	}()
	collectPKI([]pkiTarget{{Addr: "x:1", Leaf: "a"}}, func(pkiTarget) ([]*x509.Certificate, error) {
		return nil, errors.New("down")
	}, time.Now())
}
