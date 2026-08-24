// Package collectors holds every healthreport data source. Importing a
// collector's package registers it into healthreport.Registry, mirroring
// the Python original's decorator-based registration via import side
// effects.
package collectors

import (
	"fmt"
	"io"
	"net/http"
	"time"
)

// httpGet performs a GET and returns an error unless the response is 2xx,
// mirroring requests.Response.raise_for_status().
func httpGet(url string, timeout time.Duration, modify func(*http.Request)) (*http.Response, error) {
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if modify != nil {
		modify(req)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 500))
		resp.Body.Close()
		return nil, fmt.Errorf("%s: HTTP %d: %s", url, resp.StatusCode, string(body))
	}
	return resp, nil
}
