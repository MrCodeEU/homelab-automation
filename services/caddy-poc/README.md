# caddy-poc

Caddy with the CrowdSec bouncer and AppSec plugins, only for the proof of
concept in [`docs/APPSEC_POC_PLAN.md`](../../docs/APPSEC_POC_PLAN.md).
Production Caddy on mljr is still the COPR package.

- `Dockerfile` – xcaddy build, pinned by Caddy version, image digests and the
  bouncer's release tag (the upstream README uses `@main`, which we do not).
- `Caddyfile.poc` – `:8444` with AppSec, `:8445` baseline.

Check a build:

```
podman build -t caddy-poc:test services/caddy-poc
podman run --rm caddy-poc:test caddy list-modules | grep -E 'appsec|crowdsec'
podman run --rm -e CROWDSEC_BOUNCER_KEY=x -v ./Caddyfile.poc:/etc/caddy/Caddyfile:ro,Z caddy-poc:test \
  caddy validate --config /etc/caddy/Caddyfile
```

No compose file yet: it comes with the PR that enables the AppSec component
in the `crowdsec` container.

## Deploying the PoC to mljr

The deploy runs `docker compose pull` / `up`, it does not build. Build the
image on a host with spare RAM (nuc) and load it on mljr first:

```
scp -r services/caddy-poc root@nuc:/tmp/caddy-poc
ssh root@nuc 'docker build -t local/caddy-poc:latest /tmp/caddy-poc && docker save local/caddy-poc:latest' \
  | ssh root@mljr docker load
```

Then `make openvox-deploy-mljr`. Listeners: `100.100.20.1:8444` (AppSec) and
`:8445` (baseline). Send `X-Appsec-Mode: block` to get a 403 on a match;
without it AppSec only reports.
