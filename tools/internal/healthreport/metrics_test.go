package healthreport

import (
	"strings"
	"testing"
	"time"
)

func TestRenderMetrics(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	crit := NewObservation("disk.ugreen./", "victoria", "ugreen", "disk", `ugreen "/" is 97% full`)
	crit.Severity = "crit"
	crit.FirstSeen = "2026-11-08T05:18:44Z"
	notice := NewObservation("appsec.mljr.", "appsec", "mljr", "appsec", "2884 matches")
	notice.Notice = true
	quiet := NewObservation("ok.nuc.", "victoria", "nuc", "ok", "fine")
	facts := &Facts{
		Collectors: map[string]*CollectorResult{
			"victoria": {Name: "victoria", Status: "ok", DurationS: 1.5},
			"kuma":     {Name: "kuma", Status: "error"},
		},
		Observations: []*Observation{crit, notice, quiet},
		Summary:      Summary{Crit: 1, Info: 2},
	}
	out := RenderMetrics(facts, "metrics", now)

	for _, want := range []string{
		`healthreport_last_run_timestamp_seconds{mode="metrics"} 1.7e+09 1700000000000`,
		`healthreport_observations{mode="metrics",severity="crit"} 1 `,
		`healthreport_collector_up{collector="kuma",status="error"} 0 `,
		`healthreport_collector_up{collector="victoria",status="ok"} 1 `,
		`healthreport_observation{id="disk.ugreen./",collector="victoria",subject="ugreen",kind="disk",severity="crit",message="ugreen \"/\" is 97% full"} 2 `,
		`healthreport_observation_first_seen_timestamp_seconds{id="disk.ugreen./",collector="victoria",subject="ugreen",kind="disk",severity="crit"} 1.794115124e+09 `,
		`healthreport_observation{id="appsec.mljr.",collector="appsec",subject="mljr",kind="appsec",severity="info",message="2884 matches"} 0 `,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s\n--- got:\n%s", want, out)
		}
	}
	if strings.Contains(out, `id="ok.nuc."`) {
		t.Errorf("plain info observation exported:\n%s", out)
	}
	if strings.Contains(out, `first_seen_timestamp_seconds{id="appsec.mljr."`) {
		t.Errorf("first_seen exported without a timestamp:\n%s", out)
	}
}
