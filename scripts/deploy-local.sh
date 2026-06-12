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
STATUS_VARS_FILE=""
chmod 600 "$VAULT_PASS_FILE"
echo "$VAULT_PASS" > "$VAULT_PASS_FILE"
unset VAULT_PASS
trap "rm -f '$VAULT_PASS_FILE' ${STATUS_VARS_FILE:+'$STATUS_VARS_FILE'}" EXIT INT TERM

export ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASS_FILE"

# Auto-detect Mitogen strategy plugin — speeds up deploys by 40-70%.
# Falls back to standard linear strategy if Mitogen is not installed.
MITOGEN_PATH=$(pip show mitogen 2>/dev/null | grep "^Location:" | cut -d' ' -f2 || true)
if [[ -n "$MITOGEN_PATH" && -d "$MITOGEN_PATH/ansible_mitogen/plugins/strategy" ]]; then
    export ANSIBLE_STRATEGY_PLUGINS="$MITOGEN_PATH/ansible_mitogen/plugins/strategy"
    echo "==> Mitogen enabled: $ANSIBLE_STRATEGY_PLUGINS"
else
    # Override mitogen_linear default from ansible.cfg to standard linear
    export ANSIBLE_STRATEGY=linear
    echo "==> Mitogen not found — using linear strategy (install: pip install mitogen ansible-mitogen)"
fi

cd "$REPO_ROOT/ansible"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
START_EPOCH=$(date +%s)
LOG_DIR="$REPO_ROOT/deploy-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${TIMESTAMP}.log"

echo "==> Local deploy (${TIMESTAMP})"
echo "==> Args: $*"
echo "==> Log: $LOG_FILE"
echo ""

LIMIT="all"
TAGS="all"
CHECK_MODE="false"
TARGETED_SERVICE=""
TARGET_ENVIRONMENT=""
NEXT_IS_LIMIT="false"
NEXT_IS_TAGS="false"
NEXT_IS_EXTRA_VARS="false"
for arg in "$@"; do
    if [[ "$NEXT_IS_LIMIT" == "true" ]]; then
        LIMIT="$arg"
        NEXT_IS_LIMIT="false"
        continue
    fi
    if [[ "$NEXT_IS_TAGS" == "true" ]]; then
        TAGS="$arg"
        NEXT_IS_TAGS="false"
        continue
    fi
    if [[ "$NEXT_IS_EXTRA_VARS" == "true" ]]; then
        if [[ "$arg" =~ (^|[[:space:]])changed_services=([^[:space:]]+) ]]; then
            TARGETED_SERVICE="${BASH_REMATCH[2]}"
        fi
        NEXT_IS_EXTRA_VARS="false"
        continue
    fi
    case "$arg" in
        --limit)
            NEXT_IS_LIMIT="true"
            ;;
        --limit=*)
            LIMIT="${arg#--limit=}"
            ;;
        --tags)
            NEXT_IS_TAGS="true"
            ;;
        --tags=*)
            TAGS="${arg#--tags=}"
            ;;
        --check)
            CHECK_MODE="true"
            ;;
        --extra-vars|-e)
            NEXT_IS_EXTRA_VARS="true"
            ;;
        --extra-vars=*)
            extra_vars="${arg#--extra-vars=}"
            if [[ "$extra_vars" =~ (^|[[:space:]])changed_services=([^[:space:]]+) ]]; then
                TARGETED_SERVICE="${BASH_REMATCH[2]}"
            fi
            ;;
    esac
done

set +e
ansible-playbook playbooks/site.yml \
    --forks 20 \
    --extra-vars "is_staging_deployment=true" \
    "$@" 2>&1 | tee "$LOG_FILE"
ANSIBLE_EXIT_CODE=${PIPESTATUS[0]}
set -e

END_EPOCH=$(date +%s)
DURATION=$((END_EPOCH - START_EPOCH))
STATUS="success"
if [[ "$ANSIBLE_EXIT_CODE" -ne 0 ]]; then
    STATUS="failed"
fi

BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
COMMIT_MESSAGE="$(git -C "$REPO_ROOT" log -1 --pretty=%B 2>/dev/null | head -1 || echo '')"
ACTOR="${USER:-local}"

echo ""
echo "==> Updating deploy.mljr.eu via Ansible"
STATUS_VARS_FILE=$(mktemp)
export LOG_FILE START_TIME DURATION STATUS BRANCH COMMIT_SHA COMMIT_MESSAGE ACTOR CHECK_MODE LIMIT TAGS TARGETED_SERVICE TARGET_ENVIRONMENT
python3 > "$STATUS_VARS_FILE" <<'PY'
import json
import os

data = {
    "deploy_status_log_file": os.environ["LOG_FILE"],
    "deploy_status_start_time": os.environ["START_TIME"],
    "deploy_status_duration_seconds": int(os.environ["DURATION"]),
    "deploy_status_status": os.environ["STATUS"],
    "deploy_status_trigger": "local",
    "deploy_status_branch": os.environ["BRANCH"],
    "deploy_status_commit_sha": os.environ["COMMIT_SHA"],
    "deploy_status_commit_message": os.environ["COMMIT_MESSAGE"],
    "deploy_status_actor": os.environ["ACTOR"],
    "deploy_status_check_mode": os.environ["CHECK_MODE"] == "true",
    "deploy_status_is_staging": True,
    "deploy_status_limit": os.environ["LIMIT"],
    "deploy_status_tags": os.environ["TAGS"],
    "deploy_status_targeted_service": os.environ["TARGETED_SERVICE"],
    "deploy_status_target_environment": os.environ["TARGET_ENVIRONMENT"],
}
print(json.dumps(data))
PY
ansible-playbook playbooks/deploy-status.yml \
    --extra-vars "@$STATUS_VARS_FILE" \
    || echo "WARNING: deployment status page update failed"

exit "$ANSIBLE_EXIT_CODE"
