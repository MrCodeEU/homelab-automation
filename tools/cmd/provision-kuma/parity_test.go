package main

import (
	"os"
	"testing"

	"gopkg.in/yaml.v3"
)

// Sanity-checks the catalog parsing + expected-name logic against a real
// services.yml pulled from production (not committed - copy one in
// manually before running `go test ./cmd/provision-kuma/... -run Parity -v`).
func TestParityAgainstRealCatalog(t *testing.T) {
	path := os.Getenv("KUMA_TEST_SERVICES_YML")
	if path == "" {
		t.Skip("KUMA_TEST_SERVICES_YML not set")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cat catalog
	if err := yaml.Unmarshal(raw, &cat); err != nil {
		t.Fatal(err)
	}

	t.Logf("services: %d, hosts: %d", len(cat.Services), len(cat.Hosts))

	expected := getExpectedMonitorNames(cat.Services, cat.Hosts)
	t.Logf("expected monitor names: %d", len(expected))
	for name := range expected {
		t.Logf("  %s", name)
	}

	enabledWithDomain := 0
	for _, svc := range cat.Services {
		if svc.isEnabled() && firstDomain(svc.Domain) != "" {
			enabledWithDomain++
		}
	}
	if enabledWithDomain+len(cat.Hosts)+1 != len(expected) {
		t.Errorf("expected count mismatch: %d enabled-with-domain + %d hosts + 1 smtp != %d expected",
			enabledWithDomain, len(cat.Hosts), len(expected))
	}
}
