package collectors

import (
	"reflect"
	"testing"
)

func TestSSHTarget(t *testing.T) {
	cases := []struct {
		in, host string
		port     []string
	}{
		{"100.100.20.1", "100.100.20.1", nil},
		{"127.0.0.1:2423", "127.0.0.1", []string{"-p", "2423"}},
		{"nas.tail33930.ts.net", "nas.tail33930.ts.net", nil},
	}
	for _, c := range cases {
		host, port := sshTarget(c.in)
		if host != c.host || !reflect.DeepEqual(port, c.port) {
			t.Errorf("sshTarget(%q) = %q %v, want %q %v", c.in, host, port, c.host, c.port)
		}
	}
}
