package zitimesh

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// fakeController serves the five list endpoints from fixed data, two items
// per page, and expires the first session after its first call.
type fakeController struct {
	logins int
	used   int // requests made with session t1
	data   map[string][]any
}

func (f *fakeController) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/edge/management/v1/authenticate" {
		if r.Method != http.MethodPost || r.URL.Query().Get("method") != "cert" {
			http.Error(w, "bad login", http.StatusBadRequest)
			return
		}
		f.logins++
		fmt.Fprintf(w, `{"data":{"token":"t%d"}}`, f.logins)
		return
	}
	switch tok := r.Header.Get("zt-session"); tok {
	case "":
		http.Error(w, "no session", http.StatusUnauthorized)
		return
	case "t1":
		// the first session is valid for one request, then it expires
		if f.used++; f.used > 1 {
			http.Error(w, "expired", http.StatusUnauthorized)
			return
		}
	}
	items, ok := f.data[r.URL.Path]
	if !ok {
		http.NotFound(w, r)
		return
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	end := min(offset+2, len(items))
	if offset > end {
		offset = end
	}
	_ = json.NewEncoder(w).Encode(map[string]any{
		"data": items[offset:end],
		"meta": map[string]any{"pagination": map[string]any{"totalCount": len(items)}},
	})
}

func obj(s string) any {
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		panic(err)
	}
	return v
}

func newFake() *fakeController {
	return &fakeController{data: map[string][]any{
		"/edge/management/v1/edge-routers": {
			obj(`{"id":"R1","name":"nuc.int.mljr.eu","isOnline":true}`),
			obj(`{"id":"R2","name":"mljr.int.mljr.eu","isOnline":true}`),
			obj(`{"id":"R3","name":"nas.int.mljr.eu","isOnline":false}`),
		},
		"/fabric/v1/links": {
			obj(`{"id":"L1","sourceRouter":{"id":"R1","name":"nuc.int.mljr.eu"},"destRouter":{"id":"R2","name":"mljr.int.mljr.eu"},"state":"Connected","sourceLatency":12000000,"destLatency":15000000}`),
		},
		"/edge/management/v1/identities": {
			obj(`{"id":"I1","name":"m2m-nuc","type":{"name":"Default"},"hasEdgeRouterConnection":true}`),
			obj(`{"id":"I2","name":"phone","type":{"name":"Default"},"hasEdgeRouterConnection":false}`),
			obj(`{"id":"R1","name":"nuc.int.mljr.eu","type":{"name":"Router"},"hasEdgeRouterConnection":true}`),
		},
		"/edge/management/v1/terminators": {
			obj(`{"id":"T1","service":{"name":"grafana-loki"},"router":{"name":"nuc.int.mljr.eu"},"binding":"tunnel"}`),
			obj(`{"id":"T2","service":{"name":"kuma"},"router":{"name":"nuc.int.mljr.eu"},"binding":"tunnel"}`),
		},
		"/fabric/v1/circuits": {
			obj(`{"id":"C1","service":{"name":"grafana-loki"},"tags":{"clientId":"I1"},"path":{"nodes":[{"name":"mljr.int.mljr.eu"},{"name":"nuc.int.mljr.eu"}]}}`),
			obj(`{"id":"C2","service":{"name":"grafana-loki"},"tags":{"clientId":"I1"},"path":{"nodes":[{"name":"mljr.int.mljr.eu"},{"name":"nuc.int.mljr.eu"}]}}`),
			obj(`{"id":"C3","service":{"name":"ghost"},"tags":{"clientId":"gone"},"path":{"nodes":[{"name":"nuc.int.mljr.eu"}]}}`),
		},
	}}
}

func TestReadAndRender(t *testing.T) {
	fake := newFake()
	srv := httptest.NewServer(fake)
	defer srv.Close()
	c := &Client{HTTP: srv.Client(), Base: srv.URL}

	st, err := c.Read(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Routers) != 3 || len(st.Identities) != 3 || len(st.Circuits) != 3 {
		t.Fatalf("pagination lost items: %d routers, %d identities, %d circuits",
			len(st.Routers), len(st.Identities), len(st.Circuits))
	}

	var b strings.Builder
	if err := st.Render(&b); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{
		`ziti_mesh_router_online{router="nas"} 0`,
		`ziti_mesh_identity_online{identity="phone"} 0`,
		`ziti_mesh_link_latency_seconds{source="nuc",target="mljr",measured_by="mljr"} 0.015`,
		`ziti_mesh_circuits{service="grafana-loki",client="m2m-nuc",ingress="mljr",egress="nuc"} 2`,
		`ziti_mesh_circuits{service="ghost",client="unknown",ingress="nuc",egress="nuc"} 1`,
		`ziti_mesh_node{id="router:nas",title="nas",subtitle="router",kind="router",color="red"} 0`,
		`ziti_mesh_node{id="identity:m2m-nuc",title="m2m-nuc",subtitle="online",kind="identity",color="green"} 2`,
		`ziti_mesh_node{id="service:grafana-loki",title="grafana-loki",subtitle="active",kind="service",color="green"} 2`,
		`ziti_mesh_node{id="service:kuma",title="kuma",subtitle="no traffic",kind="service",color="gray"} 0`,
		`ziti_mesh_node{id="service:ghost",title="ghost",subtitle="no terminator",kind="service",color="red"} 1`,
		`ziti_mesh_edge{id="link:L1",source="router:nuc",target="router:mljr",kind="link",state="connected"} 15`,
		`ziti_mesh_edge{id="client:m2m-nuc>mljr",source="identity:m2m-nuc",target="router:mljr",kind="client",state="connected"} 2`,
		`ziti_mesh_edge{id="egress:nuc>grafana-loki",source="router:nuc",target="service:grafana-loki",kind="egress",state="connected"} 2`,
		`ziti_mesh_edge{id="host:nuc>kuma",source="router:nuc",target="service:kuma",kind="host",state="idle"} 0`,
	} {
		if !strings.Contains(out, want+"\n") {
			t.Errorf("missing %s\n--- got:\n%s", want, out)
		}
	}
	if strings.Contains(out, `identity="nuc.int.mljr.eu"`) {
		t.Error("router identities must not be listed as clients")
	}
	if fake.logins != 2 {
		t.Errorf("expected exactly one new login after the expired session, logins=%d", fake.logins)
	}
}

func TestReadFailsWholeOnError(t *testing.T) {
	fake := newFake()
	delete(fake.data, "/fabric/v1/circuits")
	srv := httptest.NewServer(fake)
	defer srv.Close()
	c := &Client{HTTP: srv.Client(), Base: srv.URL}
	if _, err := c.Read(context.Background()); err == nil {
		t.Fatal("a failed endpoint must fail the whole read")
	}
}

func TestEscape(t *testing.T) {
	if got := labelString([]string{"a", `x"y\z`}); got != `{a="x\"y\\z"}` {
		t.Fatalf("got %s", got)
	}
}

// After a controller restart, links reported latencies of minutes to hours
// while they were fast; those values are dropped, not graphed.
func TestImpossibleLatencyDropped(t *testing.T) {
	nuc := ref{ID: "R1", Name: "nuc.int.mljr.eu"}
	mljr := ref{ID: "R2", Name: "mljr.int.mljr.eu"}
	nas := ref{ID: "R3", Name: "nas.int.mljr.eu"}
	st := &State{Links: []link{
		// One end bogus (8888.9 s), the other a real 20 ms.
		{ID: "L1", SourceRouter: nuc, DestRouter: mljr, State: "Connected",
			SourceLatency: 8888900000000, DestLatency: 20000000},
		// Neither end has a real measurement.
		{ID: "L2", SourceRouter: nas, DestRouter: mljr, State: "Connected",
			SourceLatency: 4444450000000, DestLatency: 0},
	}}
	var b strings.Builder
	if err := st.Render(&b); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{
		`ziti_mesh_link_latency_seconds{source="nuc",target="mljr",measured_by="mljr"} 0.02`,
		`ziti_mesh_edge{id="link:L1",source="router:nuc",target="router:mljr",kind="link",state="connected"} 20`,
		`ziti_mesh_edge{id="link:L2",source="router:nas",target="router:mljr",kind="link",state="connected"} NaN`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s", want)
		}
	}
	for _, bad := range []string{`measured_by="nuc"`, `source="nas",target="mljr",measured_by`} {
		if strings.Contains(out, bad) {
			t.Errorf("bogus latency rendered: %s", bad)
		}
	}
}
