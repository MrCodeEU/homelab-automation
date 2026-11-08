# CrowdSec

CrowdSec is the primary security engine for the public ingress host `mljr`.

## Components

- `crowdsec`: Dockerized CrowdSec engine and local API.
- `crowdsec-web-ui`: Web UI exposed through Caddy.
- `crowdsec-firewall-bouncer`: Host-level nftables bouncer installed by Ansible, not by this Compose file.

## Domains

- `https://crowdsec.mljr.eu`
- `https://security.mljr.eu`

Both are protected with Authelia.

## Required Secrets

| Secret | Purpose |
|--------|---------|
| `CROWDSEC_WEB_UI_PASSWORD` | Machine password used by the web UI |
| `CROWDSEC_WEB_UI_NOTIFICATION_SECRET` | Web UI notification encryption secret |
| `CROWDSEC_FIREWALL_BOUNCER_KEY` | API key used by the host firewall bouncer |

The Docker service receives `BOUNCER_KEY_firewall=${CROWDSEC_FIREWALL_BOUNCER_KEY}`. The host bouncer role writes the same key to `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`.

## Log Acquisition

`acquis.yaml` currently collects:

- `/var/log/secure`
- `/var/log/caddy/*.log`

Fail2ban logs are no longer collected because fail2ban is retired.

## Local Allowlist

`parsers/s02-enrich/mljr-local-allowlist.yaml` ignores trusted owner and
Tailscale sources before decisions are created:

- `145.40.45.14`
- `100.64.0.0/10`

It also keeps the Nocturne Caddy access-log exception for `nc.mljr.eu` to avoid
global bans from repeated app-auth failures.

## Ban Duration

`profiles.yaml` bans both IPs and ranges for a flat 4h. A progressive
duration (`duration_expr` scaling with `GetDecisionsCount`, longer for
repeat offenders) was tried but is rejected by the installed
`crowdsecurity/crowdsec:latest` image (v1.7.8): "field duration_expr not
found in type models.Decision" - crash-looped the container live on mljr.
The expr is left commented out in `profiles.yaml` as a marker to revisit
once the image supports it.

## Hub Maintenance

The post-deploy hook runs on every deployment:

```bash
docker exec crowdsec cscli hub update
docker exec crowdsec cscli hub upgrade
```

It also converges stricter HTTP scenarios:

- `crowdsecurity/http-dos-random-uri`
- `crowdsecurity/http-dos-switching-ua`
- `crowdsecurity/http-dos-invalid-http-versions`
- `crowdsecurity/http-dos-bypass-cache`
- `crowdsecurity/http-wordpress_user-enum`
- `crowdsecurity/http-wordpress_wpconfig`
- `ltsich/http-w00tw00t`

The workflow runs weekly, so installed CrowdSec parsers, scenarios, collections, and data files are kept current through normal automation.

## Useful Commands

```bash
docker exec crowdsec cscli lapi status
docker exec crowdsec cscli machines list
docker exec crowdsec cscli bouncers list
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli decisions list
systemctl status crowdsec-firewall-bouncer
tail -f /var/log/crowdsec-firewall-bouncer.log
```

If the bouncer is enabled and `CROWDSEC_FIREWALL_BOUNCER_KEY` is missing, deployment intentionally fails before host enforcement is configured.
