# Nightscout + LibreLink Up Configuration

This directory contains the configuration for running Nightscout CGM monitoring with automatic LibreLink Up data synchronization.

## What This Stack Includes

- **Nightscout**: Web-based CGM (Continuous Glucose Monitor) viewer
- **MongoDB**: Database for storing CGM readings
- **LibreLink Up Connector**: Custom Go implementation that automatically fetches glucose readings from LibreLink Up and uploads to Nightscout

## Setup Instructions

### 1. Configure Environment Variables

Copy the example environment file and configure it:

```bash
cd /opt/nightscout
cp .env.example .env
nano .env
```

### 2. Required Settings

**Nightscout:**
- `API_SECRET`: Your master password (minimum 12 characters)
  - Example: `mySecurePassword123`
  - Keep this secret!

**LibreLink Up:**
- `LINK_UP_USERNAME`: Your LibreLink Up email
- `LINK_UP_PASSWORD`: Your LibreLink Up password
- `LINK_UP_REGION`: Your region (EU, US, DE, etc.)

**API Token Generation:**

The LibreLink Up connector needs a SHA1 hash of an access token. Generate it like this:

```bash
# 1. Choose a token name (e.g., "librelink-connector")
# 2. Generate SHA1 hash
echo -n "librelink-connector" | sha1sum | cut -d ' ' -f 1

# 3. Add the output to .env file as:
# NIGHTSCOUT_API_TOKEN=<your-hash-here>
```

### 3. Set Domain Name

Update `services.yml` to add Nightscout:

```yaml
services:
  - name: nightscout
    enabled: true
    domain: "nightscout.yourdomain.com"
    port: 1337
    description: "CGM Monitor"
    icon: "mdi:diabetes"
```

Then regenerate configs:

```bash
/tmp/homelab-deploy/scripts/generate-configs.sh
```

### 4. Deploy

```bash
cd /opt/nightscout
docker compose up -d
```

### 5. Verify Deployment

Check that all services are running:

```bash
docker compose ps
```

Check logs:

```bash
# Nightscout logs
docker logs -f nightscout

# LibreLink Up connector logs
docker logs -f nightscout-librelink-up

# MongoDB logs
docker logs -f nightscout-mongo
```

## Architecture

```
Internet
   │
   ├─> LibreLink Up (Abbott's cloud service)
   │        │
   │        │ (Polls every 5 minutes)
   │        ↓
   │   librelink-up container
   │        │
   │        │ (HTTP POST - internal network)
   │        ↓
   ├─> Caddy (HTTPS)
   │     ↓
   ├─> nightscout container (:1337)
   │        │
   │        ↓
   └─> mongo container (database)
```

**Key Points:**
- Only Nightscout is exposed via Caddy (HTTPS public access)
- LibreLink Up connector talks to Nightscout internally (no public access needed)
- MongoDB is completely internal (no external access)

## Access

- **Public Web Access**: https://nightscout.yourdomain.com
- **Local Access**: http://localhost:1337
- **API Documentation**: https://nightscout.yourdomain.com/api-docs/

## Security

1. **API_SECRET**: Keep this secret! It's your master admin password.
2. **NIGHTSCOUT_API_TOKEN**: Used internally by the connector (SHA1 hash).
3. **LibreLink Credentials**: Stored in `.env` file (never commit to git!).
4. **MongoDB**: Not exposed externally, only accessible within Docker network.

## Troubleshooting

### LibreLink Up connector can't connect

```bash
docker logs nightscout-librelink-up
```

Common issues:
- Wrong username/password
- Wrong region
- Multiple connections available (need to set LINK_UP_CONNECTION)

### Nightscout shows no data

1. Check Nightscout is running: `docker logs nightscout`
2. Check connector is uploading: `docker logs nightscout-librelink-up`
3. Check MongoDB is running: `docker logs nightscout-mongo`
4. Verify API token hash is correct

### Can't access Nightscout web interface

1. Check Caddy configuration: `/opt/caddy/Caddyfile`
2. Check Caddy logs: `docker logs caddy`
3. Verify DNS points to your server
4. Check firewall allows ports 80 and 443

## Updating

```bash
cd /opt/nightscout
docker compose pull
docker compose up -d
```

## Data Backup

MongoDB data is stored in a Docker volume. To backup:

```bash
# Backup
docker exec nightscout-mongo mongodump --out /tmp/backup
docker cp nightscout-mongo:/tmp/backup ./nightscout-backup-$(date +%Y%m%d)

# Restore
docker cp ./nightscout-backup-YYYYMMDD nightscout-mongo:/tmp/restore
docker exec nightscout-mongo mongorestore /tmp/restore
```

## Environment Variables Reference

See `.env.example` for a complete list of configuration options.

### Essential Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `API_SECRET` | Nightscout admin password | `myPassword123` |
| `LINK_UP_USERNAME` | LibreLink Up email | `user@example.com` |
| `LINK_UP_PASSWORD` | LibreLink Up password | `secret` |
| `LINK_UP_REGION` | Your region | `EU` |
| `NIGHTSCOUT_API_TOKEN` | SHA1 hash for API access | `abc123...` |

### Optional Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DISPLAY_UNITS` | Blood glucose units | `mg/dl` |
| `TIME_FORMAT` | 12 or 24 hour | `24` |
| `LINK_UP_TIME_INTERVAL` | Fetch interval (minutes) | `5` |
| `BG_HIGH` | High BG threshold | `260` |
| `BG_LOW` | Low BG threshold | `55` |

## Support

- Nightscout Documentation: https://nightscout.github.io/
- Nightscout GitHub: https://github.com/nightscout/cgm-remote-monitor
- LibreLink Up Connector: https://github.com/timoschlueter/nightscout-librelink-up
