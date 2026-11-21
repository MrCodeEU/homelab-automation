// Command ziti-renew renews the certificates of this host's Ziti identity
// files before they expire (package zitirenew) and reports every watched
// certificate's expiry for Alloy's textfile collector. Run daily by
// roles::ziti_renew's timer.
//
//	ziti-renew [-config FILE] [-days N] [-metrics FILE] [-renew PATH]
//
// The config has one entry per line, "<path> [restart command ...]":
//
//	/etc/caddy/ziti/caddy-mljr.json systemctl reload caddy
//	/opt/ziti-proxy/data/m2m-mljr.json docker restart ziti-proxy
//	/opt/ziti-router/data/mljr.cert
//
// A .json identity with less than -days left is renewed, then the restart
// command (run by sh -c) makes its service load the new file. Any other path
// is a PEM certificate that is only watched (the routers renew their own).
// -renew renews that one identity now, whatever its expiry. Exit status 1
// when a renewal, restart or read failed.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/MrCodeEU/homelab-automation/tools/internal/zitirenew"
)

type entry struct {
	path, restart string
}

func readConfig(path string) ([]entry, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []entry
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		p, restart, _ := strings.Cut(line, " ")
		out = append(out, entry{path: p, restart: strings.TrimSpace(restart)})
	}
	return out, sc.Err()
}

func name(path string) string {
	return strings.TrimSuffix(strings.TrimSuffix(filepath.Base(path), ".json"), ".cert")
}

func expiry(path string) (time.Time, error) {
	if strings.HasSuffix(path, ".json") {
		id, err := zitirenew.Load(path)
		if err != nil {
			return time.Time{}, err
		}
		return id.Cert.NotAfter, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}, err
	}
	c, err := zitirenew.LeafCert(data)
	if err != nil {
		return time.Time{}, fmt.Errorf("%s: %w", path, err)
	}
	return c.NotAfter, nil
}

func main() {
	config := flag.String("config", "/etc/ziti-renew/identities.conf", "watched files, one per line")
	days := flag.Int("days", 60, "renew identities with fewer days left")
	metrics := flag.String("metrics", "/var/lib/node-textfile/ziti_identity.prom", "textfile collector output")
	force := flag.String("renew", "", "renew this identity now")
	flag.Parse()

	entries, err := readConfig(*config)
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	var b strings.Builder
	failed := false
	for _, e := range entries {
		n := name(e.path)
		bad := 0
		notAfter, err := expiry(e.path)
		renewable := strings.HasSuffix(e.path, ".json")
		due := err == nil && renewable && (time.Until(notAfter) < time.Duration(*days)*24*time.Hour || e.path == *force)
		switch {
		case err != nil:
			slog.Error("read", "file", e.path, "err", err)
			bad = 1
		case due:
			slog.Info("renewing", "file", e.path, "not_after", notAfter)
			leaf, rerr := zitirenew.Renew(ctx, e.path)
			if leaf != nil {
				notAfter = leaf.NotAfter
			}
			if rerr != nil {
				slog.Error("renew", "file", e.path, "err", rerr)
				bad = 1
			}
			if leaf != nil && e.restart != "" {
				out, xerr := exec.CommandContext(ctx, "/bin/sh", "-c", e.restart).CombinedOutput()
				if xerr != nil {
					slog.Error("restart", "file", e.path, "cmd", e.restart, "err", xerr, "out", strings.TrimSpace(string(out)))
					bad = 1
				}
			}
			if bad == 0 {
				slog.Info("renewed", "file", e.path, "not_after", notAfter)
			}
		}
		if bad == 1 {
			failed = true
		}
		if !notAfter.IsZero() {
			fmt.Fprintf(&b, "ziti_identity_cert_expiry_timestamp_seconds{name=%q,file=%q} %d\n", n, e.path, notAfter.Unix())
		}
		fmt.Fprintf(&b, "ziti_identity_renew_failed{name=%q,file=%q} %d\n", n, e.path, bad)
	}
	fmt.Fprintf(&b, "ziti_identity_renew_last_run_timestamp_seconds %d\n", time.Now().Unix())
	if *metrics != "" {
		tmp := *metrics + ".tmp"
		if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err == nil {
			err = os.Rename(tmp, *metrics)
		}
		if err != nil {
			slog.Error("metrics", "err", err)
			failed = true
		}
	}
	if failed {
		os.Exit(1)
	}
}
