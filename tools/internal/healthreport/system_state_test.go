package healthreport

import "testing"

func TestStateBackupTargetsDerivesWdCloudUsageFromDiskUsage(t *testing.T) {
	facts := &Facts{
		Collectors: map[string]*CollectorResult{
			"ssh_facts": {Status: "ok", Data: &SSHFactsData{Payloads: map[string]map[string]any{
				"nas": {"sections": map[string]any{
					"backup_targets": map[string]any{
						"status": "ok",
						"data": map[string]any{
							"targets": []any{
								map[string]any{"name": "wd-cloud", "kind": "remote"},
							},
						},
					},
				}},
			}}},
		},
		Observations: []*Observation{
			{ID: "backup_target_usage.nas.wd-cloud", Kind: "backup_target_usage", Subject: "nas", Value: 68.1},
		},
	}

	targets := StateBackupTargets(facts)
	if len(targets) != 1 {
		t.Fatalf("expected 1 target, got %d: %+v", len(targets), targets)
	}
	got := targets[0]
	if got.UsedPercent == nil || *got.UsedPercent != 68.1 {
		t.Errorf("expected UsedPercent 68.1, got %v", got.UsedPercent)
	}
	if got.Note != "" {
		t.Errorf("expected Note cleared once percent is derived, got %q", got.Note)
	}
}

func TestStateBackupTargetsKeepsNoQuotaNoteWithoutDerivedObservation(t *testing.T) {
	facts := &Facts{
		Collectors: map[string]*CollectorResult{
			"ssh_facts": {Status: "ok", Data: &SSHFactsData{Payloads: map[string]map[string]any{
				"nas": {"sections": map[string]any{
					"backup_targets": map[string]any{
						"status": "ok",
						"data": map[string]any{
							"targets": []any{
								map[string]any{"name": "wd-cloud", "kind": "remote"},
							},
						},
					},
				}},
			}}},
		},
	}

	targets := StateBackupTargets(facts)
	if len(targets) != 1 {
		t.Fatalf("expected 1 target, got %d", len(targets))
	}
	if targets[0].UsedPercent != nil {
		t.Errorf("expected no derived percent without the correlated observation, got %v", *targets[0].UsedPercent)
	}
	if targets[0].Note != "no quota API" {
		t.Errorf("Note = %q", targets[0].Note)
	}
}
