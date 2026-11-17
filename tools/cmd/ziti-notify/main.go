// Command ziti-notify follows the OpenZiti controller's event log on mljr
// and posts short, named ntfy messages (package zitinotify): enrolments,
// configuration changes, failed logins, and services whose circuits keep
// failing. Grafana keeps the alerts that must work with the controller down.
//
// Environment:
//
//	ZITI_NOTIFY_EVENTS     default /opt/ziti-controller/data/events.log
//	ZITI_NOTIFY_API        default https://127.0.0.1:8440/edge/management/v1
//	ZITI_NOTIFY_ROOT_CA    default /opt/ziti-controller/data/pki/root/certs/root.cert
//	ZITI_NOTIFY_ENV_FILE   default /opt/ziti-controller/.env; only
//	                       ZITI_ADMIN_PASSWORD is read from it
//	ZITI_NOTIFY_NTFY_URL   default https://ntfy.mljr.eu/homelab-security
//	ZITI_NOTIFY_DRY_RUN    "1": log messages instead of sending them
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/MrCodeEU/homelab-automation/tools/internal/zitinotify"
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// adminPassword reads one key from the controller's .env, so the rest of
// that file (OpenTofu state key) never enters this process.
func adminPassword(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(strings.TrimSpace(sc.Text()), "ZITI_ADMIN_PASSWORD="); ok {
			return strings.Trim(v, `"'`), nil
		}
	}
	return "", fmt.Errorf("%s: no ZITI_ADMIN_PASSWORD", path)
}

func main() {
	if err := run(); err != nil {
		slog.Error("ziti-notify", "err", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pw, err := adminPassword(envOr("ZITI_NOTIFY_ENV_FILE", "/opt/ziti-controller/.env"))
	if err != nil {
		return err
	}
	rootPEM, err := os.ReadFile(envOr("ZITI_NOTIFY_ROOT_CA", "/opt/ziti-controller/data/pki/root/certs/root.cert"))
	if err != nil {
		return err
	}
	dir, err := zitinotify.NewDirectory(envOr("ZITI_NOTIFY_API", "https://127.0.0.1:8440/edge/management/v1"), "admin", pw, rootPEM)
	if err != nil {
		return err
	}
	if err := dir.Refresh(ctx); err != nil {
		// Not fatal: messages fall back to ids until the controller answers.
		slog.Warn("initial name load", "err", err)
	}

	ntfy := zitinotify.Ntfy{URL: envOr("ZITI_NOTIFY_NTFY_URL", "https://ntfy.mljr.eu/homelab-security")}
	dry := os.Getenv("ZITI_NOTIFY_DRY_RUN") == "1"
	send := func(m zitinotify.Message) {
		if dry {
			slog.Info("message", "title", m.Title, "priority", m.Priority, "body", m.Body)
			return
		}
		for attempt := 1; attempt <= 3; attempt++ {
			if err := ntfy.Send(ctx, m); err == nil {
				return
			} else if attempt == 3 {
				slog.Error("send", "title", m.Title, "err", err)
			}
			time.Sleep(time.Duration(attempt) * 5 * time.Second)
		}
	}

	lines := make(chan []byte, 1024)
	path := envOr("ZITI_NOTIFY_EVENTS", "/opt/ziti-controller/data/events.log")
	errc := make(chan error, 1)
	go func() { errc <- zitinotify.Follow(ctx, path, 2*time.Second, lines) }()
	slog.Info("following", "path", path, "dry_run", dry)

	eng := zitinotify.New(dir, zitinotify.Settings{})
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-errc:
			return err
		case line := <-lines:
			var ev zitinotify.Event
			if err := json.Unmarshal(line, &ev); err != nil {
				continue
			}
			eng.Handle(ev)
		case now := <-tick.C:
			for _, m := range eng.Tick(now) {
				send(m)
			}
		}
	}
}
