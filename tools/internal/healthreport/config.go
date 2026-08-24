package healthreport

import (
	"os"
	"strconv"
	"strings"
)

func envBool(name string, def bool) bool {
	raw := strings.ToLower(strings.TrimSpace(os.Getenv(name)))
	if raw == "" {
		return def
	}
	switch raw {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

func envInt(name string, def int) int {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return v
}

func envOr(name, def string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	return def
}

// parseWindows parses "sun 05:00-08:00,daily 00:00-00:10" into a list. An
// unset variable (raw==nil) keeps the defaults; an explicitly empty one
// ("HEALTHREPORT_MAINTENANCE_WINDOWS=") disables suppression entirely, which
// is what you want when checking whether a window is hiding a real problem.
func parseWindows(raw *string, def []string) []string {
	if raw == nil {
		out := make([]string, len(def))
		copy(out, def)
		return out
	}
	var out []string
	for _, chunk := range strings.Split(*raw, ",") {
		chunk = strings.TrimSpace(chunk)
		if chunk != "" {
			out = append(out, chunk)
		}
	}
	return out
}

// parseHosts parses "mljr=100.100.20.1,nas=100.100.10.2" into a mapping.
func parseHosts(raw string) map[string]string {
	out := map[string]string{}
	for _, chunk := range strings.Split(raw, ",") {
		chunk = strings.TrimSpace(chunk)
		if chunk == "" || !strings.Contains(chunk, "=") {
			continue
		}
		name, addr, _ := strings.Cut(chunk, "=")
		out[strings.TrimSpace(name)] = strings.TrimSpace(addr)
	}
	return out
}

var defaultMaintenanceWindows = []string{
	// Community Applications docker auto-update stops and restarts every
	// container it manages on nas.
	"daily 00:00-00:10",
	// Unraid appdata backup (plugin cron: Sunday 05:00), ~2h45 wall clock.
	"sun 04:55-08:00",
	// Weekly full deploy (.github/workflows/deploy.yml, Sunday 00:00 UTC),
	// which restarts changed containers. An hour is generous: the deploy
	// itself runs ~15 minutes.
	"sun 02:00-03:00",
}

// Config is runtime configuration, read from the environment. The .env is
// rendered by openvox's roles::services env.epp, so every value here has a
// matching block there.
type Config struct {
	StateDir  string
	RulesPath string

	VictoriaURL string
	LokiURL     string
	KumaURL     string
	KumaAPIKey  string

	OllamaURL   string
	OllamaModel string
	LLMEnabled  bool
	// CPU inference on the NAS. 8B at ~10-18 tok/s needs headroom even with
	// thinking disabled; 180s was not enough and every run degraded.
	LLMTimeoutS int

	// Hosts reachable through the forced-command SSH endpoint. The local
	// host runs the script directly instead of dialling itself over SSH.
	SSHHosts      map[string]string
	SSHKeyPath    string
	LocalHost     string
	LocalFactsBin string

	GithubToken string
	GithubOwner string

	HAURL   string
	HAToken string

	NtfyURL   string
	NtfyTopic string
	NtfyToken string

	SMTPHost     string
	SMTPPort     int
	SMTPUser     string
	SMTPPassword string
	SMTPFrom     string
	EmailTo      string

	GrafanaURL    string
	LookbackHours int

	// Scheduled outages, in the container's local time. Traffic-derived
	// findings would otherwise report planned maintenance as an incident.
	MaintenanceWindows    []string
	Caddy5xxHourThreshold int

	// Drift detection for nas's backup coverage - basenames of things known
	// to be covered or deliberately excluded.
	BackupKnownPaths    []string
	BackupExcludedPaths []string

	// Home Assistant cluster names (haCluster() output, e.g. "prusa_mk4")
	// known to sit unavailable on purpose - device switched off, hobby
	// integration nobody's watching - so they don't count toward
	// ha_unavailable_entities and drown out clusters that are an actual
	// broken integration.
	HAExcludedClusters []string
}

func defaultConfig() Config {
	return Config{
		StateDir:              "/state",
		RulesPath:             "/app/rules.yml",
		VictoriaURL:           "http://127.0.0.1:19090",
		LokiURL:               "http://127.0.0.1:3100",
		KumaURL:               "http://127.0.0.1:3001",
		OllamaURL:             "http://127.0.0.1:11434",
		OllamaModel:           "qwen3:8b",
		LLMTimeoutS:           300,
		SSHHosts:              map[string]string{},
		SSHKeyPath:            "/ssh/id_ed25519",
		LocalFactsBin:         "/usr/local/bin/homelab-facts",
		HAURL:                 "http://100.100.10.200:8123",
		NtfyURL:               "https://ntfy.mljr.eu",
		NtfyTopic:             "homelab-health",
		SMTPPort:              587,
		SMTPFrom:              "notifications@mljr.eu",
		GrafanaURL:            "https://monitor.mljr.eu",
		LookbackHours:         24,
		MaintenanceWindows:    defaultMaintenanceWindows,
		Caddy5xxHourThreshold: 100,
	}
}

func ConfigFromEnv() Config {
	c := defaultConfig()
	c.StateDir = envOr("HEALTHREPORT_STATE_DIR", c.StateDir)
	c.RulesPath = envOr("HEALTHREPORT_RULES", c.RulesPath)
	c.VictoriaURL = envOr("HEALTHREPORT_VM_URL", c.VictoriaURL)
	c.LokiURL = envOr("HEALTHREPORT_LOKI_URL", c.LokiURL)
	c.KumaURL = envOr("HEALTHREPORT_KUMA_URL", c.KumaURL)
	c.KumaAPIKey = os.Getenv("HEALTHREPORT_KUMA_API_KEY")
	c.OllamaURL = envOr("HEALTHREPORT_OLLAMA_URL", c.OllamaURL)
	c.OllamaModel = envOr("HEALTHREPORT_MODEL", c.OllamaModel)
	c.LLMEnabled = envBool("HEALTHREPORT_LLM_ENABLED", false)
	c.LLMTimeoutS = envInt("HEALTHREPORT_LLM_TIMEOUT", c.LLMTimeoutS)
	c.SSHHosts = parseHosts(os.Getenv("HEALTHREPORT_SSH_HOSTS"))
	c.SSHKeyPath = envOr("HEALTHREPORT_SSH_KEY", c.SSHKeyPath)
	c.LocalHost = envOr("HEALTHREPORT_LOCAL_HOST", c.LocalHost)
	c.GithubToken = os.Getenv("HEALTHREPORT_GITHUB_TOKEN")
	c.GithubOwner = os.Getenv("HEALTHREPORT_GITHUB_OWNER")
	c.HAURL = envOr("HEALTHREPORT_HA_URL", c.HAURL)
	c.HAToken = os.Getenv("HEALTHREPORT_HA_TOKEN")
	c.NtfyURL = envOr("HEALTHREPORT_NTFY_URL", c.NtfyURL)
	c.NtfyTopic = envOr("HEALTHREPORT_NTFY_TOPIC", c.NtfyTopic)
	c.NtfyToken = os.Getenv("HEALTHREPORT_NTFY_TOKEN")
	c.SMTPHost = os.Getenv("HEALTHREPORT_SMTP_HOST")
	c.SMTPPort = envInt("HEALTHREPORT_SMTP_PORT", 587)
	c.SMTPUser = os.Getenv("HEALTHREPORT_SMTP_USER")
	c.SMTPPassword = os.Getenv("HEALTHREPORT_SMTP_PASSWORD")
	c.SMTPFrom = envOr("HEALTHREPORT_SMTP_FROM", c.SMTPFrom)
	c.EmailTo = os.Getenv("HEALTHREPORT_EMAIL_TO")
	c.GrafanaURL = envOr("HEALTHREPORT_GRAFANA_URL", c.GrafanaURL)
	c.LookbackHours = envInt("HEALTHREPORT_LOOKBACK_HOURS", 24)
	if raw, ok := os.LookupEnv("HEALTHREPORT_MAINTENANCE_WINDOWS"); ok {
		c.MaintenanceWindows = parseWindows(&raw, defaultMaintenanceWindows)
	} else {
		c.MaintenanceWindows = parseWindows(nil, defaultMaintenanceWindows)
	}
	c.Caddy5xxHourThreshold = envInt("HEALTHREPORT_5XX_HOUR_THRESHOLD", 100)
	if raw, ok := os.LookupEnv("HEALTHREPORT_BACKUP_KNOWN_PATHS"); ok {
		c.BackupKnownPaths = parseWindows(&raw, nil)
	}
	if raw, ok := os.LookupEnv("HEALTHREPORT_BACKUP_EXCLUDED_PATHS"); ok {
		c.BackupExcludedPaths = parseWindows(&raw, nil)
	}
	if raw, ok := os.LookupEnv("HEALTHREPORT_HA_EXCLUDED_CLUSTERS"); ok {
		c.HAExcludedClusters = parseWindows(&raw, nil)
	}
	return c
}

// AllHosts returns every host this run should reach. LocalHost is normally
// empty: the facts script lives on the host, not in this container, so
// every host is reached over SSH including the one the agent runs on.
func (c Config) AllHosts() []string {
	hosts := make([]string, 0, len(c.SSHHosts)+1)
	for name := range c.SSHHosts {
		hosts = append(hosts, name)
	}
	if c.LocalHost != "" {
		found := false
		for _, h := range hosts {
			if h == c.LocalHost {
				found = true
				break
			}
		}
		if !found {
			hosts = append(hosts, c.LocalHost)
		}
	}
	return hosts
}
