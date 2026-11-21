package zitinotify

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeNames map[string]string

func (f fakeNames) get(id string) string {
	if n, ok := f[id]; ok {
		return n
	}
	return id
}
func (f fakeNames) Identity(id string) string { return f.get(id) }
func (f fakeNames) Service(id string) string  { return f.get(id) }
func (f fakeNames) Router(id string) string   { return f.get(id) }
func (f fakeNames) Learn(_, id, name string)  { f[id] = name }

var t0 = time.Date(2026, 11, 17, 20, 0, 0, 0, time.UTC)

func ev(t *testing.T, js string) Event {
	t.Helper()
	var e Event
	if err := json.Unmarshal([]byte(js), &e); err != nil {
		t.Fatal(err)
	}
	return e
}

func at(e Event, d time.Duration) Event { e.Timestamp = t0.Add(d); return e }

func titles(ms []Message) []string {
	var out []string
	for _, m := range ms {
		out = append(out, m.Title)
	}
	return out
}

func TestEnrolment(t *testing.T) {
	names := fakeNames{"phone1": "phone-mrcode"}
	e := New(names, Settings{})
	e.Handle(at(ev(t, `{"namespace":"entityChange","eventType":"created","entityType":"authenticators",
		"metadata":{"author":{"type":"identity","id":"phone1","name":"phone-mrcode"},"source":{"remoteAddr":"[2001:db8::5]:53876"}},
		"finalState":{"id":"a1","type":"cert","identityId":"phone1"}}`), 0))
	if got := e.Tick(t0.Add(30 * time.Second)); len(got) != 0 {
		t.Fatalf("sent before the quiet period: %v", titles(got))
	}
	got := e.Tick(t0.Add(61 * time.Second))
	if len(got) != 1 || got[0].Title != "Ziti: phone-mrcode enrolled" || got[0].Priority != 4 {
		t.Fatalf("got %+v", got)
	}
	if !strings.Contains(got[0].Body, "2001:db8::5") {
		t.Errorf("body lacks the address: %q", got[0].Body)
	}
}

func TestChangesGroupedByAuthor(t *testing.T) {
	e := New(fakeNames{}, Settings{})
	tofu := `"metadata":{"author":{"type":"identity","id":"adm","name":"Default Admin"},"source":{"remoteAddr":"127.0.0.1:4000"}}`
	e.Handle(at(ev(t, `{"namespace":"entityChange","eventType":"created","entityType":"identities",`+tofu+`,"finalState":{"id":"i1","name":"phone-mrcode"}}`), 0))
	e.Handle(at(ev(t, `{"namespace":"entityChange","eventType":"created","entityType":"servicePolicies",`+tofu+`,"finalState":{"id":"p1","name":"mobile-dial"}}`), time.Second))
	e.Handle(at(ev(t, `{"namespace":"entityChange","eventType":"deleted","entityType":"postureChecks",`+tofu+`,"initialState":{"id":"c1","name":"mfa-mobile"}}`), 2*time.Second))
	// Noise: sessions, and an identity update that only moved interfaces.
	e.Handle(at(ev(t, `{"namespace":"entityChange","eventType":"created","entityType":"apiSessions",`+tofu+`,"finalState":{"id":"s1"}}`), 3*time.Second))
	e.Handle(at(ev(t, `{"namespace":"entityChange","eventType":"updated","entityType":"identities",`+tofu+`,
		"initialState":{"id":"i2","name":"nuc","interfaces":[1]},"finalState":{"id":"i2","name":"nuc","interfaces":[2]}}`), 4*time.Second))
	got := e.Tick(t0.Add(2 * time.Minute))
	if len(got) != 1 {
		t.Fatalf("want one message, got %v", titles(got))
	}
	m := got[0]
	want := "+ identity phone-mrcode\n+ service policy mobile-dial\n- posture check mfa-mobile\n(on the controller host)"
	if m.Title != "Ziti: 3 change(s) by Default Admin" || m.Body != want || m.Priority != 2 {
		t.Fatalf("got %q / %q / %d", m.Title, m.Body, m.Priority)
	}
}

func TestRemoteAccessChange(t *testing.T) {
	e := New(fakeNames{}, Settings{})
	e.Handle(at(ev(t, `{"namespace":"entityChange","eventType":"updated","entityType":"identities",
		"metadata":{"author":{"type":"identity","id":"x","name":"someone"},"source":{"remoteAddr":"198.51.100.7:443"}},
		"initialState":{"id":"i2","name":"phone","roleAttributes":["mobile"]},"finalState":{"id":"i2","name":"phone","roleAttributes":["mobile","admin"]}}`), 0))
	got := e.Tick(t0.Add(5 * time.Minute))
	if len(got) != 1 || got[0].Priority != 4 || !strings.Contains(got[0].Body, "~ identity phone\n(from 198.51.100.7)") {
		t.Fatalf("got %+v", got)
	}
}

func TestAuthFailures(t *testing.T) {
	e := New(fakeNames{"i1": "phone-mrcode"}, Settings{})
	for i := 0; i < 3; i++ {
		e.Handle(at(ev(t, `{"namespace":"authentication","event_type":"fail","type":"cert","identity_id":"i1","remote_address":"203.0.113.9:1234","reason":"invalid certificate"}`), time.Duration(i)*time.Minute))
	}
	e.Handle(at(ev(t, `{"namespace":"authentication","event_type":"success","type":"cert","identity_id":"i1"}`), 4*time.Minute))
	if got := e.Tick(t0.Add(10 * time.Minute)); len(got) != 0 {
		t.Fatalf("sent before the window closed: %v", titles(got))
	}
	got := e.Tick(t0.Add(15 * time.Minute))
	if len(got) != 1 || got[0].Title != "Ziti: 3 failed login(s) in 15m0s" ||
		got[0].Body != "3× phone-mrcode (cert) from 203.0.113.9: invalid certificate" {
		t.Fatalf("got %+v", got)
	}
}

func circuit(t *testing.T, typ, cause string, d time.Duration) Event {
	return at(ev(t, `{"namespace":"circuit","event_type":"`+typ+`","service_id":"svc","failure_cause":"`+cause+`","tags":{"clientId":"cli","hostId":"rtr"}}`), d)
}

func TestCircuits(t *testing.T) {
	e := New(fakeNames{"svc": "grafana-loki", "cli": "m2m-mljr", "rtr": "nuc"}, Settings{})
	// Window 1: retries through a restart, mostly fine. No message.
	for i := 0; i < 40; i++ {
		e.Handle(circuit(t, "created", "", time.Duration(i)*time.Second))
	}
	for i := 0; i < 8; i++ {
		e.Handle(circuit(t, "failed", "ROUTER_RESPONSE_TIMEOUT", time.Duration(i)*time.Second))
	}
	if got := e.Tick(t0.Add(10 * time.Minute)); len(got) != 0 {
		t.Fatalf("retries reported: %v", titles(got))
	}
	// Window 2: the service is down.
	for i := 0; i < 6; i++ {
		e.Handle(circuit(t, "failed", "ROUTER_ERR_CONN_REFUSED", 11*time.Minute))
	}
	e.Handle(circuit(t, "created", "", 11*time.Minute))
	got := e.Tick(t0.Add(20 * time.Minute))
	if len(got) != 1 || got[0].Title != "Ziti: grafana-loki failing" {
		t.Fatalf("got %v", titles(got))
	}
	if want := "6 of 7 connections failed in 10m0s.\n6× ROUTER_ERR_CONN_REFUSED\nClients: m2m-mljr\nHosted by: nuc"; got[0].Body != want {
		t.Errorf("body %q", got[0].Body)
	}
	// Window 3: still failing, no repeat.
	for i := 0; i < 6; i++ {
		e.Handle(circuit(t, "failed", "ROUTER_ERR_CONN_REFUSED", 21*time.Minute))
	}
	if got := e.Tick(t0.Add(30 * time.Minute)); len(got) != 0 {
		t.Fatalf("repeated: %v", titles(got))
	}
	// Window 4: recovered.
	e.Handle(circuit(t, "created", "", 31*time.Minute))
	got = e.Tick(t0.Add(40 * time.Minute))
	if len(got) != 1 || got[0].Title != "Ziti: grafana-loki ok again" {
		t.Fatalf("got %v", titles(got))
	}
}

func TestCircuitsQuiet(t *testing.T) {
	quiet := true
	e := New(fakeNames{"svc": "grafana-loki"}, Settings{Quiet: func(time.Time) bool { return quiet }})
	// Failing while quiet (hosts rebooting): dropped.
	for i := 0; i < 6; i++ {
		e.Handle(circuit(t, "failed", "ROUTER_ERR_CONN_REFUSED", time.Duration(i)*time.Second))
	}
	if got := e.Tick(t0.Add(10 * time.Minute)); len(got) != 0 {
		t.Fatalf("reported while quiet: %v", titles(got))
	}
	// Still failing after the window: reported.
	quiet = false
	for i := 0; i < 6; i++ {
		e.Handle(circuit(t, "failed", "ROUTER_ERR_CONN_REFUSED", 11*time.Minute))
	}
	if got := e.Tick(t0.Add(20 * time.Minute)); len(got) != 1 || got[0].Title != "Ziti: grafana-loki failing" {
		t.Fatalf("got %v", titles(got))
	}
}

func TestFollowRotation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.log")
	if err := os.WriteFile(path, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	lines := make(chan []byte, 10)
	go Follow(ctx, path, 10*time.Millisecond, lines)
	time.Sleep(50 * time.Millisecond)
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("a\nb")
	time.Sleep(50 * time.Millisecond)
	f.WriteString("\n")
	f.Close()
	// Rotate: rename, new file.
	os.Rename(path, filepath.Join(dir, "events-1.log"))
	os.WriteFile(path, []byte("c\n"), 0o644)
	var got []string
	for len(got) < 3 {
		select {
		case l := <-lines:
			got = append(got, string(l))
		case <-ctx.Done():
			t.Fatalf("got only %q", got)
		}
	}
	if strings.Join(got, "") != "a\nb\nc\n" {
		t.Fatalf("got %q", got)
	}
}
