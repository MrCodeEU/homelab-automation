# DMARC Monitor

parsedmarc watches the `dmarc-reports@mljr.eu` mailbox over IMAP for DMARC
aggregate reports and stores them in Postgres. No public UI - visualized via
the "DMARC Reports" Grafana dashboard.

## Why `nuc`

Same placement rule as Netronome/speedtest: `nuc` is the stronger, less
critical compute node, and this has no public-facing surface anyway.

## Runtime

- Image: `ghcr.io/domainaware/parsedmarc:latest`
- No exposed app port - it's a long-running IMAP watch daemon (`watch = True`
  in `config.ini`, using IMAP IDLE), not a web service.
- Postgres port `5432` is published (bound to `${BIND_ADDR}`, nuc's Tailscale
  IP) so Grafana - a separate Docker Compose project - can reach it as a
  datasource. It is not reachable outside the tailnet.
- `config.ini` holds only non-secret settings (folders, batch size, watch
  mode). All credentials come from env vars, which override the config file:
  `PARSEDMARC_IMAP_HOST/USER/PASSWORD`, `PARSEDMARC_POSTGRESQL_PASSWORD`.

## Configuration

Required secrets:

| Secret | Purpose |
|--------|---------|
| `DMARCMONITOR_IMAP_HOST` | Mailcow IMAP host (`mail.mljr.eu`) |
| `DMARCMONITOR_IMAP_USER` | Mailbox address (`dmarc-reports@mljr.eu`) |
| `DMARCMONITOR_IMAP_PASSWORD` | Mailbox password, set in mailcow's own admin UI |
| `DMARCMONITOR_DB_PASSWORD` | Postgres password, shared between the app and db containers |

## Verifying it's working

```bash
docker logs dmarc-monitor-app       # should show a clean IMAP IDLE connection, no auth/TLS errors
docker exec dmarc-monitor-db psql -U parsedmarc -c '\dt'   # parsedmarc's tables should exist
docker exec dmarc-monitor-db psql -U parsedmarc -c 'select count(*) from aggregate_reports;'
```
