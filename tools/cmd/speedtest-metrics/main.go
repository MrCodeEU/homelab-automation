// speedtest-metrics runs an internet speedtest (Ookla servers, via the
// MIT-licensed speedtest-go library, no proprietary CLI) at a fixed
// interval and writes the result to VictoriaMetrics' Prometheus import API.
// It replaces netronome's speedtests: netronome found its agents only over
// Tailscale and could be configured only in its web UI, and its host
// metrics duplicate Alloy's (docs/ZERO_TRUST_PLAN.md, Phase 4).
//
// Runs on nuc next to VictoriaMetrics (services/speedtest-metrics), so the
// push stays on the host. Environment:
//
//	SPEEDTEST_VM_URL     VictoriaMetrics base URL (default http://127.0.0.1:19090)
//	SPEEDTEST_INTERVAL   time between tests (default 1h)
//	SPEEDTEST_SERVER_ID  Ookla server id; empty picks the lowest-latency server
//	SPEEDTEST_HOST       value of the host label (default nuc)
//
// --once runs one test, prints the metrics and pushes them, then exits.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/showwin/speedtest-go/speedtest"
)

// One test (server list, ping, download, upload) must finish within this.
const testTimeout = 3 * time.Minute

func main() {
	once := len(os.Args) > 1 && os.Args[1] == "--once"

	vmURL := envOr("SPEEDTEST_VM_URL", "http://127.0.0.1:19090")
	host := envOr("SPEEDTEST_HOST", "nuc")
	interval, err := time.ParseDuration(envOr("SPEEDTEST_INTERVAL", "1h"))
	if err != nil || interval < 10*time.Minute {
		fatal(fmt.Errorf("SPEEDTEST_INTERVAL must be a duration of at least 10m: %q", os.Getenv("SPEEDTEST_INTERVAL")))
	}
	var serverIDs []int
	if v := os.Getenv("SPEEDTEST_SERVER_ID"); v != "" {
		id, err := strconv.Atoi(v)
		if err != nil {
			fatal(fmt.Errorf("SPEEDTEST_SERVER_ID: %w", err))
		}
		serverIDs = []int{id}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	run := func() {
		r := measure(ctx, serverIDs)
		body := render(host, r, time.Now())
		if once {
			fmt.Print(body)
		}
		if err := push(ctx, vmURL, body); err != nil {
			slog.Error("push to VictoriaMetrics failed", "err", err)
			return
		}
		if r.Err != nil {
			slog.Warn("speedtest failed", "err", r.Err, "duration", r.Duration.Round(time.Second))
			return
		}
		slog.Info("speedtest done", "server", r.ServerName, "server_id", r.ServerID,
			"down_mbps", fmt.Sprintf("%.1f", r.DownloadBps/1e6), "up_mbps", fmt.Sprintf("%.1f", r.UploadBps/1e6),
			"latency", r.Latency, "duration", r.Duration.Round(time.Second))
	}

	run()
	if once {
		return
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			run()
		}
	}
}

// measure runs one full test. A failure is returned in Result.Err, so it
// is still reported (speedtest_up 0) instead of leaving a silent gap.
func measure(parent context.Context, serverIDs []int) Result {
	start := time.Now()
	ctx, cancel := context.WithTimeout(parent, testTimeout)
	defer cancel()

	r := Result{}
	err := func() error {
		client := speedtest.New()
		servers, err := client.FetchServerListContext(ctx)
		if err != nil {
			return fmt.Errorf("fetch servers: %w", err)
		}
		targets, err := servers.FindServer(serverIDs)
		if err != nil {
			return fmt.Errorf("find server: %w", err)
		}
		if len(targets) == 0 {
			return errors.New("no server")
		}
		s := targets[0]
		r.ServerID, r.ServerName, r.Sponsor, r.Country = s.ID, s.Name, s.Sponsor, s.Country
		if err := s.PingTestContext(ctx, nil); err != nil {
			return fmt.Errorf("ping: %w", err)
		}
		if err := s.DownloadTestContext(ctx); err != nil {
			return fmt.Errorf("download: %w", err)
		}
		if err := s.UploadTestContext(ctx); err != nil {
			return fmt.Errorf("upload: %w", err)
		}
		// ByteRate is bytes per second
		r.DownloadBps = float64(s.DLSpeed) * 8
		r.UploadBps = float64(s.ULSpeed) * 8
		r.Latency = s.Latency
		r.Jitter = s.Jitter
		s.Context.Reset()
		return nil
	}()
	r.Err = err
	r.Duration = time.Since(start)
	return r
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func fatal(err error) {
	slog.Error(err.Error())
	os.Exit(1)
}
