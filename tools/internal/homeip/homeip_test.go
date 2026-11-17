package homeip

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestValidate(t *testing.T) {
	for _, c := range []struct {
		h  Home
		ok bool
	}{
		{Home{IPv4: "85.193.174.52", IPv6Prefix: "2a03:c100:f902:9700::/56"}, true},
		{Home{IPv4: "85.193.174.52"}, true},
		{Home{IPv4: "0.0.0.0"}, false},
		{Home{IPv4: "192.168.50.1"}, false},
		{Home{IPv4: "100.64.1.2"}, true}, // CGNAT is not IsPrivate; the FRITZ!Box would report it as is
		{Home{IPv4: "2a03::1"}, false},
		{Home{IPv4: "85.193.174.52", IPv6Prefix: "2a03:c100::/32"}, false},
		{Home{IPv4: "85.193.174.52", IPv6Prefix: "fd00:1::/56"}, false},
		{Home{IPv4: "85.193.174.52", IPv6Prefix: "2a03:c100:f902:9701::/56"}, false},
		{Home{IPv4: "85.193.174.52", IPv6Prefix: "::ffff:1.2.3.0/120"}, false},
	} {
		if err := c.h.Validate(); (err == nil) != c.ok {
			t.Errorf("%+v: err %v, want ok=%v", c.h, err, c.ok)
		}
	}
}

func fritz(t *testing.T, v4, prefix, bits string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != igdPath {
			http.NotFound(w, r)
			return
		}
		body, _ := io.ReadAll(r.Body)
		var resp string
		switch {
		case strings.Contains(r.Header.Get("SoapAction"), "#GetExternalIPAddress") && strings.Contains(string(body), "GetExternalIPAddress"):
			resp = `<u:GetExternalIPAddressResponse xmlns:u="` + igdService + `"><NewExternalIPAddress>` + v4 + `</NewExternalIPAddress></u:GetExternalIPAddressResponse>`
		case strings.Contains(r.Header.Get("SoapAction"), "#X_AVM_DE_GetIPv6Prefix"):
			resp = `<u:X_AVM_DE_GetIPv6PrefixResponse xmlns:u="` + igdService + `"><NewIPv6Prefix>` + prefix + `</NewIPv6Prefix><NewPrefixLength>` + bits +
				`</NewPrefixLength><NewValidLifetime>523793</NewValidLifetime></u:X_AVM_DE_GetIPv6PrefixResponse>`
		default:
			http.Error(w, "bad action", 500)
			return
		}
		io.WriteString(w, `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>`+resp+`</s:Body></s:Envelope>`)
	}))
}

func TestQueryFritzBox(t *testing.T) {
	ctx := context.Background()
	srv := fritz(t, "85.193.174.52", "2a03:c100:f902:9700::", "56")
	defer srv.Close()
	h, err := QueryFritzBox(ctx, srv.Client(), srv.URL)
	if err != nil || h.IPv4 != "85.193.174.52" || h.IPv6Prefix != "2a03:c100:f902:9700::/56" {
		t.Fatalf("got %+v, %v", h, err)
	}
	noV6 := fritz(t, "85.193.174.52", "", "0")
	defer noV6.Close()
	if h, err := QueryFritzBox(ctx, noV6.Client(), noV6.URL); err != nil || h.IPv6Prefix != "" {
		t.Fatalf("no ipv6: %+v, %v", h, err)
	}
	offline := fritz(t, "0.0.0.0", "", "0")
	defer offline.Close()
	if _, err := QueryFritzBox(ctx, offline.Client(), offline.URL); err == nil {
		t.Fatal("WAN down accepted")
	}
}

type fakeAllowlist struct {
	exists bool
	values []string
	calls  []string
}

func (f *fakeAllowlist) Values(context.Context) ([]string, bool, error) {
	return append([]string{}, f.values...), f.exists, nil
}
func (f *fakeAllowlist) Create(context.Context) error {
	f.exists = true
	f.calls = append(f.calls, "create")
	return nil
}
func (f *fakeAllowlist) Add(_ context.Context, vs []string, _ string) error {
	f.values = append(f.values, vs...)
	f.calls = append(f.calls, "add "+strings.Join(vs, " "))
	return nil
}
func (f *fakeAllowlist) Remove(_ context.Context, vs []string) error {
	var keep []string
	for _, v := range f.values {
		if !contains(vs, v) {
			keep = append(keep, v)
		}
	}
	f.values = keep
	f.calls = append(f.calls, "remove "+strings.Join(vs, " "))
	return nil
}

func TestSync(t *testing.T) {
	ctx := context.Background()
	now := time.Now()
	al := &fakeAllowlist{}
	h := Home{IPv4: "85.193.174.52", IPv6Prefix: "2a03:c100:f902:9700::/56"}
	ch, err := Sync(ctx, al, h, now)
	if err != nil || strings.Join(al.calls, "|") != "create|add 85.193.174.52 2a03:c100:f902:9700::/56" || len(ch.Added) != 2 {
		t.Fatalf("first sync: %v %v %+v", err, al.calls, ch)
	}
	al.calls = nil
	if ch, err := Sync(ctx, al, h, now); err != nil || !ch.Empty() || len(al.calls) != 0 {
		t.Fatalf("no-op sync: %v %v %+v", err, al.calls, ch)
	}
	// New IPv4, IPv6 gone: add before remove.
	ch, err = Sync(ctx, al, Home{IPv4: "85.193.174.99"}, now)
	if err != nil || strings.Join(al.calls, "|") != "add 85.193.174.99|remove 2a03:c100:f902:9700::/56 85.193.174.52" {
		t.Fatalf("change: %v %v", err, al.calls)
	}
	if ch.String() != "+ 85.193.174.99\n- 2a03:c100:f902:9700::/56\n- 85.193.174.52" {
		t.Errorf("change text: %q", ch.String())
	}
	// Invalid answer: nothing touched.
	al.calls = nil
	if _, err := Sync(ctx, al, Home{IPv4: "10.0.0.1"}, now); err == nil || len(al.calls) != 0 {
		t.Fatalf("invalid accepted: %v %v", err, al.calls)
	}
}

func TestWriteMetrics(t *testing.T) {
	p := filepath.Join(t.TempDir(), "m.prom")
	if err := WriteMetrics(p, true, time.Unix(1700000000, 0), Home{IPv4: "85.193.174.52", IPv6Prefix: "2a03:c100:f902:9700::/56"}); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(p)
	for _, want := range []string{
		"homelab_home_ip_sync_success 1\n",
		"homelab_home_ip_last_sync_timestamp_seconds 1700000000\n",
		`homelab_home_ip_allowlisted_info{family="ipv4",value="85.193.174.52"} 1`,
		`homelab_home_ip_allowlisted_info{family="ipv6",value="2a03:c100:f902:9700::/56"} 1`,
	} {
		if !strings.Contains(string(data), want) {
			t.Errorf("metrics lack %q:\n%s", want, data)
		}
	}
}
