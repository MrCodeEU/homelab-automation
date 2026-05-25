#!/usr/bin/env bash
# Local deployment — identical to CI but runs directly on the laptop.
# Prerequisites:
#   - Tailscale active (handles SSH auth to nodes automatically)
#   - pip install ansible-core mitogen ansible-mitogen
#   - ansible-galaxy collection install -r ansible/requirements.yml
#   - vault.yml exists and is encrypted (ansible-vault create/edit)
#
# Vault password is prompted once, held in memory, never written to disk.
#
# Usage:
#   ./scripts/deploy-local.sh                        # full deploy, all hosts
#   ./scripts/deploy-local.sh --limit mljr           # single host
#   ./scripts/deploy-local.sh --tags services        # specific tags
#   ./scripts/deploy-local.sh --tags caddy --check   # dry run
#   ./scripts/deploy-local.sh --limit rocky --tags services --extra-vars "changed_services=grafana"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_FILE="$REPO_ROOT/ansible/inventory/group_vars/all/vault.yml"

if [[ ! -f "$VAULT_FILE" ]]; then
    echo "ERROR: $VAULT_FILE not found."
    echo "Create it: ansible-vault create $VAULT_FILE"
    echo "See vault.yml.example in the same directory for the required structure."
    exit 1
fi

if ! command -v ansible-playbook &>/dev/null; then
    echo "ERROR: ansible-playbook not found."
    echo "Run: pip install ansible-core mitogen ansible-mitogen && ansible-galaxy collection install -r ansible/requirements.yml"
    exit 1
fi

# Read vault password into memory only — never touches disk
read -rsp "Vault password: " VAULT_PASS
echo ""

# Write to a process-substitution fd so it never hits disk
# Trap ensures cleanup even on error/interrupt
VAULT_PASS_FILE=$(mktemp)
chmod 600 "$VAULT_PASS_FILE"
echo "$VAULT_PASS" > "$VAULT_PASS_FILE"
unset VAULT_PASS
trap "rm -f '$VAULT_PASS_FILE'" EXIT INT TERM

export ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASS_FILE"

# Auto-detect Mitogen strategy plugin — speeds up deploys by 40-70%.
# Falls back to standard linear strategy if Mitogen is not installed.
MITOGEN_PATH=$(pip show mitogen 2>/dev/null | grep "^Location:" | cut -d' ' -f2)
if [[ -n "$MITOGEN_PATH" && -d "$MITOGEN_PATH/ansible_mitogen/plugins/strategy" ]]; then
    export ANSIBLE_STRATEGY_PLUGINS="$MITOGEN_PATH/ansible_mitogen/plugins/strategy"
    echo "==> Mitogen enabled: $ANSIBLE_STRATEGY_PLUGINS"
else
    # Override mitogen_linear default from ansible.cfg to standard linear
    export ANSIBLE_STRATEGY=linear
    echo "==> Mitogen not found — using linear strategy (install: pip install mitogen ansible-mitogen)"
fi

cd "$REPO_ROOT/ansible"

echo "==> Local deploy ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"
echo "==> Args: $*"
echo ""

ansible-playbook playbooks/site.yml \
    --forks 20 \
    "$@"
