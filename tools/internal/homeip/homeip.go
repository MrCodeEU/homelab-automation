// Package homeip keeps CrowdSec's allowlist of the home connection current.
//
// The home connection gets a new IPv4 address and IPv6 prefix whenever the
// provider or the FRITZ!Box decides so, and a stale allowlist lets CrowdSec
// ban the owner (2026-11-17, after a router swap). Two halves:
//
//   - Serve, on nuc: answers what the FRITZ!Box reports over UPnP (no
//     password needed). Reachable only as the Ziti service home-ip-nuc.
//   - Sync, on mljr: fetches that over Ziti and makes the CrowdSec allowlist
//     "home" contain exactly the current IPv4 address and IPv6 prefix.
//
// The source of truth is the router itself, not an IP echo service, and the
// channel is authenticated by Ziti, so there is no public endpoint.
package homeip

import (
	"fmt"
	"net/netip"
)

// Home is the home connection's public addresses.
type Home struct {
	IPv4 string `json:"ipv4"`
	// IPv6Prefix is the prefix the provider delegates (a /56 at the time of
	// writing), covering every home subnet. Empty without IPv6.
	IPv6Prefix string `json:"ipv6_prefix,omitempty"`
}

// Values returns the allowlist values, IPv4 first.
func (h Home) Values() []string {
	out := []string{h.IPv4}
	if h.IPv6Prefix != "" {
		out = append(out, h.IPv6Prefix)
	}
	return out
}

// Validate rejects anything that is not a public address: a FRITZ!Box
// without a WAN connection reports 0.0.0.0 or nothing, and a private
// address in the allowlist would be a mistake, never the home connection.
func (h Home) Validate() error {
	a, err := netip.ParseAddr(h.IPv4)
	if err != nil || !a.Is4() || !public(a) {
		return fmt.Errorf("ipv4 %q is not a public IPv4 address", h.IPv4)
	}
	if h.IPv6Prefix == "" {
		return nil
	}
	p, err := netip.ParsePrefix(h.IPv6Prefix)
	if err != nil || !p.Addr().Is6() || p.Addr().Is4In6() || !public(p.Addr()) {
		return fmt.Errorf("ipv6 prefix %q is not a public IPv6 prefix", h.IPv6Prefix)
	}
	// Wider than /48 would allowlist other customers of the provider.
	if p.Bits() < 48 || p.Bits() > 64 {
		return fmt.Errorf("ipv6 prefix %q: want /48 to /64", h.IPv6Prefix)
	}
	if p.Masked() != p {
		return fmt.Errorf("ipv6 prefix %q has host bits set", h.IPv6Prefix)
	}
	return nil
}

func public(a netip.Addr) bool {
	return a.IsGlobalUnicast() && !a.IsPrivate() && !a.IsLoopback() && !a.IsUnspecified()
}
