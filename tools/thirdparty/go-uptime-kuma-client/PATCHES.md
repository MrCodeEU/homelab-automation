Vendored fork of github.com/breml/go-uptime-kuma-client v0.4.2.

Reason: `maintenance.Maintenance.DateRange` was typed `[]*time.Time`,
which Go's standard JSON unmarshaling parses as RFC3339-only. Uptime
Kuma 2.5.3 sends `dateRange` as `"2026-07-31 14:58:00"` (no `T`/offset).
Since this field is decoded inside the client's internal readiness-gate
handler (the `maintenanceList` socket event, required before `New()`
returns), any Kuma instance with a real maintenance window configured
hangs on every connection until the connect timeout, then fails -
confirmed live against production (2 real maintenance windows).

Fix (`maintenance/maintenance.go`, `maintenance/helpers.go`): introduced
`KumaDate` (a `time.Time` wrapper) with custom (Un)MarshalJSON that
accepts both RFC3339 and Kuma's plain format; `DateRange` is now
`[]*KumaDate`.

Also trimmed: removed all `_test.go` files and dev/CI-only files
(`.github/`, linter configs, `Taskfile.yml`) - this fork exists to be
built, not to run the upstream test suite, and dragging in its
dockertest/golangci-lint-scale dependency tree would bloat this repo's
own tools/go.sum for no benefit. go.mod was correspondingly trimmed to
the deps package source actually imports.

To refresh from upstream: pull a newer github.com/breml/go-uptime-kuma-client
release, diff against this directory, and reapply the DateRange fix if
upstream hasn't merged an equivalent one yet.
