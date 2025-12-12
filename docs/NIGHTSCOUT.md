# Nightscout + LibreLink Up Setup Guide

Complete guide for deploying Nightscout with automatic LibreLink Up data synchronization on your VPS.

## Overview

This setup deploys three Docker containers:
1. **MongoDB** - Database for storing CGM readings
2. **Nightscout** - Web-based CGM monitor with public HTTPS access
3. **LibreLink Up Connector** - Background service that fetches data from LibreLink Up

## Prerequisites

- VPS with Docker installed
- Domain name pointing to your VPS
- LibreLink Up account with an active CGM sensor
- Caddy reverse proxy set up

## Quick Start

### 1. Update services.yml

Edit your services configuration:

```bash
nano /tmp/homelab-deploy/configs/services.yml
```

Enable Nightscout and set your domain:

```yaml
services:
  - name: nightscout
    enabled: true
    domain: "nightscout.yourdomain.com"  # Change this!
    port: 1337
    description: "CGM Monitor"
    icon: "mdi:diabetes"
```

### 2. Regenerate Caddy Configuration

```bash
bash /tmp/homelab-deploy/scripts/generate-configs.sh
```

This will add Nightscout to your Caddyfile with automatic HTTPS.

### 3. Deploy Nightscout

Run the deployment script:

```bash
bash /tmp/homelab-deploy/scripts/06-nightscout-setup.sh
```

The script will:
- Create `/opt/nightscout` directory
- Copy configuration files
- Create `.env.example` file
- Exit and prompt you to configure the `.env` file

### 4. Configure Environment Variables

Edit the environment file:

```bash
nano /opt/nightscout/.env
```

#### Required Settings:

**Nightscout Admin Password:**
```bash
API_SECRET=your-secure-password-here
```
⚠️ Must be at least 12 characters! This is your admin password.

**LibreLink Up Credentials:**
```bash
LINK_UP_USERNAME=your-email@example.com
LINK_UP_PASSWORD=your-password
LINK_UP_REGION=EU  # Your region: EU, US, DE, FR, etc.
```

**API Token for Connector:**

Generate a SHA1 hash for the connector authentication:

```bash
echo -n "librelink-connector" | sha1sum | cut -d ' ' -f 1
```

Copy the output and add it to `.env`:

```bash
NIGHTSCOUT_API_TOKEN=<paste-hash-here>
```

#### Optional Settings:

```bash
# Display settings
DISPLAY_UNITS=mg/dl  # or mmol/L
TIME_FORMAT=24       # or 12
THEME=colors         # colors, default, or colorblindfriendly

# Alarm thresholds (in mg/dl)
BG_HIGH=260
BG_TARGET_TOP=180
BG_TARGET_BOTTOM=80
BG_LOW=55

# Fetch interval (minutes)
LINK_UP_TIME_INTERVAL=5
```

### 5. Deploy Again

After configuring `.env`, run the deployment script again:

```bash
bash /tmp/homelab-deploy/scripts/06-nightscout-setup.sh
```

This time it will:
- Validate your configuration
- Start all three containers
- Connect to the Caddy network
- Show deployment status

### 6. Reload Caddy

Apply the new Caddy configuration:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### 7. Verify Deployment

Check that all services are running:

```bash
cd /opt/nightscout
docker compose ps
```

You should see:
- `nightscout-mongo` - running
- `nightscout` - running
- `nightscout-librelink-up` - running

Check the logs:

```bash
# Nightscout logs
docker logs -f nightscout

# LibreLink Up connector (should show "Successfully uploaded X entries")
docker logs -f nightscout-librelink-up
```

### 8. Access Nightscout

**Public Access (HTTPS):**
```
https://nightscout.yourdomain.com
```

**Local Access:**
```
http://localhost:1337
```

## Troubleshooting

### LibreLink Up connector not fetching data

Check the connector logs:
```bash
docker logs nightscout-librelink-up
```

**Common issues:**

1. **"Invalid credentials"** - Check your LibreLink Up username/password in `.env`

2. **"Region not supported"** - Verify `LINK_UP_REGION` is correct:
   - Europe: `EU`
   - United States: `US`
   - Germany: `DE`
   - France: `FR`
   - See full list in `.env.example`

3. **"Multiple connections found"** - If you follow multiple people on LibreLink Up:
   ```bash
   docker logs nightscout-librelink-up | grep "connection"
   ```
   Copy the patient ID and add to `.env`:
   ```bash
   LINK_UP_CONNECTION=abc123-patient-id-here
   ```
   Then restart:
   ```bash
   docker compose restart librelink-up
   ```

4. **"Cannot connect to Nightscout"** - Check API token:
   ```bash
   # Regenerate hash
   echo -n "librelink-connector" | sha1sum | cut -d ' ' -f 1
   # Update .env and restart
   docker compose restart librelink-up
   ```

### Nightscout not accessible via HTTPS

1. **Check DNS:**
   ```bash
   dig nightscout.yourdomain.com
   ```
   Should point to your VPS IP.

2. **Check Caddy:**
   ```bash
   docker logs caddy
   ```
   Look for certificate errors.

3. **Check firewall:**
   ```bash
   sudo firewall-cmd --list-all
   ```
   Ports 80 and 443 should be open.

4. **Manual certificate request:**
   ```bash
   docker exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

### Glance error: "assets directory does not exist"

This has been fixed! If you deployed before the fix:

1. Regenerate Glance configuration:
   ```bash
   bash /tmp/homelab-deploy/scripts/generate-configs.sh
   ```

2. Restart Glance:
   ```bash
   docker restart glance
   ```

### No data showing in Nightscout

1. **Wait 5-10 minutes** - Initial data fetch can take time

2. **Check connector is uploading:**
   ```bash
   docker logs nightscout-librelink-up | grep -i "upload"
   ```

3. **Check MongoDB:**
   ```bash
   docker exec nightscout-mongo mongo nightscout --eval "db.entries.count()"
   ```
   Should show entries > 0

4. **Check Nightscout can read from MongoDB:**
   ```bash
   curl http://localhost:1337/api/v1/entries.json
   ```

## Security Notes

### Protect Your Credentials

The `.env` file contains sensitive information:
- Never commit to git
- Restrict file permissions:
  ```bash
  chmod 600 /opt/nightscout/.env
  ```

### API Security

- `API_SECRET` - Your master admin password (keep secret!)
- `NIGHTSCOUT_API_TOKEN` - SHA1 hash used by connector (can be regenerated)
- Use strong passwords (min 12 characters)

### Network Security

- MongoDB is NOT exposed externally (internal Docker network only)
- LibreLink Up connector uses internal network to talk to Nightscout
- Only Nightscout web interface is exposed via HTTPS through Caddy

## Advanced Configuration

### Enable Additional Nightscout Plugins

Edit `.env` and add plugins to `ENABLE`:

```bash
ENABLE="careportal basal dbsize iob cob sage cage"
```

Available plugins:
- `careportal` - Treatment entry form
- `iob` - Insulin on Board
- `cob` - Carbs on Board  
- `sage` - Sensor Age
- `cage` - Cannula Age
- `basal` - Basal rate display
- See Nightscout docs for full plugin list

### Configure Alarms

Customize alarm thresholds in `.env`:

```bash
# Enable/disable alarms
ALARM_HIGH=on
ALARM_LOW=on
ALARM_URGENT_HIGH=on
ALARM_URGENT_LOW=on

# Snooze durations (minutes)
ALARM_HIGH_MINS="30 60 90 120"
ALARM_LOW_MINS="15 30 45 60"
```

### Push Notifications (Pushover)

Get push notifications on your phone:

1. Create Pushover account: https://pushover.net
2. Create Pushover application
3. Add to `.env`:
   ```bash
   PUSHOVER_API_TOKEN=your-app-token
   PUSHOVER_USER_KEY=your-user-key
   ```
4. Restart: `docker compose restart nightscout`

### Fetch All Historical Data

By default, only new data is fetched. To backfill:

Edit `.env`:
```bash
ALL_DATA=true
```

Restart connector:
```bash
docker compose restart librelink-up
```

After initial backfill, you can set `ALL_DATA=false` again.

## Backup & Restore

### Backup MongoDB Data

```bash
# Create backup
docker exec nightscout-mongo mongodump --out /tmp/backup
docker cp nightscout-mongo:/tmp/backup ./nightscout-backup-$(date +%Y%m%d)
tar -czf nightscout-backup-$(date +%Y%m%d).tar.gz ./nightscout-backup-$(date +%Y%m%d)
```

### Restore MongoDB Data

```bash
# Extract backup
tar -xzf nightscout-backup-YYYYMMDD.tar.gz

# Restore to container
docker cp ./nightscout-backup-YYYYMMDD nightscout-mongo:/tmp/restore
docker exec nightscout-mongo mongorestore /tmp/restore
```

### Backup Configuration

```bash
cp /opt/nightscout/.env ~/nightscout-env-backup-$(date +%Y%m%d)
```

## Updating

Update to the latest versions:

```bash
cd /opt/nightscout
docker compose pull
docker compose up -d
```

Check logs after update:
```bash
docker compose logs -f
```

## Useful Commands

```bash
# View all logs
cd /opt/nightscout && docker compose logs -f

# View specific service
docker logs -f nightscout
docker logs -f nightscout-librelink-up
docker logs -f nightscout-mongo

# Restart all services
docker compose restart

# Restart specific service
docker compose restart librelink-up

# Stop everything
docker compose down

# Start everything
docker compose up -d

# Check resource usage
docker stats

# Access MongoDB directly
docker exec -it nightscout-mongo mongo nightscout
```

## Integration with Glance Dashboard

After deploying Nightscout, update your Glance dashboard:

1. Edit the Glance template:
   ```bash
   nano /tmp/homelab-deploy/configs/glance/glance.yml.template
   ```

2. Find the Nightscout URL references and update to your domain

3. Regenerate Glance config:
   ```bash
   bash /tmp/homelab-deploy/scripts/generate-configs.sh
   ```

4. Restart Glance:
   ```bash
   docker restart glance
   ```

Glance will now show:
- Nightscout link in Quick Links section
- Nightscout health monitoring

## Resources

- **Nightscout Documentation**: https://nightscout.github.io/
- **Nightscout GitHub**: https://github.com/nightscout/cgm-remote-monitor
- **LibreLink Up Connector**: https://github.com/timoschlueter/nightscout-librelink-up
- **API Documentation**: https://nightscout.yourdomain.com/api-docs/

## Support

For issues specific to:
- **Nightscout**: https://github.com/nightscout/cgm-remote-monitor/issues
- **LibreLink Up Connector**: https://github.com/timoschlueter/nightscout-librelink-up/issues
- **This automation**: https://github.com/MrCodeEU/homelab-automation/issues
