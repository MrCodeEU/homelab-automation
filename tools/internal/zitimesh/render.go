package zitimesh

import (
	"fmt"
	"io"
	"sort"
	"strings"
)

// Node Graph colours: online, offline, nothing behind it.
const (
	colorUp   = "green"
	colorDown = "red"
	colorIdle = "gray"
)

// Domain is cut from router names (nuc.int.mljr.eu -> nuc).
const Domain = ".int.mljr.eu"

func short(name string) string { return strings.TrimSuffix(name, Domain) }

// Graph node and edge ids are prefixed by kind, so a service and an identity
// with the same name stay two nodes.
func routerNode(name string) string   { return "router:" + short(name) }
func identityNode(name string) string { return "identity:" + name }
func serviceNode(name string) string  { return "service:" + name }

type series struct {
	labels []string // name, value, name, value, ...
	value  float64
}

type family struct {
	name, help string
	series     []series
}

func (f *family) add(value float64, labels ...string) {
	f.series = append(f.series, series{labels: labels, value: value})
}

// Render writes the state as Prometheus text exposition.
func (s *State) Render(w io.Writer) error {
	fams := s.families()
	for _, f := range fams {
		sort.SliceStable(f.series, func(i, j int) bool {
			return strings.Join(f.series[i].labels, "\x00") < strings.Join(f.series[j].labels, "\x00")
		})
		if _, err := fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n", f.name, f.help, f.name); err != nil {
			return err
		}
		for _, sr := range f.series {
			if _, err := fmt.Fprintf(w, "%s%s %g\n", f.name, labelString(sr.labels), sr.value); err != nil {
				return err
			}
		}
	}
	return nil
}

func labelString(kv []string) string {
	if len(kv) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteByte('{')
	for i := 0; i+1 < len(kv); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(kv[i])
		b.WriteString(`="`)
		b.WriteString(escape(kv[i+1]))
		b.WriteByte('"')
	}
	b.WriteByte('}')
	return b.String()
}

func escape(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

func b2f(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

func (s *State) families() []*family {
	routerName := map[string]string{}
	for _, r := range s.Routers {
		routerName[r.ID] = r.Name
	}
	identityName := map[string]string{}
	for _, i := range s.Identities {
		identityName[i.ID] = i.Name
	}

	routers := &family{name: "ziti_mesh_router_online", help: "1 if the edge router is connected to the controller."}
	for _, r := range s.Routers {
		routers.add(b2f(r.IsOnline), "router", short(r.Name))
	}

	identities := &family{name: "ziti_mesh_identity_online", help: "1 if the identity (not a router) has an edge router connection."}
	clients := map[string]identity{}
	for _, i := range s.Identities {
		if i.Type.Name == "Router" {
			continue
		}
		clients[i.ID] = i
		identities.add(b2f(i.Online && !i.Disabled), "identity", i.Name)
	}

	linkUp := &family{name: "ziti_mesh_link_up", help: "1 if the router link is connected."}
	linkLatency := &family{name: "ziti_mesh_link_latency_seconds", help: "Router link latency as measured by each end."}
	for _, l := range s.Links {
		src, dst := short(l.SourceRouter.Name), short(l.DestRouter.Name)
		linkUp.add(b2f(l.State == "Connected" && !l.Down), "source", src, "target", dst)
		linkLatency.add(float64(l.SourceLatency)/1e9, "source", src, "target", dst, "measured_by", src)
		linkLatency.add(float64(l.DestLatency)/1e9, "source", src, "target", dst, "measured_by", dst)
	}

	terminators := &family{name: "ziti_mesh_terminators", help: "Terminators of a service, by hosting router."}
	termCount := map[[2]string]int{} // service, router
	serviceHosted := map[string]bool{}
	for _, t := range s.Terminators {
		termCount[[2]string{t.Service.Name, short(t.Router.Name)}]++
		serviceHosted[t.Service.Name] = true
	}
	for k, n := range termCount {
		terminators.add(float64(n), "service", k[0], "router", k[1])
	}

	// Circuits: client identity -> ingress router -> ... -> egress router -> service.
	circuits := &family{name: "ziti_mesh_circuits", help: "Open circuits by service, client identity, ingress and egress router."}
	type circuitKey struct{ service, client, ingress, egress string }
	circuitCount := map[circuitKey]int{}
	for _, c := range s.Circuits {
		k := circuitKey{service: c.Service.Name, client: identityName[c.Tags["clientId"]]}
		if k.client == "" {
			k.client = "unknown"
		}
		if n := len(c.Path.Nodes); n > 0 {
			k.ingress, k.egress = short(c.Path.Nodes[0].Name), short(c.Path.Nodes[n-1].Name)
		}
		circuitCount[k]++
	}
	for k, n := range circuitCount {
		circuits.add(float64(n), "service", k.service, "client", k.client, "ingress", k.ingress, "egress", k.egress)
	}

	// Node Graph: routers, client identities, services; edges are router
	// links, client -> ingress router and egress router -> service (by
	// circuit), plus router -> service for hosted services without traffic.
	nodes := &family{name: "ziti_mesh_node", help: "Node Graph node; value is the main stat (open circuits)."}
	edges := &family{name: "ziti_mesh_edge", help: "Node Graph edge; value is the main stat (link latency in ms, or open circuits)."}

	routerCircuits := map[string]int{}
	clientCircuits := map[string]int{}
	serviceCircuits := map[string]int{}
	clientEdge := map[[2]string]int{}  // client, ingress
	serviceEdge := map[[2]string]int{} // egress, service
	for k, n := range circuitCount {
		if k.ingress != "" {
			routerCircuits[k.ingress] += n
			clientEdge[[2]string{k.client, k.ingress}] += n
		}
		if k.egress != "" && k.egress != k.ingress {
			routerCircuits[k.egress] += n
		}
		if k.egress != "" {
			serviceEdge[[2]string{k.egress, k.service}] += n
		}
		clientCircuits[k.client] += n
		serviceCircuits[k.service] += n
	}

	for _, r := range s.Routers {
		color := colorUp
		if !r.IsOnline {
			color = colorDown
		}
		nodes.add(float64(routerCircuits[short(r.Name)]),
			"id", routerNode(r.Name), "title", short(r.Name), "subtitle", "router", "kind", "router", "color", color)
	}
	for _, i := range clients {
		if clientCircuits[i.Name] == 0 && !i.Online {
			// Offline and idle: still a node, so a sidecar that dropped off shows.
			nodes.add(0, "id", identityNode(i.Name), "title", i.Name, "subtitle", "offline", "kind", "identity", "color", colorDown)
			continue
		}
		color, sub := colorUp, "online"
		if !i.Online {
			color, sub = colorDown, "offline"
		}
		nodes.add(float64(clientCircuits[i.Name]),
			"id", identityNode(i.Name), "title", i.Name, "subtitle", sub, "kind", "identity", "color", color)
	}
	if clientCircuits["unknown"] > 0 {
		nodes.add(float64(clientCircuits["unknown"]),
			"id", identityNode("unknown"), "title", "unknown", "subtitle", "client not found", "kind", "identity", "color", colorIdle)
	}
	services := map[string]bool{}
	for name := range serviceHosted {
		services[name] = true
	}
	for name := range serviceCircuits {
		services[name] = true
	}
	for name := range services {
		color, sub := colorIdle, "no traffic"
		switch {
		case !serviceHosted[name]:
			color, sub = colorDown, "no terminator"
		case serviceCircuits[name] > 0:
			color, sub = colorUp, "active"
		}
		nodes.add(float64(serviceCircuits[name]),
			"id", serviceNode(name), "title", name, "subtitle", sub, "kind", "service", "color", color)
	}

	for _, l := range s.Links {
		src, dst := routerNode(l.SourceRouter.Name), routerNode(l.DestRouter.Name)
		lat := max(l.SourceLatency, l.DestLatency)
		state := "connected"
		if l.State != "Connected" || l.Down {
			state = strings.ToLower(l.State)
		}
		edges.add(float64(lat)/1e6,
			"id", "link:"+l.ID, "source", src, "target", dst, "kind", "link", "state", state)
	}
	for k, n := range clientEdge {
		edges.add(float64(n), "id", "client:"+k[0]+">"+k[1],
			"source", identityNode(k[0]), "target", "router:"+k[1], "kind", "client", "state", "connected")
	}
	for k, n := range serviceEdge {
		edges.add(float64(n), "id", "egress:"+k[0]+">"+k[1],
			"source", "router:"+k[0], "target", serviceNode(k[1]), "kind", "egress", "state", "connected")
	}
	for k := range termCount {
		service, rtr := k[0], k[1]
		if serviceEdge[[2]string{rtr, service}] > 0 {
			continue
		}
		edges.add(0, "id", "host:"+rtr+">"+service,
			"source", "router:"+rtr, "target", serviceNode(service), "kind", "host", "state", "idle")
	}

	return []*family{routers, identities, linkUp, linkLatency, terminators, circuits, nodes, edges}
}
