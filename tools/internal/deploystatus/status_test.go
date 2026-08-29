package deploystatus

import (
	"reflect"
	"strings"
	"testing"
)

func TestGenerateHTMLRendersTypedCollections(t *testing.T) {
	html, err := GenerateHTML(map[string]any{
		"last_updated": "2026-08-29T18:23:33Z",
		"deployments": []map[string]any{{
			"timestamp": "2026-08-29T18:16:19Z",
			"status":    "success",
			"summary":   map[string]any{"ok": 1, "failed": 0, "total_services": 1},
		}},
		"services": []map[string]any{{"name": "umami", "host": "nuc", "status": "ok"}},
	})
	if err != nil {
		t.Fatalf("GenerateHTML() error = %v", err)
	}
	for _, want := range []string{"Total deployments: 1", "umami", "const deployments = [{"} {
		if !strings.Contains(html, want) {
			t.Errorf("GenerateHTML() missing %q", want)
		}
	}
}

func TestParseFailedServicesOpenVoxResourcePath(t *testing.T) {
	services := []map[string]any{
		{"name": "forgejo"},
		{"name": "ntfy"},
	}
	lines := []string{
		"[mljr] Error: /Stage[main]/Roles::Services/Roles::Services::Service[forgejo]/Exec[services-forgejo-deploy]/returns: change from 'notrun' to ['0'] failed: docker compose exited 1",
		"[mljr] Notice: /Stage[main]/Roles::Services/Roles::Services::Service[ntfy]/Exec[services-ntfy-deploy]/returns: executed successfully",
	}

	got := ParseFailedServices(lines, services)
	want := map[string]string{
		"forgejo": "[mljr] Error: /Stage[main]/Roles::Services/Roles::Services::Service[forgejo]/Exec[services-forgejo-deploy]/returns: change from 'notrun' to ['0'] failed: docker compose exited 1",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ParseFailedServices() = %#v, want %#v", got, want)
	}
}

func TestParseFailedServicesOpenVoxExecFallbackAndFirstError(t *testing.T) {
	services := []map[string]any{{"name": "grafana"}}
	lines := []string{
		"Error: /Stage[main]/Roles::Grafana/Exec[services-grafana-healthcheck]/returns: change from 'notrun' to ['0'] failed: connection refused",
		"Error: /Stage[main]/Roles::Grafana/Exec[services-grafana-healthcheck]/returns: skipped because of failed dependencies",
	}

	got := ParseFailedServices(lines, services)
	want := map[string]string{
		"grafana": "Error: /Stage[main]/Roles::Grafana/Exec[services-grafana-healthcheck]/returns: change from 'notrun' to ['0'] failed: connection refused",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ParseFailedServices() = %#v, want %#v", got, want)
	}
}

func TestParseFailedServicesDoesNotMisattributeHostOrCatalogFailure(t *testing.T) {
	services := []map[string]any{{"name": "forgejo"}, {"name": "ntfy"}}
	lines := []string{
		"[nuc] Error: Could not retrieve catalog from remote server: connection refused",
		"[nuc] Error: Could not create resources because catalog compilation failed",
	}

	if got := ParseFailedServices(lines, services); len(got) != 0 {
		t.Errorf("ParseFailedServices() = %#v, want no service failures", got)
	}
}

func TestParseFailedServicesKeepsLegacyAnsibleParsing(t *testing.T) {
	services := []map[string]any{{"name": "forgejo"}}
	lines := []string{
		"TASK [services : Deploy forgejo] *******************************************",
		"fatal: [mljr]: FAILED! => {\"msg\": \"compose failed\"}",
	}

	got := ParseFailedServices(lines, services)
	if got["forgejo"] == "" {
		t.Errorf("ParseFailedServices() = %#v, want forgejo legacy failure", got)
	}
}
