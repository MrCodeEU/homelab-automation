FROM python:3.12-slim

# No HEALTHCHECK: this is a one-shot batch job started by a systemd timer,
# not a long-running service. There is no steady state to probe.
#checkov:skip=CKV_DOCKER_2:One-shot container; a healthcheck has nothing to poll.

# Runs unprivileged, as the SAME uid healthreport's container runs as
# (10001, not a separate 10002) - this container reads healthreport's own
# SSH key read-only (see docker-compose.yml), which is 0600 and owned by
# that uid on the host. A different uid here cannot open it: numeric uid is
# what the kernel checks for a bind-mounted file, container-internal
# usernames are irrelevant. Confirmed live: the original 10002 produced
# "Identity file /ssh/id_ed25519 not accessible: Permission denied."
ARG APP_UID=10001

# openssh-client is needed for the forced-command facts endpoint on
# nas/mljr/nuc, same reason services/healthreport needs it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY app /app/app
COPY templates /app/templates

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# The collector only ever reads metrics and runs one restricted remote
# command (the same one healthreport does), so it has no reason to be root.
# Group is created explicitly with the same id for the same reason noted in
# services/healthreport/Dockerfile: useradd --system would otherwise pick a
# gid from the system range, and host directories are chowned to
# APP_UID:APP_UID by Ansible.
RUN groupadd --gid ${APP_UID} dashboard \
    && useradd --uid ${APP_UID} --gid ${APP_UID} --create-home --home-dir /home/dashboard dashboard

# /output is a fresh named Docker volume (backup-dashboard-html in
# docker-compose.yml, shared with the web container) - Docker seeds a brand
# new named volume's content, ownership included, from whatever already
# exists at that path in the image at first mount. Without this, nothing
# exists there yet, so Docker creates it root:root and the unprivileged
# collector below cannot write index.html into it. Confirmed live: the
# original Dockerfile produced "PermissionError: [Errno 13] Permission
# denied: '/output/index.html'" on its first real run.
RUN mkdir -p /output && chown dashboard:dashboard /output

USER dashboard

# One-shot by design: a systemd timer on nuc invokes it. No in-container
# scheduler, so `Persistent=true` catch-up after downtime works.
ENTRYPOINT ["python", "-m", "app.collect"]
