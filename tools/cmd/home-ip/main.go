// Command home-ip keeps CrowdSec's "home" allowlist on mljr current with the
// home connection's public addresses (package homeip):
//
//	home-ip serve   on nuc: GET /v1/home-ip answers what the FRITZ!Box reports
//	home-ip sync    on mljr: one sync from that answer (systemd timer)
//
// serve environment:
//
//	HOME_IP_LISTEN    default 127.0.0.1:19480 (bound as Ziti service home-ip-nuc)
//	HOME_IP_FRITZBOX  default http://192.168.50.1:49000
//
// sync environment:
//
//	HOME_IP_SOURCE    default http://127.0.0.1:19480/v1/home-ip (mljr's ziti-proxy)
//	HOME_IP_CSCLI     default "docker exec crowdsec cscli"
//	HOME_IP_ALLOWLIST default home
//	HOME_IP_STATE     default /var/lib/home-ip/state.json
//	HOME_IP_METRICS   default /var/lib/node-textfile/homelab_home_ip.prom
//	HOME_IP_NTFY_URL  ntfy topic URL notified on every allowlist change; empty: off
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/MrCodeEU/homelab-automation/tools/internal/homeip"
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: home-ip serve|sync")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "serve":
		serve()
	case "sync":
		if err := runSync(); err != nil {
			slog.Error("sync", "err", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, "usage: home-ip serve|sync")
		os.Exit(2)
	}
}

func serve() {
	fritz := envOr("HOME_IP_FRITZBOX", "http://192.168.50.1:49000")
	client := &http.Client{Timeout: 10 * time.Second}
	// The sync polls every few minutes; a short cache keeps retries and
	// manual curls off the router.
	var (
		mu      sync.Mutex
		cached  homeip.Home
		fetched time.Time
	)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/home-ip", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if time.Since(fetched) > 30*time.Second {
			h, err := homeip.QueryFritzBox(r.Context(), client, fritz)
			if err != nil {
				slog.Error("fritzbox", "err", err)
				http.Error(w, err.Error(), http.StatusServiceUnavailable)
				return
			}
			cached, fetched = h, time.Now()
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(cached)
	})
	srv := &http.Server{
		Addr: envOr("HOME_IP_LISTEN", "127.0.0.1:19480"), Handler: mux,
		ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 30 * time.Second,
	}
	slog.Info("serving", "addr", srv.Addr, "fritzbox", fritz)
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("serve", "err", err)
		os.Exit(1)
	}
}

// state is what sync keeps between runs: the last successful result, so a
// failed run still reports what the allowlist holds.
type state struct {
	LastSuccess time.Time   `json:"last_success"`
	Home        homeip.Home `json:"home"`
}

func runSync() error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	statePath := envOr("HOME_IP_STATE", "/var/lib/home-ip/state.json")
	metrics := envOr("HOME_IP_METRICS", "/var/lib/node-textfile/homelab_home_ip.prom")
	var st state
	if data, err := os.ReadFile(statePath); err == nil {
		json.Unmarshal(data, &st)
	}
	al := homeip.Cscli{
		Command: strings.Fields(envOr("HOME_IP_CSCLI", "docker exec crowdsec cscli")),
		Name:    envOr("HOME_IP_ALLOWLIST", "home"),
	}

	client := &http.Client{Timeout: 30 * time.Second}
	h, err := homeip.Fetch(ctx, client, envOr("HOME_IP_SOURCE", "http://127.0.0.1:19480/v1/home-ip"))
	var ch homeip.Change
	if err == nil {
		ch, err = homeip.Sync(ctx, al, h, time.Now())
	}
	if err != nil {
		// The allowlist keeps its entries: a failed fetch is no reason to
		// unlist the owner.
		if merr := homeip.WriteMetrics(metrics, false, st.LastSuccess, st.Home); merr != nil {
			slog.Error("metrics", "err", merr)
		}
		return err
	}
	st = state{LastSuccess: time.Now(), Home: h}
	data, _ := json.Marshal(st)
	if err := os.WriteFile(statePath, data, 0o600); err != nil {
		return err
	}
	if err := homeip.WriteMetrics(metrics, true, st.LastSuccess, h); err != nil {
		slog.Error("metrics", "err", err)
	}
	if ch.Empty() {
		slog.Info("allowlist current", "values", strings.Join(h.Values(), " "))
		return nil
	}
	slog.Info("allowlist changed", "change", strings.ReplaceAll(ch.String(), "\n", ", "))
	if u := os.Getenv("HOME_IP_NTFY_URL"); u != "" {
		return notify(ctx, client, u, ch)
	}
	return nil
}

// notify reports a change: a new home IP is expected after a router or
// provider change, and suspicious otherwise.
func notify(ctx context.Context, c *http.Client, url string, ch homeip.Change) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url,
		strings.NewReader("CrowdSec allowlist \"home\" on mljr:\n"+ch.String()))
	if err != nil {
		return err
	}
	req.Header.Set("Title", "Home IP changed")
	req.Header.Set("Tags", "house")
	resp, err := c.Do(req)
	if err != nil {
		return fmt.Errorf("ntfy: %w", err)
	}
	resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy: HTTP %d", resp.StatusCode)
	}
	return nil
}
