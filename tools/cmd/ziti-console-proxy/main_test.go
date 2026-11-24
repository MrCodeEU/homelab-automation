package main

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// fakeController records writes and logins, lists 3 of everything for
// session "good" and refuses any other session.
type fakeController struct {
	writes []string
	login  map[string]string
}

func (f *fakeController) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/zac/") {
		serveZAC(w, r)
		return
	}
	if r.URL.Path == mgmt+"/authenticate" {
		_ = json.NewDecoder(r.Body).Decode(&f.login)
		if r.URL.Query().Get("method") != "password" || f.login["password"] != "secret" {
			http.Error(w, `{"error":{"code":"INVALID_AUTH"}}`, http.StatusUnauthorized)
			return
		}
		fmt.Fprint(w, `{"data":{"token":"good"}}`)
		return
	}
	if r.Method != http.MethodGet {
		f.writes = append(f.writes, r.Method+" "+r.URL.Path)
	}
	if r.Header.Get("zt-session") != "good" {
		http.Error(w, `{"error":{"code":"UNAUTHORIZED"}}`, http.StatusUnauthorized)
		return
	}
	if r.URL.Path == mgmt+"/summary" || r.URL.Path == mgmt+"/enrollments" {
		// admin only, also with a valid session
		http.Error(w, "admin only", http.StatusUnauthorized)
		return
	}
	fmt.Fprint(w, `{"data":[{}],"meta":{"pagination":{"totalCount":3}}}`)
}

func setup(t *testing.T) (*fakeController, *httptest.Server) {
	t.Helper()
	fake := &fakeController{}
	up := httptest.NewServer(fake)
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	px := httptest.NewServer(newProxy(u, http.DefaultTransport, "zac-readonly", "secret", "from-caddy"))
	t.Cleanup(px.Close)
	return fake, px
}

func do(t *testing.T, method, url string, headers map[string]string, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	if _, set := headers[secretHeader]; !set {
		req.Header.Set(secretHeader, "from-caddy")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestWritesRefused(t *testing.T) {
	fake, px := setup(t)
	good := map[string]string{"zt-session": "good"}
	for _, m := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		if code, _ := do(t, m, px.URL+mgmt+"/identities/x", good, "{}"); code != http.StatusForbidden {
			t.Errorf("%s: got %d, want 403", m, code)
		}
	}
	if code, _ := do(t, "POST", px.URL+"/fabric/v1/circuits", good, "{}"); code != http.StatusForbidden {
		t.Errorf("fabric POST: got %d", code)
	}
	if code, _ := do(t, "DELETE", px.URL+mgmt+"/current-api-session", good, ""); code != http.StatusOK {
		t.Errorf("logout: got %d", code)
	}
	if len(fake.writes) != 1 || fake.writes[0] != "DELETE "+mgmt+"/current-api-session" {
		t.Errorf("only logout may reach the controller, got %v", fake.writes)
	}
}

func TestOnlyCaddy(t *testing.T) {
	fake, px := setup(t)
	for _, s := range []string{"", "wrong"} {
		h := map[string]string{secretHeader: s, "Remote-User": "mrcode", "zt-session": "good"}
		if code, _ := do(t, "POST", px.URL+mgmt+"/authenticate", h, ""); code != http.StatusForbidden {
			t.Errorf("login with secret %q: got %d, want 403", s, code)
		}
		if code, _ := do(t, "GET", px.URL+mgmt+"/identities", h, ""); code != http.StatusForbidden {
			t.Errorf("read with secret %q: got %d, want 403", s, code)
		}
	}
	if fake.login != nil {
		t.Error("no login may reach the controller without Caddy's secret")
	}
	if code, _ := do(t, "GET", px.URL+"/healthz", map[string]string{secretHeader: ""}, ""); code != 200 {
		t.Errorf("healthz must work without the secret, got %d", code)
	}
}

func TestReadsPassThrough(t *testing.T) {
	_, px := setup(t)
	if code, _ := do(t, "GET", px.URL+mgmt+"/identities", map[string]string{"zt-session": "good"}, ""); code != 200 {
		t.Errorf("read: got %d", code)
	}
	if code, _ := do(t, "GET", px.URL+"/", nil, ""); code != http.StatusFound {
		t.Errorf("/: got %d", code)
	}
}

func TestLoginNeedsAuthelia(t *testing.T) {
	fake, px := setup(t)
	if code, _ := do(t, "POST", px.URL+mgmt+"/authenticate?method=password", nil, `{"username":"admin","password":"x"}`); code != http.StatusForbidden {
		t.Errorf("without Remote-User: got %d, want 403", code)
	}
	if fake.login != nil {
		t.Fatal("no login may reach the controller without Authelia")
	}
	code, body := do(t, "POST", px.URL+mgmt+"/authenticate?method=cert",
		map[string]string{"Remote-User": "mrcode"}, `{"username":"admin","password":"typed"}`)
	if code != 200 || !strings.Contains(body, `"token":"good"`) {
		t.Fatalf("login: %d %s", code, body)
	}
	if fake.login["username"] != "zac-readonly" || fake.login["password"] != "secret" {
		t.Errorf("must log in as the read-only identity, sent %v", fake.login)
	}
}

func TestSummary(t *testing.T) {
	_, px := setup(t)
	code, body := do(t, "GET", px.URL+mgmt+"/summary", map[string]string{"zt-session": "good"}, "")
	if code != 200 {
		t.Fatalf("summary: %d %s", code, body)
	}
	var s struct{ Data map[string]int }
	if err := json.Unmarshal([]byte(body), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Data) != len(summaryLists)-1 || s.Data["identities"] != 3 || s.Data["routers.edge"] != 3 {
		t.Errorf("summary data: %v", s.Data)
	}
	if _, ok := s.Data["enrollments"]; ok {
		t.Error("a list the identity may not read must be left out, not fail the summary")
	}
	if code, _ := do(t, "GET", px.URL+mgmt+"/summary", map[string]string{"zt-session": "bad"}, ""); code != http.StatusUnauthorized {
		t.Errorf("summary with a bad session: got %d, want 401", code)
	}
}

// serveZAC answers like the controller's spa binding: index.html for any
// route, gzipped when the client accepts it, and a script file as is.
func serveZAC(w http.ResponseWriter, r *http.Request) {
	if strings.HasSuffix(r.URL.Path, ".js") {
		w.Header().Set("Content-Type", "text/javascript")
		fmt.Fprint(w, "zac();")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	page := `<html><head><base href="/zac/"></head><body><app-root></app-root></body></html>`
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		zw := gzip.NewWriter(w)
		fmt.Fprint(zw, page)
		_ = zw.Close()
		return
	}
	fmt.Fprint(w, page)
}

func TestAutologinInjected(t *testing.T) {
	_, px := setup(t)
	for _, path := range []string{"/zac/", "/zac/dashboard"} {
		code, body := do(t, http.MethodGet, px.URL+path, nil, "")
		if code != http.StatusOK || !strings.Contains(body, autologinTag+"</head>") {
			t.Errorf("%s: %d %q, want the autologin tag before </head>", path, code, body)
		}
	}
	if _, body := do(t, http.MethodGet, px.URL+"/zac/main.js", nil, ""); body != "zac();" {
		t.Errorf("script changed: %q", body)
	}
	code, body := do(t, http.MethodGet, px.URL+autologinPath, nil, "")
	if code != http.StatusOK || !strings.Contains(body, "ziti.settings") {
		t.Errorf("autologin script: %d %q", code, body)
	}
	if code, _ := do(t, http.MethodGet, px.URL+autologinPath, map[string]string{secretHeader: ""}, ""); code != http.StatusForbidden {
		t.Errorf("autologin script without the Caddy secret: %d, want 403", code)
	}
}
