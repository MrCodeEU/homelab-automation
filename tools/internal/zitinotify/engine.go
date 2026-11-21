// Package zitinotify turns the OpenZiti controller's event stream
// (events.log, config.yml `events:`) into short ntfy messages a person can
// act on: names instead of ids, grouped, and circuit failures only when a
// service is really failing rather than retrying through a restart.
//
// Grafana keeps the alerts that must work while the controller is down
// (controller down, router offline, link down: services/grafana/
// provisioning/alerting/ziti.yml); everything event-based is here.
package zitinotify

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Event is the part of a controller event this package reads. Every
// namespace shares the envelope; the rest is per namespace.
type Event struct {
	Namespace string    `json:"namespace"`
	Timestamp time.Time `json:"timestamp"`
	// circuit, authentication, sdk, router
	EventType string `json:"event_type"`
	// entityChange
	ChangeType   string          `json:"eventType"`
	EntityType   string          `json:"entityType"`
	Metadata     changeMetadata  `json:"metadata"`
	InitialState json.RawMessage `json:"initialState"`
	FinalState   json.RawMessage `json:"finalState"`
	// circuit
	ServiceID    string            `json:"service_id"`
	FailureCause string            `json:"failure_cause"`
	Tags         map[string]string `json:"tags"`
	// authentication
	AuthType      string `json:"type"`
	IdentityID    string `json:"identity_id"`
	RemoteAddress string `json:"remote_address"`
	Reason        string `json:"reason"`
}

type changeMetadata struct {
	Author struct {
		Type string `json:"type"`
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"author"`
	Source struct {
		Type       string `json:"type"`
		RemoteAddr string `json:"remoteAddr"`
	} `json:"source"`
}

type entityState struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	IdentityID string `json:"identityId"`
	Type       string `json:"type"`
}

// Message is one ntfy notification.
type Message struct {
	Title    string
	Body     string
	Priority int // ntfy: 1 min .. 5 max, 3 default
	Tags     []string
}

// Names resolves ids to names; it returns the id itself when unknown.
type Names interface {
	Identity(id string) string
	Service(id string) string
	Router(id string) string
	// Learn records a name seen in an event, ahead of the next refresh.
	Learn(kind, id, name string)
}

// Settings tune the engine; zero values take the defaults.
type Settings struct {
	// Changes are collected until none came for ChangeQuiet, at most
	// ChangeMax after the first.
	ChangeQuiet, ChangeMax time.Duration
	// Login failures and circuits are counted in windows of this length.
	AuthWindow, CircuitWindow time.Duration
	// A service is failing when a window has at least CircuitMinFailed
	// failed circuits and they are at least half of all attempts.
	CircuitMinFailed int
	// Quiet, when set, reports times (the weekly host maintenance) whose
	// circuit windows are dropped: failures while hosts reboot are no news.
	// A service still failing after it is reported by the next window.
	Quiet func(time.Time) bool
}

func (s *Settings) defaults() {
	if s.ChangeQuiet == 0 {
		s.ChangeQuiet = time.Minute
	}
	if s.ChangeMax == 0 {
		s.ChangeMax = 5 * time.Minute
	}
	if s.AuthWindow == 0 {
		s.AuthWindow = 15 * time.Minute
	}
	if s.CircuitWindow == 0 {
		s.CircuitWindow = 10 * time.Minute
	}
	if s.CircuitMinFailed == 0 {
		s.CircuitMinFailed = 5
	}
}

// Engine aggregates events into messages. Not safe for concurrent use.
type Engine struct {
	set   Settings
	names Names

	changes                 []change
	firstChange, lastChange time.Time
	authFails               []authFail
	authStart               time.Time
	circuits                map[string]*circuitStats // by service id
	circuitStart            time.Time
	failing                 map[string]bool // services reported as failing
}

type change struct {
	op, kind, name, author, remote string
	enrolment                      bool
}

type authFail struct{ identity, authType, reason, remote string }

type circuitStats struct {
	ok, failed int
	causes     map[string]int
	clients    map[string]bool
	hosts      map[string]bool
}

func New(names Names, set Settings) *Engine {
	set.defaults()
	return &Engine{set: set, names: names, circuits: map[string]*circuitStats{}, failing: map[string]bool{}}
}

// The entity types worth a message, with their label. Updates are reported
// only for configuration: identities and routers are updated by every
// connection (interfaces, sdkInfo), so an identity update counts only when
// a field in identityAccess changed. Sessions, terminators and eventual
// events are noise.
var watched = map[string]struct {
	label   string
	updates bool
}{
	"identities":                {"identity", true},
	"authenticators":            {"authenticator", false},
	"services":                  {"service", true},
	"configs":                   {"config", true},
	"servicePolicies":           {"service policy", true},
	"edgeRouterPolicies":        {"edge router policy", true},
	"serviceEdgeRouterPolicies": {"service edge router policy", true},
	"postureChecks":             {"posture check", true},
	"authPolicies":              {"auth policy", true},
	"externalJwtSigners":        {"external JWT signer", true},
	"cas":                       {"CA", true},
	"routers":                   {"router", false},
}

// Handle takes one event.
func (e *Engine) Handle(ev Event) {
	now := ev.Timestamp
	switch ev.Namespace {
	case "entityChange":
		e.handleChange(ev, now)
	case "authentication":
		if ev.EventType != "fail" {
			return
		}
		if len(e.authFails) == 0 {
			e.authStart = now
		}
		e.authFails = append(e.authFails, authFail{
			identity: e.names.Identity(ev.IdentityID), authType: ev.AuthType,
			reason: ev.Reason, remote: hostOnly(ev.RemoteAddress),
		})
	case "circuit":
		if ev.ServiceID == "" || (ev.EventType != "created" && ev.EventType != "failed") {
			return
		}
		if e.circuitStart.IsZero() {
			e.circuitStart = now
		}
		st := e.circuits[ev.ServiceID]
		if st == nil {
			st = &circuitStats{causes: map[string]int{}, clients: map[string]bool{}, hosts: map[string]bool{}}
			e.circuits[ev.ServiceID] = st
		}
		if ev.EventType == "created" {
			st.ok++
			return
		}
		st.failed++
		st.causes[ev.FailureCause]++
		if c := ev.Tags["clientId"]; c != "" {
			st.clients[e.names.Identity(c)] = true
		}
		if h := ev.Tags["hostId"]; h != "" {
			st.hosts[e.names.Router(h)] = true
		}
	}
}

func (e *Engine) handleChange(ev Event, now time.Time) {
	w, ok := watched[ev.EntityType]
	if !ok {
		return
	}
	op := map[string]string{"created": "+", "updated": "~", "deleted": "-"}[ev.ChangeType]
	if op == "" || (op == "~" && !w.updates) {
		return
	}
	raw := ev.FinalState
	if op == "-" {
		raw = ev.InitialState
	}
	var st entityState
	json.Unmarshal(raw, &st)
	if op == "~" && ev.EntityType == "identities" && !accessChanged(ev.InitialState, ev.FinalState) {
		return
	}
	kind := map[string]string{"identities": "identity", "services": "service", "routers": "router"}[ev.EntityType]
	if kind != "" && st.Name != "" {
		e.names.Learn(kind, st.ID, st.Name)
	}
	name := st.Name
	c := change{op: op, kind: w.label, remote: hostOnly(ev.Metadata.Source.RemoteAddr)}
	if ev.EntityType == "authenticators" {
		owner := e.names.Identity(st.IdentityID)
		name = fmt.Sprintf("%s of %s", st.Type, owner)
		// An identity creating its own authenticator is an enrolment.
		c.enrolment = op == "+" && ev.Metadata.Author.ID != "" && ev.Metadata.Author.ID == st.IdentityID
		if c.enrolment {
			name = owner
		}
	}
	if name == "" {
		name = st.ID
	}
	c.name = name
	c.author = ev.Metadata.Author.Name
	if c.author == "" {
		c.author = ev.Metadata.Author.Type
	}
	if len(e.changes) == 0 {
		e.firstChange = now
	}
	e.lastChange = now
	e.changes = append(e.changes, c)
}

// Tick returns the messages due at now. Call it about every few seconds and
// with the timestamp of each event, so windows close on time.
func (e *Engine) Tick(now time.Time) []Message {
	var out []Message
	if len(e.changes) > 0 && (now.Sub(e.lastChange) >= e.set.ChangeQuiet || now.Sub(e.firstChange) >= e.set.ChangeMax) {
		out = append(out, e.changeMessages()...)
		e.changes = nil
	}
	if len(e.authFails) > 0 && now.Sub(e.authStart) >= e.set.AuthWindow {
		out = append(out, e.authMessage())
		e.authFails = nil
	}
	if !e.circuitStart.IsZero() && now.Sub(e.circuitStart) >= e.set.CircuitWindow {
		if e.set.Quiet == nil || !e.set.Quiet(now) {
			out = append(out, e.circuitMessages()...)
		}
		e.circuits = map[string]*circuitStats{}
		e.circuitStart = now
	}
	return out
}

func (e *Engine) changeMessages() []Message {
	var out []Message
	var rest []change
	for _, c := range e.changes {
		if c.enrolment {
			out = append(out, Message{
				Title:    "Ziti: " + c.name + " enrolled",
				Body:     fmt.Sprintf("New certificate for identity %s, from %s. Expected only right after an enrolment script; otherwise delete its authenticators.", c.name, orUnknown(c.remote)),
				Priority: 4, Tags: []string{"key"},
			})
			continue
		}
		rest = append(rest, c)
	}
	if len(rest) == 0 {
		return out
	}
	// One message per author and address: an OpenTofu apply is one message.
	type key struct{ author, remote string }
	groups := map[key][]change{}
	var keys []key
	for _, c := range rest {
		k := key{c.author, c.remote}
		if _, ok := groups[k]; !ok {
			keys = append(keys, k)
		}
		groups[k] = append(groups[k], c)
	}
	for _, k := range keys {
		cs := groups[k]
		var lines []string
		for _, c := range cs {
			lines = append(lines, fmt.Sprintf("%s %s %s", c.op, c.kind, c.name))
		}
		// From the controller host (OpenTofu, scripts): expected, low
		// priority. From anywhere else: someone used the API remotely.
		prio, tags := 2, []string{"gear"}
		via := "on the controller host"
		if !loopback(k.remote) {
			prio, tags = 4, []string{"warning"}
			via = "from " + orUnknown(k.remote)
		}
		out = append(out, Message{
			Title:    fmt.Sprintf("Ziti: %d change(s) by %s", len(cs), k.author),
			Body:     strings.Join(lines, "\n") + "\n(" + via + ")",
			Priority: prio, Tags: tags,
		})
	}
	return out
}

func (e *Engine) authMessage() Message {
	counts := map[string]int{}
	var order []string
	for _, f := range e.authFails {
		reason := f.reason
		if reason == "" {
			reason = "no reason given"
		}
		line := fmt.Sprintf("%s (%s) from %s: %s", orUnknown(f.identity), f.authType, orUnknown(f.remote), reason)
		if counts[line] == 0 {
			order = append(order, line)
		}
		counts[line]++
	}
	var lines []string
	for _, l := range order {
		lines = append(lines, fmt.Sprintf("%d× %s", counts[l], l))
	}
	prio := 3
	if len(e.authFails) >= 5 {
		prio = 4
	}
	return Message{
		Title:    fmt.Sprintf("Ziti: %d failed login(s) in %s", len(e.authFails), e.set.AuthWindow),
		Body:     strings.Join(lines, "\n"),
		Priority: prio, Tags: []string{"no_entry"},
	}
}

func (e *Engine) circuitMessages() []Message {
	var out []Message
	ids := make([]string, 0, len(e.circuits))
	for id := range e.circuits {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		st := e.circuits[id]
		name := e.names.Service(id)
		failing := st.failed >= e.set.CircuitMinFailed && st.failed*2 >= st.failed+st.ok
		switch {
		case failing && !e.failing[id]:
			e.failing[id] = true
			var causes []string
			for c, n := range st.causes {
				causes = append(causes, fmt.Sprintf("%d× %s", n, c))
			}
			sort.Sort(sort.Reverse(sort.StringSlice(causes)))
			out = append(out, Message{
				Title: fmt.Sprintf("Ziti: %s failing", name),
				Body: fmt.Sprintf("%d of %d connections failed in %s.\n%s\nClients: %s\nHosted by: %s",
					st.failed, st.failed+st.ok, e.set.CircuitWindow, strings.Join(causes, ", "),
					joinKeys(st.clients), joinKeys(st.hosts)),
				Priority: 4, Tags: []string{"warning"},
			})
		case !failing && e.failing[id] && st.ok > 0:
			delete(e.failing, id)
			out = append(out, Message{
				Title:    fmt.Sprintf("Ziti: %s ok again", name),
				Body:     fmt.Sprintf("%d of %d connections succeeded in the last %s.", st.ok, st.failed+st.ok, e.set.CircuitWindow),
				Priority: 2, Tags: []string{"white_check_mark"},
			})
		}
	}
	return out
}

// The identity fields that change what it may reach or how it logs in.
var identityAccess = []string{"name", "roleAttributes", "isAdmin", "authPolicyId", "type", "externalId", "disabled"}

func accessChanged(before, after json.RawMessage) bool {
	var a, b map[string]json.RawMessage
	if json.Unmarshal(before, &a) != nil || json.Unmarshal(after, &b) != nil {
		return true
	}
	for _, k := range identityAccess {
		if string(a[k]) != string(b[k]) {
			return true
		}
	}
	return false
}

func joinKeys(m map[string]bool) string {
	if len(m) == 0 {
		return "unknown"
	}
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return strings.Join(ks, ", ")
}

func hostOnly(addr string) string {
	if addr == "" {
		return ""
	}
	if i := strings.LastIndex(addr, ":"); i > 0 && !strings.HasSuffix(addr, "]") {
		addr = addr[:i]
	}
	return strings.Trim(addr, "[]")
}

func loopback(host string) bool {
	return host == "127.0.0.1" || host == "::1" || host == "localhost" || host == ""
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}
