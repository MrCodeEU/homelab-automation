#!/usr/bin/env bash
# nuc's repos have no python3-docker candidate (confirmed elsewhere in this
# migration, see roles::grafana_alloy) - falls back to pip, same as the
# Ansible role's failed_when:false + pip fallback.
set -euo pipefail
dnf install -y python3-docker || pip3 install docker
