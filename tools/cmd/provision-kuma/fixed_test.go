package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/breml/go-uptime-kuma-client/monitor"
)

func TestFixedTargetsOverZitiSpeakTheProtocol(t *testing.T) {
	for _, tt := range tcpTargets {
		over := strings.Contains(tt.host, kumaZitiProxy) || strings.Contains(tt.url, kumaZitiProxy)
		if over && tt.kind == kindTCP {
			t.Errorf("%s: a TCP check through %s always connects", tt.name, kumaZitiProxy)
		}
		if strings.HasPrefix(tt.host, "100.") || strings.Contains(tt.host, ".ts.net") {
			if tt.name != defectdojoName {
				t.Errorf("%s: still on the tailnet (%s)", tt.name, tt.host)
			}
		}
	}
}

func TestFreshMarshalsKumaTypes(t *testing.T) {
	base := monitor.Base{Name: "x", Interval: 60}
	cases := []struct {
		target tcpTarget
		want   []string
	}{
		{tcpTarget{kind: kindSMTP, host: "p", port: 2525}, []string{`"type":"smtp"`, `"smtpSecurity":"nostarttls"`, `"port":2525`, `"hostname":"p"`}},
		{tcpTarget{kind: kindHTTP, url: "http://p:8088/health"}, []string{`"type":"http"`, `"url":"http://p:8088/health"`, `"accepted_statuscodes":["200-299"]`}},
		{tcpTarget{host: "h", port: 993}, []string{`"type":"port"`, `"port":993`}},
	}
	for _, c := range cases {
		m := c.target.fresh(base)
		if m.Type() != c.target.monitorType() {
			t.Errorf("Type() = %s, want %s", m.Type(), c.target.monitorType())
		}
		raw, err := json.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		for _, w := range c.want {
			if !strings.Contains(string(raw), w) {
				t.Errorf("%s: missing %s in %s", c.target.monitorType(), w, raw)
			}
		}
	}
}
