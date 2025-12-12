# Glance Dashboard Integration

This document describes the Glance dashboard integration in the homelab automation system.

## Overview

Glance is a self-hosted dashboard application that provides a beautiful, customizable homepage with various widgets for monitoring services, displaying information, and staying updated with news feeds.

## Features

### Included Widgets

#### 📊 Monitoring & System
- **Docker Containers**: Monitor running containers and their status
- **Server Stats**: CPU usage, memory, disk space
- **Service Health**: HTTP(s) monitoring of services
- **GitHub Releases**: Track releases for important projects

#### 🌐 Information & Utilities
- **Weather**: Current conditions and forecast (configurable location)
- **Calendar**: Display events and schedules
- **Clock**: Multiple timezone clocks (New York, Tokyo, etc.)
- **Bookmarks**: Quick access to important services

#### 📰 News & Feeds
- **RSS Feeds**:
  - Hacker News
  - The Verge
  - TechCrunch
- **Reddit Feeds**: r/selfhosted
- **Lobsters**: Tech news aggregator
- **Hacker News Feed**: Dedicated HN widget

### Dashboard Layout

The Glance dashboard is organized into 3 pages:

1. **Home**: Main dashboard with weather, calendar, server stats, and services
2. **Monitoring**: Service health checks and system monitoring
3. **News**: Aggregated news feeds from various sources

## Configuration

### services.yml Configuration

Services are defined in [configs/services.yml](configs/services.yml). Key sections:

```yaml
global:
  domain: example.com
  email: admin@example.com
  location: "London, United Kingdom"  # Used for weather widget

dashboard:
  name: "Homelab Dashboard"
  theme: "dark"
  timezone: "Europe/London"

services:
  - name: Glance
    domain: home.example.com
    port: 8080
    enabled: true
    icon: si:glance
```

### Template File

The Glance configuration template is at [configs/glance/glance.yml.template](configs/glance/glance.yml.template).

Environment variables used:
- `${LOCATION}`: Location for weather widget (from services.yml)
- `${SERVER_NAME}`: Hostname of the server
- `${DASHBOARD_NAME}`: Dashboard title (from services.yml)

### Auto-Generation

The `generate-configs.sh` script automatically:
1. Reads services.yml
2. Generates glance.yml from template
3. Replaces environment variables
4. Adds enabled services to monitoring widgets
5. Creates docker-compose.yml for Glance

## Deployment

### Automatic Deployment

Glance is deployed automatically via GitHub Actions workflows:

1. **Deploy VPS**: [.github/workflows/deploy-vps.yml](../.github/workflows/deploy-vps.yml)
2. **Deploy Home Server**: [.github/workflows/deploy-homeserver.yml](../.github/workflows/deploy-homeserver.yml)
3. **Deploy All**: [.github/workflows/deploy-all.yml](../.github/workflows/deploy-all.yml)

The deployment steps:
1. Copy configurations to target device
2. Generate Glance config from template
3. Run `05-glance-setup.sh` deployment script
4. Start Glance Docker container

### Manual Deployment

```bash
# SSH to target device via Tailscale
tailscale ssh user@hostname

# Navigate to homelab deploy directory
cd /tmp/homelab-deploy

# Generate configurations
sudo bash scripts/generate-configs.sh /tmp/homelab-deploy/configs/services.yml

# Deploy Glance
sudo bash scripts/05-glance-setup.sh
```

### Deployment Script

The [scripts/05-glance-setup.sh](scripts/05-glance-setup.sh) script:
- Validates Docker is running
- Checks configuration files exist
- Creates Docker network if needed
- Starts Glance container
- Verifies successful deployment
- Displays access information

## Access

After deployment:
- **Local**: http://localhost:8080
- **Behind Caddy**: https://home.example.com (configured domain)

## Docker Configuration

Glance runs as a Docker container with:
- **Image**: glanceapp/glance:latest
- **Port**: 8080
- **Network**: caddy_network (shared with Caddy)
- **Volumes**:
  - `./glance.yml:/app/config/glance.yml:ro` (config file)
  - `/var/run/docker.sock:/var/run/docker.sock:ro` (Docker monitoring)

## Customization

### Adding Widgets

To add new widgets, edit [configs/glance/glance.yml.template](configs/glance/glance.yml.template):

```yaml
pages:
  - name: Home
    columns:
      - size: small
        widgets:
          - type: weather
            location: ${LOCATION}
          
          # Add your widget here
          - type: markets
            title: Crypto Prices
            markets:
              - symbol: BTC-USD
                name: Bitcoin
```

Available widget types:
- `weather`, `calendar`, `clock`, `bookmarks`
- `docker-containers`, `monitor`, `extension`
- `rss`, `reddit`, `lobsters`, `hacker-news`
- `releases`, `repository`, `markets`
- `videos`, `twitch-channels`, `twitch-top-games`

See [Glance Documentation](https://github.com/glanceapp/glance) for full widget reference.

### Changing Theme

Modify the theme section in glance.yml.template:

```yaml
theme:
  background-color: 240 8 9     # HSL: Hue Saturation Lightness
  primary-color: 43 50 70
  positive-color: 115 54 91
  negative-color: 347 70 65
```

### Adding Services to Monitor

Services with `enabled: true` and a `domain` field in services.yml are automatically added to the monitor widget.

Manual addition:
```yaml
- type: monitor
  title: Service Health
  sites:
    - title: My Service
      url: https://service.example.com
      icon: si:service-icon
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker logs glance

# Verify configuration syntax
docker run --rm -v /opt/glance/glance.yml:/config.yml glanceapp/glance validate /config.yml

# Check if port 8080 is available
sudo netstat -tlnp | grep 8080
```

### Configuration Not Applied

```bash
# Restart container to reload config
docker restart glance

# Force recreation
cd /opt/glance
docker compose down
docker compose up -d
```

### Docker Containers Not Showing

Ensure Docker socket is mounted:
```bash
# Check volume mount
docker inspect glance | grep -A5 Mounts

# Verify socket accessibility
docker exec glance ls -l /var/run/docker.sock
```

### Weather Widget Not Working

1. Verify location format in services.yml: `"City, Country"`
2. Check Glance logs for API errors: `docker logs glance | grep -i weather`
3. Location must be recognized by weather API

### Can't Access Behind Caddy

1. Verify Caddy reverse proxy configuration:
   ```bash
   cat /opt/caddy/Caddyfile | grep -A3 "home.example.com"
   ```

2. Check Caddy is running:
   ```bash
   docker ps | grep caddy
   docker logs caddy
   ```

3. Ensure Glance and Caddy are on same network:
   ```bash
   docker network inspect caddy_network
   ```

## Integration Points

### Caddy Reverse Proxy

Glance is automatically added to Caddy configuration from services.yml:

```caddyfile
# Glance
home.example.com {
    reverse_proxy localhost:8080
}
```

### Uptime Kuma (Future)

The Monitoring page includes a placeholder for Uptime Kuma integration. When Uptime Kuma is deployed:

1. Use Uptime Kuma's API to fetch service status
2. Display status in Glance monitor widget
3. Or embed Uptime Kuma status page iframe

See [configs/uptime-kuma/README.md](uptime-kuma/README.md) for setup.

## Backup & Restore

Glance configuration is stored in `/opt/glance/glance.yml`.

### Backup

```bash
# Backup Glance directory
tar czf glance-backup-$(date +%Y%m%d).tar.gz /opt/glance/

# Or just config
cp /opt/glance/glance.yml ~/backups/
```

### Restore

```bash
# Restore from backup
tar xzf glance-backup-YYYYMMDD.tar.gz -C /

# Restart container
docker restart glance
```

## Performance

Glance is lightweight and has minimal resource requirements:
- **CPU**: <1% during normal operation
- **Memory**: ~50-100MB
- **Disk**: <100MB (image + config)

Widget refresh intervals can be configured to reduce load:
```yaml
- type: rss
  refresh: 600  # Refresh every 10 minutes (default: 60s)
```

## Resources

- **Official Repository**: https://github.com/glanceapp/glance
- **Documentation**: https://github.com/glanceapp/glance/blob/main/docs/configuration.md
- **Docker Hub**: https://hub.docker.com/r/glanceapp/glance
- **Widget Reference**: https://github.com/glanceapp/glance/blob/main/docs/widgets.md

## Future Enhancements

- [ ] Dynamic service addition from services.yml to all monitoring widgets
- [ ] Automatic bookmark generation from services
- [ ] Integration with Uptime Kuma API for real-time status
- [ ] Custom widget for Tailscale network status
- [ ] Multi-tenant support (different dashboards per device)
- [ ] Backup automation
- [ ] Mobile-optimized layout option
