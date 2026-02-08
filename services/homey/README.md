# Homey Self-Hosted Server

Homey Self-Hosted Server is a self-hosted home automation platform that runs locally on your infrastructure.

## Features

- **Local Control**: All home automation runs locally without cloud dependency
- **Extensive Device Support**: Compatible with hundreds of smart home devices
- **Custom Flows**: Create complex automation workflows
- **Mobile Apps**: Control via iOS and Android apps
- **Privacy-Focused**: Data stays on your local network

## System Requirements

- At least 1 GB available RAM
- At least 1 GB available storage
- A dedicated LAN IP address (uses host networking)
- Docker with privileged mode support

## Installation

The service is automatically deployed through Ansible when enabled in the inventory configuration.

### Manual Deployment

```bash
# Navigate to Homey directory
cd /opt/homey

# Start Homey Self-Hosted Server
docker compose up -d

# View logs
docker compose logs -f
```

## Configuration

### Initial Setup

1. After deployment, Homey will be accessible on the host's IP address
2. Download the Homey app for [iOS](https://apps.apple.com/app/homey/id1443821766) or [Android](https://play.google.com/store/apps/details?id=app.homey)
3. Open the app and select "Add Homey" → "Self-Hosted Server"
4. The app will automatically discover your Homey instance on the local network
5. Follow the on-screen instructions to complete the setup

### Networking

Homey uses `network_mode: host` which means:
- It binds directly to the host's network interfaces
- Default ports:
  - **4859**: HTTP & Socket.io Server
  - **4860**: HTTPS & Socket.io Server
  - **4861-4862**: Homey Bridge Servers
- The service is accessible at `http://<host-ip>:4859`
- Via Caddy proxy: `https://homey.mljr.eu`

### Data Persistence

Service data is stored in a Docker volume:
- Volume: `homey-data`
- Container path: `/homey/user`

## Backup

The Homey data volume should be included in the backup strategy:

```bash
# Manual backup
docker run --rm -v homey-data:/source -v /opt/backups:/backup alpine tar czf /backup/homey-backup-$(date +%Y%m%d).tar.gz -C /source .
```

## Updating

To update Homey Self-Hosted Server:

```bash
cd /opt/homey
docker compose pull
docker compose up -d
```

Or use the automated update via Ansible playbook.

## Troubleshooting

### Service Not Starting

Check the logs for errors:
```bash
docker compose logs homey-shs
```

### Can't Connect from Mobile App

1. Ensure the host firewall allows connections on ports 4859-4862
2. Verify the service is running: `docker compose ps`
3. Check network connectivity between mobile device and host
4. Ensure both devices are on the same local network

### Port Conflicts

If default ports are in use, set environment variables in `.env`:
```
PORT_SERVER_HTTP=<custom-port>
```

## Documentation

- [Official Homey Documentation](https://support.homey.app/)
- [Homey Community Forum](https://community.homey.app/)
- [Docker Installation Guide](https://support.homey.app/hc/en-us/articles/24010537261980)

## Notes

- Requires privileged mode for hardware access
- Uses host networking for optimal device discovery
- Designed for single-instance deployment per network
