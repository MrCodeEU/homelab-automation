package main

import (
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
	if r.URL.Path == mgmt+"/summary" {
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
	px := httptest.NewServer(newProxy(u, http.DefaultTransport, "zac-readonly", "secret"))
	t.Cleanup(px.Close)
	return fake, px
}

func do(t *testing.T, method, url string, headers map[string]string, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
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
	if len(s.Data) != len(summaryLists) || s.Data["identities"] != 3 || s.Data["routers.edge"] != 3 {
		t.Errorf("summary data: %v", s.Data)
	}
	if code, _ := do(t, "GET", px.URL+mgmt+"/summary", map[string]string{"zt-session": "bad"}, ""); code != http.StatusUnauthorized {
		t.Errorf("summary with a bad session: got %d, want 401", code)
	}
}
