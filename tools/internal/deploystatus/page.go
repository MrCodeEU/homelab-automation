// Package deploystatus generates the deployment status page (deploy.mljr.eu)
// from deployment history data.
//
// Port of scripts/generate_deploy_page.py's generate_html().
package deploystatus

import (
	"encoding/json"
	"fmt"
	htmlpkg "html"
	"sort"
	"strings"
	"time"
)

func formatDuration(seconds int) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	minutes := seconds / 60
	secs := seconds % 60
	if minutes < 60 {
		return fmt.Sprintf("%dm %ds", minutes, secs)
	}
	hours := minutes / 60
	mins := minutes % 60
	return fmt.Sprintf("%dh %dm", hours, mins)
}

func formatRelativeTime(timestamp string) string {
	if timestamp == "" {
		return "Never"
	}
	ts := strings.Replace(timestamp, "Z", "+00:00", 1)
	dt, err := time.Parse("2006-01-02T15:04:05-07:00", ts)
	if err != nil {
		if len(timestamp) >= 10 {
			return timestamp[:10]
		}
		return timestamp
	}
	now := time.Now().In(dt.Location())
	diff := now.Sub(dt)
	days := int(diff.Hours() / 24)
	secondsRemainder := int(diff.Seconds()) - days*86400

	switch {
	case days > 30:
		return dt.Format("Jan 02, 2006")
	case days > 0:
		return fmt.Sprintf("%dd ago", days)
	case secondsRemainder > 3600:
		return fmt.Sprintf("%dh ago", secondsRemainder/3600)
	case secondsRemainder > 60:
		return fmt.Sprintf("%dm ago", secondsRemainder/60)
	default:
		return "just now"
	}
}

func getIconClass(icon string) string {
	if icon == "" {
		return "mdi:application"
	}
	return icon
}

func esc(s string) string { return htmlpkg.EscapeString(s) }

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

func str(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

func boolv(m map[string]any, key string) bool {
	b, _ := m[key].(bool)
	return b
}

func numAsInt(v any) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	default:
		return 0
	}
}

func domainOf(svc map[string]any) string {
	switch d := svc["domain"].(type) {
	case string:
		return d
	case []any:
		if len(d) > 0 {
			s, _ := d[0].(string)
			return s
		}
	}
	return ""
}

func list(m map[string]any, key string) []map[string]any {
	raw, _ := m[key].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		if im, ok := item.(map[string]any); ok {
			out = append(out, im)
		}
	}
	return out
}

// GenerateHTML ports generate_deploy_page.py's generate_html() line for
// line - including its JS/Chart.js payload, which is emitted verbatim.
func GenerateHTML(data map[string]any) (string, error) {
	deployments := list(data, "deployments")
	services := list(data, "services")
	lastUpdated := str(data, "last_updated")

	recent := deployments
	if len(recent) > 100 {
		recent = recent[:100]
	}
	successCount := 0
	for _, d := range recent {
		if str(d, "status") == "success" {
			successCount++
		}
	}
	successRate := 0.0
	if len(recent) > 0 {
		successRate = float64(successCount) / float64(len(recent)) * 100
	}

	durationSum, durationCount := 0, 0
	for _, d := range recent {
		if v, ok := d["duration_seconds"]; ok {
			n := numAsInt(v)
			if n != 0 {
				durationSum += n
				durationCount++
			}
		}
	}
	avgDuration := 0
	if durationCount > 0 {
		avgDuration = durationSum / durationCount
	}

	lastStatus := "none"
	var lastDeployment map[string]any
	if len(deployments) > 0 {
		lastDeployment = deployments[0]
		lastStatus = str(lastDeployment, "status")
		if lastStatus == "" {
			lastStatus = "none"
		}
	}

	failedServicesHTML := ""
	if lastDeployment != nil {
		var failedSvcs []map[string]any
		for _, s := range list(lastDeployment, "services") {
			if str(s, "status") == "failed" {
				failedSvcs = append(failedSvcs, s)
			}
		}
		if len(failedSvcs) > 0 {
			var b strings.Builder
			b.WriteString(`
            <div class="bg-red-500/10 rounded-xl border border-red-500/30 p-4 mb-8">
                <h2 class="text-lg font-semibold text-red-400 mb-4 flex items-center gap-2">
                    <iconify-icon icon="mdi:alert-circle" class="text-xl"></iconify-icon>
                    Failed Services (Last Deployment)
                </h2>
                <div class="space-y-3">
            `)
			for _, svc := range failedSvcs {
				name := esc(orDefault(str(svc, "name"), "Unknown"))
				host := esc(orDefault(str(svc, "host"), "unknown"))
				errMsg := esc(truncate(orDefault(str(svc, "error"), "No error details available"), 300))
				fmt.Fprintf(&b, `
                    <div class="bg-slate-800/50 rounded-lg p-3 border border-red-500/20">
                        <div class="flex items-center gap-2 mb-2">
                            <span class="font-medium text-red-300">%s</span>
                            <span class="text-xs text-slate-500">on %s</span>
                        </div>
                        <div class="text-sm text-slate-400 font-mono bg-slate-900/50 p-2 rounded overflow-x-auto">
                            %s
                        </div>
                    </div>
                `, name, host, errMsg)
			}
			b.WriteString(`
                </div>
            </div>
            `)
			failedServicesHTML = b.String()
		}
	}

	servicesByHost := map[string][]map[string]any{}
	for _, svc := range services {
		host := str(svc, "host")
		if host == "" {
			host = "unknown"
		}
		servicesByHost[host] = append(servicesByHost[host], svc)
	}

	hostOrder := []string{"mljr", "nuc", "nas", "pi", "monitoring"}
	hostLabels := map[string]string{
		"mljr":       "Production Server (mljr)",
		"nuc":        "Staging Server (nuc)",
		"nas":        "NAS (Unraid)",
		"pi":         "Raspberry Pi",
		"monitoring": "Monitoring Host",
	}

	deploymentsForJSON := deployments
	if len(deploymentsForJSON) > 200 {
		deploymentsForJSON = deploymentsForJSON[:200]
	}
	deploymentsJSON, err := json.Marshal(deploymentsForJSON)
	if err != nil {
		return "", err
	}
	servicesJSON, err := json.Marshal(services)
	if err != nil {
		return "", err
	}

	statusColor := func(status string) string {
		switch status {
		case "success":
			return "text-emerald-400"
		case "failed":
			return "text-red-400"
		default:
			return "text-slate-400"
		}
	}

	servicesHTML := ""
	{
		var b strings.Builder
		for _, host := range hostOrder {
			hostServices, ok := servicesByHost[host]
			if !ok {
				continue
			}
			label := host
			if l, ok := hostLabels[host]; ok {
				label = l
			}
			fmt.Fprintf(&b, `
        <div class="mb-8">
            <h3 class="text-lg font-semibold text-slate-300 mb-4 flex items-center gap-2">
                <span class="w-2 h-2 rounded-full bg-emerald-400"></span>
                %s
                <span class="text-sm font-normal text-slate-500">(%d services)</span>
            </h3>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        `, label, len(hostServices))

			sorted := append([]map[string]any{}, hostServices...)
			sort.Slice(sorted, func(i, j int) bool { return str(sorted[i], "name") < str(sorted[j], "name") })

			for _, svc := range sorted {
				domain := domainOf(svc)
				var url string
				if domain != "" {
					url = "https://" + domain
				}
				icon := getIconClass(str(svc, "icon"))
				name := esc(orDefault(str(svc, "name"), "Unknown"))
				desc := esc(truncate(str(svc, "description"), 60))

				linkClass := "opacity-60"
				linkAttr := ""
				if url != "" {
					linkClass = "hover:bg-slate-700/50 cursor-pointer"
					linkAttr = fmt.Sprintf(`onclick="window.open('%s', '_blank')"`, url)
				}
				domainDisplay := domain
				if domainDisplay == "" {
					domainDisplay = "Internal service"
				}
				descHTML := ""
				if desc != "" {
					descHTML = fmt.Sprintf(`<div class="text-xs text-slate-400 mt-2 truncate">%s</div>`, desc)
				}

				fmt.Fprintf(&b, `
                <div class="bg-slate-800/50 rounded-lg p-3 border border-slate-700/50 %s transition-all" %s>
                    <div class="flex items-center gap-3">
                        <div class="w-10 h-10 rounded-lg bg-slate-700/50 flex items-center justify-center text-slate-300">
                            <iconify-icon icon="%s" class="text-xl"></iconify-icon>
                        </div>
                        <div class="flex-1 min-w-0">
                            <div class="font-medium text-slate-200 truncate">%s</div>
                            <div class="text-xs text-slate-500 truncate">%s</div>
                        </div>
                    </div>
                    %s
                </div>
            `, linkClass, linkAttr, icon, name, domainDisplay, descHTML)
			}
			b.WriteString(`
            </div>
        </div>
        `)
		}
		servicesHTML = b.String()
	}

	deploymentsHTML := ""
	{
		var b strings.Builder
		limit := len(deployments)
		if limit > 15 {
			limit = 15
		}
		for idx := 0; idx < limit; idx++ {
			dep := deployments[idx]
			status := orDefault(str(dep, "status"), "unknown")
			statusIcon := "mdi:close-circle"
			statusClass := "text-red-400"
			if status == "success" {
				statusIcon = "mdi:check-circle"
				statusClass = "text-emerald-400"
			}

			timestamp := str(dep, "timestamp")
			relative := formatRelativeTime(timestamp)
			duration := formatDuration(numAsInt(dep["duration_seconds"]))
			branch := esc(orDefault(str(dep, "branch"), "unknown"))
			actor := esc(orDefault(str(dep, "actor"), "unknown"))
			commit := esc(truncate(str(dep, "commit_sha"), 7))

			summary, _ := dep["summary"].(map[string]any)
			okCount := numAsInt(summary["ok"])
			failedCount := numAsInt(summary["failed"])
			total := okCount + failedCount
			if v, ok := summary["total_services"]; ok {
				total = numAsInt(v)
			}

			checkBadge := ""
			if boolv(dep, "check_mode") {
				checkBadge = `<span class="px-1.5 py-0.5 text-xs bg-amber-500/20 text-amber-400 rounded">dry-run</span>`
			}
			stagingBadge := ""
			if boolv(dep, "is_staging") {
				stagingBadge = `<span class="px-1.5 py-0.5 text-xs bg-purple-500/20 text-purple-400 rounded">staging</span>`
			}
			runURL := esc(str(dep, "run_url"))
			araArtifact := esc(str(dep, "ara_artifact"))
			trigger := str(dep, "trigger")

			linksHTML := ""
			if runURL != "" {
				linksHTML += fmt.Sprintf(`
                <a href="%s" target="_blank" rel="noopener noreferrer" class="inline-flex items-center gap-1 px-2 py-1 text-xs bg-slate-700/60 hover:bg-slate-700 rounded text-slate-300">
                    <iconify-icon icon="mdi:github"></iconify-icon>
                    Run
                </a>
            `, runURL)
			}
			if araArtifact != "" {
				linksHTML += fmt.Sprintf(`
                <span title="Download artifact '%s' from the GitHub Actions run" class="inline-flex items-center gap-1 px-2 py-1 text-xs bg-blue-500/15 text-blue-300 rounded">
                    <iconify-icon icon="mdi:database-search"></iconify-icon>
                    ARA
                </span>
            `, araArtifact)
			}
			if linksHTML == "" && trigger == "local" {
				linksHTML = `
                <span title="Executed locally via make deploy" class="inline-flex items-center gap-1 px-2 py-1 text-xs bg-slate-700/50 text-slate-300 rounded">
                    <iconify-icon icon="mdi:console"></iconify-icon>
                    Local
                </span>
            `
			}

			var depFailedSvcs []map[string]any
			for _, s := range list(dep, "services") {
				if str(s, "status") == "failed" {
					depFailedSvcs = append(depFailedSvcs, s)
				}
			}

			expandBtn := ""
			expandedContent := ""
			if len(depFailedSvcs) > 0 {
				expandBtn = fmt.Sprintf(`<button onclick="toggleExpand(%d)" class="text-red-400 hover:text-red-300 ml-2"><iconify-icon icon="mdi:chevron-down" id="chevron-%d"></iconify-icon></button>`, idx, idx)
				var eb strings.Builder
				fmt.Fprintf(&eb, `
            <tr id="expanded-%d" class="hidden">
                <td colspan="8" class="px-4 pb-4 bg-slate-800/30">
                    <div class="text-sm text-red-400 mb-2">Failed services:</div>
                    <div class="space-y-2">
            `, idx)
				for _, svc := range depFailedSvcs {
					svcName := esc(orDefault(str(svc, "name"), "Unknown"))
					svcError := esc(truncate(orDefault(str(svc, "error"), "No details"), 200))
					fmt.Fprintf(&eb, `
                        <div class="bg-slate-900/50 p-2 rounded text-xs">
                            <span class="text-red-300 font-medium">%s</span>
                            <span class="text-slate-500 ml-2 font-mono">%s</span>
                        </div>
                `, svcName, svcError)
				}
				eb.WriteString(`
                    </div>
                </td>
            </tr>
            `)
				expandedContent = eb.String()
			}

			timestampDisplay := ""
			if timestamp != "" {
				timestampDisplay = strings.Replace(truncate(timestamp, 19), "T", " ", 1)
			}
			linksOrDash := linksHTML
			if linksOrDash == "" {
				linksOrDash = `<span class="text-slate-600">-</span>`
			}

			fmt.Fprintf(&b, `
        <tr class="border-b border-slate-800 hover:bg-slate-800/30">
            <td class="py-3 px-4">
                <iconify-icon icon="%s" class="%s text-xl"></iconify-icon>
            </td>
            <td class="py-3 px-4">
                <div class="text-slate-200">%s</div>
                <div class="text-xs text-slate-500">%s</div>
            </td>
            <td class="py-3 px-4 text-slate-300">%s</td>
            <td class="py-3 px-4">
                <span class="text-slate-300">%s</span>
                <span class="text-slate-500 text-xs ml-1">(%s)</span>
            </td>
            <td class="py-3 px-4 text-slate-400">%s</td>
            <td class="py-3 px-4">
                <span class="text-emerald-400">%d</span>
                <span class="text-slate-600">/</span>
                <span class="text-red-400">%d</span>
                <span class="text-slate-600">/</span>
                <span class="text-slate-400">%d</span>
                %s
            </td>
            <td class="py-3 px-4 space-x-1">%s%s</td>
            <td class="py-3 px-4">
                <div class="flex flex-wrap gap-1">%s</div>
            </td>
        </tr>
        %s
        `, statusIcon, statusClass, relative, timestampDisplay, duration, branch, commit, actor,
				okCount, failedCount, total, expandBtn, checkBadge, stagingBadge, linksOrDash, expandedContent)
		}
		deploymentsHTML = b.String()
	}

	lastUpdatedDisplay := "Never"
	if lastUpdated != "" {
		lastUpdatedDisplay = strings.Replace(truncate(lastUpdated, 19), "T", " ", 1)
	}
	successRateClass := statusColor("failed")
	if successRate >= 80 {
		successRateClass = statusColor("success")
	}
	lastStatusTitle := "None"
	if lastStatus != "" && lastStatus != "none" {
		lastStatusTitle = strings.ToUpper(lastStatus[:1]) + lastStatus[1:]
	} else if lastStatus == "none" {
		lastStatusTitle = "None"
	}
	lastDeployRelative := "Never"
	if lastDeployment != nil {
		lastDeployRelative = formatRelativeTime(str(lastDeployment, "timestamp"))
	}

	deploymentsHTMLOrEmpty := deploymentsHTML
	if deploymentsHTMLOrEmpty == "" {
		deploymentsHTMLOrEmpty = `<tr><td colspan="8" class="py-8 text-center text-slate-500">No deployments yet</td></tr>`
	}
	servicesHTMLOrEmpty := servicesHTML
	if servicesHTMLOrEmpty == "" {
		servicesHTMLOrEmpty = `<p class="text-slate-500">No services configured</p>`
	}

	page := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Deployment Status - mljr.eu</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://code.iconify.design/iconify-icon/1.0.7/iconify-icon.min.js"></script>
    <meta http-equiv="refresh" content="60">
    <style>
        .chart-container { position: relative; height: 200px; }
    </style>
</head>
<body class="bg-slate-900 text-slate-100 min-h-screen">
    <div class="max-w-7xl mx-auto px-4 py-8">
        <!-- Header -->
        <header class="mb-8">
            <div class="flex items-center justify-between">
                <div>
                    <h1 class="text-3xl font-bold text-white flex items-center gap-3">
                        <iconify-icon icon="mdi:rocket-launch" class="text-blue-400"></iconify-icon>
                        Deployment Status
                    </h1>
                    <p class="text-slate-400 mt-1">Homelab Infrastructure Monitoring</p>
                </div>
                <div class="text-right text-sm text-slate-500">
                    <div>Last updated: %s UTC</div>
                    <div>Total deployments: %d</div>
                </div>
            </div>
        </header>

        <!-- Stats Cards -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Success Rate</div>
                <div class="text-2xl font-bold %s">%.1f%%</div>
                <div class="text-xs text-slate-500">last 100 deploys</div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Avg Duration</div>
                <div class="text-2xl font-bold text-blue-400">%s</div>
                <div class="text-xs text-slate-500">last 100 deploys</div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Total Deploys</div>
                <div class="text-2xl font-bold text-slate-200">%d</div>
                <div class="text-xs text-slate-500">all time</div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Last Deploy</div>
                <div class="text-2xl font-bold %s">%s</div>
                <div class="text-xs text-slate-500">%s</div>
            </div>
        </div>

        <!-- Failed Services Alert (if any) -->
        %s

        <!-- Charts -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-8">
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <h3 class="text-sm font-medium text-slate-300 mb-3">Success Rate (30 days)</h3>
                <div class="chart-container">
                    <canvas id="successRateChart"></canvas>
                </div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <h3 class="text-sm font-medium text-slate-300 mb-3">Deployments per Day (14 days)</h3>
                <div class="chart-container">
                    <canvas id="deploymentsPerDayChart"></canvas>
                </div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <h3 class="text-sm font-medium text-slate-300 mb-3">Duration Trend (30 deploys)</h3>
                <div class="chart-container">
                    <canvas id="durationTrendChart"></canvas>
                </div>
            </div>
        </div>

        <!-- Recent Deployments -->
        <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 mb-8 overflow-hidden">
            <div class="px-4 py-3 border-b border-slate-700/50">
                <h2 class="text-lg font-semibold text-slate-200 flex items-center gap-2">
                    <iconify-icon icon="mdi:history"></iconify-icon>
                    Recent Deployments
                </h2>
            </div>
            <div class="overflow-x-auto">
                <table class="w-full text-sm">
                    <thead class="bg-slate-800/50 text-slate-400 text-left">
                        <tr>
                            <th class="py-2 px-4 w-12"></th>
                            <th class="py-2 px-4">Time</th>
                            <th class="py-2 px-4">Duration</th>
                            <th class="py-2 px-4">Branch</th>
                            <th class="py-2 px-4">Actor</th>
                            <th class="py-2 px-4">Services (ok/fail/total)</th>
                            <th class="py-2 px-4">Flags</th>
                            <th class="py-2 px-4">Links</th>
                        </tr>
                    </thead>
                    <tbody>
                        %s
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Services Grid -->
        <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
            <h2 class="text-lg font-semibold text-slate-200 mb-4 flex items-center gap-2">
                <iconify-icon icon="mdi:server"></iconify-icon>
                Services
            </h2>
            %s
        </div>

        <!-- Footer -->
        <footer class="mt-8 text-center text-sm text-slate-500">
            <a href="https://github.com/MrCodeEU/homelab-automation" class="hover:text-slate-300 flex items-center justify-center gap-2">
                <iconify-icon icon="mdi:github"></iconify-icon>
                MrCodeEU/homelab-automation
            </a>
            <span class="mt-1 block">Auto-refreshes every 60 seconds</span>
        </footer>
    </div>

    <script>
        const deployments = %s;
        const services = %s;

        // Toggle expanded row for failed services
        function toggleExpand(idx) {
            const row = document.getElementById('expanded-' + idx);
            const chevron = document.getElementById('chevron-' + idx);
            if (row.classList.contains('hidden')) {
                row.classList.remove('hidden');
                chevron.setAttribute('icon', 'mdi:chevron-up');
            } else {
                row.classList.add('hidden');
                chevron.setAttribute('icon', 'mdi:chevron-down');
            }
        }

        // Chart.js default config
        Chart.defaults.color = '#94a3b8';
        Chart.defaults.borderColor = '#334155';

        // Success Rate Chart
        function renderSuccessRateChart() {
            const ctx = document.getElementById('successRateChart');
            if (!ctx || deployments.length === 0) return;

            const byDay = {};
            deployments.forEach(d => {
                const day = d.timestamp.split('T')[0];
                if (!byDay[day]) byDay[day] = { success: 0, total: 0 };
                byDay[day].total++;
                if (d.status === 'success') byDay[day].success++;
            });

            const days = Object.keys(byDay).sort().slice(-30);
            const rates = days.map(day => (byDay[day].success / byDay[day].total * 100).toFixed(1));

            new Chart(ctx, {
                type: 'line',
                data: {
                    labels: days.map(d => d.slice(5)),
                    datasets: [{
                        label: 'Success %%',
                        data: rates,
                        borderColor: '#10b981',
                        backgroundColor: 'rgba(16, 185, 129, 0.1)',
                        fill: true,
                        tension: 0.3,
                        pointRadius: 2
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        y: { min: 0, max: 100, grid: { color: '#1e293b' } },
                        x: { grid: { display: false } }
                    },
                    plugins: { legend: { display: false } }
                }
            });
        }

        // Deployments per Day Chart
        function renderDeploymentsPerDayChart() {
            const ctx = document.getElementById('deploymentsPerDayChart');
            if (!ctx || deployments.length === 0) return;

            const byDay = {};
            deployments.forEach(d => {
                const day = d.timestamp.split('T')[0];
                byDay[day] = (byDay[day] || 0) + 1;
            });

            const days = Object.keys(byDay).sort().slice(-14);
            const counts = days.map(day => byDay[day]);

            new Chart(ctx, {
                type: 'bar',
                data: {
                    labels: days.map(d => d.slice(5)),
                    datasets: [{
                        label: 'Deployments',
                        data: counts,
                        backgroundColor: '#3b82f6'
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        y: { beginAtZero: true, grid: { color: '#1e293b' } },
                        x: { grid: { display: false } }
                    },
                    plugins: { legend: { display: false } }
                }
            });
        }

        // Duration Trend Chart
        function renderDurationTrendChart() {
            const ctx = document.getElementById('durationTrendChart');
            if (!ctx || deployments.length === 0) return;

            const recent = deployments.slice(0, 30).reverse();
            const labels = recent.map((d, i) => '#' + (deployments.length - 29 + i));
            const durations = recent.map(d => Math.round((d.duration_seconds || 0) / 60));

            new Chart(ctx, {
                type: 'line',
                data: {
                    labels: labels,
                    datasets: [{
                        label: 'Minutes',
                        data: durations,
                        borderColor: '#f59e0b',
                        backgroundColor: 'rgba(245, 158, 11, 0.1)',
                        fill: true,
                        tension: 0.3,
                        pointRadius: 2
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        y: { beginAtZero: true, grid: { color: '#1e293b' } },
                        x: { grid: { display: false }, display: false }
                    },
                    plugins: { legend: { display: false } }
                }
            });
        }

        // Initialize charts
        renderSuccessRateChart();
        renderDeploymentsPerDayChart();
        renderDurationTrendChart();
    </script>
</body>
</html>`, lastUpdatedDisplay, len(deployments), successRateClass, successRate, formatDuration(avgDuration),
		len(deployments), statusColor(lastStatus), lastStatusTitle, lastDeployRelative,
		failedServicesHTML, deploymentsHTMLOrEmpty, servicesHTMLOrEmpty, string(deploymentsJSON), string(servicesJSON))

	return page, nil
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
