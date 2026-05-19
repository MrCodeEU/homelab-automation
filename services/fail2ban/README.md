# Retired Fail2ban Configuration

Fail2ban has been retired in favor of CrowdSec plus the host-level CrowdSec firewall bouncer on `mljr`.

This directory is kept only as historical reference for the old configuration. New deployments do not install or start fail2ban when:

```yaml
fail2ban_enabled: false
crowdsec_firewall_bouncer_enabled: true
```

The active migration path is:

1. Deploy Dockerized CrowdSec on `mljr`.
2. Install and start `crowdsec-firewall-bouncer-nftables` with the `crowdsec-firewall-bouncer` role.
3. Retire fail2ban with the `fail2ban-retire` role.
4. Remove the old `fail2ban-ui` Compose deployment and Caddy snippet through normal idempotent cleanup.

Use CrowdSec for active security operations:

```bash
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli decisions list
systemctl status crowdsec-firewall-bouncer
tail -f /var/log/crowdsec-firewall-bouncer.log
```

CrowdSec UI is exposed through Caddy at:

- `https://crowdsec.mljr.eu`
- `https://security.mljr.eu`
