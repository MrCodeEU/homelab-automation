#!/usr/bin/env bash
# Render a fixture Caddy catalog with OpenVox, then validate the assembled
# configuration with Caddy. Both images are pinned; no host, secret, or
# Tailscale access is involved.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render_dir="$(mktemp -d "${TMPDIR:-/tmp}/openvox-caddy-render.XXXXXX")"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/openvox-fixtures.XXXXXX")"
trap 'rm -rf -- "$render_dir" "$fixture_dir"' EXIT

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e OPENVOX_CADDY_RENDER_DIR=/rendered \
  -v "$repo_root/openvox:/repo:ro" \
  -v "$fixture_dir:/repo/spec/fixtures/modules" \
  -v "$render_dir:/rendered" \
  ghcr.io/voxpupuli/voxbox@sha256:704dfe406a3f2f16d0b2a4d71fb4de4b72a9768df1e1cda06134240e5f01dc3c \
  spec SPEC=spec/integration/caddy_render_spec.rb

docker run --rm \
  -v "$render_dir:/etc/caddy:ro" \
  caddy@sha256:834468128c7696cec0ceea6172f7d692daf645ae51983ca76e39da54a97c570d \
  caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
