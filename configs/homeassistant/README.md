# Home Assistant Reverse Proxy Configuration

## Problem: 400 Bad Request Behind Caddy

Home Assistant returns HTTP 400 when accessed through a reverse proxy because it requires explicit configuration to trust the proxy.

## Solution

Add the following to your Home Assistant `configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12      # Docker network range
    - 192.168.0.0/16     # Local network
    - 100.0.0.0/8        # Tailscale network
    - mljr.tail33930.ts.net  # Your VPS Tailscale hostname
```

## Steps to Fix

### Option 1: Via Home Assistant UI

1. Go to **Settings** → **System** → **Repairs**
2. If there's a warning about "Detected HA is accessed via reverse proxy", follow the repair instructions

### Option 2: Edit configuration.yaml

**On your Raspberry Pi:**

```bash
# SSH to the Pi
ssh pi@192.168.50.4

# Edit the configuration (location varies by install method)

# For Home Assistant OS:
sudo nano /config/configuration.yaml

# For Docker install:
nano ~/homeassistant/configuration.yaml

# For Core install:
nano ~/.homeassistant/configuration.yaml
```

Add the `http:` section shown above, then restart Home Assistant:

```bash
# Via UI: Settings → System → Restart
# Or via CLI:
ha core restart
```

### Option 3: Via File Editor Add-on (Home Assistant OS)

1. Install **File Editor** add-on from the Add-on Store
2. Open **File Editor**
3. Navigate to `configuration.yaml`
4. Add the `http:` configuration
5. Save and restart Home Assistant

## Verification

After applying the fix, test the connection:

```powershell
curl -I https://home.mljr.eu
```

Should return `200 OK` instead of `400 Bad Request`.

## Additional Caddy Configuration (If Needed)

If you still have issues, you may need to add headers in Caddy. Edit the generated Caddyfile:

```
home.mljr.eu {
    reverse_proxy 192.168.50.4:8123 {
        header_up X-Forwarded-Proto {http.request.scheme}
        header_up X-Forwarded-For {http.request.remote.host}
        header_up Host {http.reverse_proxy.upstream.hostport}
    }
}
```

## References

- [Home Assistant Reverse Proxy Docs](https://www.home-assistant.io/integrations/http/#reverse-proxies)
- [Caddy Reverse Proxy Guide](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
