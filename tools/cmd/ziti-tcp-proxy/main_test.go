package main

import "testing"

func TestParseTargets(t *testing.T) {
	got, err := parseTargets([]string{"crowdsec-lapi:8088", "grafana-loki:3100"})
	if err != nil || len(got) != 2 || got[0] != (target{"crowdsec-lapi", 8088}) || got[1] != (target{"grafana-loki", 3100}) {
		t.Fatalf("got %v, %v", got, err)
	}
	for _, bad := range [][]string{nil, {"x"}, {":80"}, {"x:0"}, {"x:70000"}, {"x:y"}, {"a:80", "b:80"}} {
		if _, err := parseTargets(bad); err == nil {
			t.Errorf("parseTargets(%q): want error", bad)
		}
	}
}
