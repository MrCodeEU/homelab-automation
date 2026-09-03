FROM alpine:3.24

# Long-running HTTP service (unlike healthreport/backup-dashboard-collect's
# one-shot batch jobs) - needs a real healthcheck for docker compose /
# healthcheck.sh to probe.
ARG APP_UID=10001

RUN apk add --no-cache ca-certificates wget \
    && addgroup -g ${APP_UID} csp \
    && adduser -D -H -u ${APP_UID} -G csp csp

# Compiled statically on the host (CGO_ENABLED=0), same as
# tools/cmd/caddylog and tools/cmd/provision-kuma - no Go toolchain needed
# in this build.
COPY csp-reports /usr/local/bin/csp-reports

USER csp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/csp-reports"]
