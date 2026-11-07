# ziti-caddy (kept in this repo)

Caddy's `http.reverse_proxy.transport.ziti`: Caddy dials an upstream over
OpenZiti with its own identity, no tunneler and no loopback ports
(docs/ZERO_TRUST_PLAN.md Phase 4).

Origin: [openziti-test-kitchen/ziti-caddy](https://github.com/openziti-test-kitchen/ziti-caddy)
at `a21294979dd77df4435d167b3f291cdb194a3023` (2025-01-08, its last change),
Apache-2.0 (`LICENSE`). Only the module root is kept (`transport.go`,
`listener.go`); the upstream `cmd/` and `sample/` are not.

Changes against upstream:

- Lazy login. Upstream logs in to the controller in `Provision`, so Caddy
  cannot start while the controller is unreachable: with the pinned SDK it
  exits, with SDK 1.8.3 it hangs retrying, and in both cases every site is
  down, not just the Ziti upstreams (tested 2026-11-07). Here `Provision`
  only checks that the identity file parses, a goroutine logs in and
  retries every 5 s, and a dial waits for it at most `dial_timeout` (3 s by
  default), then fails with a 502.
- `go.mod`: Caddy 2.11.7, `sdk-golang` v1.8.3 (the controller runs 2.0.8).
- `CaddyModule` on a pointer receiver (the struct now holds a mutex).

Tested 2026-11-07 from the laptop against the live controller: controller
reachable (200), unreachable at start (other sites 200, Ziti upstream 502
after 3 s), reachable again (picked up without a restart), lost after login
(200 at +0, +40, +90 s).

Usage, dialing by intercept address:

```caddyfile
reverse_proxy kuma.nuc.int.mljr.eu:3001 {
	transport ziti {
		identity /etc/caddy/ziti/caddy-mljr.json
	}
}
```

Built into the custom Caddy by `../Dockerfile`
(`.github/workflows/caddy-build.yml`). The upstream listener (serving a site
on Ziti) is unchanged and unused here.
