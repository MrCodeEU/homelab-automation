#!/usr/bin/env python3
"""Generate the deployment status page from deployment data."""

import json
import sys
from datetime import datetime
from pathlib import Path


def format_duration(seconds: int) -> str:
    """Format duration in human-readable form."""
    if seconds < 60:
        return f"{seconds}s"
    minutes = seconds // 60
    secs = seconds % 60
    if minutes < 60:
        return f"{minutes}m {secs}s"
    hours = minutes // 60
    mins = minutes % 60
    return f"{hours}h {mins}m"


def format_relative_time(timestamp: str) -> str:
    """Format timestamp as relative time."""
    try:
        dt = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
        now = datetime.now(dt.tzinfo)
        diff = now - dt

        if diff.days > 30:
            return dt.strftime('%b %d, %Y')
        elif diff.days > 0:
            return f"{diff.days}d ago"
        elif diff.seconds > 3600:
            return f"{diff.seconds // 3600}h ago"
        elif diff.seconds > 60:
            return f"{diff.seconds // 60}m ago"
        else:
            return "just now"
    except Exception:
        return timestamp[:10]


def generate_html(data: dict) -> str:
    """Generate the status page HTML."""

    deployments = data.get('deployments', [])
    services = data.get('services', [])
    last_updated = data.get('last_updated', '')

    # Calculate stats from recent deployments
    recent = deployments[:100] if deployments else []
    success_count = len([d for d in recent if d.get('status') == 'success'])
    success_rate = (success_count / len(recent) * 100) if recent else 0

    durations = [d.get('duration_seconds', 0) for d in recent if d.get('duration_seconds')]
    avg_duration = sum(durations) // len(durations) if durations else 0

    last_status = deployments[0].get('status', 'none') if deployments else 'none'
    last_deployment = deployments[0] if deployments else None

    # Group services by host
    services_by_host = {}
    for svc in services:
        host = svc.get('host', 'unknown')
        if host not in services_by_host:
            services_by_host[host] = []
        services_by_host[host].append(svc)

    # Host display order and labels
    host_order = ['mljr', 'nuc', 'nas', 'pi', 'monitoring']
    host_labels = {
        'mljr': 'Production Server (mljr)',
        'nuc': 'Staging Server (nuc)',
        'nas': 'NAS (Unraid)',
        'pi': 'Raspberry Pi',
        'monitoring': 'Monitoring Host'
    }

    # Prepare JSON for JavaScript
    deployments_json = json.dumps(deployments[:200])  # Last 200 for charts
    services_json = json.dumps(services)

    # Status colors
    status_colors = {
        'success': 'text-emerald-400',
        'failed': 'text-red-400',
        'none': 'text-slate-400'
    }
    status_bg = {
        'success': 'bg-emerald-500/20 border-emerald-500/30',
        'failed': 'bg-red-500/20 border-red-500/30',
        'none': 'bg-slate-500/20 border-slate-500/30'
    }

    # Generate services HTML
    services_html = ""
    for host in host_order:
        if host not in services_by_host:
            continue
        host_services = services_by_host[host]
        services_html += f'''
        <div class="mb-8">
            <h3 class="text-lg font-semibold text-slate-300 mb-4 flex items-center gap-2">
                <span class="w-2 h-2 rounded-full bg-emerald-400"></span>
                {host_labels.get(host, host)}
                <span class="text-sm font-normal text-slate-500">({len(host_services)} services)</span>
            </h3>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        '''
        for svc in sorted(host_services, key=lambda x: x.get('name', '')):
            domain = svc.get('domain')
            if isinstance(domain, list):
                domain = domain[0] if domain else None

            url = f"https://{domain}" if domain else None
            icon = svc.get('icon', 'mdi:application')
            name = svc.get('name', 'Unknown')
            desc = svc.get('description', '')[:50]

            link_class = 'hover:bg-slate-700/50 cursor-pointer' if url else 'opacity-60'
            link_attr = f'onclick="window.open(\'{url}\', \'_blank\')"' if url else ''

            services_html += f'''
                <div class="bg-slate-800/50 rounded-lg p-3 border border-slate-700/50 {link_class} transition-all" {link_attr}>
                    <div class="flex items-center gap-3">
                        <div class="w-8 h-8 rounded bg-slate-700/50 flex items-center justify-center text-slate-400">
                            <span class="text-sm">{name[0].upper()}</span>
                        </div>
                        <div class="flex-1 min-w-0">
                            <div class="font-medium text-slate-200 truncate">{name}</div>
                            <div class="text-xs text-slate-500 truncate">{domain or 'No public URL'}</div>
                        </div>
                    </div>
                </div>
            '''
        services_html += '''
            </div>
        </div>
        '''

    # Generate recent deployments HTML
    deployments_html = ""
    for dep in deployments[:10]:
        status = dep.get('status', 'unknown')
        status_icon = '&#10003;' if status == 'success' else '&#10007;'
        status_class = 'text-emerald-400' if status == 'success' else 'text-red-400'

        timestamp = dep.get('timestamp', '')
        relative = format_relative_time(timestamp)
        duration = format_duration(dep.get('duration_seconds', 0))
        branch = dep.get('branch', 'unknown')
        actor = dep.get('actor', 'unknown')
        commit = dep.get('commit_sha', '')[:7]

        summary = dep.get('summary', {})
        ok_count = summary.get('ok', 0)
        failed_count = summary.get('failed', 0)
        total = summary.get('total_services', ok_count + failed_count)

        check_badge = '<span class="px-1.5 py-0.5 text-xs bg-amber-500/20 text-amber-400 rounded">dry-run</span>' if dep.get('check_mode') else ''
        staging_badge = '<span class="px-1.5 py-0.5 text-xs bg-purple-500/20 text-purple-400 rounded">staging</span>' if dep.get('is_staging') else ''

        deployments_html += f'''
        <tr class="border-b border-slate-800 hover:bg-slate-800/30">
            <td class="py-3 px-4">
                <span class="{status_class} text-lg">{status_icon}</span>
            </td>
            <td class="py-3 px-4">
                <div class="text-slate-200">{relative}</div>
                <div class="text-xs text-slate-500">{timestamp[:19].replace('T', ' ')}</div>
            </td>
            <td class="py-3 px-4 text-slate-300">{duration}</td>
            <td class="py-3 px-4">
                <span class="text-slate-300">{branch}</span>
                <span class="text-slate-500 text-xs ml-1">({commit})</span>
            </td>
            <td class="py-3 px-4 text-slate-400">{actor}</td>
            <td class="py-3 px-4">
                <span class="text-emerald-400">{ok_count}</span>
                <span class="text-slate-600">/</span>
                <span class="text-red-400">{failed_count}</span>
                <span class="text-slate-600">/</span>
                <span class="text-slate-400">{total}</span>
            </td>
            <td class="py-3 px-4 space-x-1">{check_badge}{staging_badge}</td>
        </tr>
        '''

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Deployment Status - mljr.eu</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <meta http-equiv="refresh" content="60">
    <style>
        .chart-container {{ position: relative; height: 200px; }}
    </style>
</head>
<body class="bg-slate-900 text-slate-100 min-h-screen">
    <div class="max-w-7xl mx-auto px-4 py-8">
        <!-- Header -->
        <header class="mb-8">
            <div class="flex items-center justify-between">
                <div>
                    <h1 class="text-3xl font-bold text-white">Deployment Status</h1>
                    <p class="text-slate-400 mt-1">Homelab Infrastructure Monitoring</p>
                </div>
                <div class="text-right text-sm text-slate-500">
                    <div>Last updated: {last_updated[:19].replace('T', ' ') if last_updated else 'Never'} UTC</div>
                    <div>Total deployments: {len(deployments)}</div>
                </div>
            </div>
        </header>

        <!-- Stats Cards -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Success Rate</div>
                <div class="text-2xl font-bold {status_colors.get('success' if success_rate >= 80 else 'failed')}">{success_rate:.1f}%</div>
                <div class="text-xs text-slate-500">last 100 deploys</div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Avg Duration</div>
                <div class="text-2xl font-bold text-blue-400">{format_duration(avg_duration)}</div>
                <div class="text-xs text-slate-500">last 100 deploys</div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Total Deploys</div>
                <div class="text-2xl font-bold text-slate-200">{len(deployments)}</div>
                <div class="text-xs text-slate-500">all time</div>
            </div>
            <div class="bg-slate-800/50 rounded-xl p-4 border border-slate-700/50">
                <div class="text-sm text-slate-400 mb-1">Last Deploy</div>
                <div class="text-2xl font-bold {status_colors.get(last_status, 'text-slate-400')}">{last_status.title()}</div>
                <div class="text-xs text-slate-500">{format_relative_time(last_deployment.get('timestamp', '')) if last_deployment else 'Never'}</div>
            </div>
        </div>

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
                <h2 class="text-lg font-semibold text-slate-200">Recent Deployments</h2>
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
                            <th class="py-2 px-4">Services</th>
                            <th class="py-2 px-4">Flags</th>
                        </tr>
                    </thead>
                    <tbody>
                        {deployments_html if deployments_html else '<tr><td colspan="7" class="py-8 text-center text-slate-500">No deployments yet</td></tr>'}
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Services Grid -->
        <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
            <h2 class="text-lg font-semibold text-slate-200 mb-4">Services</h2>
            {services_html if services_html else '<p class="text-slate-500">No services configured</p>'}
        </div>

        <!-- Footer -->
        <footer class="mt-8 text-center text-sm text-slate-500">
            <a href="https://github.com/MrCodeEU/homelab-automation" class="hover:text-slate-300">
                MrCodeEU/homelab-automation
            </a>
            <span class="mx-2">|</span>
            Auto-refreshes every 60 seconds
        </footer>
    </div>

    <script>
        const deployments = {deployments_json};
        const services = {services_json};

        // Chart.js default config
        Chart.defaults.color = '#94a3b8';
        Chart.defaults.borderColor = '#334155';

        // Success Rate Chart
        function renderSuccessRateChart() {{
            const ctx = document.getElementById('successRateChart');
            if (!ctx || deployments.length === 0) return;

            const byDay = {{}};
            deployments.forEach(d => {{
                const day = d.timestamp.split('T')[0];
                if (!byDay[day]) byDay[day] = {{ success: 0, total: 0 }};
                byDay[day].total++;
                if (d.status === 'success') byDay[day].success++;
            }});

            const days = Object.keys(byDay).sort().slice(-30);
            const rates = days.map(day => (byDay[day].success / byDay[day].total * 100).toFixed(1));

            new Chart(ctx, {{
                type: 'line',
                data: {{
                    labels: days.map(d => d.slice(5)),
                    datasets: [{{
                        label: 'Success %',
                        data: rates,
                        borderColor: '#10b981',
                        backgroundColor: 'rgba(16, 185, 129, 0.1)',
                        fill: true,
                        tension: 0.3,
                        pointRadius: 2
                    }}]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        y: {{ min: 0, max: 100, grid: {{ color: '#1e293b' }} }},
                        x: {{ grid: {{ display: false }} }}
                    }},
                    plugins: {{ legend: {{ display: false }} }}
                }}
            }});
        }}

        // Deployments per Day Chart
        function renderDeploymentsPerDayChart() {{
            const ctx = document.getElementById('deploymentsPerDayChart');
            if (!ctx || deployments.length === 0) return;

            const byDay = {{}};
            deployments.forEach(d => {{
                const day = d.timestamp.split('T')[0];
                byDay[day] = (byDay[day] || 0) + 1;
            }});

            const days = Object.keys(byDay).sort().slice(-14);
            const counts = days.map(day => byDay[day]);

            new Chart(ctx, {{
                type: 'bar',
                data: {{
                    labels: days.map(d => d.slice(5)),
                    datasets: [{{
                        label: 'Deployments',
                        data: counts,
                        backgroundColor: '#3b82f6'
                    }}]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        y: {{ beginAtZero: true, grid: {{ color: '#1e293b' }} }},
                        x: {{ grid: {{ display: false }} }}
                    }},
                    plugins: {{ legend: {{ display: false }} }}
                }}
            }});
        }}

        // Duration Trend Chart
        function renderDurationTrendChart() {{
            const ctx = document.getElementById('durationTrendChart');
            if (!ctx || deployments.length === 0) return;

            const recent = deployments.slice(0, 30).reverse();
            const labels = recent.map((d, i) => '#' + (deployments.length - 29 + i));
            const durations = recent.map(d => Math.round((d.duration_seconds || 0) / 60));

            new Chart(ctx, {{
                type: 'line',
                data: {{
                    labels: labels,
                    datasets: [{{
                        label: 'Minutes',
                        data: durations,
                        borderColor: '#f59e0b',
                        backgroundColor: 'rgba(245, 158, 11, 0.1)',
                        fill: true,
                        tension: 0.3,
                        pointRadius: 2
                    }}]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        y: {{ beginAtZero: true, grid: {{ color: '#1e293b' }} }},
                        x: {{ grid: {{ display: false }}, display: false }}
                    }},
                    plugins: {{ legend: {{ display: false }} }}
                }}
            }});
        }}

        // Initialize charts
        renderSuccessRateChart();
        renderDeploymentsPerDayChart();
        renderDurationTrendChart();
    </script>
</body>
</html>'''


def main():
    if len(sys.argv) < 3:
        print("Usage: generate_deploy_page.py <input_json> <output_html>")
        sys.exit(1)

    input_file = Path(sys.argv[1])
    output_file = Path(sys.argv[2])

    # Load data
    if input_file.exists():
        with open(input_file, 'r') as f:
            data = json.load(f)
    else:
        data = {'deployments': [], 'services': [], 'last_updated': ''}

    # Generate HTML
    html = generate_html(data)

    # Write output
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with open(output_file, 'w') as f:
        f.write(html)

    print(f"Generated {output_file} with {len(data.get('deployments', []))} deployments")


if __name__ == '__main__':
    main()
