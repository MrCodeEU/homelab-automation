FROM python:3.12-slim

# No HEALTHCHECK: this is a one-shot batch job started by a systemd timer,
# not a long-running service. There is no steady state to probe.
#checkov:skip=CKV_DOCKER_2:One-shot container; a healthcheck has nothing to poll.

# Runs unprivileged. The uid is fixed because the host directories it mounts
# (/state, /catalog) are chowned to it by ansible/roles/backup-dashboard.
ARG APP_UID=10002

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
USER dashboard

# One-shot by design: a systemd timer on nuc invokes it. No in-container
# scheduler, so `Persistent=true` catch-up after downtime works.
ENTRYPOINT ["python", "-m", "app.collect"]
