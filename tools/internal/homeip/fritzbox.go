package homeip

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
)

// The FRITZ!Box's UPnP IGD control endpoint answers these two actions without
// a password ("Transmit status information over UPnP"; the TR-064 variants
// under /upnp/control need one).
const (
	igdPath    = "/igdupnp/control/WANIPConn1"
	igdService = "urn:schemas-upnp-org:service:WANIPConnection:1"
)

// QueryFritzBox asks the FRITZ!Box at base (http://192.168.50.1:49000) for
// the external IPv4 address and the delegated IPv6 prefix. A box without
// IPv6 yields an empty prefix, not an error.
func QueryFritzBox(ctx context.Context, c *http.Client, base string) (Home, error) {
	v4, err := soap(ctx, c, base, "GetExternalIPAddress")
	if err != nil {
		return Home{}, err
	}
	h := Home{IPv4: v4["NewExternalIPAddress"]}
	v6, err := soap(ctx, c, base, "X_AVM_DE_GetIPv6Prefix")
	if err != nil {
		return Home{}, err
	}
	if p, bits := v6["NewIPv6Prefix"], v6["NewPrefixLength"]; p != "" && p != "::" {
		n, err := strconv.Atoi(bits)
		if err != nil {
			return Home{}, fmt.Errorf("ipv6 prefix length %q", bits)
		}
		a, err := netip.ParseAddr(p)
		if err != nil {
			return Home{}, fmt.Errorf("ipv6 prefix %q", p)
		}
		h.IPv6Prefix = netip.PrefixFrom(a, n).String()
	}
	return h, h.Validate()
}

// soap calls one action and returns the response's New* fields by name.
func soap(ctx context.Context, c *http.Client, base, action string) (map[string]string, error) {
	body := `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ` +
		`s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:` + action +
		` xmlns:u="` + igdService + `"/></s:Body></s:Envelope>`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+igdPath, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	req.Header.Set("SoapAction", igdService+"#"+action)
	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", action, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", action, resp.StatusCode)
	}
	out := map[string]string{}
	dec := xml.NewDecoder(io.LimitReader(resp.Body, 64*1024))
	var field string
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", action, err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			field = ""
			if strings.HasPrefix(t.Name.Local, "New") {
				field = t.Name.Local
			}
		case xml.CharData:
			if field != "" {
				out[field] += strings.TrimSpace(string(t))
			}
		case xml.EndElement:
			field = ""
		}
	}
	return out, nil
}
