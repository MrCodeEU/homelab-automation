#!/usr/bin/env bash
# Always runs on every apply, same as the Ansible role's own
# `dnf: name=* state=latest` - dnf itself is what's idempotent here (a
# no-op transaction when everything is already current), not this exec.
set -euo pipefail
dnf install -y epel-release
dnf upgrade -y --refresh
