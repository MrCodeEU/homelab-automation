package zitirenew

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type ca struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pem  []byte
	n    int64
}

func newCA(t *testing.T) *ca {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test ca"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	return &ca{cert: c, key: key, pem: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), n: 1}
}

func (c *ca) sign(t *testing.T, pub any, cn string, days int, usage x509.ExtKeyUsage, dns ...string) []byte {
	c.n++
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(c.n), Subject: pkix.Name{CommonName: cn}, DNSNames: dns,
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Duration(days) * 24 * time.Hour),
		ExtKeyUsage: []x509.ExtKeyUsage{usage}, KeyUsage: x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.cert, pub, c.key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

// controller fakes the three client API calls. Only the committed cert logs
// in; a pending one only after extend-verify.
type controller struct {
	t          *testing.T
	ca         *ca
	mu         sync.Mutex
	committed  string // leaf fingerprint (raw DER) that may log in
	pending    []byte
	failVerify bool
}

func (c *controller) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	defer c.mu.Unlock()
	switch r.URL.Path {
	case "/edge/client/v1/authenticate":
		if r.URL.Query().Get("method") != "cert" || len(r.TLS.PeerCertificates) == 0 ||
			string(r.TLS.PeerCertificates[0].Raw) != c.committed {
			http.Error(w, `{"error":"INVALID_AUTH"}`, http.StatusUnauthorized)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"data": map[string]string{"token": "tok", "authenticatorId": "auth1"}})
	case "/edge/client/v1/current-identity/authenticators/auth1/extend":
		var in struct{ ClientCertCsr string }
		json.NewDecoder(r.Body).Decode(&in)
		b, _ := pem.Decode([]byte(in.ClientCertCsr))
		if r.Header.Get("zt-session") != "tok" || b == nil {
			http.Error(w, "bad", http.StatusBadRequest)
			return
		}
		csr, err := x509.ParseCertificateRequest(b.Bytes)
		if err != nil || csr.CheckSignature() != nil {
			http.Error(w, "bad csr", http.StatusBadRequest)
			return
		}
		c.pending = c.ca.sign(c.t, csr.PublicKey, csr.Subject.CommonName, 365, x509.ExtKeyUsageClientAuth)
		json.NewEncoder(w).Encode(map[string]any{"data": map[string]string{"clientCert": string(c.pending), "ca": string(c.ca.pem)}})
	case "/edge/client/v1/current-identity/authenticators/auth1/extend-verify":
		var in struct{ ClientCert string }
		json.NewDecoder(r.Body).Decode(&in)
		if c.failVerify || in.ClientCert != string(c.pending) {
			http.Error(w, "verify failed", http.StatusBadRequest)
			return
		}
		b, _ := pem.Decode(c.pending)
		c.committed = string(b.Bytes)
		w.WriteHeader(http.StatusOK)
	default:
		http.NotFound(w, r)
	}
}

// setup starts the fake controller and writes an identity file for it whose
// certificate has days left.
func setup(t *testing.T, days int) (string, *controller) {
	t.Helper()
	authority := newCA(t)
	ctrl := &controller{t: t, ca: authority}
	srv := httptest.NewUnstartedServer(ctrl)
	srvKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	srvCert, _ := tls.X509KeyPair(authority.sign(t, &srvKey.PublicKey, "ctrl", 30, x509.ExtKeyUsageServerAuth, "localhost"), mustEC(srvKey))
	pool := x509.NewCertPool()
	pool.AddCert(authority.cert)
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{srvCert}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: pool}
	srv.StartTLS()
	t.Cleanup(srv.Close)

	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	certPEM := authority.sign(t, &key.PublicKey, "abc123", days, x509.ExtKeyUsageClientAuth)
	b, _ := pem.Decode(certPEM)
	ctrl.committed = string(b.Bytes)
	api := strings.Replace(srv.URL, "127.0.0.1", "localhost", 1) + "/edge/client/v1"
	id := map[string]any{
		"ztAPI": api, "ztAPIs": nil, "configTypes": nil,
		"id": map[string]string{
			"key":  "pem:" + string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})),
			"cert": "pem:" + string(certPEM),
			"ca":   "pem:" + string(authority.pem),
		},
	}
	data, _ := json.Marshal(id)
	path := filepath.Join(t.TempDir(), "svc.json")
	if err := os.WriteFile(path, data, 0o640); err != nil {
		t.Fatal(err)
	}
	return path, ctrl
}

func mustEC(k *ecdsa.PrivateKey) []byte {
	der, _ := x509.MarshalECPrivateKey(k)
	return pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
}

func TestRenew(t *testing.T) {
	path, _ := setup(t, 20)
	before, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := Renew(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	after, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if !after.Cert.Equal(leaf) || after.Cert.NotAfter.Before(time.Now().Add(300*24*time.Hour)) {
		t.Fatalf("new cert not in the file or too short: %s", after.Cert.NotAfter)
	}
	if after.Cert.Subject.CommonName != "abc123" {
		t.Errorf("CN %q", after.Cert.Subject.CommonName)
	}
	if _, ok := after.Key.(*rsa.PrivateKey); !ok || after.Key.(*rsa.PrivateKey).N.BitLen() != 2048 {
		t.Errorf("key kind or size changed: %T", after.Key)
	}
	if after.Key.(*rsa.PrivateKey).Equal(before.Key) {
		t.Error("key not rolled")
	}
	if after.API != before.API || string(after.CA) != string(before.CA) {
		t.Error("ztAPI or ca changed")
	}
	raw, _ := os.ReadFile(path)
	var top map[string]json.RawMessage
	json.Unmarshal(raw, &top)
	if _, ok := top["configTypes"]; !ok {
		t.Error("unknown field dropped")
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o640 {
		t.Errorf("mode %v", st.Mode().Perm())
	}
	if _, err := os.Stat(path + ".renew"); !os.IsNotExist(err) {
		t.Error("temp file left")
	}
}

func TestRenewVerifyFailsKeepsOldFile(t *testing.T) {
	path, ctrl := setup(t, 20)
	ctrl.failVerify = true
	old, _ := os.ReadFile(path)
	if _, err := Renew(context.Background(), path); err == nil || !strings.Contains(err.Error(), "verify failed") {
		t.Fatalf("err = %v", err)
	}
	now, _ := os.ReadFile(path)
	if string(now) != string(old) {
		t.Error("file changed although nothing was committed")
	}
	if _, err := os.Stat(path + ".renew"); !os.IsNotExist(err) {
		t.Error("temp file left")
	}
}

func TestLoadRejectsFileRefs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.json")
	os.WriteFile(path, []byte(`{"ztAPI":"https://x","id":{"key":"file:///k","cert":"pem:x","ca":"pem:x"}}`), 0o600)
	if _, err := Load(path); err == nil || !strings.Contains(err.Error(), "inline pem") {
		t.Fatalf("err = %v", err)
	}
}
