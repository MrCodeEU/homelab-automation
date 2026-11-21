package collectors

import "testing"

func TestSystemdNoise(t *testing.T) {
	for unit, noise := range map[string]bool{
		"session-12.scope":       true,
		"session-c3.scope":       true,
		"cameramgr_serv.service": true,
		"smbftpd.service":        true,
		"ziti-renew.service":     false,
		"smbftpd.service.bak":    false,
		"session-x.scope":        false,
	} {
		if got := systemdNoise.MatchString(unit); got != noise {
			t.Errorf("systemdNoise(%q) = %v, want %v", unit, got, noise)
		}
	}
}
