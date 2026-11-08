FROM alpine:3.24

# No HEALTHCHECK: the process listens on nothing; it runs a test every
# SPEEDTEST_INTERVAL and reports failures itself as speedtest_up 0.
#checkov:skip=CKV_DOCKER_2:No listening port to probe; failures are reported as metrics.

ARG APP_UID=10002

# ca-certificates for speedtest.net's server list (HTTPS).
RUN apk add --no-cache ca-certificates \
    && addgroup -g ${APP_UID} speedtest \
    && adduser -D -H -u ${APP_UID} -G speedtest speedtest

COPY speedtest-metrics /usr/local/bin/speedtest-metrics

USER speedtest

ENTRYPOINT ["/usr/local/bin/speedtest-metrics"]
