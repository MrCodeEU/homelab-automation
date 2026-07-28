FROM python:3.12-slim

# No HEALTHCHECK: this is a one-shot batch job started by a systemd timer, not
# a long-running service. There is no steady state to probe.
#checkov:skip=CKV_DOCKER_2:One-shot container; a healthcheck has nothing to poll.

# Runs unprivileged. The uid is fixed because the host directories it mounts
# (/state, /ssh) are chowned to it by ansible/roles/healthreport.
ARG APP_UID=10001

# openssh-client is needed for the forced-command facts endpoint on mljr/nas.
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY app /app/app
COPY templates /app/templates
COPY rules.yml /app/rules.yml

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# The agent only ever reads metrics and runs one restricted remote command, so
# it has no reason to be root. The SSH private key it mounts must be readable
# by exactly this uid and nothing else.
# Group is created explicitly with the same id: `useradd --system` would
# otherwise pick a gid from the system range (999), and the host directories
# are chowned to APP_UID:APP_UID by Ansible.
RUN groupadd --gid ${APP_UID} report \
    && useradd --uid ${APP_UID} --gid ${APP_UID} --create-home --home-dir /home/report report
USER report

# One-shot by design: a systemd timer on nuc invokes it. No in-container
# scheduler, so `Persistent=true` catch-up after downtime works.
ENTRYPOINT ["python", "-m", "app.main"]
CMD ["--send"]
