# Fail2ban Configuration

This directory contains fail2ban configuration for protecting your homelab services.

## Overview

Fail2ban monitors log files and automatically bans IPs that show malicious signs, such as too many password failures or seeking for exploits. When an IP is banned, it's blocked via iptables for a configured duration.

## Features

- **SSH Protection**: Monitors `/var/log/secure` for failed SSH login attempts
- **Caddy Basic Auth Protection**: Monitors `/var/log/caddy/access.log` for failed basic authentication attempts (e.g., on logs.mljr.eu)
- **ntfy Notifications**: Sends real-time notifications to your ntfy server when IPs are banned

## Configuration

### Ban Settings

- **Ban Time**: 24 hours (86400 seconds)
- **Max Retries**: 5 failed attempts
- **Find Time**: 10 minutes (600 seconds)

This means if an IP fails 5 times within 10 minutes, it will be banned for 24 hours.

### Protected Services

1. **SSH (sshd jail)**
   - Monitors: `/var/log/secure`
   - Protects: SSH service on port 22
   - Max retries: 5

2. **Caddy Basic Auth (caddy-basicauth jail)**
   - Monitors: `/var/log/caddy/access.log` (JSON format)
   - Protects: Services with basic authentication (e.g., logs.mljr.eu)
   - Detects: HTTP 401 (Unauthorized) responses
   - Max retries: 5

3. **Caddy Bad Bots (caddy-badbots jail)** *(disabled by default)*
   - Monitors: `/var/log/caddy/access.log`
   - Protects: Against common exploit attempts (wp-admin, phpmyadmin, .env, etc.)
   - Enable by uncommenting in `/etc/fail2ban/jail.d/homelab.conf`

### Notifications

Fail2ban is configured to send notifications to ntfy when IPs are banned:

- **ntfy URL**: https://ntfy.mljr.eu
- **Topic**: `fail2ban`
- **Priority**: 4 (high priority for security alerts)

Subscribe to the `fail2ban` topic in your ntfy client to receive ban notifications:
```bash
# Subscribe via curl
curl -s https://ntfy.mljr.eu/fail2ban/json

# Or open in browser
https://ntfy.mljr.eu/fail2ban
```

## Installation

The fail2ban setup is automated via the deployment script:

```bash
# Run the fail2ban setup script
sudo bash scripts/setup-fail2ban.sh
```

This will:
1. Install fail2ban and fail2ban-systemd
2. Create custom filters for Caddy
3. Configure jails for SSH and Caddy
4. Set up ntfy notification action
5. Start and enable the fail2ban service

## Usage

### Check fail2ban status

```bash
# Check overall status
sudo fail2ban-client status

# Check specific jail status
sudo fail2ban-client status sshd
sudo fail2ban-client status caddy-basicauth
```

### Unban an IP address

```bash
# Unban from specific jail
sudo fail2ban-client set sshd unbanip 1.2.3.4
sudo fail2ban-client set caddy-basicauth unbanip 1.2.3.4
```

### View banned IPs

```bash
# List currently banned IPs for a jail
sudo fail2ban-client status sshd | grep "Banned IP"
```

### View fail2ban logs

```bash
# View fail2ban service logs
sudo journalctl -u fail2ban -f

# View specific jail logs
sudo grep 'caddy-basicauth' /var/log/fail2ban.log
```

### Test filters

```bash
# Test SSH filter
sudo fail2ban-regex /var/log/secure /etc/fail2ban/filter.d/sshd.conf

# Test Caddy basic auth filter
sudo fail2ban-regex /var/log/caddy/access.log /etc/fail2ban/filter.d/caddy-basicauth.conf
```

## Files

- `/etc/fail2ban/jail.d/homelab.conf` - Main jail configuration
- `/etc/fail2ban/filter.d/caddy-basicauth.conf` - Caddy basic auth filter
- `/etc/fail2ban/filter.d/caddy-badbots.conf` - Caddy bad bots filter (disabled)
- `/etc/fail2ban/action.d/ntfy.conf` - ntfy notification action

## Whitelisting IPs

To whitelist your own IPs, edit `/etc/fail2ban/jail.d/homelab.conf` and add them to the `ignoreip` line:

```ini
ignoreip = 127.0.0.1/8 ::1
           10.0.0.0/8
           172.16.0.0/12
           192.168.0.0/16
           100.64.0.0/10
           1.2.3.4        # Your IP here
```

Then reload fail2ban:
```bash
sudo systemctl reload fail2ban
```

## Troubleshooting

### Fail2ban not starting

Check the configuration syntax:
```bash
sudo fail2ban-client -t
```

### No bans happening

1. Check if the log file exists and is readable:
   ```bash
   ls -l /var/log/caddy/access.log
   ```

2. Test the filter against the log:
   ```bash
   sudo fail2ban-regex /var/log/caddy/access.log /etc/fail2ban/filter.d/caddy-basicauth.conf
   ```

3. Check fail2ban logs for errors:
   ```bash
   sudo journalctl -u fail2ban -n 50
   ```

### ntfy notifications not working

1. Test ntfy manually:
   ```bash
   curl -X POST -H "Title: Test" -d "Test message" https://ntfy.mljr.eu/fail2ban
   ```

2. Check if curl is installed:
   ```bash
   which curl
   ```

3. Verify the action is configured:
   ```bash
   sudo fail2ban-client get caddy-basicauth action
   ```

## Security Considerations

- Private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10) are whitelisted by default
- Adjust `maxretry` and `bantime` based on your security requirements
- Monitor fail2ban logs regularly for unusual patterns
- Consider enabling the `caddy-badbots` jail if you notice exploit attempts

## References

- [Fail2ban Documentation](https://fail2ban.readthedocs.io/)
- [Caddy Logging](https://caddyserver.com/docs/caddyfile/directives/log)
- [ntfy Documentation](https://docs.ntfy.sh/)
