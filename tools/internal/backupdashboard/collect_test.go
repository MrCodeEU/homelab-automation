// Port of services/backup-dashboard/tests/test_collect.py's badge/status
// reduction tests - pins Phase 1's host-level granularity so it isn't
// silently "improved" into something the data doesn't actually support
// (see collect.go's HostStatus doc comment).
package backupdashboard

import (
	"encoding/json"
	"reflect"
	"testing"
)

func f64(v float64) *float64 { return &v }

func factsPayload(available, completed bool, critical int, failedServices []string) *FactsPayload {
	var p FactsPayload
	p.Sections.Backup.Data.Available = available
	p.Sections.Backup.Data.Completed = completed
	p.Sections.Backup.Data.CriticalFailures = critical
	p.Sections.Backup.Data.FailedServices = failedServices
	p.Sections.Backup.Data.AgeSeconds = f64(3600)
	return &p
}

func TestHostStatusOK(t *testing.T) {
	status := hostStatus(factsPayload(true, true, 0, nil), "")
	if status.State != "ok" {
		t.Errorf("state = %q, want ok", status.State)
	}
	if status.AgeSeconds == nil || *status.AgeSeconds != 3600 {
		t.Errorf("age_seconds = %v, want 3600", status.AgeSeconds)
	}
}

func TestHostStatusIncludesVerificationResult(t *testing.T) {
	payload := factsPayload(true, true, 0, nil)
	payload.Sections.BackupVerification.Data.Available = true
	payload.Sections.BackupVerification.Data.State = "ok"
	payload.Sections.BackupVerification.Data.LastMode = "restore"
	payload.Sections.BackupVerification.Data.UpdatedAt = "2026-08-28T08:30:00Z"
	payload.Sections.BackupVerification.Data.Checks = map[string]VerificationCheck{
		"restore": {State: "ok", UpdatedAt: "2026-08-28T08:30:00Z"},
	}

	status := hostStatus(payload, "")
	if status.VerificationState != "ok" || status.VerificationMode != "restore" || status.VerificationAt != "2026-08-28T08:30:00Z" {
		t.Errorf("verification = %+v, want ok restore timestamp", status)
	}
	if status.RestoreState != "ok" || status.RestoreAt != "2026-08-28T08:30:00Z" {
		t.Errorf("restore = %+v, want ok restore timestamp", status)
	}
}

func TestHostStatusMarksMissingVerificationAsUnknown(t *testing.T) {
	status := hostStatus(factsPayload(true, true, 0, nil), "")
	if status.VerificationState != "unknown" {
		t.Errorf("verification state = %q, want unknown", status.VerificationState)
	}
}

func TestHistoryStatusIsSeparateFromBackupSourceStatus(t *testing.T) {
	var payload FactsPayload
	payload.Sections.BackupHistory.Data.Available = true
	payload.Sections.BackupHistory.Data.State = "ready"
	payload.Sections.BackupHistory.Data.SnapshotCount = 3
	free := 46.2
	payload.Sections.BackupHistory.Data.FreePercent = &free

	history, ok := historyStatus("ugreen", &payload, "")
	if !ok || history.Name != "ugreen" || history.State != "ready" || history.SnapshotCount != 3 || history.FreePercent == nil || *history.FreePercent != 46.2 {
		t.Errorf("history = %+v, ok = %v", history, ok)
	}
}

func TestHistoryStatusDecodesFactsEndpointShape(t *testing.T) {
	raw := []byte(`{"sections":{"backup_history":{"status":"ok","data":{"available":true,"state":"ready","snapshot_count":0,"latest_snapshot":null,"free_percent":43.1,"floor_percent":20,"reason":""}}}}`)
	var payload FactsPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatal(err)
	}
	history, ok := historyStatus("ugreen", &payload, "")
	if !ok || history.State != "ready" || history.FreePercent == nil || *history.FreePercent != 43.1 {
		t.Fatalf("decoded history = %+v, ok = %v", history, ok)
	}
}

func TestHostStatusDegradedOnCriticalFailure(t *testing.T) {
	status := hostStatus(factsPayload(true, true, 2, nil), "")
	if status.State != "degraded" {
		t.Errorf("state = %q, want degraded", status.State)
	}
}

func TestHostStatusUnreachable(t *testing.T) {
	status := hostStatus(nil, "ssh timed out")
	if status.State != "unknown" || status.Reason != "ssh timed out" {
		t.Errorf("got %+v", status)
	}
}

func TestHostStatusNoLogAvailable(t *testing.T) {
	var p FactsPayload
	p.Sections.Backup.Data.Available = false
	p.Sections.Backup.Data.Reason = "no backup logs"
	status := hostStatus(&p, "")
	if status.State != "unknown" || status.Reason != "no backup logs" {
		t.Errorf("got %+v", status)
	}
}

func TestTargetUsageSkipsUnsupportedQuota(t *testing.T) {
	var p FactsPayload
	p.Sections.BackupTargets.Data.Targets = []BackupTarget{
		{Name: "pcloud", Kind: "remote", QuotaSupported: true, UsedPercent: f64(67.1), FreeBytes: f64(10 * 1024 * 1024 * 1024)},
		{Name: "wd-cloud", Kind: "remote", QuotaSupported: false, UsedPercent: nil},
	}
	usage := targetUsage(&p, "")
	if _, ok := usage["pcloud"]; !ok {
		t.Fatal("pcloud missing")
	}
	if usage["pcloud"].UsedPercent != 67.1 {
		t.Errorf("used_percent = %v, want 67.1", usage["pcloud"].UsedPercent)
	}
	if _, ok := usage["wd-cloud"]; ok {
		t.Error("wd-cloud should be skipped")
	}
}

func TestTargetUsageSkipsLocalPaths(t *testing.T) {
	// collect_backup_targets also reports kind == "local" staging paths
	// (borg/appdata on nas) - real disk usage, but not a "destination" in
	// the sense the capacity cards mean. Found live in the Python
	// original: without this filter, /mnt/user/backup and /mnt/fastpool
	// showed up as destination cards next to pcloud.
	var p FactsPayload
	p.Sections.BackupTargets.Data.Targets = []BackupTarget{
		{Name: "/mnt/user/backup", Kind: "local", QuotaSupported: true, UsedPercent: f64(28.9), FreeBytes: f64(1)},
		{Name: "pcloud", Kind: "remote", QuotaSupported: true, UsedPercent: f64(48.7), FreeBytes: f64(1)},
	}
	usage := targetUsage(&p, "")
	if _, ok := usage["/mnt/user/backup"]; ok {
		t.Error("local path should be skipped")
	}
	if _, ok := usage["pcloud"]; !ok {
		t.Error("pcloud missing")
	}
}

func TestTargetUsageEmptyOnError(t *testing.T) {
	usage := targetUsage(nil, "unreachable")
	if len(usage) != 0 {
		t.Errorf("got %+v, want empty", usage)
	}
}

func TestEntryBadgeMatchesUgreenAndWdCloudLegFormat(t *testing.T) {
	// unraid-backup's ugreen/wd_cloud legs append "(leg)" to the bare name
	// (see backup.sh.j2's failed_paths+=("{{ pair.name }} (ugreen)")).
	entry := CatalogEntry{Name: "fotos", Host: "nas", Dest: "pcloud:Fotos"}
	statuses := map[string]HostStatus{"nas": {State: "ok", FailedServices: []string{"fotos (wd-cloud)"}}}
	if got := EntryBadge(entry, statuses); got != "failed" {
		t.Errorf("got %q, want failed", got)
	}
	statuses = map[string]HostStatus{"nas": {State: "ok", FailedServices: []string{"fotos (ugreen)"}}}
	if got := EntryBadge(entry, statuses); got != "failed" {
		t.Errorf("got %q, want failed", got)
	}
}

func TestEntryBadgeMatchesPcloudLegDestFormat(t *testing.T) {
	// The pcloud leg uses the raw dest string, not the entry name (see
	// backup.sh.j2's failed_paths+=("{{ pair.dest }}")) - name-substring
	// matching alone would miss this.
	entry := CatalogEntry{Name: "fotos", Host: "nas", Dest: "pcloud:Fotos"}
	statuses := map[string]HostStatus{"nas": {State: "ok", FailedServices: []string{"pcloud:Fotos"}}}
	if got := EntryBadge(entry, statuses); got != "failed" {
		t.Errorf("got %q, want failed", got)
	}
}

func TestEntryBadgeMatchesBareServiceName(t *testing.T) {
	// The rocky `backup` role's service failures are just the bare name.
	entry := CatalogEntry{Name: "mailcow", Host: "mljr"}
	statuses := map[string]HostStatus{"mljr": {State: "ok", FailedServices: []string{"mailcow"}}}
	if got := EntryBadge(entry, statuses); got != "failed" {
		t.Errorf("got %q, want failed", got)
	}
}

func TestEntryBadgeNoMatchStaysAtHostState(t *testing.T) {
	entry := CatalogEntry{Name: "fotos", Host: "nas", Dest: "pcloud:Fotos"}
	statuses := map[string]HostStatus{"nas": {State: "ok", FailedServices: []string{"musik (wd-cloud)"}}}
	if got := EntryBadge(entry, statuses); got != "ok" {
		t.Errorf("got %q, want ok", got)
	}
}

func TestEntryBadgeFallsBackToHostState(t *testing.T) {
	entry := CatalogEntry{Name: "sync", Host: "nas"}
	statuses := map[string]HostStatus{"nas": {State: "degraded"}}
	if got := EntryBadge(entry, statuses); got != "degraded" {
		t.Errorf("got %q, want degraded", got)
	}
}

func TestEntryBadgeUnknownForMissingHost(t *testing.T) {
	entry := CatalogEntry{Name: "sync", Host: "ghost-host"}
	if got := EntryBadge(entry, map[string]HostStatus{}); got != "unknown" {
		t.Errorf("got %q, want unknown", got)
	}
}

func TestEntryStatForMatchByExactName(t *testing.T) {
	entry := CatalogEntry{Name: "fotos", Host: "nas"}
	statuses := map[string]HostStatus{
		"nas": {State: "ok", Stats: map[string]EntryStat{"fotos": {Bytes: 1024, Files: 7}}},
	}
	stat, ok := EntryStatFor(entry, statuses)
	if !ok {
		t.Fatal("expected a stat match")
	}
	if stat.Bytes != 1024 || stat.Files != 7 {
		t.Errorf("got %+v, want bytes=1024 files=7", stat)
	}
}

func TestEntryStatForNoMatch(t *testing.T) {
	entry := CatalogEntry{Name: "musik", Host: "nas"}
	statuses := map[string]HostStatus{
		"nas": {State: "ok", Stats: map[string]EntryStat{"fotos": {Bytes: 1024, Files: 7}}},
	}
	if _, ok := EntryStatFor(entry, statuses); ok {
		t.Error("expected no stat match for an entry with no BACKUP_STATS line")
	}
}

func TestEntryStatForMissingHost(t *testing.T) {
	entry := CatalogEntry{Name: "fotos", Host: "ghost-host"}
	if _, ok := EntryStatFor(entry, map[string]HostStatus{}); ok {
		t.Error("expected no stat match for a missing host")
	}
}

func TestParseHostsPreservesOrder(t *testing.T) {
	got := parseHosts(" mljr=100.100.20.1, nuc=100.100.20.2 ,nas=100.100.10.2")
	want := []Host{
		{Name: "mljr", Address: "100.100.20.1"},
		{Name: "nuc", Address: "100.100.20.2"},
		{Name: "nas", Address: "100.100.10.2"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestCatalogEntrySourceDisplay(t *testing.T) {
	if got := (CatalogEntry{Source: "single"}).SourceDisplay(); got != "single" {
		t.Errorf("got %q", got)
	}
	if got := (CatalogEntry{Source: []any{"a", "b"}}).SourceDisplay(); got != "a, b" {
		t.Errorf("got %q", got)
	}
}
