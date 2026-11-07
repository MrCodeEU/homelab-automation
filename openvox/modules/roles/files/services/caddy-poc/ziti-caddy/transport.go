package ziti_caddy

import (
	"context"
	"fmt"
	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp/reverseproxy"
	"github.com/openziti/sdk-golang/ziti"
	"net"
	"net/http"
	"sync"
	"time"

	"go.uber.org/zap"
)

var zitiContexts = ziti.NewSdkCollection()

func init() {
	zitiContexts.ConfigTypes = append(zitiContexts.ConfigTypes, ziti.InterceptV1, ziti.ClientConfigV1)

	caddy.RegisterModule(new(ZitiTransport))
	caddy.RegisterNetwork("ziti", newZitiListener)
}

// ZitiTransport implements reverse proxy that connects to a Ziti service
type ZitiTransport struct {

	// Identity is a Ziti identity file
	Identity string `json:"identity,omitempty"`

	// Service is Ziti service proxy will connect to
	Service string `json:"service,omitempty"`

	// Terminator is a specific service terminator proxy will connect to
	Terminator string `json:"terminator,omitempty"`

	ztx   ziti.Context
	caddy caddy.Context
	proxy *reverseproxy.HTTPTransport

	// Lazy login: Provision never waits for the controller, so Caddy starts
	// (and serves every other site) while the controller is unreachable.
	// connect() logs in in the background; dials wait for it, bounded by
	// the dial's own context.
	mu    sync.Mutex
	ready chan struct{}
	done  chan struct{}
}

func (z *ZitiTransport) Cleanup() error {
	var err error
	if z.done != nil {
		close(z.done)
		z.done = nil
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.ztx != nil {
		zitiContexts.Remove(z.ztx)
		z.ztx.Close()
		z.ztx = nil
	}

	if z.proxy != nil {
		err = z.proxy.Cleanup()
		z.proxy = nil
	}
	return err
}

func (z *ZitiTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return z.proxy.RoundTrip(request)
}

func (z *ZitiTransport) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {

	if !d.Next() {
		return fmt.Errorf("missing ziti transport configuration")
	}

	for d.NextBlock(0) {
		switch d.Val() {
		case "identity":
			d.Args(&z.Identity)
		case "service":
			d.Args(&z.Service)
		case "terminator":
			d.Args(&z.Terminator)
		default:
			return fmt.Errorf("unsupported configuration option `%s`", d.Val())
		}
	}
	return nil
}

// CaddyModule returns the Caddy module information.
func (*ZitiTransport) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID: "http.reverse_proxy.transport.ziti",
		New: func() caddy.Module {
			return new(ZitiTransport)
		},
	}
}

func (z *ZitiTransport) Provision(ctx caddy.Context) error {
	log := ctx.Logger(z)
	log.Info("ZitiTransport is loading")

	z.caddy = ctx

	// default proxy roundTripper
	ctr := new(reverseproxy.HTTPTransport)
	err := ctr.Provision(z.caddy)
	if err != nil {
		return err
	}

	// Fail fast on a missing or broken identity file: that is a config
	// error, not an outage.
	if _, err = ziti.NewConfigFromFile(z.Identity); err != nil {
		return err
	}

	z.ready = make(chan struct{})
	z.done = make(chan struct{})
	go z.connect(log, z.ready, z.done)

	if z.Service != "" {
		options := &ziti.DialOptions{
			ConnectTimeout: time.Duration(ctr.DialTimeout),
			Identity:       z.Terminator,
		}
		ctr.Transport.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
			ztx, err := z.context(ctx, time.Duration(ctr.DialTimeout))
			if err != nil {
				return nil, err
			}
			return ztx.DialWithOptions(z.Service, options)
		}
	} else {
		ctr.Transport.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
			ztx, err := z.context(ctx, time.Duration(ctr.DialTimeout))
			if err != nil {
				return nil, err
			}
			return ztx.DialAddr(network, addr)
		}
	}

	z.proxy = ctr

	return err
}

// connect logs in until it succeeds or the transport is cleaned up.
func (z *ZitiTransport) connect(log *zap.Logger, ready, done chan struct{}) {
	opts := &ziti.Options{
		RefreshInterval: 30 * time.Second,
	}
	for {
		ztx, err := zitiContexts.NewContextFromFileWithOpts(z.Identity, opts)
		if err == nil {
			if err = ztx.Authenticate(); err != nil {
				zitiContexts.Remove(ztx)
				ztx.Close()
			}
		}
		if err == nil {
			z.mu.Lock()
			select {
			case <-done:
				z.mu.Unlock()
				zitiContexts.Remove(ztx)
				ztx.Close()
				return
			default:
			}
			z.ztx = ztx
			z.mu.Unlock()
			close(ready)
			log.Info("ziti login done")
			return
		}
		log.Warn("ziti login failed, retrying in 5s", zap.Error(err))
		select {
		case <-done:
			return
		case <-time.After(5 * time.Second):
		}
	}
}

// context waits for the login, at most as long as the dial may take
// (dial_timeout, 3s by default), so an unreachable controller gives a quick
// 502 instead of a request hanging until the client gives up.
func (z *ZitiTransport) context(ctx context.Context, timeout time.Duration) (ziti.Context, error) {
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	select {
	case <-z.ready:
	case <-ctx.Done():
		return nil, fmt.Errorf("ziti: not logged in to the controller yet: %w", ctx.Err())
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.ztx == nil {
		return nil, fmt.Errorf("ziti: transport closed")
	}
	return z.ztx, nil
}

var (
	_ caddyfile.Unmarshaler = (*ZitiTransport)(nil)
	_ http.RoundTripper     = (*ZitiTransport)(nil)
	_ caddy.CleanerUpper    = (*ZitiTransport)(nil)
)
