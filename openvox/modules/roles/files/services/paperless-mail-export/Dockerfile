FROM alpine:3.24

# One-shot batch job started by a systemd timer, not a long-running service:
# there is no steady state to probe.
#checkov:skip=CKV_DOCKER_2:One-shot container; a healthcheck has nothing to poll.

# Fixed uid: the host dirs it mounts (/state, /outbox) are chowned to it by
# hooks/post-deploy.sh.
ARG APP_UID=10001

RUN apk add --no-cache ca-certificates \
    && addgroup -g ${APP_UID} mailexport \
    && adduser -D -H -u ${APP_UID} -G mailexport mailexport

# Compiled statically on a dev machine with scripts/service-binary.sh; CI
# fails when tools/cmd/paperless-mail-export changed without a rebuild.
COPY paperless-mail-export /usr/local/bin/paperless-mail-export

USER mailexport

ENTRYPOINT ["/usr/local/bin/paperless-mail-export"]
CMD ["--help"]
