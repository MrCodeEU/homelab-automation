// Command ziti-console-proxy is the read-only front of Ziti's web console
// (ZAC) on mljr: https://ziti.mljr.eu, behind Authelia (two factors, group
// admins) at mljr's Caddy, which forwards to this on 127.0.0.1:8446. ZAC is
// served by the controller's admin listener (127.0.0.1:8440, /zac/) and
// talks to the management and fabric APIs on the same origin, so
// everything is proxied there (services/ziti-console).
//
//   - Reads (GET, HEAD, OPTIONS) pass through with the browser's session.
//   - Every write is refused (403), except logout.
//   - Login: the proxy logs in to the controller itself as the read-only
//     identity (ZAC_USER, permission admin_readonly) with ZAC_PASSWORD,
//     whatever the form held, and only for a request Authelia let through
//     (Remote-User set by Caddy's forward_auth). So clicking LOG IN with
//     empty fields is enough after the Authelia login.
//   - GET /edge/management/v1/summary (the dashboard's counters) is
//     admin-only in the controller; admin_readonly gets 401 there and ZAC
//     shows "Session Expired". The proxy answers it from the list
//     endpoints' totals, with the browser's own session.
//
// Environment:
//
//	ZAC_PASSWORD     password of ZAC_USER (required)
//	ZAC_USER         default zac-readonly
//	ZAC_UPSTREAM     admin listener (default https://127.0.0.1:8440)
//	ZAC_SERVER_NAME  name in its certificate (default localhost)
//	ZAC_CA           overlay root CA (default /ca/root.cert)
//	ZAC_LISTEN       default 127.0.0.1:8446
//
// `ziti-console-proxy healthcheck` asks the running proxy's /healthz.
package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"sync"
	"time"
)

const mgmt = "/edge/management/v1"

// summaryLists maps the summary's keys to the list endpoints counted for
// them. Keys without a list endpoint (revocations, mfas, ...) are left out.
var summaryLists = map[string]string{
	"apiSessions":               mgmt + "/api-sessions",
	"authPolicies":              mgmt + "/auth-policies",
	"authenticators":            mgmt + "/authenticators",
	"cas":                       mgmt + "/cas",
	"configTypes":               mgmt + "/config-types",
	"configs":                   mgmt + "/configs",
	"controllers":               mgmt + "/controllers",
	"edgeRouterPolicies":        mgmt + "/edge-router-policies",
	"enrollments":               mgmt + "/enrollments",
	"externalJwtSigners":        mgmt + "/external-jwt-signers",
	"identities":                mgmt + "/identities",
	"identityTypes":             mgmt + "/identity-types",
	"postureCheckTypes":         mgmt + "/posture-check-types",
	"postureChecks":             mgmt + "/posture-checks",
	"routers":                   "/fabric/v1/routers",
	"routers.edge":              mgmt + "/edge-routers",
	"serviceEdgeRouterPolicies": mgmt + "/service-edge-router-policies",
	"servicePolicies":           mgmt + "/service-policies",
	"services":                  mgmt + "/services",
	"services.edge":             mgmt + "/services",
	"sessions":                  mgmt + "/sessions",
	"terminators":               mgmt + "/terminators",
}

type proxy struct {
	upstream *url.URL
	client   *http.Client // to the upstream, for login and summary
	rp       *httputil.ReverseProxy
	user     string
	password string
}

func newProxy(upstream *url.URL, transport http.RoundTripper, user, password string) *proxy {
	rp := httputil.NewSingleHostReverseProxy(upstream)
	rp.Transport = transport
	return &proxy{
		upstream: upstream,
		client:   &http.Client{Transport: transport, Timeout: 20 * time.Second},
		rp:       rp,
		user:     user,
		password: password,
	}
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/healthz":
		_, _ = w.Write([]byte("ok\n"))
	case path == "/":
		http.Redirect(w, r, "/zac/", http.StatusFound)
	case path == mgmt+"/authenticate" && r.Method == http.MethodPost:
		p.login(w, r)
	case path == mgmt+"/current-api-session" && r.Method == http.MethodDelete:
		p.rp.ServeHTTP(w, r) // logout
	case path == mgmt+"/summary" && r.Method == http.MethodGet:
		p.summary(w, r)
	case r.Method == http.MethodGet || r.Method == http.MethodHead || r.Method == http.MethodOptions:
		p.rp.ServeHTTP(w, r)
	default:
		http.Error(w, "Read-only console: changes go through the repo (ziti/tofu).", http.StatusForbidden)
	}
}

// login answers ZAC's login (any method: password, cert, ext-jwt) with a
// login of the read-only identity, for Authelia-authenticated requests only.
func (p *proxy) login(w http.ResponseWriter, r *http.Request) {
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 1<<16))
	who := r.Header.Get("Remote-User")
	if who == "" {
		http.Error(w, "Sign in through Authelia (https://ziti.mljr.eu).", http.StatusForbidden)
		return
	}
	body, _ := json.Marshal(map[string]string{"username": p.user, "password": p.password})
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost,
		p.upstream.JoinPath(mgmt, "authenticate").String()+"?method=password", bytes.NewReader(body))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		slog.Error("login", "authelia_user", who, "err", err)
		http.Error(w, "controller unreachable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	slog.Info("login", "authelia_user", who, "as", p.user, "status", resp.StatusCode)
	w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

var errSession = errors.New("session not valid")

// count reads one list endpoint's total with the browser's session.
func (p *proxy) count(r *http.Request, path string) (int, error) {
	u := p.upstream.JoinPath(path)
	u.RawQuery = "limit=1"
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, u.String(), nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("zt-session", r.Header.Get("zt-session"))
	if a := r.Header.Get("Authorization"); a != "" {
		req.Header.Set("Authorization", a)
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		return 0, errSession
	}
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("%s: %s", path, resp.Status)
	}
	var page struct {
		Meta struct {
			Pagination struct {
				TotalCount int `json:"totalCount"`
			} `json:"pagination"`
		} `json:"meta"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		return 0, fmt.Errorf("%s: %w", path, err)
	}
	return page.Meta.Pagination.TotalCount, nil
}

func (p *proxy) summary(w http.ResponseWriter, r *http.Request) {
	var (
		mu      sync.Mutex
		wg      sync.WaitGroup
		data    = map[string]int{}
		expired bool
	)
	for key, path := range summaryLists {
		wg.Add(1)
		go func() {
			defer wg.Done()
			n, err := p.count(r, path)
			mu.Lock()
			defer mu.Unlock()
			switch {
			case errors.Is(err, errSession):
				expired = true
			case err != nil:
				slog.Warn("summary", "key", key, "err", err)
			default:
				data[key] = n
			}
		}()
	}
	wg.Wait()
	w.Header().Set("Content-Type", "application/json")
	if expired {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"code":"UNAUTHORIZED","message":"The request could not be completed. The session is not authorized or the credentials are invalid"},"meta":{}}`))
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"data": data, "meta": map[string]any{}})
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func fatal(msg string, err error) {
	slog.Error(msg, "err", err)
	os.Exit(1)
}

func main() {
	listen := env("ZAC_LISTEN", "127.0.0.1:8446")
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		c := &http.Client{Timeout: 3 * time.Second}
		resp, err := c.Get("http://" + listen + "/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	password := os.Getenv("ZAC_PASSWORD")
	if password == "" {
		fatal("config", errors.New("ZAC_PASSWORD is empty"))
	}
	upstream, err := url.Parse(env("ZAC_UPSTREAM", "https://127.0.0.1:8440"))
	if err != nil {
		fatal("ZAC_UPSTREAM", err)
	}
	pem, err := os.ReadFile(env("ZAC_CA", "/ca/root.cert"))
	if err != nil {
		fatal("ZAC_CA", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		fatal("ZAC_CA", errors.New("no certificate in file"))
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{
		RootCAs:    pool,
		ServerName: env("ZAC_SERVER_NAME", "localhost"),
		MinVersion: tls.VersionTLS12,
	}
	p := newProxy(upstream, transport, env("ZAC_USER", "zac-readonly"), password)
	slog.Info("listening", "addr", listen, "upstream", upstream.String())
	srv := &http.Server{Addr: listen, Handler: p, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fatal("listen", err)
	}
}
