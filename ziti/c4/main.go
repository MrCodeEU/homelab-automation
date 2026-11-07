// C4 (docs/ZERO_TRUST_PLAN.md): a GitHub Actions job dials a Ziti service
// with nothing but the job's own OIDC token. Run by
// .github/workflows/ziti-c4.yml only.
//
//  1. ask the Actions runtime for an ID token (audience ziti-homelab)
//  2. log in to the controller with it; the controller's ext-jwt signer
//     github-actions matches job_workflow_ref to identity ci-homelab-main
//  3. dial nuc-alloy and fetch Alloy's /metrics on nuc
//
// The controller is trusted through the overlay's root CA from the repo
// (ziti/pki/root-ca.crt), not trust on first use. The token is never
// printed.
package main

import (
	"bufio"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	edge_apis "github.com/openziti/sdk-golang/edge-apis"
	"github.com/openziti/sdk-golang/ziti"
)

const (
	controller = "https://ctrl.ziti.mljr.eu:8441"
	audience   = "ziti-homelab"
	service    = "nuc-alloy"
	rootCA     = "../pki/root-ca.crt"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "C4 FAILED:", err)
		os.Exit(1)
	}
}

func run() error {
	token, err := actionsToken()
	if err != nil {
		return fmt.Errorf("OIDC token: %w", err)
	}

	pem, err := os.ReadFile(rootCA)
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return errors.New("no certificate in " + rootCA)
	}

	creds := edge_apis.NewJwtCredentials(token)
	creds.CaPool = pool
	ctx, err := ziti.NewContext(&ziti.Config{
		ZtAPI:       controller + "/edge/client/v1",
		Credentials: creds,
	})
	if err != nil {
		return err
	}
	defer ctx.Close()

	start := time.Now()
	if err := ctx.Authenticate(); err != nil {
		return fmt.Errorf("authenticate: %w", err)
	}
	fmt.Printf("authenticated to %s in %s\n", controller, time.Since(start).Round(time.Millisecond))

	conn, err := ctx.Dial(service)
	if err != nil {
		return fmt.Errorf("dial %s: %w", service, err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))

	if _, err := fmt.Fprint(conn, "GET /metrics HTTP/1.0\r\nHost: alloy.nuc.int.mljr.eu\r\n\r\n"); err != nil {
		return err
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "alloy_build_info") {
			fmt.Printf("dialed %s over Ziti, HTTP %d, %d bytes:\n%s\n", service, resp.StatusCode, len(body), line)
			return nil
		}
	}
	return fmt.Errorf("HTTP %d from %s, no alloy_build_info", resp.StatusCode, service)
}

// actionsToken fetches the job's OIDC ID token (needs permissions:
// id-token: write).
func actionsToken() (string, error) {
	reqURL, reqToken := os.Getenv("ACTIONS_ID_TOKEN_REQUEST_URL"), os.Getenv("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
	if reqURL == "" || reqToken == "" {
		return "", errors.New("not in a GitHub Actions job with id-token: write")
	}
	req, err := http.NewRequest(http.MethodGet, reqURL+"&audience="+url.QueryEscape(audience), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+reqToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("token endpoint: HTTP %d", resp.StatusCode)
	}
	var out struct {
		Value string `json:"value"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if out.Value == "" {
		return "", errors.New("empty token")
	}
	return out.Value, nil
}
