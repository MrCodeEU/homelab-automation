// canary-gen creates Canarytokens against the homelab's self-hosted
// instance (roles::canarytokens, mljr) and, for file-based token types,
// downloads the decoy artifact. The frontend/create API only listens on
// mljr's loopback (see roles::canarytokens' own header comment on why -
// it's an infrequent admin action, not worth a public/Tailscale vhost),
// so this always runs against an SSH tunnel:
//
//	ssh -L 8101:localhost:8101 mljr.tail33930.ts.net
//	canary-gen -type web -memo "nas-fotos-share-bait" -email you@example.com
//
// Every created token's trigger value (URL and/or downloaded file) and
// its auth_token (needed to edit/delete the token later) are written to
// -out-dir as JSON - not committed anywhere, this is a local staging
// area for the next step (deciding per-host placement, then wiring the
// real values into OpenVox hiera/decoy files).
//
// Endpoint path is intentionally the app's own fixed, unguessable
// mount point (thinkst/canarytokens' ROOT_API_ENDPOINT,
// "/d3aece8093b71007b5ccfedad91ebb11") - not a real secret, just how
// the upstream app itself is wired, kept identical here rather than
// reverse-proxied to something shorter.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const apiRoot = "/d3aece8093b71007b5ccfedad91ebb11"

// Token types with a real HTTP/file trigger surface, reachable through
// the switchboard HTTP channel this instance actually publishes (no
// DNS/SMTP channel) - see roles::canarytokens' own scope note. AWS_KEYS
// is deliberately excluded: it needs thinkst's own private AWS ID
// infrastructure (CANARY_AWSID_URL/AUTH), which this self-hosted
// instance has no access to - token creation for that type fails
// server-side.
var fileFormats = map[string]string{
	"ms_word":   "msword",
	"ms_excel":  "msexcel",
	"adobe_pdf": "pdf",
	"qr_code":   "qr_code",
	"svg":       "svg",
}

var linkOnlyTypes = map[string]bool{
	"web":           true,
	"fast_redirect": true,
	"slow_redirect": true,
}

type generateResponse struct {
	Token     string `json:"token"`
	AuthToken string `json:"auth_token"`
	TokenURL  string `json:"token_url"`
	Hostname  string `json:"hostname"`
	Error     string `json:"error"`
}

type record struct {
	CreatedAt time.Time `json:"created_at"`
	TokenType string    `json:"token_type"`
	Memo      string    `json:"memo"`
	Token     string    `json:"token"`
	AuthToken string    `json:"auth_token"`
	TokenURL  string    `json:"token_url,omitempty"`
	DecoyFile string    `json:"decoy_file,omitempty"`
}

func main() {
	baseURL := flag.String("base-url", "http://localhost:8101", "canarytokens frontend base URL (via SSH tunnel, see package doc)")
	tokenType := flag.String("type", "", "token type: web, fast_redirect, slow_redirect, ms_word, ms_excel, adobe_pdf, qr_code, svg")
	memo := flag.String("memo", "", "reminder note shown when this token fires - also used as the output filename stem")
	email := flag.String("email", "", "alert destination email (mutually exclusive with -webhook-url; one is required)")
	webhookURL := flag.String("webhook-url", "", "alert destination webhook (mutually exclusive with -email)")
	redirectURL := flag.String("redirect-url", "", "required for fast_redirect/slow_redirect: where the visitor lands after triggering")
	outDir := flag.String("out-dir", "./canary-out", "local directory for the created token's JSON record and any downloaded decoy file")
	insecure := flag.Bool("insecure", false, "skip TLS verification (only relevant if -base-url is https)")
	flag.Parse()

	if *tokenType == "" || *memo == "" {
		fmt.Fprintln(os.Stderr, "usage: canary-gen -type <type> -memo <text> [-email addr | -webhook-url url] [-redirect-url url] [-out-dir dir]")
		flag.PrintDefaults()
		os.Exit(2)
	}
	if _, linkOnly := linkOnlyTypes[*tokenType]; !linkOnly {
		if _, fileType := fileFormats[*tokenType]; !fileType {
			fmt.Fprintf(os.Stderr, "unknown or unsupported -type %q (supported: web, fast_redirect, slow_redirect, ms_word, ms_excel, adobe_pdf, qr_code, svg)\n", *tokenType)
			os.Exit(2)
		}
	}
	if *tokenType == "fast_redirect" || *tokenType == "slow_redirect" {
		if *redirectURL == "" {
			fmt.Fprintln(os.Stderr, "-redirect-url is required for fast_redirect/slow_redirect")
			os.Exit(2)
		}
	}
	if *email == "" && *webhookURL == "" {
		fmt.Fprintln(os.Stderr, "one of -email or -webhook-url is required")
		os.Exit(2)
	}

	client := &http.Client{Timeout: 30 * time.Second}
	_ = insecure // reserved: base-url is loopback-only today, no TLS to skip

	body := map[string]any{
		"token_type": *tokenType,
		"memo":       *memo,
	}
	if *email != "" {
		body["email"] = *email
	}
	if *webhookURL != "" {
		body["webhook_url"] = *webhookURL
	}
	if *redirectURL != "" {
		body["redirect_url"] = *redirectURL
	}

	resp, err := postJSON(client, *baseURL+apiRoot+"/generate", body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create token: %v\n", err)
		os.Exit(1)
	}
	if resp.Error != "" || resp.Token == "" {
		fmt.Fprintf(os.Stderr, "server rejected token request: %s\n", resp.Error)
		os.Exit(1)
	}

	if err := os.MkdirAll(*outDir, 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "create out-dir: %v\n", err)
		os.Exit(1)
	}

	rec := record{
		CreatedAt: time.Now(),
		TokenType: *tokenType,
		Memo:      *memo,
		Token:     resp.Token,
		AuthToken: resp.AuthToken,
		TokenURL:  resp.TokenURL,
	}

	if fmt_, ok := fileFormats[*tokenType]; ok {
		filename, content, err := download(client, *baseURL, fmt_, resp.Token, resp.AuthToken)
		if err != nil {
			fmt.Fprintf(os.Stderr, "download decoy file: %v\n", err)
			os.Exit(1)
		}
		decoyPath := filepath.Join(*outDir, slugify(*memo)+"-"+filename)
		if err := os.WriteFile(decoyPath, content, 0o600); err != nil {
			fmt.Fprintf(os.Stderr, "save decoy file: %v\n", err)
			os.Exit(1)
		}
		rec.DecoyFile = decoyPath
		fmt.Printf("decoy file saved: %s\n", decoyPath)
	}

	recordPath := filepath.Join(*outDir, slugify(*memo)+".json")
	recordJSON, _ := json.MarshalIndent(rec, "", "  ")
	if err := os.WriteFile(recordPath, recordJSON, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "save record: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("token created: %s\n", rec.Token)
	if rec.TokenURL != "" {
		fmt.Printf("trigger URL:   %s\n", rec.TokenURL)
	}
	fmt.Printf("record saved:  %s (includes auth_token - keep private, needed to edit/delete this token)\n", recordPath)
}

func postJSON(client *http.Client, url string, body map[string]any) (*generateResponse, error) {
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(data))
	}
	var out generateResponse
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("decode response: %w (body: %s)", err, string(data))
	}
	return &out, nil
}

func download(client *http.Client, baseURL, fmtParam, token, auth string) (filename string, content []byte, err error) {
	url := fmt.Sprintf("%s%s/download?fmt=%s&token=%s&auth=%s", baseURL, apiRoot, fmtParam, token, auth)
	resp, err := client.Get(url)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close()
	content, err = io.ReadAll(resp.Body)
	if err != nil {
		return "", nil, err
	}
	if resp.StatusCode >= 400 {
		return "", nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(content))
	}
	filename = "decoy"
	if cd := resp.Header.Get("Content-Disposition"); cd != "" {
		if _, params, err := mime.ParseMediaType(cd); err == nil && params["filename"] != "" {
			filename = params["filename"]
		}
	}
	return filename, content, nil
}

var slugRe = regexp.MustCompile(`[^a-z0-9]+`)

func slugify(s string) string {
	s = strings.ToLower(s)
	s = slugRe.ReplaceAllString(s, "-")
	return strings.Trim(s, "-")
}
