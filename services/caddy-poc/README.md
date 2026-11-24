# caddy-poc

Build sources of the custom Caddy that production runs on mljr (CrowdSec
bouncer + AppSec plugins and the OpenZiti transport). The name is left over
from the AppSec proof of concept in
[`docs/APPSEC_POC_PLAN.md`](../../docs/APPSEC_POC_PLAN.md); the PoC container
itself (tailnet-only listeners on 8444/8445) was removed on 2026-11-24.

- `Dockerfile` – xcaddy build, pinned by Caddy version, image digests and the
  bouncer's release tag (the upstream README uses `@main`, which we do not).
  `.github/workflows/caddy-build.yml` builds the release binary from it.
- `ziti-caddy/` – the OpenZiti `reverse_proxy` transport module.

Check a build:

```
podman build -t caddy-custom:test services/caddy-poc
podman run --rm caddy-custom:test caddy list-modules | grep -E 'appsec|crowdsec|ziti'
```
