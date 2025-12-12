# 🔧 Nightscout Deployment Fix

## Problem Identified

The Nightscout and LibreLink Up containers were not being deployed because:

1. **Missing deployment steps**: The `05-glance-setup.sh` and `06-nightscout-setup.sh` scripts were never called during deployment
2. **Nightscout disabled**: The `services.yml` had Nightscout set to `enabled: false`
3. **Missing API token**: The `.env.example` didn't have the NIGHTSCOUT_API_TOKEN pre-filled

## ✅ Fixes Applied

### 1. Updated Deployment Scripts
**Files modified:**
- `scripts/deploy.sh` - Added Glance and Nightscout deployment steps
- `scripts/deploy-single.sh` - Added Glance and Nightscout deployment steps

**What was added:**
```bash
# Deploy Glance dashboard (if Caddy role is included)
if [[ "$roles" == *"caddy"* ]] || [ "$roles" = "all" ]; then
    echo "Deploying Glance dashboard..."
    ssh ... "bash /tmp/homelab-deploy/05-glance-setup.sh"
fi

# Deploy Nightscout (if enabled in services.yml)
if [[ "$roles" == *"nightscout"* ]] || [ "$roles" = "all" ]; then
    echo "Deploying Nightscout (if enabled)..."
    ssh ... "bash /tmp/homelab-deploy/06-nightscout-setup.sh"
fi
```

### 2. Enabled Nightscout in services.yml
**File modified:** `configs/services.yml`

Changed:
```yaml
- name: nightscout
  enabled: false  # ← Was disabled
```

To:
```yaml
- name: nightscout
  enabled: true   # ← Now enabled
```

### 3. Pre-configured .env.example
**File modified:** `configs/nightscout/.env.example`

Added:
```bash
# Generate with: echo -n "librelink-connector" | shasum | cut -d ' ' -f 1
NIGHTSCOUT_API_TOKEN=32a6420c2c92d24c2f5e9f61c84c3a9db23789d3

# Domain name for Nightscout (used in BASE_URL)
NIGHTSCOUT_DOMAIN=nightscout.mljr.eu
```

Your credentials are already in the file:
- ✅ API_SECRET: H0s3nh0d3n124062001
- ✅ LINK_UP_USERNAME: reinemic2.0@gmail.com
- ✅ LINK_UP_PASSWORD: H0s3nh0d3n124062001
- ✅ LINK_UP_REGION: EU

### 4. Improved Setup Script
**File modified:** `scripts/06-nightscout-setup.sh`

Now automatically creates `.env` from `.env.example` if it doesn't exist.

---

## 🚀 How to Deploy Now

### Option 1: Re-run the Workflow (Recommended)

The easiest way is to re-run your GitHub Actions workflow:

1. Commit and push these changes:
   ```bash
   git add .
   git commit -m "Fix: Add Glance and Nightscout to deployment flow"
   git push
   ```

2. Go to GitHub Actions and re-run the VPS deployment workflow

This will:
- ✅ Deploy Glance (already working)
- ✅ Deploy Nightscout stack
- ✅ Start MongoDB, Nightscout, and LibreLink Up connector

### Option 2: Manual Deployment on VPS

If you want to deploy manually right now:

```bash
# SSH to your VPS
ssh root@your-vps

# Run the Nightscout deployment
cd /tmp/homelab-deploy
bash ./scripts/06-nightscout-setup.sh
```

The script will:
1. Create `/opt/nightscout/` directory
2. Copy configuration files
3. Create `.env` from `.env.example` (already has your credentials!)
4. Start the Docker Compose stack

---

## 📋 What Gets Deployed

When Nightscout deployment runs, it will create:

```
/opt/nightscout/
├── .env                    ← Your credentials (created from .env.example)
├── .env.example            ← Template with your pre-filled values
├── docker-compose.yml      ← Stack definition
└── README.md               ← Quick reference
```

And start 3 Docker containers:
1. **nightscout-mongo** - MongoDB database (internal only)
2. **nightscout** - Nightscout web interface (port 1337)
3. **nightscout-librelink-up** - LibreLink Up connector (background)

---

## 🔍 Verify Deployment

After deployment, check that containers are running:

```bash
# On your VPS
docker compose -f /opt/nightscout/docker-compose.yml ps

# Or
cd /opt/nightscout && docker compose ps
```

You should see:
```
NAME                        STATUS
nightscout-mongo           Up
nightscout                 Up
nightscout-librelink-up    Up
```

Check logs:
```bash
docker logs -f nightscout
docker logs -f nightscout-librelink-up
```

---

## 🌐 Access Nightscout

Once deployed and Caddy is configured:

- **Public URL**: https://nightscout.mljr.eu
- **Local URL**: http://localhost:1337
- **API Docs**: https://nightscout.mljr.eu/api-docs/

**Wait 5-10 minutes** for initial data sync from LibreLink Up.

---

## 🔧 Troubleshooting

### If containers don't start

Check if .env exists:
```bash
ls -la /opt/nightscout/.env
```

If not, the script should have created it. If there's an error:
```bash
cat /opt/nightscout/.env.example
cp /opt/nightscout/.env.example /opt/nightscout/.env
cd /opt/nightscout
docker compose up -d
```

### If LibreLink Up connector fails

Check logs:
```bash
docker logs nightscout-librelink-up
```

Common issues:
- Wrong credentials → Check LINK_UP_USERNAME and LINK_UP_PASSWORD
- Wrong region → Verify LINK_UP_REGION=EU is correct
- Multiple connections → You may need to add LINK_UP_CONNECTION

### If Caddy doesn't serve Nightscout

The deployment should have regenerated the Caddyfile. Reload Caddy:
```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Check Caddyfile includes Nightscout:
```bash
cat /opt/caddy/Caddyfile | grep nightscout
```

Should show:
```
# nightscout
nightscout.mljr.eu {
    reverse_proxy localhost:1337
}
```

---

## 📝 Summary

✅ **Fixed Issues:**
- Deployment scripts now call Glance and Nightscout setup
- Nightscout enabled in services.yml  
- API token pre-generated and added to .env.example
- Domain name added to .env.example

✅ **Ready to Deploy:**
- Just re-run the GitHub workflow OR
- Manually run `06-nightscout-setup.sh` on VPS

✅ **Your Configuration:**
- Domain: nightscout.mljr.eu
- Region: EU
- LibreLink account: reinemic2.0@gmail.com
- All credentials pre-configured in .env.example

---

## Next Steps

1. **Deploy**: Re-run GitHub workflow or manually run the script
2. **Wait**: Give it 5-10 minutes for LibreLink Up to fetch data
3. **Access**: Go to https://nightscout.mljr.eu
4. **Monitor**: Check logs to ensure data is syncing

If you have any issues, check the logs and refer to [docs/NIGHTSCOUT.md](docs/NIGHTSCOUT.md) for detailed troubleshooting.
