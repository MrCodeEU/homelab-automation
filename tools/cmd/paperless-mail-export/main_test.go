package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestWanted(t *testing.T) {
	cases := []struct {
		name string
		size int64
		want bool
	}{
		{"Rechnung.pdf", 5000, true},
		{"tiny.pdf", 500, false},
		{"scan.JPG", 150000, true},
		{"photo.jpg", 5000, false},
		{"image001.png", 90000, false},
		{"Outlook-abc123.png", 90000, false},
		{"logo-firma.png", 90000, false},
		{"Lohnzettel.docx", 40000, true},
		{"winmail.dat", 90000, false},
		{"report.html", 90000, false},
		{"dmarc.xml.gz", 90000, false},
		{"invite.ics", 3000, false},
	}
	for _, c := range cases {
		if got := wanted(attachment{FileName: c.name, Size: c.size}, 20000, 2000); got != c.want {
			t.Errorf("%s (%d bytes): got %v, want %v", c.name, c.size, got, c.want)
		}
	}
}

func TestAPITime(t *testing.T) {
	var e emailSummary
	if err := json.Unmarshal([]byte(`{"sentDate":"2026-10-31T16:30:16"}`), &e); err != nil {
		t.Fatal(err)
	}
	if !e.SentDate.Equal(time.Date(2026, 10, 31, 16, 30, 16, 0, time.UTC)) {
		t.Fatalf("naive timestamp: %v", e.SentDate)
	}
	if err := json.Unmarshal([]byte(`{"sentDate":"0001-01-01T01:05:00"}`), &e); err != nil || !e.SentDate.IsZero() {
		t.Fatalf("bogus date should be zero: %v %v", e.SentDate, err)
	}
	if err := json.Unmarshal([]byte(`{"sentDate":"2024-01-10T08:00:00Z"}`), &e); err != nil || e.SentDate.IsZero() {
		t.Fatalf("RFC3339: %v %v", e.SentDate, err)
	}
	if got := outName("Gmail", time.Time{}, "a@b.at", "x.pdf", "abcdef1234", func(string) bool { return false }); !strings.Contains(got, "undated_") {
		t.Fatalf("undated name %q", got)
	}
}

func TestOutName(t *testing.T) {
	sent := time.Date(2024, 3, 5, 10, 0, 0, 0, time.UTC)
	none := func(string) bool { return false }
	got := outName("Gmail", sent, `"Müller, Hans" <h@firma.at>`, "Rech/nung 03.pdf", "abcdef1234", none)
	want := filepath.Join("Mail", "Gmail", "2024-03-05_Müller_ Hans_Rech_nung 03.pdf")
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	taken := func(string) bool { return true }
	got = outName("Gmail", sent, "plain@firma.at", "a.pdf", "abcdef1234", taken)
	if !strings.HasSuffix(got, "-abcdef12.pdf") {
		t.Fatalf("collision name %q", got)
	}
}

type fake struct {
	t        *testing.T
	failMail int
	hits     atomic.Int32
	rateOnce atomic.Bool
}

func (f *fake) handler() http.Handler {
	mux := http.NewServeMux()
	auth := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer ma_test" {
				w.WriteHeader(401)
				return
			}
			f.hits.Add(1)
			h(w, r)
		}
	}
	js := func(w http.ResponseWriter, v any) { json.NewEncoder(w).Encode(v) }
	mux.HandleFunc("/api/v1/accounts", auth(func(w http.ResponseWriter, r *http.Request) {
		js(w, []account{{ID: 1, Name: "Gmail"}})
	}))
	mux.HandleFunc("/api/v1/emails", auth(func(w http.ResponseWriter, r *http.Request) {
		// Two mails with attachments on page 1, a mail without on page 2.
		pg := r.URL.Query().Get("page")
		d1 := time.Date(2024, 1, 10, 8, 0, 0, 0, time.UTC)
		d2 := time.Date(2024, 2, 11, 8, 0, 0, 0, time.UTC)
		d3 := time.Date(2024, 3, 12, 8, 0, 0, 0, time.UTC)
		if pg == "1" {
			js(w, page{Page: 1, TotalPages: 2, Items: []emailSummary{
				{ID: 10, AccountID: 1, From: "Bank <bank@x.at>", SentDate: apiTime{d1}, HasAttachments: true},
				{ID: 11, AccountID: 1, From: "hr@firma.at", SentDate: apiTime{d2}, HasAttachments: true},
			}})
			return
		}
		js(w, page{Page: 2, TotalPages: 2, Items: []emailSummary{{ID: 12, AccountID: 1, SentDate: apiTime{d3}}}})
	}))
	mux.HandleFunc("/api/v1/emails/10", auth(func(w http.ResponseWriter, r *http.Request) {
		js(w, emailDetail{Attachments: []attachment{
			{ID: 1, FileName: "Kontoauszug.pdf", Size: 6000},
			{ID: 2, FileName: "logo.png", Size: 90000},
		}})
	}))
	mux.HandleFunc("/api/v1/emails/11", auth(func(w http.ResponseWriter, r *http.Request) {
		if f.failMail == 11 {
			w.WriteHeader(500)
			return
		}
		js(w, emailDetail{Attachments: []attachment{{ID: 3, FileName: "Kopie.pdf", Size: 6000}}})
	}))
	mux.HandleFunc("/api/v1/emails/10/attachments/1", auth(func(w http.ResponseWriter, r *http.Request) {
		if f.rateOnce.CompareAndSwap(false, true) {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(429)
			return
		}
		fmt.Fprint(w, strings.Repeat("same-bytes ", 600))
	}))
	// Identical content to attachment 1 -> must be deduplicated.
	mux.HandleFunc("/api/v1/emails/11/attachments/3", auth(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, strings.Repeat("same-bytes ", 600))
	}))
	return mux
}

func testConfig(t *testing.T) config {
	dir := t.TempDir()
	return config{mode: "sweep", out: filepath.Join(dir, "out"), statePath: filepath.Join(dir, "state.json"),
		minImage: 20000, minDoc: 2000, overlap: 24 * time.Hour, pageSize: 100, saveEvery: 1}
}

func testClient(url string) *client {
	c := newClient(url, "ma_test", 6000)
	c.sleep = func(time.Duration) {}
	return c
}

func TestRunExportsFiltersAndDedupes(t *testing.T) {
	f := &fake{t: t}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	cfg := testConfig(t)
	os.MkdirAll(cfg.out, 0o755)
	st, _ := loadState(cfg.statePath)

	res, err := run(context.Background(), testClient(srv.URL), cfg, st, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if res.exported != 1 || res.deduped != 1 || res.skipped != 1 || res.failed != 0 {
		t.Fatalf("unexpected result %+v", res)
	}
	want := filepath.Join(cfg.out, "Mail", "Gmail", "2024-01-10_Bank_Kontoauszug.pdf")
	info, err := os.Stat(want)
	if err != nil {
		t.Fatalf("missing output: %v", err)
	}
	if !info.ModTime().Equal(time.Date(2024, 1, 10, 8, 0, 0, 0, time.UTC)) {
		t.Fatalf("mtime not set from mail date: %v", info.ModTime())
	}
	if !st.Watermark.Equal(time.Date(2024, 2, 11, 8, 0, 0, 0, time.UTC)) {
		t.Fatalf("watermark %v", st.Watermark)
	}

	// Second run: everything is done, no detail or download calls.
	before := f.hits.Load()
	st2, _ := loadState(cfg.statePath)
	res, err = run(context.Background(), testClient(srv.URL), cfg, st2, t.Logf)
	if err != nil || res.exported != 0 || res.processed != 0 {
		t.Fatalf("rerun not idempotent: %+v %v", res, err)
	}
	// accounts + 2 list pages only
	if got := f.hits.Load() - before; got != 3 {
		t.Fatalf("rerun made %d API calls, want 3", got)
	}
}

func TestFailedMailKeepsWatermarkAndRetries(t *testing.T) {
	f := &fake{t: t, failMail: 11}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()
	cfg := testConfig(t)
	os.MkdirAll(cfg.out, 0o755)
	st, _ := loadState(cfg.statePath)

	res, err := run(context.Background(), testClient(srv.URL), cfg, st, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if res.failed != 1 {
		t.Fatalf("want 1 failure, got %+v", res)
	}
	if !st.Watermark.IsZero() {
		t.Fatalf("watermark advanced despite failure: %v", st.Watermark)
	}
	if st.Done[11] || !st.Done[10] {
		t.Fatalf("done flags wrong: %v", st.Done)
	}

	// Server recovers: the failed mail is retried, the finished one is not.
	f.failMail = 0
	st2, _ := loadState(cfg.statePath)
	res, err = run(context.Background(), testClient(srv.URL), cfg, st2, t.Logf)
	if err != nil || res.failed != 0 || res.processed != 1 {
		t.Fatalf("retry run: %+v %v", res, err)
	}
	if st2.Watermark.IsZero() {
		t.Fatal("watermark should advance after a clean run")
	}
}

func TestBadKeyFails(t *testing.T) {
	srv := httptest.NewServer((&fake{t: t}).handler())
	defer srv.Close()
	cfg := testConfig(t)
	os.MkdirAll(cfg.out, 0o755)
	st, _ := loadState(cfg.statePath)
	c := newClient(srv.URL, "wrong", 6000)
	c.sleep = func(time.Duration) {}
	if _, err := run(context.Background(), c, cfg, st, t.Logf); err == nil {
		t.Fatal("expected an auth error")
	}
}
