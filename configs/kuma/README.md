# Uptime Kuma Monitoring

Uptime Kuma is a self-hosted monitoring tool similar to Uptime Robot.

## Features

- **Service Monitoring**: HTTP(s), TCP, DNS, Ping, Docker Container, etc.
- **Notifications**: Multiple notification channels (Telegram, Discord, Slack, Email, etc.)
- **Status Pages**: Public status pages for your services
- **Multi-language**: Support for 20+ languages
- **Beautiful UI**: Modern and intuitive dashboard

## Installation

### Manual Deployment

```bash
# Navigate to Uptime Kuma directory
cd /opt/uptime-kuma

# Copy the docker-compose file
cp /path/to/configs/uptime-kuma/docker-compose.yml .

# Start Uptime Kuma
docker compose up -d

# Check logs
docker logs -f uptime-kuma
```

### Automatic Deployment

Uptime Kuma deployment will be added to the automation scripts in a future update.

## Configuration

### Initial Setup

1. Access Uptime Kuma at `https://status.yourdomain.com` (after Caddy reverse proxy is configured)
2. Create an admin account on first access
3. Start adding monitors for your services

### Adding Monitors

1. Click "Add New Monitor"
2. Select monitor type (HTTP(s), TCP, Ping, etc.)
3. Configure:
   - **Friendly Name**: Service name (e.g., "Homepage")
   - **URL**: Service URL to monitor
   - **Heartbeat Interval**: How often to check (default: 60s)
   - **Retries**: Number of retries before marking as down
   - **Notification**: Select notification channels

### Recommended Monitors for Homelab

Add monitors for:
- ✅ Caddy reverse proxy (localhost:2019)
- ✅ Glance dashboard (localhost:8080)
- ✅ Portainer (localhost:9443)
- ✅ Homepage dashboard (localhost:3000)
- ✅ Each of your public-facing services

### Status Page

Create a public status page:
1. Go to "Status Page" section
2. Click "New Status Page"
3. Configure:
   - **Slug**: URL path (e.g., `status`)
   - **Title**: "Homelab Services Status"
   - **Description**: Brief description
4. Add monitors to display
5. Customize theme and layout
6. Save and publish

## Integration with Glance

Uptime Kuma can be integrated into the Glance dashboard to show service status at a glance.

### API Integration (Planned)

The Glance configuration includes a placeholder for Uptime Kuma integration on the Monitoring page:

```yaml
# In glance.yml
- type: monitor
  title: Service Health
  sites:
    # Services are auto-populated from services.yml
    # Uptime Kuma API integration coming soon
```

### Current Workaround

For now, embed Uptime Kuma status page in Glance:
1. Create a public status page in Uptime Kuma
2. Add iframe or link to Glance dashboard
3. Use Glance's monitor widget to duplicate key service checks

## Backup

Uptime Kuma data is stored in a Docker volume. To backup:

```bash
# Backup data volume
docker run --rm \
  -v uptime-kuma-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/uptime-kuma-backup-$(date +%Y%m%d).tar.gz -C /data .

# Restore from backup
docker run --rm \
  -v uptime-kuma-data:/data \
  -v $(pwd):/backup \
  alpine sh -c "cd /data && tar xzf /backup/uptime-kuma-backup-YYYYMMDD.tar.gz"
```

## Reverse Proxy Configuration

Uptime Kuma is automatically configured in Caddy if enabled in `services.yml`:

```yaml
services:
  - name: Uptime Kuma
    domain: status.example.com
    port: 3001
    enabled: true
    icon: si:uptimekuma
```

## Troubleshooting

### Container won't start

```bash
# Check logs
docker logs uptime-kuma

# Check if port 3001 is already in use
sudo netstat -tlnp | grep 3001

# Restart container
docker restart uptime-kuma
```

### Can't access web interface

1. Verify container is running: `docker ps | grep uptime-kuma`
2. Check Caddy reverse proxy configuration
3. Ensure port 3001 is accessible locally: `curl http://localhost:3001`

### Database corruption

If the SQLite database gets corrupted:

```bash
# Stop container
docker stop uptime-kuma

# Backup current data
docker run --rm -v uptime-kuma-data:/data -v $(pwd):/backup alpine tar czf /backup/kuma-corrupted.tar.gz -C /data .

# Remove volume and recreate
docker volume rm uptime-kuma-data
docker compose up -d

# You'll need to reconfigure from scratch
```

## Resources

- [Official Documentation](https://github.com/louislam/uptime-kuma/wiki)
- [Docker Hub](https://hub.docker.com/r/louislam/uptime-kuma)
- [GitHub Repository](https://github.com/louislam/uptime-kuma)

## Future Enhancements

- [ ] Automated deployment script (06-uptime-kuma-setup.sh)
- [ ] Integration with Glance dashboard via API
- [ ] Automatic monitor creation from services.yml
- [ ] Backup automation
- [ ] Notification configuration templates
