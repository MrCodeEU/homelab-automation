package healthreport

// Shared collector data shapes, read cross-collector by system_state.go and
// render.go. ssh_facts's payloads are kept as generic JSON (map[string]any)
// instead, since that JSON is produced by an external, unported script
// (ansible/roles/host-facts-endpoint's homelab-facts.py.j2) whose schema
// this service only ever consumed dynamically.

type FilesystemRow struct {
	Instance    string  `json:"instance"`
	Mountpoint  string  `json:"mountpoint"`
	UsedPercent float64 `json:"used_percent"`
}

type MemoryRow struct {
	Instance    string  `json:"instance"`
	UsedPercent float64 `json:"used_percent"`
}

type LoadRow struct {
	Instance      string  `json:"instance"`
	Load15PerCore float64 `json:"load15_per_core"`
}

type UptimeRow struct {
	Instance string `json:"instance"`
	Uptime   int64  `json:"uptime"`
}

type HostMetricsData struct {
	Filesystems       []FilesystemRow   `json:"filesystems"`
	Memory            []MemoryRow       `json:"memory"`
	LoadPerCore       []LoadRow         `json:"load_per_core"`
	UptimeSeconds     []UptimeRow       `json:"uptime_seconds"`
	MetricsAgeSeconds map[string]float64 `json:"metrics_age_seconds"`
}

type ContainersData struct {
	CurrentCount  int      `json:"current_count"`
	PreviousCount int      `json:"previous_count"`
	Missing       []string `json:"missing"`
	New           []string `json:"new"`
}

type KumaMonitor struct {
	Name       string   `json:"name"`
	URL        *string  `json:"url"`
	Status     *int     `json:"status,omitempty"`
	CertDays   *int     `json:"cert_days,omitempty"`
	ResponseMs *float64 `json:"response_ms,omitempty"`
}

type KumaData struct {
	MonitorCount int           `json:"monitor_count"`
	Monitors     []KumaMonitor `json:"monitors"`
}

type GithubRepoEntry struct {
	Repo             string `json:"repo"`
	DefaultBranch    string `json:"default_branch"`
	FailedRuns       int    `json:"failed_runs"`
	DependabotOpen   int    `json:"dependabot_open"`
	CodeScanningOpen int    `json:"code_scanning_open"`
}

type GithubData struct {
	Repos              []GithubRepoEntry `json:"repos"`
	Unavailable        []string          `json:"unavailable"`
	RepoCount          int               `json:"repo_count"`
	Owner              string            `json:"owner"`
	TokenExpiresInDays *int              `json:"token_expires_in_days,omitempty"`
}

type HAUpdate struct {
	Name      string `json:"name"`
	Installed string `json:"installed"`
	Latest    string `json:"latest"`
}

type HomeAssistantData struct {
	Version             string     `json:"version"`
	CoreState           string     `json:"core_state"`
	EntityCount         int        `json:"entity_count"`
	UnavailableCount    int        `json:"unavailable_count"`
	RawUnavailableCount int        `json:"raw_unavailable_count"`
	Clusters            []string   `json:"clusters"`
	UpdatesAvailable    []HAUpdate `json:"updates_available"`
}

type UpdateMessage struct {
	Title   string `json:"title"`
	Message string `json:"message"`
	Time    any    `json:"time"`
}

type UpdatesData struct {
	Count    int             `json:"count"`
	Messages []UpdateMessage `json:"messages"`
}

// SSHFactsData is ssh_facts's own collector data: reachable/unreachable
// hosts plus each host's raw facts payload (dynamic JSON from the
// forced-command endpoint).
type SSHFactsData struct {
	Hosts    []string                  `json:"hosts"`
	Errors   map[string]string         `json:"errors"`
	Payloads map[string]map[string]any `json:"payloads"`
}

// factsSection reads payload["sections"][name] and returns its "data" map
// if status == "ok", mirroring ssh_facts.py's _section() helper.
func factsSection(payload map[string]any, name string) (map[string]any, bool) {
	sections, _ := payload["sections"].(map[string]any)
	if sections == nil {
		return nil, false
	}
	section, _ := sections[name].(map[string]any)
	if section == nil {
		return nil, false
	}
	if status, _ := section["status"].(string); status != "ok" {
		return nil, false
	}
	data, _ := section["data"].(map[string]any)
	return data, data != nil
}
