# Caddy with the CrowdSec bouncer + AppSec plugins, for the AppSec proof of
# concept (docs/APPSEC_POC_PLAN.md). Not used by production Caddy, which is
# still the COPR package.
#
# Everything is pinned: Caddy by version and image digest, the plugin by its
# release tag (v0.14.1 = commit 6b35f6be25e457aa0b94e32c6ae519123e50e7b7).
# The upstream README builds from @main; a moving branch is not acceptable for
# an edge binary. Renovate bumps the tag and the digests together.

# renovate: datasource=docker depName=caddy
ARG CADDY_VERSION=2.11.7
ARG CADDY_BUILDER_DIGEST=sha256:c2fc374fd352439d76e1777b28d97d9f6d9c1dd86116db9227460374d46097d5
ARG CADDY_RUNTIME_DIGEST=sha256:504a44d7d74bd2bc28a66afc4774912fc21223ca8a67734af1c54ab2f999b489
# renovate: datasource=github-tags depName=hslatman/caddy-crowdsec-bouncer
ARG BOUNCER_VERSION=v0.14.1

FROM docker.io/library/caddy:${CADDY_VERSION}-builder@${CADDY_BUILDER_DIGEST} AS builder
ARG CADDY_VERSION
ARG BOUNCER_VERSION
# http = the bouncer handler (IP decisions from the LAPI), appsec = the
# per-route WAF handler. layer4 is deliberately not built in.
RUN xcaddy build "${CADDY_VERSION}" \
      --with "github.com/hslatman/caddy-crowdsec-bouncer/http@${BOUNCER_VERSION}" \
      --with "github.com/hslatman/caddy-crowdsec-bouncer/appsec@${BOUNCER_VERSION}"

FROM docker.io/library/caddy:${CADDY_VERSION}@${CADDY_RUNTIME_DIGEST}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
