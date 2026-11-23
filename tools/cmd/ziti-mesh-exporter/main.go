// Command ziti-mesh-exporter serves the state of the Ziti overlay (routers,
// links, identities, terminators, circuits) as Prometheus metrics for the
// Grafana dashboard "Ziti mesh" (package zitimesh). It runs on mljr next to
// the controller and reads the management and fabric APIs on the admin
// listener as the read-only identity mesh-exporter.
//
// Environment:
//
//	MESH_IDENTITY     identity file (default /identity/mesh-exporter.json)
//	MESH_API          admin listener (default https://127.0.0.1:8440)
//	MESH_SERVER_NAME  name in the listener's certificate (default localhost)
//	MESH_LISTEN       metrics listener (default 127.0.0.1:9479)
//
// `ziti-mesh-exporter healthcheck` asks the running exporter's /healthz and
// exits 0 if it answers (the container's HEALTHCHECK; the image has no curl).
//
// A scrape reads the controller at most every 15 s (results are cached), so
// two scrapers do not double the load. A failed read serves the last good
// state with ziti_mesh_read_success 0, so the map does not blink empty.
package main

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/MrCodeEU/homelab-automation/tools/internal/zitimesh"
	"github.com/MrCodeEU/homelab-automation/tools/internal/zitirenew"
)

const cacheFor = 15 * time.Second

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

type exporter struct {
	client *zitimesh.Client
	path   string // identity file, reloaded when it changes (renewal)
	name   string
	mtime  time.Time

	mu      sync.Mutex
	at      time.Time
	last    []byte // last good state, rendered
	ok      bool
	elapsed time.Duration
}

// reloadIdentity swaps the TLS client when ziti-renew rewrote the file.
func (e *exporter) reloadIdentity() error {
	st, err := os.Stat(e.path)
	if err != nil {
		return err
	}
	if e.client != nil && st.ModTime().Equal(e.mtime) {
		return nil
	}
	id, err := zitirenew.Load(e.path)
	if err != nil {
		return err
	}
	c, err := id.HTTPClient(e.name)
	if err != nil {
		return err
	}
	base := env("MESH_API", "https://127.0.0.1:8440")
	e.client = &zitimesh.Client{HTTP: c, Base: base}
	e.mtime = st.ModTime()
	slog.Info("identity loaded", "file", e.path, "expires", id.Cert.NotAfter.Format(time.DateOnly))
	return nil
}

func (e *exporter) refresh(ctx context.Context) {
	start := time.Now()
	err := e.reloadIdentity()
	var st *zitimesh.State
	if err == nil {
		st, err = e.client.Read(ctx)
	}
	var buf bytes.Buffer
	if err == nil {
		err = st.Render(&buf)
	}
	e.at, e.elapsed, e.ok = time.Now(), time.Since(start), err == nil
	if err != nil {
		slog.Error("read failed", "err", err)
		return
	}
	e.last = buf.Bytes()
}

func (e *exporter) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if time.Since(e.at) >= cacheFor {
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		e.refresh(ctx)
		cancel()
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write(e.last)
	ok := 0
	if e.ok {
		ok = 1
	}
	fmt.Fprintf(w, "# HELP ziti_mesh_read_success 1 if the last read of the controller succeeded.\n# TYPE ziti_mesh_read_success gauge\nziti_mesh_read_success %d\n", ok)
	fmt.Fprintf(w, "# HELP ziti_mesh_read_duration_seconds Duration of the last read.\n# TYPE ziti_mesh_read_duration_seconds gauge\nziti_mesh_read_duration_seconds %g\n", e.elapsed.Seconds())
}

func main() {
	listen := env("MESH_LISTEN", "127.0.0.1:9479")
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		c := &http.Client{Timeout: 3 * time.Second}
		resp, err := c.Get("http://" + listen + "/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	e := &exporter{
		path: env("MESH_IDENTITY", "/identity/mesh-exporter.json"),
		name: env("MESH_SERVER_NAME", "localhost"),
	}
	if err := e.reloadIdentity(); err != nil {
		slog.Error("identity", "err", err)
		os.Exit(1)
	}
	mux := http.NewServeMux()
	mux.Handle("/metrics", e)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	slog.Info("listening", "addr", listen)
	srv := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("listen", "err", err)
		os.Exit(1)
	}
}
