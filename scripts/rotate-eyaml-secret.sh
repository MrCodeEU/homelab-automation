#!/usr/bin/env bash
# Remote eyaml command below is deliberately constructed from a validated
# client-side path, same pattern as scripts/openvox-sync.sh.
# shellcheck disable=SC2029
# Interactive secret rotation: pick a vault_* key, paste its new value, and
# this walks the whole flow documented in AGENTS.md ("Secrets are
# host-scoped and decrypt host-side") end to end:
#
#   1. discover which openvox/data/secrets/<certname>.eyaml files carry the
#      key (a secret can have several recipient hosts)
#   2. encrypt the new value once per recipient, via THAT host's own bundled
#      eyaml binary and ITS public key only (no decrypt, no private key
#      leaves the host, matches the "edit only through that recipient
#      host's eyaml" rule)
#   3. patch each local .eyaml file in place, show the diff, ask before
#      writing to disk
#   4. branch, commit, push, open a PR
#   5. confirm before merging, before each noop check, and before each real
#      `make openvox-deploy-<host>` - nothing destructive runs unattended
#
# Never prints the plaintext secret to the terminal or into any command
# that would land it in shell history / process listing on the remote host
# (piped over stdin to `eyaml encrypt`, not passed as an argv string).
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "not inside a git repo" >&2
  exit 1
}
cd "$repo_root" || exit 1

secrets_dir="openvox/data/secrets"
declare -A HOST_CERTNAME=(
  [mljr]="mljr.tail33930.ts.net"
  [nuc]="nuc.tail33930.ts.net"
  [ugreen]="ugreen.tail33930.ts.net"
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  local prompt="$1" reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

for bin in ssh git gh; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done

# ---------------------------------------------------------------------------
# 0. Args: optional --dry-run flag + optional key name, in either order
# ---------------------------------------------------------------------------
dry_run=false
positional=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    -h|--help)
      echo "usage: $0 [--dry-run] [vault_key_name]"
      exit 0
      ;;
    *) positional+=("$arg") ;;
  esac
done
[ "$dry_run" = true ] && bold "DRY RUN — will stop after showing the ciphertext diff, no commit/push/PR/deploy"

# ---------------------------------------------------------------------------
# 1. Discover vault_* keys and their recipient hosts
# ---------------------------------------------------------------------------
step "Scanning $secrets_dir for vault_* keys"

declare -A KEY_HOSTS   # key -> space-separated short host names
declare -a KEY_ORDER

for f in "$secrets_dir"/*.eyaml; do
  [ -f "$f" ] || continue
  certname="$(basename "$f" .eyaml)"
  short=""
  for h in "${!HOST_CERTNAME[@]}"; do
    [ "${HOST_CERTNAME[$h]}" = "$certname" ] && short="$h"
  done
  [ -n "$short" ] || die "no known host maps to certname '$certname' (edit HOST_CERTNAME in this script)"

  while IFS= read -r key; do
    if [ -z "${KEY_HOSTS[$key]:-}" ]; then
      KEY_ORDER+=("$key")
      KEY_HOSTS[$key]="$short"
    else
      KEY_HOSTS[$key]="${KEY_HOSTS[$key]} $short"
    fi
  done < <(grep -oE '^"vault_[A-Za-z0-9_]+"' "$f" | tr -d '"')
done

[ "${#KEY_ORDER[@]}" -gt 0 ] || die "no vault_* keys found under $secrets_dir"

mapfile -t KEY_ORDER < <(printf '%s\n' "${KEY_ORDER[@]}" | sort)

# ---------------------------------------------------------------------------
# 2. Pick the key (CLI arg or menu)
# ---------------------------------------------------------------------------
target_key="${positional[0]:-}"

if [ -z "$target_key" ]; then
  step "Select a secret to rotate"
  i=1
  for k in "${KEY_ORDER[@]}"; do
    printf '  %2d) %-45s [%s]\n' "$i" "$k" "${KEY_HOSTS[$k]}"
    i=$((i + 1))
  done
  read -r -p "Number: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#KEY_ORDER[@]}" ] \
    || die "invalid selection"
  target_key="${KEY_ORDER[$((choice - 1))]}"
else
  [ -n "${KEY_HOSTS[$target_key]:-}" ] || die "unknown key '$target_key' (not found in any $secrets_dir/*.eyaml)"
fi

hosts="${KEY_HOSTS[$target_key]}"
bold "Rotating: $target_key"
info "recipient hosts: $hosts"

# ---------------------------------------------------------------------------
# 3. Paste new value
# ---------------------------------------------------------------------------
step "Paste the new value for $target_key (input hidden)"
read -r -s -p "New value: " new_value
echo
[ -n "$new_value" ] || die "empty value, aborting"
read -r -s -p "Confirm (paste again): " new_value_confirm
echo
[ "$new_value" = "$new_value_confirm" ] || die "values did not match, aborting"
unset new_value_confirm

confirm "Proceed encrypting for hosts: $hosts?" || die "aborted"

# ---------------------------------------------------------------------------
# 4. Encrypt per host (public key only, host-side eyaml, no decrypt)
# ---------------------------------------------------------------------------
declare -A CIPHERTEXT
for short in $hosts; do
  certname="${HOST_CERTNAME[$short]}"
  step "Encrypting for $short ($certname)"
  remote_pub="/etc/puppetlabs/puppet/eyaml/hosts/${certname}/public_key.pkcs7.pem"
  cipher="$(printf '%s' "$new_value" | ssh "root@${certname}" \
    "/opt/puppetlabs/puppet/bin/eyaml encrypt --pkcs7-public-key='${remote_pub}' -o string --stdin" \
    2>/dev/null)" || die "eyaml encrypt failed on $short"
  # -o string prints exactly "ENC[PKCS7,...]" with a trailing newline, no
  # other framing - strip only that trailing newline.
  cipher="${cipher%$'\n'}"
  [[ "$cipher" =~ ^ENC\[PKCS7, ]] || die "unexpected eyaml output for $short, refusing to write it"
  CIPHERTEXT[$short]="$cipher"
  info "OK"
done

# ---------------------------------------------------------------------------
# 5. Patch local files
# ---------------------------------------------------------------------------
declare -a changed_files
for short in $hosts; do
  certname="${HOST_CERTNAME[$short]}"
  file="${secrets_dir}/${certname}.eyaml"
  lineno="$(grep -n "^\"${target_key}\":" "$file" | head -1 | cut -d: -f1)"
  [ -n "$lineno" ] || die "could not find line for $target_key in $file"
  newline="\"${target_key}\": \"${CIPHERTEXT[$short]}\""
  awk -v n="$lineno" -v newline="$newline" 'NR==n { print newline; next } { print }' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
  changed_files+=("$file")
done

step "Diff (ciphertext only, no plaintext ever touches disk unencrypted)"
git diff -- "${changed_files[@]}"

if [ "$dry_run" = true ]; then
  git checkout -- "${changed_files[@]}"
  bold "Dry run complete - files reverted, nothing committed/pushed/deployed."
  info "Re-run without --dry-run to actually rotate ${target_key}."
  exit 0
fi

confirm "Write looks right - keep these changes staged for commit?" || {
  git checkout -- "${changed_files[@]}"
  die "reverted, aborted"
}

# ---------------------------------------------------------------------------
# 6. Branch, commit, push, PR
# ---------------------------------------------------------------------------
slug="$(echo "$target_key" | tr '_' '-')"
branch="rotate/${slug}-$(date +%Y%m%d)"

step "Creating branch $branch"
current_branch="$(git branch --show-current)"
[ "$current_branch" = "main" ] || confirm "Not on main (on '$current_branch') - branch off here anyway?" || die "aborted, switch to main first"
git checkout -b "$branch"
git add "${changed_files[@]}"
git commit -m "chore: rotate ${target_key}"

confirm "Push $branch and open a PR?" || die "left committed locally on $branch, not pushed"
git push -u origin "$branch"
pr_url="$(gh pr create --fill --head "$branch")"
bold "PR opened: $pr_url"

# ---------------------------------------------------------------------------
# 7. Merge (confirmed)
# ---------------------------------------------------------------------------
step "Waiting on PR checks"
if confirm "Watch checks now (gh pr checks --watch)?"; then
  gh pr checks "$branch" --watch || info "checks did not all pass - review before merging"
fi

if confirm "Merge $pr_url now (squash)?"; then
  gh pr merge "$branch" --squash --delete-branch
  git checkout main
  git pull --ff-only
else
  bold "Not merged. Re-run the deploy steps below yourself once it's merged:"
  info "git checkout main && git pull --ff-only"
  for short in $hosts; do
    info "make openvox-check-$short   # then make openvox-deploy-$short"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# 8. Deploy (noop always runs first and must pass - not skippable; real
#    deploy is still confirmed per host)
# ---------------------------------------------------------------------------
for short in $hosts; do
  step "Noop check: $short (required before deploy)"
  if make "openvox-check-$short"; then
    info "noop OK on $short"
  else
    info "noop FAILED on $short - refusing to offer a real deploy for this host"
    continue
  fi
  if confirm "Noop looked right - run REAL 'make openvox-deploy-$short' now?"; then
    make "openvox-deploy-$short"
  else
    info "skipped deploy for $short - run 'make openvox-deploy-$short' manually when ready"
  fi
done

bold "Done rotating ${target_key}."
