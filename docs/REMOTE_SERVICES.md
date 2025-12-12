# Remote Services Configuration Guide

This guide explains how to configure services running on other devices (Tailscale network or local network) to be accessible through your VPS via Caddy reverse proxy.

## 🌐 Use Cases

1. **Tailscale Network Services** - Services on other devices connected via Tailscale
2. **Home Network Services** - Services on local network devices (via Tailscale exit node)
3. **Mixed Environments** - Combination of local and remote services

---

## 📝 Configuration Options

### services.yml Fields

Each service in `services.yml` can have:

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | ✅ Yes | - | Service identifier |
| `enabled` | No | `true` | Enable/disable service |
| `domain` | ✅ Yes | - | Public domain (e.g., `home.mljr.eu`) |
| `port` | Conditional | - | Port number (required if no `upstream`) |
| `host` | No | `localhost` | Target host (IP, hostname, or Tailscale name) |
| `upstream` | No | - | Full upstream URL (overrides `host:port`) |
| `description` | No | - | Human-readable description |
| `icon` | No | - | Icon for Glance dashboard |

---

## 🎯 Configuration Examples

### Example 1: Local Service on VPS (Default)

Services running on the same VPS as Caddy:

```yaml
services:
  - name: glance
    enabled: true
    domain: "dash.mljr.eu"
    port: 8080
    description: "Main dashboard"
    icon: "mdi:view-dashboard"
    # host: localhost  # Optional, defaults to localhost
```

**Generated Caddy config:**
```
dash.mljr.eu {
    reverse_proxy localhost:8080
}
```

---

### Example 2: Home Network Device (via Tailscale Exit Node)

Home Assistant on Raspberry Pi at local IP `192.168.50.4`:

```yaml
services:
  - name: homeassistant
    enabled: true
    domain: "home.mljr.eu"
    host: "192.168.50.4"
    port: 8123
    description: "Home Automation"
    icon: "mdi:home-assistant"
```

**Generated Caddy config:**
```
home.mljr.eu {
    reverse_proxy 192.168.50.4:8123
}
```

**Requirements:**
- VPS must have Tailscale exit node configured to your home network
- The IP `192.168.50.4` must be reachable from the VPS through Tailscale

---

### Example 3: Service on Another Tailscale Device

Plex server on another Tailscale-connected machine:

```yaml
services:
  - name: plex
    enabled: true
    domain: "plex.mljr.eu"
    host: "homeserver.tailnet-xxx.ts.net"
    port: 32400
    description: "Media Server"
    icon: "mdi:plex"
```

**Generated Caddy config:**
```
plex.mljr.eu {
    reverse_proxy homeserver.tailnet-xxx.ts.net:32400
}
```

---

### Example 4: Custom Upstream URL

For services that need a specific path or protocol:

```yaml
services:
  - name: api
    enabled: true
    domain: "api.mljr.eu"
    upstream: "http://192.168.1.100:8080/api/v1"
    description: "Backend API"
    icon: "mdi:api"
```

**Generated Caddy config:**
```
api.mljr.eu {
    reverse_proxy http://192.168.1.100:8080/api/v1
}
```

---

## 🔧 Setup Instructions

### Step 1: Configure Tailscale Exit Node (for Home Network Services)

On your VPS, set up Tailscale to use your home network as exit node:

```bash
# On VPS
sudo tailscale up --advertise-exit-node

# On your home network device (e.g., Raspberry Pi or router)
# Make it an exit node
sudo tailscale up --advertise-exit-node --accept-routes

# On VPS, use the home exit node
sudo tailscale set --exit-node=<home-device-name>
```

Verify connectivity:
```bash
# From VPS, test reaching home device
ping 192.168.50.4
curl http://192.168.50.4:8123
```

### Step 2: Add Service to services.yml

Edit your configuration:

```bash
nano configs/services.yml
```

Add your service:

```yaml
services:
  - name: homeassistant
    enabled: true
    domain: "home.mljr.eu"
    host: "192.168.50.4"
    port: 8123
    description: "Home Automation"
    icon: "mdi:home-assistant"
```

### Step 3: Regenerate Caddy Configuration

Run the config generator:

```bash
./scripts/generate-configs.sh
```

Or deploy via GitHub Actions (automatically runs generator).

### Step 4: Verify Caddyfile

Check that the service was added:

```bash
cat /opt/caddy/Caddyfile
```

Should show:
```
# homeassistant
home.mljr.eu {
    reverse_proxy 192.168.50.4:8123
}
```

### Step 5: Reload Caddy

Apply the new configuration:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### Step 6: Configure DNS

Add an A record for your domain:

```
home.mljr.eu  →  <your-vps-ip>
```

### Step 7: Test Access

Wait a few minutes for DNS propagation and certificate generation, then:

```
https://home.mljr.eu
```

---

## 🔍 Troubleshooting

### Service Not Reachable from VPS

**Test connectivity:**
```bash
# SSH to VPS
ssh root@your-vps

# Test connection to remote service
curl -v http://192.168.50.4:8123
# or
curl -v http://homeserver.tailnet-xxx.ts.net:32400
```

**If connection fails:**

1. **Check Tailscale exit node:**
   ```bash
   tailscale status
   # Look for exit node in use
   ```

2. **Verify Tailscale can reach the network:**
   ```bash
   ping 192.168.50.4
   ```

3. **Check firewall on target device:**
   ```bash
   # On Raspberry Pi
   sudo ufw status
   sudo ufw allow 8123
   ```

4. **Verify service is running:**
   ```bash
   # On target device
   netstat -tulpn | grep 8123
   ```

### Caddy Shows Certificate Errors

**Check Caddy logs:**
```bash
docker logs caddy
```

**Common issues:**
- DNS not propagating yet → Wait 10-15 minutes
- Port 80/443 blocked → Check VPS firewall
- Rate limited by Let's Encrypt → Wait 1 hour

### Service Loads but Shows Connection Error

**Check target service logs:**
```bash
# On target device
docker logs <container-name>
# or
journalctl -u <service-name>
```

**Possible issues:**
- Service not binding to correct interface (needs `0.0.0.0` not `127.0.0.1`)
- Service has IP whitelist/firewall
- CORS issues (needs proper headers)

### Adding HTTPS to Upstream

If your upstream service already uses HTTPS:

```yaml
services:
  - name: secure-app
    enabled: true
    domain: "app.mljr.eu"
    upstream: "https://192.168.1.100:8443"
```

For self-signed certificates on upstream, you may need to configure Caddy to skip verification (not recommended for production):

```
app.mljr.eu {
    reverse_proxy https://192.168.1.100:8443 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

---

## 📋 Quick Reference

### Local Service (on VPS)
```yaml
- name: service
  enabled: true
  domain: "service.mljr.eu"
  port: 8080
```

### Home Network Device
```yaml
- name: service
  enabled: true
  domain: "service.mljr.eu"
  host: "192.168.50.4"
  port: 8123
```

### Tailscale Device
```yaml
- name: service
  enabled: true
  domain: "service.mljr.eu"
  host: "device.tailnet-xxx.ts.net"
  port: 8080
```

### Custom Upstream
```yaml
- name: service
  enabled: true
  domain: "service.mljr.eu"
  upstream: "http://192.168.1.100:8080/path"
```

---

## 🎉 Example: Complete Setup for Home Assistant

**1. On Raspberry Pi (Home Network):**
```bash
# Home Assistant should be running
docker ps | grep homeassistant
```

**2. On Home Network Device (acting as Tailscale exit node):**
```bash
# Make it an exit node
sudo tailscale up --advertise-exit-node --accept-routes
```

**3. On VPS:**
```bash
# Use home exit node
sudo tailscale set --exit-node=<your-home-device>

# Test connectivity
curl http://192.168.50.4:8123
```

**4. Add to services.yml:**
```yaml
services:
  - name: homeassistant
    enabled: true
    domain: "home.mljr.eu"
    host: "192.168.50.4"
    port: 8123
    description: "Home Automation"
    icon: "mdi:home-assistant"
```

**5. Deploy:**
```bash
# Via GitHub Actions or manually
./scripts/generate-configs.sh
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

**6. Add DNS Record:**
```
home.mljr.eu  →  <your-vps-ip>
```

**7. Access:**
```
https://home.mljr.eu
```

Done! 🎉

---

## 🔐 Security Considerations

1. **Expose Only What's Needed** - Don't expose your entire home network
2. **Use Tailscale ACLs** - Restrict which devices can talk to each other
3. **Keep Services Updated** - Regularly update exposed services
4. **Monitor Access Logs** - Check Caddy logs for suspicious activity
5. **Use Strong Authentication** - Enable 2FA on exposed services
6. **Consider VPN** - For very sensitive services, require VPN access

---

## 📚 Additional Resources

- [Tailscale Exit Nodes Documentation](https://tailscale.com/kb/1103/exit-nodes/)
- [Caddy Reverse Proxy Guide](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [services.yml Examples](../configs/services.yml)
