#!/usr/bin/env bash
# Local deployment — identical to CI but runs directly on the laptop.
# Prerequisites:
#   - Tailscale active (handles SSH auth to nodes automatically)
#   - pip install ansible-core mitogen ansible-mitogen
#   - ansible-galaxy collection install -r ansible/requirements.yml
#
# Secrets: export them as env vars in your shell session BEFORE running.
# Never save secrets to disk — source them from your password manager directly.
# List required secret names: gh secret list
#
# Usage:
#   ./scripts/deploy-local.sh                        # full deploy, all hosts
#   ./scripts/deploy-local.sh --limit mljr           # single host
#   ./scripts/deploy-local.sh --tags services        # specific tags
#   ./scripts/deploy-local.sh --tags caddy --check   # dry run
#   ./scripts/deploy-local.sh --limit rocky --tags services --extra-vars "changed_services=grafana"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v ansible-playbook &>/dev/null; then
    echo "ERROR: ansible-playbook not found."
    echo "Run: pip install ansible-core mitogen ansible-mitogen && ansible-galaxy collection install -r ansible/requirements.yml"
    exit 1
fi

cd "$REPO_ROOT/ansible"

echo "==> Local deploy ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"
echo "==> Args: $*"
echo ""

ansible-playbook playbooks/site.yml \
    --forks 20 \
    "$@"
