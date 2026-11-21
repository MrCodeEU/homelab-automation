// Command ziti-tcp-proxy listens on local TCP ports and relays every
// connection to a Ziti service, as `ziti tunnel proxy` does, but closes a
// connection once no byte has moved either way for -idle (package
// tcpproxy). It replaces `ziti tunnel proxy` in the m2m sidecars: when the
// nuc-mljr link dropped, a circuit could vanish without the proxy closing
// the client side, and CrowdSec's LAPI client hung on it for hours.
//
//	ziti-tcp-proxy -identity FILE [-idle 5m] [-dial-timeout 15s] SERVICE:PORT...
//
// Each SERVICE:PORT listens on 0.0.0.0:PORT (inside the sidecar's network
// namespace; the compose file decides what is published). SDK flow control
// stays at the SDK default (off), unlike `ziti tunnel`, which turns it on.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/openziti/sdk-golang/ziti"

	"github.com/MrCodeEU/homelab-automation/tools/internal/tcpproxy"
)

type target struct {
	service string
	port    int
}

func parseTargets(args []string) ([]target, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("no SERVICE:PORT given")
	}
	var out []target
	seen := map[int]bool{}
	for _, a := range args {
		svc, p, ok := strings.Cut(a, ":")
		port, err := strconv.Atoi(p)
		if !ok || svc == "" || err != nil || port < 1 || port > 65535 {
			return nil, fmt.Errorf("%q: want SERVICE:PORT", a)
		}
		if seen[port] {
			return nil, fmt.Errorf("port %d given twice", port)
		}
		seen[port] = true
		out = append(out, target{service: svc, port: port})
	}
	return out, nil
}

func main() {
	identity := flag.String("identity", "", "enrolled Ziti identity file")
	idle := flag.Duration("idle", 5*time.Minute, "close a connection after this long with no traffic either way")
	dialTimeout := flag.Duration("dial-timeout", 15*time.Second, "timeout for dialing the Ziti service")
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	targets, err := parseTargets(flag.Args())
	if err != nil || *identity == "" {
		if err == nil {
			err = fmt.Errorf("-identity is required")
		}
		fmt.Fprintln(os.Stderr, "ziti-tcp-proxy:", err)
		flag.Usage()
		os.Exit(2)
	}

	zctx, err := ziti.NewContextFromFile(*identity)
	if err != nil {
		log.Error("load identity", "file", *identity, "err", err)
		os.Exit(1)
	}
	defer zctx.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var wg sync.WaitGroup
	for _, t := range targets {
		ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", t.port))
		if err != nil {
			log.Error("listen", "service", t.service, "port", t.port, "err", err)
			os.Exit(1)
		}
		dial := func(context.Context) (net.Conn, error) {
			return zctx.DialWithOptions(t.service, &ziti.DialOptions{ConnectTimeout: *dialTimeout})
		}
		log.Info("listening", "service", t.service, "port", t.port, "idle", idle.String())
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := tcpproxy.Serve(ctx, ln, t.service, dial, *dialTimeout, *idle, log); err != nil {
				log.Error("serve", "service", t.service, "err", err)
				stop()
			}
		}()
	}
	wg.Wait()
}
