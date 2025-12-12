# Deployment Summary - Nightscout Setup

## ✅ What Was Done

### 1. Fixed Glance Assets Error
- **Problem**: Glance container reported "assets directory does not exist: /app/assets"
- **Solution**: Removed unnecessary `assets-path` configuration from glance.yml.template
- **File Updated**: [configs/glance/glance.yml.template](../configs/glance/glance.yml.template)
- **Action Required**: Regenerate Glance config and restart container on VPS

### 2. Added Nightscout CGM Monitoring

Created a complete Nightscout stack with three containers:

#### Files Created:

1. **Configuration Files** (`configs/nightscout/`):
   - `.env.example` - Template with all environment variables
   - `docker-compose.yml` - Three-service stack (MongoDB, Nightscout, LibreLink-Up)
   - `README.md` - Quick reference for the Nightscout directory

2. **Deployment Script**:
   - `scripts/06-nightscout-setup.sh` - Automated deployment with validation

3. **Documentation**:
   - `docs/NIGHTSCOUT.md` - Complete setup guide with troubleshooting

4. **Integration**:
   - Updated `configs/services.yml` - Added Nightscout service definition
   - Updated `configs/glance/glance.yml.template` - Added Nightscout to dashboard
   - Updated `README.md` - Documented new feature

## 📋 Required Actions for Deployment on VPS

### Step 1: Fix Glance (Do This First!)

```bash
# SSH to your VPS
ssh root@vps.tailnet-xxx.ts.net

# Regenerate Glance config (removes assets-path)
cd /tmp/homelab-deploy
./scripts/generate-configs.sh

# Restart Glance
docker restart glance

# Verify fix
docker logs glance
# Should NOT show "assets directory does not exist" error anymore
```

### Step 2: Deploy Nightscout

#### A. Update Repository on VPS

```bash
# Get latest code with Nightscout support
cd /path/to/homelab-automation
git pull

# Copy to deployment directory
rsync -av --exclude='.git' ./ /tmp/homelab-deploy/
```

#### B. Configure Nightscout Service

Edit services.yml:
```bash
nano /tmp/homelab-deploy/configs/services.yml
```

Update Nightscout entry:
```yaml
  - name: nightscout
    enabled: true  # Change from false to true
    domain: "nightscout.YOUR-DOMAIN.com"  # Set your actual domain!
    port: 1337
    description: "CGM Monitor"
    icon: "mdi:diabetes"
```

#### C. Regenerate Configs

```bash
/tmp/homelab-deploy/scripts/generate-configs.sh
```

This will:
- Add Nightscout to Caddyfile (automatic HTTPS)
- Update Glance dashboard with Nightscout links

#### D. Deploy Nightscout

```bash
bash /tmp/homelab-deploy/scripts/06-nightscout-setup.sh
```

**First run** will:
- Create `/opt/nightscout/` directory
- Copy configuration files
- Create `.env.example`
- Exit and ask you to configure `.env`

#### E. Configure Environment Variables

```bash
nano /opt/nightscout/.env
```

**Required settings:**

```bash
# Nightscout admin password (min 12 chars)
API_SECRET=your-strong-password-here

# Your LibreLink Up credentials
LINK_UP_USERNAME=your-email@example.com
LINK_UP_PASSWORD=your-librelink-password
LINK_UP_REGION=EU  # or US, DE, FR, etc.

# Generate API token hash
# Run: echo -n "librelink-connector" | sha1sum | cut -d ' ' -f 1
NIGHTSCOUT_API_TOKEN=paste-hash-here
```

**To generate API token:**
```bash
echo -n "librelink-connector" | sha1sum | cut -d ' ' -f 1
```

#### F. Deploy Again (After Configuration)

```bash
bash /tmp/homelab-deploy/scripts/06-nightscout-setup.sh
```

This time it will:
- Validate configuration
- Start all three containers
- Show deployment status

#### G. Reload Caddy

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### Step 3: Verify Deployment

```bash
# Check all containers running
cd /opt/nightscout
docker compose ps

# Should show:
# - nightscout-mongo (running)
# - nightscout (running)
# - nightscout-librelink-up (running)

# Check logs
docker logs -f nightscout
docker logs -f nightscout-librelink-up
```

### Step 4: Access Nightscout

- **Public**: https://nightscout.YOUR-DOMAIN.com
- **Local**: http://localhost:1337

Wait 5-10 minutes for initial data sync from LibreLink Up.

## 🔧 Quick Commands Reference

### Glance Management
```bash
docker restart glance          # Restart Glance
docker logs -f glance          # View logs
```

### Nightscout Management
```bash
cd /opt/nightscout
docker compose ps              # Check status
docker compose logs -f         # View all logs
docker compose restart         # Restart all services
docker compose down            # Stop all services
docker compose up -d           # Start all services
```

### Configuration Updates
```bash
# After changing services.yml
/tmp/homelab-deploy/scripts/generate-configs.sh
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
docker restart glance
```

## 📚 Documentation

- **Complete Nightscout Guide**: [docs/NIGHTSCOUT.md](../docs/NIGHTSCOUT.md)
- **Nightscout Config Reference**: [configs/nightscout/README.md](../configs/nightscout/README.md)
- **Glance Dashboard**: [docs/GLANCE.md](../docs/GLANCE.md)

## 🎯 Architecture Overview

```
Internet
   │
   ├─> LibreLink Up (CGM data source)
   │        ↓ (polls every 5 min)
   │   librelink-up container
   │        ↓ (internal network)
   │
   ├─> Caddy :443 (HTTPS)
   │     ├─> Glance :8080
   │     └─> Nightscout :1337
   │              ↓
   └─> MongoDB (internal only)
```

**Key Points:**
- Only Caddy is exposed to internet (ports 80/443)
- MongoDB is completely internal
- LibreLink-Up uses internal network (no public access)
- All services connected via `caddy_network`

## ❓ Troubleshooting

### Glance Still Shows Assets Error
```bash
# Check if config was updated
cat /opt/glance/glance.yml | grep assets
# Should NOT show "assets-path: /app/assets"

# If it does, regenerate:
/tmp/homelab-deploy/scripts/generate-configs.sh
docker restart glance
```

### LibreLink Up Not Syncing
```bash
docker logs nightscout-librelink-up

# Common issues:
# - Wrong credentials → Check .env file
# - Wrong region → Verify LINK_UP_REGION
# - Multiple connections → Add LINK_UP_CONNECTION to .env
```

### Can't Access Nightscout via Domain
```bash
# Check Caddy
docker logs caddy | grep nightscout

# Check DNS
dig nightscout.YOUR-DOMAIN.com

# Check Caddy config
cat /opt/caddy/Caddyfile | grep nightscout

# Reload Caddy
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## ✨ Features Included

### Nightscout Stack
- ✅ Nightscout CGM web interface
- ✅ MongoDB database
- ✅ LibreLink Up automatic sync
- ✅ HTTPS via Caddy
- ✅ Internal network security
- ✅ Automatic configuration validation
- ✅ Comprehensive logging

### Integration
- ✅ Added to Glance dashboard (Quick Links + Health Monitor)
- ✅ Auto-generated Caddy configuration
- ✅ Documented in main README
- ✅ Complete setup guides

## 🎉 Next Steps

1. Deploy to VPS following steps above
2. Test LibreLink Up data sync
3. Configure alarms/notifications if desired
4. Consider adding:
   - Pushover notifications
   - Additional Nightscout plugins
   - Custom alert thresholds

## 📞 Support

- **Nightscout Issues**: https://github.com/nightscout/cgm-remote-monitor/issues
- **LibreLink Up Issues**: https://github.com/timoschlueter/nightscout-librelink-up/issues
- **This Project**: Create an issue in the repository

---

**Summary**: Glance error fixed, Nightscout fully integrated! Ready to deploy. 🚀
