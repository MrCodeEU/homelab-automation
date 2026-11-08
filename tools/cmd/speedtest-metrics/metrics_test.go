package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 11, 8, 20, 0, 0, 0, time.UTC)

func TestRenderSuccess(t *testing.T) {
	r := Result{
		ServerID: "1234", ServerName: `Vienna "AT"`, Sponsor: "Magenta", Country: "Austria",
		DownloadBps: 250e6, UploadBps: 40e6,
		Latency: 12 * time.Millisecond, Jitter: 1500 * time.Microsecond,
		Duration: 25 * time.Second,
	}
	got := render("nuc", r, now)
	labels := `host="nuc",server_id="1234",server_name="Vienna \"AT\"",sponsor="Magenta",country="Austria"`
	want := strings.Join([]string{
		`speedtest_up{host="nuc"} 1 1794168000000`,
		`speedtest_duration_seconds{host="nuc"} 25 1794168000000`,
		`speedtest_last_run_timestamp_seconds{host="nuc"} 1.794168e+09 1794168000000`,
		`speedtest_download_bits_per_second{` + labels + `} 2.5e+08 1794168000000`,
		`speedtest_upload_bits_per_second{` + labels + `} 4e+07 1794168000000`,
		`speedtest_latency_seconds{` + labels + `} 0.012 1794168000000`,
		`speedtest_jitter_seconds{` + labels + `} 0.0015 1794168000000`,
	}, "\n") + "\n"
	if got != want {
		t.Errorf("render:\n got: %s\nwant: %s", got, want)
	}
}

func TestRenderFailureHasNoMeasurements(t *testing.T) {
	got := render("nuc", Result{Err: errors.New("boom"), Duration: 3 * time.Second}, now)
	if !strings.Contains(got, `speedtest_up{host="nuc"} 0 `) {
		t.Errorf("want speedtest_up 0, got:\n%s", got)
	}
	if strings.Contains(got, "bits_per_second") || strings.Contains(got, "latency") {
		t.Errorf("failure must not report measurements, got:\n%s", got)
	}
}

func TestPush(t *testing.T) {
	var gotPath, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	if err := push(context.Background(), srv.URL+"/", "x 1\n"); err != nil {
		t.Fatal(err)
	}
	if gotPath != "/api/v1/import/prometheus" || gotBody != "x 1\n" {
		t.Errorf("got %s %q", gotPath, gotBody)
	}
}

func TestPushError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "cannot parse", http.StatusBadRequest)
	}))
	defer srv.Close()
	err := push(context.Background(), srv.URL, "x 1\n")
	if err == nil || !strings.Contains(err.Error(), "cannot parse") {
		t.Fatalf("want error with body, got %v", err)
	}
}

func TestParseIperfTargets(t *testing.T) {
	got, err := parseIperfTargets(" mljr=127.0.0.1:15201, ugreen=127.0.0.1:15202,")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != (IperfTarget{"mljr", "127.0.0.1:15201"}) || got[1].Name != "ugreen" {
		t.Errorf("got %+v", got)
	}
	if ts, err := parseIperfTargets(""); err != nil || len(ts) != 0 {
		t.Errorf("empty: %v %v", ts, err)
	}
	if _, err := parseIperfTargets("mljr"); err == nil {
		t.Error("want error without =host:port")
	}
}

func TestParseIperf(t *testing.T) {
	bps, rt, err := parseIperf([]byte(`{"start":{},"end":{"sum_sent":{"bits_per_second":9e8,"retransmits":12},"sum_received":{"bits_per_second":8.8e8}}}`))
	if err != nil || bps != 8.8e8 || rt != 12 {
		t.Errorf("got %g %g %v", bps, rt, err)
	}
	if _, _, err := parseIperf([]byte(`{"start":{},"end":{},"error":"the server is busy running a test. try again later"}`)); err == nil || !strings.Contains(err.Error(), "busy") {
		t.Errorf("want server error, got %v", err)
	}
	if _, _, err := parseIperf([]byte(`not json`)); err == nil {
		t.Error("want parse error")
	}
}

func TestRenderIperf(t *testing.T) {
	got := renderIperf([]IperfResult{
		{Src: "nuc", Dst: "mljr", Bps: 1.5e8, Retransmits: 3},
		{Src: "mljr", Dst: "nuc", Err: errors.New("timeout")},
	}, now)
	want := strings.Join([]string{
		`iperf_up{src="nuc",dst="mljr",path="ziti"} 1 1794168000000`,
		`iperf_bits_per_second{src="nuc",dst="mljr",path="ziti"} 1.5e+08 1794168000000`,
		`iperf_retransmits{src="nuc",dst="mljr",path="ziti"} 3 1794168000000`,
		`iperf_up{src="mljr",dst="nuc",path="ziti"} 0 1794168000000`,
		`iperf_last_run_timestamp_seconds 1.794168e+09 1794168000000`,
	}, "\n") + "\n"
	if got != want {
		t.Errorf("renderIperf:\n got: %s\nwant: %s", got, want)
	}
}
