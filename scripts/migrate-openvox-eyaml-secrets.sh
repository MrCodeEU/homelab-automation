#!/usr/bin/env bash
# Re-encrypt active OpenVox vault_* values into one ciphertext file per agent.
#
# Preconditions:
#   - the legacy private key remains at openvox/keys/private_key.pkcs7.pem
#   - bootstrap-openvox-eyaml-host-key.sh has created all three public keys
#   - Docker can run the pinned VoxBox image used for catalog tests
#
# EYaml's recrypt operation performs decryption and re-encryption internally
# inside the ephemeral container. Plaintext is never written to the working
# tree, command line, or this script's output. Only freshly encrypted
# ENC[PKCS7,...] values are written to Git.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

targets=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
  targets=(mljr nuc ugreen)
fi
for target in "${targets[@]}"; do
  case "$target" in mljr|nuc|ugreen) ;; *)
    echo "usage: $0 [mljr] [nuc] [ugreen]" >&2
    exit 2
  esac
done

image='ghcr.io/voxpupuli/voxbox@sha256:704dfe406a3f2f16d0b2a4d71fb4de4b72a9768df1e1cda06134240e5f01dc3c'
legacy_file='openvox/data/common.eyaml'
legacy_private='openvox/keys/private_key.pkcs7.pem'
legacy_public='openvox/keys/public_key.pkcs7.pem'

for path in "$legacy_file" "$legacy_private" "$legacy_public" \
  openvox/keys/mljr/public_key.pkcs7.pem \
  openvox/keys/nuc/public_key.pkcs7.pem \
  openvox/keys/ugreen/public_key.pkcs7.pem; do
  test -s "$path" || { echo "missing required file: $path" >&2; exit 1; }
done

# The same external credential may legitimately occur in multiple lists. That
# produces distinct ciphertext for every recipient key; it does not share a
# decrypt key across hosts.
mljr_labels=(
  vault_dockerhub_username vault_dockerhub_token vault_github_username vault_github_token
  vault_caddy_auth_user vault_caddy_auth_hash
  vault_authelia_jwt_secret vault_authelia_session_secret
  vault_authelia_storage_encryption_key vault_authelia_admin_password
  vault_smtp_host vault_smtp_port vault_smtp_user vault_smtp_password vault_smtp_from
  vault_pcloud_token vault_wd_cloud_user vault_wd_cloud_password
  vault_crowdsec_firewall_bouncer_key vault_crowdsec_web_ui_password
  vault_crowdsec_web_ui_notification_secret vault_hetrixtools_api_token
  vault_strava_client_id vault_strava_client_secret vault_strava_refresh_token
  vault_homepage_umami_website_id vault_homepage_tailscale_api_key vault_homepage_contact_to
)
nuc_labels=(
  vault_dockerhub_username vault_dockerhub_token vault_github_username vault_github_token
  vault_github_readonly_token vault_pcloud_token vault_wd_cloud_user vault_wd_cloud_password
  vault_nocturne_instance_key vault_nocturne_base_domain vault_nocturne_postgres_password
  vault_nocturne_postgres_app_password vault_nocturne_postgres_migrator_password vault_nocturne_postgres_web_password
  vault_mailarchiver_db_password vault_mailarchiver_admin_user vault_mailarchiver_admin_password
  vault_dmarcmonitor_db_password
  vault_sudoku_api_user vault_sudoku_api_password
  vault_strava_client_id vault_strava_client_secret vault_strava_refresh_token
  vault_homepage_umami_website_id vault_homepage_tailscale_api_key vault_homepage_contact_to
  vault_smtp_host vault_smtp_port vault_smtp_user vault_smtp_password vault_smtp_from
  vault_umami_app_secret vault_umami_postgres_password
  vault_forgejo_postgres_password vault_forgejo_runner_secret
  vault_kuma_username vault_kuma_password vault_kuma_api_key
  vault_grafana_admin_user vault_grafana_admin_password
  vault_netronome_admin_password vault_netronome_session_secret
  vault_homeassistant_token vault_healthreport_email_to
  vault_tutabridge_keyring_password vault_tuta_email vault_tuta_password
)
ugreen_labels=(
  vault_dockerhub_username vault_dockerhub_token vault_github_username vault_github_token
  vault_oxicloud_postgres_password vault_syncthing_nas_api_key
)

docker run --rm -i --entrypoint /bin/sh \
  --user "$(id -u):$(id -g)" \
  -v "$repo_root/openvox:/repo:ro" \
  -v "$repo_root/openvox/data/secrets:/output" \
  "$image" -s -- "${mljr_labels[*]}" "${nuc_labels[*]}" "${ugreen_labels[*]}" "${targets[*]}" <<'CONTAINER_SCRIPT'
set -euo pipefail
trap 'rm -f /output/mljr.tail33930.ts.net.eyaml.tmp /output/nuc.tail33930.ts.net.eyaml.tmp /output/ugreen.tail33930.ts.net.eyaml.tmp' EXIT

eyaml() {
  (cd /opt/voxbox && bundle exec eyaml "$@")
}

legacy=/repo/data/common.eyaml
private=/repo/keys/private_key.pkcs7.pem
write_host_file() {
  host="$1"
  labels="$2"
  public="/repo/keys/${host}/public_key.pkcs7.pem"
  case "$host" in
    mljr) certname='mljr.tail33930.ts.net' ;;
    nuc) certname='nuc.tail33930.ts.net' ;;
    ugreen) certname='ugreen.tail33930.ts.net' ;;
  esac
  output="/output/${certname}.eyaml"
  tmp="${output}.tmp"
  : > "$tmp"
  chmod 0600 "$tmp"
  for label in $labels; do
    # Current values are one-line quoted YAML scalars. Failing closed is
    # safer than silently omitting a secret if that format ever changes.
    [ "$(grep -Ec "^\"${label}\": \"ENC\\[PKCS7," "$legacy")" -eq 1 ] || {
      echo "missing or ambiguous ciphertext for ${label}" >&2
      exit 1
    }
    grep -E "^\"${label}\": \"ENC\\[PKCS7," "$legacy" >> "$tmp"
  done
  eyaml recrypt --pkcs7-private-key="$private" --pkcs7-public-key="$public" "$tmp"
  mv "$tmp" "$output"
  chmod 0644 "$output"
}

for host in $4; do
  case "$host" in
    mljr) write_host_file mljr "$1" ;;
    nuc) write_host_file nuc "$2" ;;
    ugreen) write_host_file ugreen "$3" ;;
  esac
done
CONTAINER_SCRIPT

echo 'Created encrypted host files under openvox/data/secrets/. Review the diff; no plaintext was written.'
