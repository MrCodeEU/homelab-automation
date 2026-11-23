// Package zitirenew renews the certificate of a Ziti identity file before it
// expires. The SDK identities (caddy-mljr, the m2m proxies, ...) get a
// one-year certificate at enrolment and the SDK never renews it; the routers
// renew their own.
//
// Renewal uses the client API's certificate extension, with a new key:
//
//	POST /authenticate?method=cert                        log in with the old cert
//	POST /current-identity/authenticators/{id}/extend         CSR -> new cert
//	POST /current-identity/authenticators/{id}/extend-verify  commit the new cert
//
// The old certificate keeps working until extend-verify, so the new file is
// written next to the old one first and moved over it only after the
// controller committed the new cert. The service using the file must then
// reload it (Config.Restart).
package zitirenew

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"syscall"
	"time"
)

// Identity is a Ziti identity file: {"ztAPI": ..., "id": {"key", "cert",
// "ca"}}, each id value inline as "pem:<PEM>". Other fields are kept as they
// are when the file is rewritten.
type Identity struct {
	raw   map[string]json.RawMessage
	rawID map[string]json.RawMessage

	API  string
	Key  crypto.Signer
	Cert *x509.Certificate // the leaf
	CA   []byte            // PEM bundle the controller is verified against
	// certPEM is the whole "cert" value (leaf, maybe with intermediates).
	certPEM []byte
}

// Load reads an identity file.
func Load(path string) (*Identity, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	id := &Identity{}
	if err := json.Unmarshal(data, &id.raw); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := json.Unmarshal(id.raw["ztAPI"], &id.API); err != nil || id.API == "" {
		return nil, fmt.Errorf("%s: no ztAPI", path)
	}
	if err := json.Unmarshal(id.raw["id"], &id.rawID); err != nil {
		return nil, fmt.Errorf("%s: no id: %v", path, err)
	}
	field := func(k string) ([]byte, error) {
		var v string
		if err := json.Unmarshal(id.rawID[k], &v); err != nil {
			return nil, fmt.Errorf("%s: id.%s: %v", path, k, err)
		}
		p, ok := strings.CutPrefix(v, "pem:")
		if !ok {
			return nil, fmt.Errorf("%s: id.%s is not inline pem: (file references are not supported)", path, k)
		}
		return []byte(p), nil
	}
	keyPEM, err := field("key")
	if err != nil {
		return nil, err
	}
	if id.certPEM, err = field("cert"); err != nil {
		return nil, err
	}
	if id.CA, err = field("ca"); err != nil {
		return nil, err
	}
	if id.Key, err = parseKey(keyPEM); err != nil {
		return nil, fmt.Errorf("%s: id.key: %w", path, err)
	}
	if id.Cert, err = LeafCert(id.certPEM); err != nil {
		return nil, fmt.Errorf("%s: id.cert: %w", path, err)
	}
	return id, nil
}

// LeafCert is the first certificate of a PEM bundle.
func LeafCert(data []byte) (*x509.Certificate, error) {
	b, _ := pem.Decode(data)
	if b == nil || b.Type != "CERTIFICATE" {
		return nil, errors.New("no PEM certificate")
	}
	return x509.ParseCertificate(b.Bytes)
}

func parseKey(data []byte) (crypto.Signer, error) {
	b, _ := pem.Decode(data)
	if b == nil {
		return nil, errors.New("no PEM key")
	}
	switch b.Type {
	case "RSA PRIVATE KEY":
		return x509.ParsePKCS1PrivateKey(b.Bytes)
	case "EC PRIVATE KEY":
		return x509.ParseECPrivateKey(b.Bytes)
	case "PRIVATE KEY":
		k, err := x509.ParsePKCS8PrivateKey(b.Bytes)
		if err != nil {
			return nil, err
		}
		s, ok := k.(crypto.Signer)
		if !ok {
			return nil, fmt.Errorf("unsupported key %T", k)
		}
		return s, nil
	}
	return nil, fmt.Errorf("unsupported PEM block %q", b.Type)
}

// newKey makes a key of the same kind and size as old, so the services see
// nothing new but the key itself.
func newKey(old crypto.Signer) (crypto.Signer, []byte, error) {
	switch k := old.(type) {
	case *rsa.PrivateKey:
		n, err := rsa.GenerateKey(rand.Reader, k.N.BitLen())
		if err != nil {
			return nil, nil, err
		}
		return n, pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(n)}), nil
	case *ecdsa.PrivateKey:
		n, err := ecdsa.GenerateKey(k.Curve, rand.Reader)
		if err != nil {
			return nil, nil, err
		}
		der, err := x509.MarshalECPrivateKey(n)
		if err != nil {
			return nil, nil, err
		}
		return n, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), nil
	}
	return nil, nil, fmt.Errorf("unsupported key %T", old)
}

// client is an HTTP client that logs in with the identity's certificate and
// trusts only its CA bundle.
func (id *Identity) client(key crypto.Signer, certPEM []byte) (*http.Client, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(id.CA) {
		return nil, errors.New("id.ca holds no certificate")
	}
	var chain tls.Certificate
	for rest := certPEM; ; {
		var b *pem.Block
		b, rest = pem.Decode(rest)
		if b == nil {
			break
		}
		chain.Certificate = append(chain.Certificate, b.Bytes)
	}
	if len(chain.Certificate) == 0 {
		return nil, errors.New("no client certificate")
	}
	chain.PrivateKey = key
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			RootCAs: pool, Certificates: []tls.Certificate{chain}, MinVersion: tls.VersionTLS12,
		}},
	}, nil
}

// HTTPClient is a client that authenticates with the identity's own key and
// certificate and verifies the server against id.ca. serverName overrides
// the name checked in the server's certificate (e.g. "localhost" when
// dialing the controller's admin listener on 127.0.0.1); empty keeps the
// dialed host.
func (id *Identity) HTTPClient(serverName string) (*http.Client, error) {
	c, err := id.client(id.Key, id.certPEM)
	if err != nil {
		return nil, err
	}
	c.Transport.(*http.Transport).TLSClientConfig.ServerName = serverName
	return c, nil
}

type session struct {
	c     *http.Client
	api   string
	token string
	authn string // the cert authenticator's id
}

func (s *session) call(ctx context.Context, path string, in, out any) error {
	body, _ := json.Marshal(in)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.api+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if s.token != "" {
		req.Header.Set("zt-session", s.token)
	}
	resp, err := s.c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("POST %s: %s: %s", path, resp.Status, strings.TrimSpace(string(data)))
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(data, out)
}

func login(ctx context.Context, c *http.Client, api string) (*session, error) {
	s := &session{c: c, api: strings.TrimRight(api, "/")}
	var r struct {
		Data struct {
			Token           string `json:"token"`
			AuthenticatorID string `json:"authenticatorId"`
		} `json:"data"`
	}
	if err := s.call(ctx, "/authenticate?method=cert", struct{}{}, &r); err != nil {
		return nil, err
	}
	if r.Data.Token == "" || r.Data.AuthenticatorID == "" {
		return nil, errors.New("authenticate: no token or authenticatorId")
	}
	s.token, s.authn = r.Data.Token, r.Data.AuthenticatorID
	return s, nil
}

// Renew replaces the identity file's key and certificate with new ones from
// the controller. The file keeps its owner and mode.
func Renew(ctx context.Context, path string) (*x509.Certificate, error) {
	id, err := Load(path)
	if err != nil {
		return nil, err
	}
	c, err := id.client(id.Key, id.certPEM)
	if err != nil {
		return nil, err
	}
	s, err := login(ctx, c, id.API)
	if err != nil {
		return nil, fmt.Errorf("login with the current certificate: %w", err)
	}
	key, keyPEM, err := newKey(id.Key)
	if err != nil {
		return nil, err
	}
	csr, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject: pkix.Name{CommonName: id.Cert.Subject.CommonName},
	}, key)
	if err != nil {
		return nil, err
	}
	csrPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csr}))
	var ext struct {
		Data struct {
			ClientCert string `json:"clientCert"`
		} `json:"data"`
	}
	ep := "/current-identity/authenticators/" + url.PathEscape(s.authn)
	if err := s.call(ctx, ep+"/extend", map[string]string{"clientCertCsr": csrPEM}, &ext); err != nil {
		return nil, err
	}
	leaf, err := LeafCert([]byte(ext.Data.ClientCert))
	if err != nil {
		return nil, fmt.Errorf("extend answer: %w", err)
	}

	// The new file goes next to the old one before the controller commits
	// the cert: after extend-verify only the new key logs in.
	next, err := id.encode(keyPEM, []byte(ext.Data.ClientCert))
	if err != nil {
		return nil, err
	}
	tmp := path + ".renew"
	if err := writeLike(tmp, path, next); err != nil {
		return nil, err
	}
	if err := s.call(ctx, ep+"/extend-verify", map[string]string{"clientCert": ext.Data.ClientCert}, nil); err != nil {
		os.Remove(tmp)
		return nil, err
	}
	if err := os.Rename(tmp, path); err != nil {
		return nil, fmt.Errorf("the controller committed the new certificate, but %s could not replace %s: %w", tmp, path, err)
	}
	// The new key must log in now; a failure here needs a person (the
	// script's --reenroll), so it is an error, not a retry.
	nc, err := id.client(key, []byte(ext.Data.ClientCert))
	if err == nil {
		_, err = login(ctx, nc, id.API)
	}
	if err != nil {
		return leaf, fmt.Errorf("login with the new certificate: %w", err)
	}
	return leaf, nil
}

func (id *Identity) encode(keyPEM, certPEM []byte) ([]byte, error) {
	ids := map[string]json.RawMessage{}
	for k, v := range id.rawID {
		ids[k] = v
	}
	k, _ := json.Marshal("pem:" + string(keyPEM))
	c, _ := json.Marshal("pem:" + string(certPEM))
	ids["key"], ids["cert"] = k, c
	top := map[string]json.RawMessage{}
	for k, v := range id.raw {
		top[k] = v
	}
	idJSON, err := json.Marshal(ids)
	if err != nil {
		return nil, err
	}
	top["id"] = idJSON
	return json.Marshal(top)
}

// writeLike writes data to path with like's owner and mode.
func writeLike(path, like string, data []byte) error {
	st, err := os.Stat(like)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		if err := os.Chown(path, int(sys.Uid), int(sys.Gid)); err != nil {
			return err
		}
	}
	return os.Chmod(path, st.Mode().Perm())
}
