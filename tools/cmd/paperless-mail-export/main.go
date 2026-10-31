// paperless-mail-export copies useful mail attachments out of mail-archiver
// (via its read-only REST API v1) into an outbox directory that a host job
// then rsyncs into paperless' consume dir on nas.
//
//	paperless-mail-export --mode incremental   # daily: recent mail only
//	paperless-mail-export --mode sweep         # weekly / first backfill: every mail
//
// The API has no inline-attachment flag, so noise is filtered by type, size,
// filename patterns and a sha256 dedupe (a signature logo is exported once at
// most). State (mails done, content hashes seen, watermark) makes every run
// idempotent: re-running, or catching up after weeks of failed runs, simply
// continues. The watermark only advances after a run with no errors, and the
// sweep mode ignores it entirely, so late-arriving or later-imported mail is
// always picked up within a week.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/mail"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type account struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// apiTime reads mail-archiver timestamps, which carry no timezone
// ("2026-10-31T16:30:16", taken as UTC). Mails with a missing or bogus date
// (the API returns 0001-01-01 for some) become the zero time.
type apiTime struct{ time.Time }

func (t *apiTime) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "null" || s == "" {
		return nil
	}
	var v time.Time
	var err error
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02T15:04:05.999999999", "2006-01-02"} {
		if v, err = time.Parse(layout, s); err == nil {
			break
		}
	}
	if err != nil {
		return err
	}
	if v.Year() < 1990 {
		v = time.Time{}
	}
	t.Time = v
	return nil
}

type emailSummary struct {
	ID             int     `json:"id"`
	AccountID      int     `json:"accountId"`
	Subject        string  `json:"subject"`
	From           string  `json:"from"`
	SentDate       apiTime `json:"sentDate"`
	HasAttachments bool    `json:"hasAttachments"`
}

type attachment struct {
	ID          int    `json:"id"`
	FileName    string `json:"fileName"`
	ContentType string `json:"contentType"`
	Size        int64  `json:"size"`
}

type emailDetail struct {
	emailSummary
	Attachments []attachment `json:"attachments"`
}

type page struct {
	Items      []emailSummary `json:"items"`
	Page       int            `json:"page"`
	TotalPages int            `json:"totalPages"`
}

// State is persisted as JSON between runs.
type State struct {
	Watermark time.Time           `json:"watermark"`
	Done      map[int]bool        `json:"done"` // mails fully processed (had attachments)
	Seen      map[string]struct{} `json:"seen"` // sha256 of exported content
}

func loadState(path string) (*State, error) {
	s := &State{Done: map[int]bool{}, Seen: map[string]struct{}{}}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, s); err != nil {
		return nil, fmt.Errorf("parse state %s: %w", path, err)
	}
	if s.Done == nil {
		s.Done = map[int]bool{}
	}
	if s.Seen == nil {
		s.Seen = map[string]struct{}{}
	}
	return s, nil
}

func (s *State) save(path string) error {
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ---- filtering ------------------------------------------------------------

var (
	docExts   = map[string]bool{".pdf": true, ".doc": true, ".docx": true, ".odt": true, ".ppt": true, ".pptx": true, ".xls": true, ".xlsx": true}
	imageExts = map[string]bool{".tif": true, ".tiff": true, ".jpg": true, ".jpeg": true, ".png": true, ".heic": true}
	// Mail-client generated inline images and signature art.
	noiseName = regexp.MustCompile(`(?i)^(image\d*|outlook-[a-z0-9]+|unnamed|logo[\w-]*|signature[\w-]*|spacer|pixel|~wrd\d+|att\d+)\.(png|jpe?g|gif|heic)$`)
)

// wanted reports whether an attachment is worth sending to paperless.
// Automated bulk senders (newsletters, system mail): their images are banners
// and tracking pixels, never documents. PDFs and Office files are still kept,
// invoices come from exactly these senders.
var (
	bulkSender = regexp.MustCompile(`(?i)(^|[.@_-])(no-?reply|do-?not-?reply|newsletter|news|mailer|marketing|bounce)([.@_-]|$)`)
	bannerName = regexp.MustCompile(`(?i)(banner|header|footer|qr-?code|modul\d|flyer|aktion|^ic_|sponsor|newsletter)`)
)

// errLocked marks a mail whose password-protected PDF no known password
// opens. The mail is not marked done, so a later run retries it once the
// password has been added to the secret.
var errLocked = errors.New("password-protected PDF, no known password")

// parsePasswords splits the vault_pdf_passwords secret: one password per line.
// The .env file cannot hold newlines, so the template joins the lines with a
// literal backslash-n, which is accepted here as well.
func parsePasswords(raw string) []string {
	var out []string
	for _, l := range strings.Split(strings.ReplaceAll(raw, `\n`, "\n"), "\n") {
		if l = strings.TrimRight(l, "\r"); l != "" {
			out = append(out, l)
		}
	}
	return out
}

const (
	pdfPlain    = "plain"
	pdfUnlocked = "unlocked"
	pdfLocked   = "locked"
)

// unlock is swapped out in tests that have no qpdf.
var unlock = unlockPDF

// unlockPDF removes the password from an encrypted PDF in place. PDFs that
// need no password (or when qpdf is missing) are left untouched.
func unlockPDF(path string, passwords []string) string {
	if _, err := exec.LookPath("qpdf"); err != nil {
		return pdfPlain
	}
	// exit 0: a password is required; 2: not encrypted; 3: encrypted, none needed.
	if exec.Command("qpdf", "--requires-password", path).Run() != nil {
		return pdfPlain
	}
	dir := filepath.Dir(path)
	for _, pw := range passwords {
		pf, err := os.CreateTemp(dir, ".pw-*")
		if err != nil {
			return pdfLocked
		}
		// A password file keeps the secret off the process list.
		_, werr := pf.WriteString(pw)
		pf.Close()
		out := path + ".dec"
		var runErr error
		if werr == nil {
			runErr = exec.Command("qpdf", "--password-file="+pf.Name(), "--decrypt", path, out).Run()
		}
		os.Remove(pf.Name())
		// exit 3 means success with warnings.
		var ee *exec.ExitError
		if runErr == nil || (errors.As(runErr, &ee) && ee.ExitCode() == 3) {
			if os.Rename(out, path) == nil {
				return pdfUnlocked
			}
		}
		os.Remove(out)
	}
	return pdfLocked
}

func wanted(a attachment, from string, minImage, minDoc int64) bool {
	ext := strings.ToLower(filepath.Ext(a.FileName))
	switch {
	case docExts[ext]:
		return a.Size >= minDoc
	case imageExts[ext]:
		if a.Size < minImage || noiseName.MatchString(a.FileName) || bannerName.MatchString(a.FileName) {
			return false
		}
		addr := from
		if m, err := mail.ParseAddress(from); err == nil {
			addr = m.Address
		}
		return !bulkSender.MatchString(addr)
	}
	return false
}

var unsafeChars = regexp.MustCompile(`[^\p{L}\p{N}._ -]+`)

func clean(s string, max int) string {
	s = strings.TrimSpace(unsafeChars.ReplaceAllString(s, "_"))
	s = strings.Trim(s, "._ ")
	if r := []rune(s); len(r) > max {
		s = string(r[:max])
	}
	if s == "" {
		return "unknown"
	}
	return s
}

func senderOf(from string) string {
	if a, err := mail.ParseAddress(from); err == nil {
		if a.Name != "" {
			return clean(a.Name, 40)
		}
		return clean(a.Address, 40)
	}
	return clean(from, 40)
}

// outName builds Mail/<Account>/<date>_<sender>_<file>. The folders become
// the tags "Mail" and the account name in paperless.
func outName(acct string, sent time.Time, from, file, sha string, exists func(string) bool) string {
	ext := filepath.Ext(file)
	base := clean(strings.TrimSuffix(file, ext), 80)
	ext = strings.ToLower(clean(ext, 8))
	if ext != "" && !strings.HasPrefix(ext, ".") {
		ext = "." + ext
	}
	dir := filepath.Join("Mail", clean(acct, 40))
	day := "undated"
	if !sent.IsZero() {
		day = sent.UTC().Format("2006-01-02")
	}
	name := fmt.Sprintf("%s_%s_%s%s", day, senderOf(from), base, ext)
	p := filepath.Join(dir, name)
	if exists(p) {
		p = filepath.Join(dir, fmt.Sprintf("%s_%s_%s-%s%s", day, senderOf(from), base, sha[:8], ext))
	}
	return p
}

// ---- API client -----------------------------------------------------------

type client struct {
	base   string
	key    string
	http   *http.Client
	tick   *time.Ticker
	sleep  func(time.Duration)
	retrys int
}

func newClient(base, key string, perMinute int) *client {
	return &client{
		base:   strings.TrimRight(base, "/"),
		key:    key,
		http:   &http.Client{Timeout: 120 * time.Second},
		tick:   time.NewTicker(time.Minute / time.Duration(perMinute)),
		sleep:  time.Sleep,
		retrys: 5,
	}
}

// get performs a rate-limited GET, retrying 429 and 5xx with backoff. The
// caller must close the body.
func (c *client) get(ctx context.Context, path string, q url.Values) (*http.Response, error) {
	u := c.base + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	var lastErr error
	for attempt := 0; attempt <= c.retrys; attempt++ {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-c.tick.C:
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		req.Header.Set("Authorization", "Bearer "+c.key)
		resp, err := c.http.Do(req)
		if err == nil && resp.StatusCode < 400 {
			return resp, nil
		}
		wait := time.Duration(attempt+1) * 5 * time.Second
		if err != nil {
			lastErr = err
		} else {
			lastErr = fmt.Errorf("GET %s: %s", path, resp.Status)
			if resp.StatusCode == http.StatusTooManyRequests {
				if s, e := strconv.Atoi(resp.Header.Get("Retry-After")); e == nil {
					wait = time.Duration(s) * time.Second
				}
			}
			retryable := resp.StatusCode == 429 || resp.StatusCode >= 500
			resp.Body.Close()
			if !retryable {
				return nil, lastErr
			}
		}
		c.sleep(wait)
	}
	return nil, lastErr
}

func (c *client) getJSON(ctx context.Context, path string, q url.Values, out any) error {
	resp, err := c.get(ctx, path, q)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(out)
}

// ---- run ------------------------------------------------------------------

type config struct {
	passwords        []string
	mode             string
	out, statePath   string
	minImage, minDoc int64
	overlap          time.Duration
	pageSize         int
	saveEvery        int
}

type result struct {
	scanned, processed, exported, deduped, skipped, failed, locked int
}

func run(ctx context.Context, c *client, cfg config, st *State, logf func(string, ...any)) (result, error) {
	var res result
	var accts []account
	if err := c.getJSON(ctx, "/api/v1/accounts", nil, &accts); err != nil {
		return res, fmt.Errorf("accounts: %w", err)
	}
	names := map[int]string{}
	for _, a := range accts {
		names[a.ID] = a.Name
	}

	q := url.Values{"sortBy": {"sentDate"}, "sortOrder": {"asc"}, "pageSize": {strconv.Itoa(cfg.pageSize)}}
	if cfg.mode == "incremental" && !st.Watermark.IsZero() {
		q.Set("from", st.Watermark.Add(-cfg.overlap).UTC().Format("2006-01-02"))
	}
	var maxSent time.Time
	sinceSave := 0
	for pg := 1; ; pg++ {
		q.Set("page", strconv.Itoa(pg))
		var p page
		if err := c.getJSON(ctx, "/api/v1/emails", q, &p); err != nil {
			return res, fmt.Errorf("list page %d: %w", pg, err)
		}
		for _, e := range p.Items {
			res.scanned++
			if !e.HasAttachments || st.Done[e.ID] {
				continue
			}
			n, d, s, err := processMail(ctx, c, cfg, st, e, names[e.AccountID])
			res.exported += n
			res.deduped += d
			res.skipped += s
			if errors.Is(err, errLocked) {
				// Not a failure: retried by later runs, needs a password.
				res.locked++
				logf("mail %d (%s): %v", e.ID, e.SentDate.Format("2006-01-02"), err)
				continue
			}
			if err != nil {
				res.failed++
				logf("mail %d (%s): %v", e.ID, e.SentDate.Format("2006-01-02"), err)
				continue
			}
			res.processed++
			st.Done[e.ID] = true
			if e.SentDate.After(maxSent) {
				maxSent = e.SentDate.Time
			}
			if sinceSave++; sinceSave >= cfg.saveEvery {
				if err := st.save(cfg.statePath); err != nil {
					return res, err
				}
				sinceSave = 0
			}
		}
		if len(p.Items) == 0 || pg >= p.TotalPages {
			break
		}
		if pg%25 == 0 {
			logf("page %d/%d: %d mails scanned, %d exported", pg, p.TotalPages, res.scanned, res.exported)
		}
	}
	// Advance only on a clean run: a failed mail must be retried next time
	// and an incremental run starts at the watermark minus the overlap.
	if res.failed == 0 && maxSent.After(st.Watermark) {
		st.Watermark = maxSent
	}
	return res, st.save(cfg.statePath)
}

func processMail(ctx context.Context, c *client, cfg config, st *State, e emailSummary, acct string) (exported, deduped, skipped int, err error) {
	var d emailDetail
	if err := c.getJSON(ctx, fmt.Sprintf("/api/v1/emails/%d", e.ID), nil, &d); err != nil {
		return 0, 0, 0, err
	}
	locked := 0
	for _, a := range d.Attachments {
		if !wanted(a, e.From, cfg.minImage, cfg.minDoc) {
			skipped++
			continue
		}
		resp, err := c.get(ctx, fmt.Sprintf("/api/v1/emails/%d/attachments/%d", e.ID, a.ID), nil)
		if err != nil {
			return exported, deduped, skipped, err
		}
		tmp, err := os.CreateTemp(cfg.out, ".dl-*")
		if err != nil {
			resp.Body.Close()
			return exported, deduped, skipped, err
		}
		h := sha256.New()
		_, cpErr := io.Copy(io.MultiWriter(tmp, h), resp.Body)
		resp.Body.Close()
		tmp.Close()
		if cpErr != nil {
			os.Remove(tmp.Name())
			return exported, deduped, skipped, cpErr
		}
		sha := hex.EncodeToString(h.Sum(nil))
		if _, dup := st.Seen[sha]; dup {
			os.Remove(tmp.Name())
			deduped++
			continue
		}
		if strings.EqualFold(filepath.Ext(a.FileName), ".pdf") {
			switch unlock(tmp.Name(), cfg.passwords) {
			case pdfLocked:
				// Held back, not remembered in Seen: the file is fetched again
				// on the next run, when the password may be known.
				os.Remove(tmp.Name())
				locked++
				continue
			}
		}
		rel := outName(acct, e.SentDate.Time, e.From, a.FileName, sha, func(p string) bool {
			_, statErr := os.Stat(filepath.Join(cfg.out, p))
			return statErr == nil
		})
		dst := filepath.Join(cfg.out, rel)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			os.Remove(tmp.Name())
			return exported, deduped, skipped, err
		}
		if err := os.Rename(tmp.Name(), dst); err != nil {
			os.Remove(tmp.Name())
			return exported, deduped, skipped, err
		}
		// paperless falls back to the file mtime as the created date.
		if !e.SentDate.IsZero() {
			_ = os.Chtimes(dst, e.SentDate.Time, e.SentDate.Time)
		}
		_ = os.Chmod(dst, 0o644)
		st.Seen[sha] = struct{}{}
		exported++
	}
	if locked > 0 {
		return exported, deduped, skipped, fmt.Errorf("%d file(s): %w", locked, errLocked)
	}
	return exported, deduped, skipped, nil
}

func main() {
	var cfg config
	api := flag.String("api", "http://100.100.10.1:5000", "mail-archiver base URL")
	rate := flag.Int("rate", 100, "max API requests per minute (server limit is 120)")
	flag.StringVar(&cfg.mode, "mode", "incremental", "incremental | sweep")
	flag.StringVar(&cfg.out, "out", "/outbox", "outbox directory")
	flag.StringVar(&cfg.statePath, "state", "/state/state.json", "state file")
	flag.Int64Var(&cfg.minImage, "min-image", 20000, "minimum image size in bytes")
	flag.Int64Var(&cfg.minDoc, "min-doc", 2000, "minimum pdf/office size in bytes")
	flag.DurationVar(&cfg.overlap, "overlap", 7*24*time.Hour, "incremental lookback before the watermark")
	flag.IntVar(&cfg.pageSize, "page-size", 100, "API page size (server max 100)")
	flag.IntVar(&cfg.saveEvery, "save-every", 50, "persist state every N processed mails")
	flag.Parse()
	cfg.passwords = parsePasswords(os.Getenv("PDF_PASSWORDS"))
	if cfg.mode != "incremental" && cfg.mode != "sweep" {
		log.Fatalf("--mode must be incremental or sweep, got %q", cfg.mode)
	}
	key := os.Getenv("MAILARCHIVER_API_KEY")
	if key == "" {
		log.Fatal("MAILARCHIVER_API_KEY is not set")
	}
	st, err := loadState(cfg.statePath)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(cfg.out, 0o755); err != nil {
		log.Fatal(err)
	}
	start := time.Now()
	res, err := run(context.Background(), newClient(*api, key, *rate), cfg, st, log.Printf)
	log.Printf("mode=%s scanned=%d processed=%d exported=%d deduped=%d skipped=%d locked=%d failed=%d in %s",
		cfg.mode, res.scanned, res.processed, res.exported, res.deduped, res.skipped, res.locked, res.failed, time.Since(start).Round(time.Second))
	if err != nil {
		log.Fatal(err)
	}
	if res.failed > 0 {
		os.Exit(1)
	}
}
