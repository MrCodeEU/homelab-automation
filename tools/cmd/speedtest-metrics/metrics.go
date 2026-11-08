package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Result of one speedtest. Rates are bits per second.
type Result struct {
	ServerID, ServerName, Sponsor, Country string

	DownloadBps, UploadBps float64
	Latency, Jitter        time.Duration
	Duration               time.Duration
	Err                    error
}

// render formats r in the Prometheus text format, every sample stamped with
// now (milliseconds), for VictoriaMetrics' /api/v1/import/prometheus.
// speedtest_up, the duration and the run timestamp are always written; the
// measurements only for a successful test.
func render(host string, r Result, now time.Time) string {
	ts := now.UnixMilli()
	base := fmt.Sprintf(`host="%s"`, escape(host))
	var b strings.Builder
	sample := func(name, labels string, v float64) {
		fmt.Fprintf(&b, "%s{%s} %g %d\n", name, labels, v, ts)
	}

	up := 1.0
	if r.Err != nil {
		up = 0
	}
	sample("speedtest_up", base, up)
	sample("speedtest_duration_seconds", base, r.Duration.Seconds())
	sample("speedtest_last_run_timestamp_seconds", base, float64(now.Unix()))
	if r.Err != nil {
		return b.String()
	}

	server := fmt.Sprintf(`%s,server_id="%s",server_name="%s",sponsor="%s",country="%s"`,
		base, escape(r.ServerID), escape(r.ServerName), escape(r.Sponsor), escape(r.Country))
	sample("speedtest_download_bits_per_second", server, r.DownloadBps)
	sample("speedtest_upload_bits_per_second", server, r.UploadBps)
	sample("speedtest_latency_seconds", server, r.Latency.Seconds())
	sample("speedtest_jitter_seconds", server, r.Jitter.Seconds())
	return b.String()
}

// escape a Prometheus label value.
func escape(s string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(s)
}

// push posts body to VictoriaMetrics' Prometheus import endpoint.
func push(ctx context.Context, baseURL, body string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimRight(baseURL, "/")+"/api/v1/import/prometheus", bytes.NewBufferString(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	return nil
}
