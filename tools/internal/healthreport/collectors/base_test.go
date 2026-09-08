package collectors

import (
	"net/url"
	"strings"
	"testing"
)

func TestGrafanaExploreURLEncodesLogQL(t *testing.T) {
	got := grafanaExploreURL("https://monitor.mljr.eu/", `{container="crowdsec"} |~ "error"`)
	if !strings.HasPrefix(got, "https://monitor.mljr.eu/explore?") {
		t.Fatalf("unexpected base/prefix: %s", got)
	}
	parsed, err := url.Parse(got)
	if err != nil {
		t.Fatalf("not a valid URL: %v", err)
	}
	q := parsed.Query()
	if q.Get("orgId") != "1" {
		t.Errorf("orgId = %q", q.Get("orgId"))
	}
	panes := q.Get("panes")
	if !strings.Contains(panes, `container=\"crowdsec\"`) || !strings.Contains(panes, `"uid":"loki"`) {
		t.Errorf("panes missing expected content: %s", panes)
	}
}

func TestGrafanaExploreURLEmptyWithoutInputs(t *testing.T) {
	if got := grafanaExploreURL("", "{container=\"x\"}"); got != "" {
		t.Errorf("expected empty URL with no Grafana base, got %q", got)
	}
	if got := grafanaExploreURL("https://monitor.mljr.eu", ""); got != "" {
		t.Errorf("expected empty URL with no logql, got %q", got)
	}
}
