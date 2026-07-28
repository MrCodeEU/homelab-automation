#!/usr/bin/env bash
# Pull the health report's triage model.
#
# Idempotent: `ollama pull` is a no-op once the manifest matches, so this is
# safe on every deploy. Runs against the container rather than the HTTP API so
# it does not depend on BIND_ADDR resolution.
set -euo pipefail

CONTAINER="ollama"
MODEL="${HEALTHREPORT_MODEL:-qwen3:8b}"

echo "==> waiting for ${CONTAINER} to accept requests"
for _ in $(seq 1 30); do
    if docker exec "${CONTAINER}" ollama list >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! docker exec "${CONTAINER}" ollama list >/dev/null 2>&1; then
    echo "ERROR: ${CONTAINER} did not become ready" >&2
    exit 1
fi

if docker exec "${CONTAINER}" ollama list | awk '{print $1}' | grep -qx "${MODEL}"; then
    echo "==> ${MODEL} already present"
else
    echo "==> pulling ${MODEL} (several GB, first run only)"
    docker exec "${CONTAINER}" ollama pull "${MODEL}"
fi

# Never leave the model resident after a deploy.
docker exec "${CONTAINER}" ollama stop "${MODEL}" >/dev/null 2>&1 || true

echo "==> ollama ready with ${MODEL}"
