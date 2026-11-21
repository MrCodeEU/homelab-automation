// Package tcpproxy relays accepted TCP connections to a dialed upstream
// (a Ziti service in ziti-tcp-proxy) and, unlike `ziti tunnel proxy`, never
// keeps a connection open forever.
//
// When the router drops a circuit without telling the SDK, the upstream
// never reads EOF; `ziti tunnel proxy` then holds the client's TCP
// connection open, and a client without its own timeout (CrowdSec's LAPI
// client) hangs on it for good. Relay closes both sides once no byte has
// moved in either direction for the idle timeout, so the client sees EOF
// and reconnects over a new circuit.
package tcpproxy

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// Dial opens the upstream for one client connection.
type Dial func(ctx context.Context) (net.Conn, error)

type closeWriter interface {
	CloseWrite() error
}

// activity is a Writer wrapper that stamps the time of every write.
type activity struct {
	w    io.Writer
	last *atomic.Int64
}

func (a activity) Write(p []byte) (int, error) {
	n, err := a.w.Write(p)
	if n > 0 {
		a.last.Store(time.Now().UnixNano())
	}
	return n, err
}

// Result is what one relayed connection did.
type Result struct {
	Sent, Received int64 // client to upstream, upstream to client
	Idle           bool  // closed by the idle timeout
}

// Relay copies between client and upstream until both directions end or
// nothing moves for idle. One direction ending half-closes the other side
// (CloseWrite) so request/response protocols that close to signal the end
// still work. Both connections are closed when Relay returns.
func Relay(client, upstream net.Conn, idle time.Duration) Result {
	var last atomic.Int64
	last.Store(time.Now().UnixNano())

	var res Result
	var wg sync.WaitGroup
	pipe := func(dst, src net.Conn, n *int64) {
		defer wg.Done()
		*n, _ = io.Copy(activity{w: dst, last: &last}, src)
		if cw, ok := dst.(closeWriter); ok {
			_ = cw.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	wg.Add(2)
	go pipe(upstream, client, &res.Sent)
	go pipe(client, upstream, &res.Received)

	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()

	tick := time.NewTicker(max(idle/4, 10*time.Millisecond))
	defer tick.Stop()
	for {
		select {
		case <-done:
			_ = client.Close()
			_ = upstream.Close()
			return res
		case <-tick.C:
			if time.Since(time.Unix(0, last.Load())) >= idle {
				res.Idle = true
				// Closing unblocks both copies; done follows.
				_ = client.Close()
				_ = upstream.Close()
			}
		}
	}
}

// Serve accepts connections on ln and relays each to dial until ctx ends.
func Serve(ctx context.Context, ln net.Listener, name string, dial Dial, dialTimeout, idle time.Duration, log *slog.Logger) error {
	go func() { <-ctx.Done(); _ = ln.Close() }()
	for {
		client, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			if errors.Is(err, net.ErrClosed) {
				return err
			}
			log.Warn("accept failed", "service", name, "err", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go func() {
			start := time.Now()
			dctx, cancel := context.WithTimeout(ctx, dialTimeout)
			upstream, err := dial(dctx)
			cancel()
			if err != nil {
				log.Warn("dial failed", "service", name, "client", client.RemoteAddr().String(), "err", err)
				_ = client.Close()
				return
			}
			res := Relay(client, upstream, idle)
			level := slog.LevelInfo
			if res.Idle {
				level = slog.LevelWarn
			}
			log.Log(ctx, level, "connection closed", "service", name, "sent", res.Sent, "received", res.Received,
				"idle_timeout", res.Idle, "duration", time.Since(start).Round(time.Millisecond).String())
		}()
	}
}
