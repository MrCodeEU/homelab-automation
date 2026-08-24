FROM alpine:3.20

# No HEALTHCHECK: this is a one-shot batch job started by a systemd timer,
# not a long-running service. There is no steady state to probe.
#checkov:skip=CKV_DOCKER_2:One-shot container; a healthcheck has nothing to poll.

# Runs unprivileged, as the SAME uid healthreport's container runs as
# (10001, not a separate one) - this container reads healthreport's own
# SSH key read-only (see docker-compose.yml), which is 0600 and owned by
# that uid on the host. A different uid here cannot open it: numeric uid
# is what the kernel checks for a bind-mounted file, container-internal
# usernames are irrelevant.
ARG APP_UID=10001

# openssh-client: the compiled binary still shells out to the system ssh
# client for the forced-command facts endpoint (same as the Python
# original), rather than a Go SSH library - same transport, same
# known_hosts/StrictHostKeyChecking=accept-new behavior.
RUN apk add --no-cache openssh-client ca-certificates \
    && addgroup -g ${APP_UID} dashboard \
    && adduser -D -H -u ${APP_UID} -G dashboard dashboard

# /output is a fresh named Docker volume (backup-dashboard-html in
# docker-compose.yml, shared with the web container) - Docker seeds a
# brand new named volume's content, ownership included, from whatever
# already exists at that path in the image at first mount. Without this,
# nothing exists there yet, so Docker creates it root:root and the
# unprivileged collector below cannot write index.html into it.
RUN mkdir -p /output && chown dashboard:dashboard /output

# Compiled statically on the host (CGO_ENABLED=0), same as
# tools/cmd/caddylog and tools/cmd/provision-kuma - no Go toolchain
# needed in this build.
COPY backup-dashboard-collect /usr/local/bin/backup-dashboard-collect

USER dashboard

# One-shot by design: a systemd timer on nuc invokes it. No in-container
# scheduler, so `Persistent=true` catch-up after downtime works.
ENTRYPOINT ["/usr/local/bin/backup-dashboard-collect"]
