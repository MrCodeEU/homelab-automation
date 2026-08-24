package backupdashboard

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

const fsExclude = `fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs|fuse.*|iso9660|autofs"`

type victoriaResponse struct {
	Status string `json:"status"`
	Error  string `json:"error"`
	Data   struct {
		Result []struct {
			Metric map[string]string `json:"metric"`
			Value  [2]any            `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

func queryVictoria(ctx context.Context, victoriaURL, promql string) (*victoriaResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	u := victoriaURL
	for len(u) > 0 && u[len(u)-1] == '/' {
		u = u[:len(u)-1]
	}
	req, err := http.NewRequestWithContext(ctx, "GET", u+"/api/v1/query?"+url.Values{"query": {promql}}.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("victoria query: HTTP %d", resp.StatusCode)
	}
	var payload victoriaResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Status != "success" {
		return nil, fmt.Errorf("query failed: %s", payload.Error)
	}
	return &payload, nil
}

// SourceDiskUsage returns {instance: {mountpoint: used_percent}}, or {}
// on failure - matches the Python original, which is best-effort and
// never fails the whole page render. Collected for parity (still written
// to state/snapshot.json) but, as in the original, not surfaced on the
// page itself yet.
func SourceDiskUsage(ctx context.Context, victoriaURL string) map[string]map[string]float64 {
	out := map[string]map[string]float64{}
	promql := fmt.Sprintf(
		"100 - (node_filesystem_avail_bytes{%s} / node_filesystem_size_bytes{%s} * 100)",
		fsExclude, fsExclude,
	)
	resp, err := queryVictoria(ctx, victoriaURL, promql)
	if err != nil {
		return out
	}
	for _, series := range resp.Data.Result {
		if len(series.Value) != 2 {
			continue
		}
		valStr, ok := series.Value[1].(string)
		if !ok {
			continue
		}
		val, err := strconv.ParseFloat(valStr, 64)
		if err != nil {
			continue
		}
		instance := series.Metric["instance"]
		mount := series.Metric["mountpoint"]
		if out[instance] == nil {
			out[instance] = map[string]float64{}
		}
		out[instance][mount] = round1(val)
	}
	return out
}
