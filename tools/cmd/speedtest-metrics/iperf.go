package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// IperfTarget is one iperf3 server, reached through the Ziti proxy.
type IperfTarget struct {
	Name string // host label of the server, e.g. mljr
	Addr string // host:port of the proxy listener
}

// IperfResult of one direction of one test. Rate is bits per second at
// the receiver.
type IperfResult struct {
	Src, Dst    string
	Bps         float64
	Retransmits float64
	Err         error
}

// One iperf3 run (-t 10 plus connection setup) must finish within this.
const iperfTimeout = 45 * time.Second

// parseIperfTargets reads "mljr=127.0.0.1:15201,ugreen=127.0.0.1:15202".
func parseIperfTargets(s string) ([]IperfTarget, error) {
	var ts []IperfTarget
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, addr, ok := strings.Cut(part, "=")
		if !ok || name == "" || !strings.Contains(addr, ":") {
			return nil, fmt.Errorf("iperf target %q: want name=host:port", part)
		}
		ts = append(ts, IperfTarget{Name: name, Addr: addr})
	}
	return ts, nil
}

// iperfAll tests every target in both directions, one run at a time:
// iperf3 servers take one test at a time, and parallel runs would share
// nuc's uplink.
func iperfAll(ctx context.Context, self string, targets []IperfTarget) []IperfResult {
	var rs []IperfResult
	for _, t := range targets {
		for _, reverse := range []bool{false, true} {
			r := IperfResult{Src: self, Dst: t.Name}
			if reverse {
				r.Src, r.Dst = t.Name, self
			}
			out, err := runIperf(ctx, t.Addr, reverse)
			if err == nil {
				r.Bps, r.Retransmits, err = parseIperf(out)
			}
			r.Err = err
			rs = append(rs, r)
		}
	}
	return rs
}

func runIperf(parent context.Context, addr string, reverse bool) ([]byte, error) {
	ctx, cancel := context.WithTimeout(parent, iperfTimeout)
	defer cancel()
	host, port, _ := strings.Cut(addr, ":")
	args := []string{"-c", host, "-p", port, "-t", "10", "-J"}
	if reverse {
		args = append(args, "-R")
	}
	// iperf3 exits non-zero on failure but still prints JSON with "error";
	// parseIperf reports that message, which says more than the exit code.
	out, err := exec.CommandContext(ctx, "iperf3", args...).Output()
	if len(out) == 0 && err != nil {
		return nil, fmt.Errorf("iperf3: %w", err)
	}
	return out, nil
}

// parseIperf returns the receiver's rate and the sender's retransmits from
// iperf3 -J output.
func parseIperf(out []byte) (bps, retransmits float64, err error) {
	var v struct {
		Error string `json:"error"`
		End   struct {
			SumSent struct {
				Retransmits float64 `json:"retransmits"`
			} `json:"sum_sent"`
			SumReceived struct {
				BitsPerSecond float64 `json:"bits_per_second"`
			} `json:"sum_received"`
		} `json:"end"`
	}
	if err := json.Unmarshal(out, &v); err != nil {
		return 0, 0, fmt.Errorf("iperf3 output: %w", err)
	}
	if v.Error != "" {
		return 0, 0, errors.New(v.Error)
	}
	if v.End.SumReceived.BitsPerSecond <= 0 {
		return 0, 0, errors.New("iperf3 reported no throughput")
	}
	return v.End.SumReceived.BitsPerSecond, v.End.SumSent.Retransmits, nil
}

// renderIperf formats rs like render: iperf_up per direction always, the
// rate and retransmits only for a successful run.
func renderIperf(rs []IperfResult, now time.Time) string {
	ts := now.UnixMilli()
	var b strings.Builder
	for _, r := range rs {
		labels := fmt.Sprintf(`src="%s",dst="%s",path="ziti"`, escape(r.Src), escape(r.Dst))
		up := 1.0
		if r.Err != nil {
			up = 0
		}
		fmt.Fprintf(&b, "iperf_up{%s} %g %d\n", labels, up, ts)
		if r.Err != nil {
			continue
		}
		fmt.Fprintf(&b, "iperf_bits_per_second{%s} %g %d\n", labels, r.Bps, ts)
		fmt.Fprintf(&b, "iperf_retransmits{%s} %g %d\n", labels, r.Retransmits, ts)
	}
	fmt.Fprintf(&b, "iperf_last_run_timestamp_seconds %g %d\n", float64(now.Unix()), ts)
	return b.String()
}
