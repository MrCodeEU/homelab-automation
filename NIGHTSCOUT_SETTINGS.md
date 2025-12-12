# Settings & Variables Checklist for Nightscout Deployment

## 🔐 Required Settings (MUST CONFIGURE)

### 1. Nightscout Admin Password
**Variable**: `API_SECRET`  
**Location**: `/opt/nightscout/.env`  
**Requirements**:
- Minimum 12 characters
- No special restrictions
- This is your master admin password for Nightscout

**Example**:
```bash
API_SECRET=MySecurePassword2024!
```

---

### 2. LibreLink Up Credentials
**Variables**:
- `LINK_UP_USERNAME` - Your LibreLink Up email
- `LINK_UP_PASSWORD` - Your LibreLink Up password
- `LINK_UP_REGION` - Your region

**Location**: `/opt/nightscout/.env`

**Available Regions**:
- `EU` - Europe
- `EU2` - Europe (alternative endpoint)
- `US` - United States
- `CA` - Canada
- `AU` - Australia
- `DE` - Germany
- `FR` - France
- `JP` - Japan
- `AP` - Asia Pacific
- `LA` - Latin America
- `RU` - Russia
- `CN` - China
- `AE` - United Arab Emirates

**Example**:
```bash
LINK_UP_USERNAME=your-email@example.com
LINK_UP_PASSWORD=your-librelink-password
LINK_UP_REGION=EU
```

---

### 3. Nightscout API Token (for LibreLink Up Connector)
**Variable**: `NIGHTSCOUT_API_TOKEN`  
**Location**: `/opt/nightscout/.env`  
**Requirements**:
- Must be SHA1 hash (40 characters)
- Used by LibreLink Up connector to authenticate with Nightscout

**How to Generate**:
```bash
# On your VPS or local machine:
echo -n "librelink-connector" | sha1sum | cut -d ' ' -f 1

# Or on Mac:
echo -n "librelink-connector" | shasum | cut -d ' ' -f 1

# Or use online tool: https://codebeautify.org/sha1-hash-generator
```

**Example**:
```bash
NIGHTSCOUT_API_TOKEN=14c779d01a34ad1337ab59c2168e31b141eb2de6
```

---

### 4. Domain Name
**Variable**: `domain` in services.yml  
**Location**: `/tmp/homelab-deploy/configs/services.yml`  
**Requirements**:
- Must point to your VPS IP address
- DNS A record configured
- Used by Caddy for HTTPS certificate

**Example**:
```yaml
services:
  - name: nightscout
    enabled: true
    domain: "nightscout.yourdomain.com"  # ← CHANGE THIS
    port: 1337
    description: "CGM Monitor"
    icon: "mdi:diabetes"
```

---

## ⚙️ Optional Settings (CUSTOMIZE IF DESIRED)

### Display Settings

**Variables** (in `/opt/nightscout/.env`):

```bash
# Blood glucose units
DISPLAY_UNITS=mg/dl          # or mmol/L (or mmol)

# Time format
TIME_FORMAT=24               # or 12

# Dashboard theme
THEME=colors                 # or default, colorblindfriendly
```

---

### Alarm Thresholds

**Variables** (in `/opt/nightscout/.env`):

For `mg/dl`:
```bash
BG_HIGH=260                  # Urgent high threshold
BG_TARGET_TOP=180            # High target
BG_TARGET_BOTTOM=80          # Low target
BG_LOW=55                    # Urgent low threshold
```

For `mmol/L`, divide by 18:
```bash
BG_HIGH=14.4
BG_TARGET_TOP=10.0
BG_TARGET_BOTTOM=4.4
BG_LOW=3.1
```

**Alarm Type**:
```bash
ALARM_TYPES=simple           # or predict
```

---

### Fetch Interval

**Variable**: `LINK_UP_TIME_INTERVAL`  
**Location**: `/opt/nightscout/.env`  
**Default**: 5 minutes  
**Range**: 1-60 minutes

```bash
LINK_UP_TIME_INTERVAL=5      # How often to fetch from LibreLink Up
```

---

### LibreLink Up Version

**Variable**: `LINK_UP_VERSION`  
**Location**: `/opt/nightscout/.env`  
**Default**: 4.16.0  
**When to change**: If you're using a newer LibreLink Up app

```bash
LINK_UP_VERSION=4.16.0       # Update if using newer app version
```

---

### Multiple Connections (Advanced)

**Variable**: `LINK_UP_CONNECTION`  
**Location**: `/opt/nightscout/.env`  
**When needed**: If you follow multiple people on LibreLink Up

**How to find Connection ID**:
```bash
docker logs nightscout-librelink-up | grep "connection"
```

**Example**:
```bash
LINK_UP_CONNECTION=abc123-def456-patient-id
```

---

### Fetch All Historical Data

**Variable**: `ALL_DATA`  
**Location**: `/opt/nightscout/.env`  
**Default**: true  
**Purpose**: Upload all available data vs only new data

```bash
ALL_DATA=true                # true = fetch all data, false = only new
```

**Recommendation**: Set to `true` at least once per day to catch any delayed data from LibreLink Up.

---

### Timezone

**Variable**: `TZ`  
**Location**: `/opt/nightscout/.env`  
**Default**: Europe/Berlin  

**Common timezones**:
- `Europe/London`
- `America/New_York`
- `America/Los_Angeles`
- `America/Chicago`
- `Asia/Tokyo`
- `Australia/Sydney`

```bash
TZ=Europe/Berlin             # Your timezone
```

---

### Enabled Plugins

**Variable**: `ENABLE`  
**Location**: `/opt/nightscout/.env`  
**Default**: `careportal basal dbsize`  

**Available plugins**:
- `careportal` - Treatment entry form
- `basal` - Basal rate display
- `dbsize` - Database size monitoring
- `iob` - Insulin on Board
- `cob` - Carbs on Board
- `sage` - Sensor Age
- `cage` - Cannula Age
- `iage` - Insulin Age
- `rawbg` - Raw BG values
- `boluscalc` - Bolus calculator

**Example**:
```bash
ENABLE="careportal basal dbsize iob cob sage"
```

---

## 📱 Push Notifications (Optional)

### Pushover Setup

**Required**:
1. Pushover account: https://pushover.net
2. Create Pushover application
3. Get API Token and User Key

**Variables** (in `/opt/nightscout/.env`):
```bash
PUSHOVER_API_TOKEN=your-pushover-app-token
PUSHOVER_USER_KEY=your-pushover-user-key
```

**Optional** (for separate alarm notifications):
```bash
PUSHOVER_ALARM_KEY=different-user-or-group-key
PUSHOVER_ANNOUNCEMENT_KEY=another-user-key
```

---

## 🌐 Glance Dashboard Integration

### Update Glance with Your Domain

**Location**: `/tmp/homelab-deploy/configs/glance/glance.yml.template`

**Find and replace** `https://nightscout.example.com` with your actual domain:
- In Quick Links section
- In Service Health monitoring

**After editing**, regenerate:
```bash
/tmp/homelab-deploy/scripts/generate-configs.sh
docker restart glance
```

---

## ✅ Pre-Deployment Checklist

Before running `06-nightscout-setup.sh`:

- [ ] `API_SECRET` set (min 12 chars)
- [ ] `LINK_UP_USERNAME` set
- [ ] `LINK_UP_PASSWORD` set
- [ ] `LINK_UP_REGION` set correctly
- [ ] `NIGHTSCOUT_API_TOKEN` generated and set
- [ ] Domain name added to `services.yml`
- [ ] Domain DNS points to VPS
- [ ] `generate-configs.sh` run to update Caddy config
- [ ] Optional settings customized (if desired)

---

## 🔄 After Deployment Changes

### If you change `.env` file:
```bash
cd /opt/nightscout
docker compose restart
```

### If you change `services.yml`:
```bash
/tmp/homelab-deploy/scripts/generate-configs.sh
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
docker restart glance  # if you updated Glance config
```

---

## 📊 Configuration Files Summary

| File | Purpose | Required Changes |
|------|---------|------------------|
| `/opt/nightscout/.env` | Nightscout environment variables | ✅ MUST edit |
| `/tmp/homelab-deploy/configs/services.yml` | Service definitions | ✅ Set domain |
| `/tmp/homelab-deploy/configs/glance/glance.yml.template` | Glance dashboard | ⚙️ Optional |
| `/opt/caddy/Caddyfile` | Reverse proxy config | ✅ Auto-generated |

---

## 🚨 Security Recommendations

1. **API_SECRET**:
   - Use strong, unique password
   - Don't reuse passwords
   - Store securely

2. **File Permissions**:
   ```bash
   chmod 600 /opt/nightscout/.env
   ```

3. **Never Commit**:
   - Don't commit `.env` to git
   - Don't share API tokens publicly

4. **Regular Updates**:
   ```bash
   cd /opt/nightscout
   docker compose pull
   docker compose up -d
   ```

---

## 📖 Full Documentation

- **Complete Setup Guide**: [docs/NIGHTSCOUT.md](../docs/NIGHTSCOUT.md)
- **Deployment Summary**: [DEPLOYMENT_SUMMARY.md](../DEPLOYMENT_SUMMARY.md)
- **Config Reference**: [configs/nightscout/README.md](../configs/nightscout/README.md)
- **Main README**: [README.md](../README.md)

---

**Questions?** See the full documentation or create an issue!
