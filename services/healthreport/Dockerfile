FROM alpine:3.24

# No HEALTHCHECK: this is a one-shot batch job started by a systemd timer, not
# a long-running service. There is no steady state to probe.
#checkov:skip=CKV_DOCKER_2:One-shot container; a healthcheck has nothing to poll.

# Runs unprivileged. The uid is fixed because the host directories it mounts
# (/state, /ssh) are chowned to it by Puppet (roles::healthreport).
ARG APP_UID=10001

# openssh-client is needed for the forced-command facts endpoint on mljr/nas.
# ca-certificates for every HTTPS collector (GitHub, ntfy, Home Assistant).
RUN apk add --no-cache openssh-client ca-certificates \
    && addgroup -g ${APP_UID} report \
    && adduser -D -H -u ${APP_UID} -G report report

COPY healthreport /usr/local/bin/healthreport
COPY rules.yml /app/rules.yml

USER report

# One-shot by design: a systemd timer on nuc invokes it. No in-container
# scheduler, so `Persistent=true` catch-up after downtime works.
ENTRYPOINT ["/usr/local/bin/healthreport"]
CMD ["--noop"]
