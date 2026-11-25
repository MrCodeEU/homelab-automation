#!/usr/bin/env bash
# Remote eyaml commands below are built from validated host names and fixed
# paths, same pattern as scripts/rotate-eyaml-secret.sh.
# shellcheck disable=SC2029
# Copy existing vault_* secrets from one host's eyaml file to other hosts,
# e.g. the healthreport mail credentials from nuc to mljr and ugreen:
#
#   copy-eyaml-secret.sh [--dry-run] [--yes] --from nuc --to mljr[,ugreen] KEY [KEY...]
#
# Per key: decrypted on the source host with its own key (scripts/eyaml-get.sh),
# encrypted on each target host with that host's public key, then decrypted
# there once more to check the round trip. The plaintext only lives in a shell
# variable of this script: it is never printed, never written to disk and
# never passed as an argument (stdin to `eyaml encrypt`). A key that already
# exists on a target is skipped there, never overwritten: that is
# `make rotate-secret`. All copies land in one branch, commit and PR.
#
# --dry-run stops after encrypting and reverts the files. --yes answers the
# confirmations (for non-interactive runs).
set -uo pipefail

# SSH over Ziti with the opkssh key (scripts/opk-ready.sh).
"$(dirname "${BASH_SOURCE[0]}")/opk-ready.sh"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "not inside a git repo" >&2
  exit 1
}
cd "$repo_root" || exit 1

secrets_dir="openvox/data/secrets"
declare -A HOST_CERTNAME=(
  [mljr]="mljr.int.mljr.eu"
  [nuc]="nuc.int.mljr.eu"
  [ugreen]="ugreen.int.mljr.eu"
  [drill]="drill.int.mljr.eu"
)
declare -A HOST_SSH=(
  [mljr]="mljr.ziti"
  [nuc]="nuc.ziti"
  [ugreen]="ugreen.ziti"
  [drill]="drill.ziti"
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

dry_run=false
yes=false
from=""
to=""
keys=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --yes) yes=true ;;
    --from) from="${2:-}"; shift ;;
    --to) to="${2:-}"; shift ;;
    -h|--help)
      echo "usage: $0 [--dry-run] [--yes] --from <host> --to <host>[,<host>] KEY [KEY...]"
      exit 0
      ;;
    -*) die "unknown option $1" ;;
    *) keys+=("$1") ;;
  esac
  shift
done

confirm() {
  [ "$yes" = true ] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

for bin in ssh git gh sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done
[ -n "${HOST_CERTNAME[$from]:-}" ] || die "--from must be one of: ${!HOST_CERTNAME[*]}"
[ -n "$to" ] || die "--to needs at least one host"
targets="${to//,/ }"
for t in $targets; do
  [ -n "${HOST_CERTNAME[$t]:-}" ] || die "unknown target host '$t' (known: ${!HOST_CERTNAME[*]})"
  [ "$t" != "$from" ] || die "target $t is the source host"
done
[ "${#keys[@]}" -gt 0 ] || die "no keys given"

src_file="${secrets_dir}/${HOST_CERTNAME[$from]}.eyaml"
has_key() { grep -q "^\"$2\":" "$1"; }
for k in "${keys[@]}"; do
  [[ "$k" =~ ^vault_[a-z0-9_]+$ ]] || die "key must match vault_[a-z0-9_]+: $k"
  has_key "$src_file" "$k" || die "$k is not in $src_file"
done

# Plan: which key goes to which target.
step "Plan"
declare -A WANT   # "target key" -> 1
todo=0
for t in $targets; do
  file="${secrets_dir}/${HOST_CERTNAME[$t]}.eyaml"
  [ -f "$file" ] || die "missing $file"
  for k in "${keys[@]}"; do
    if has_key "$file" "$k"; then
      info "$t: $k already there, skipped"
    else
      info "$t: $k (from $from)"
      WANT["$t $k"]=1
      todo=$((todo + 1))
    fi
  done
done
[ "$todo" -gt 0 ] || { bold "Nothing to copy."; exit 0; }
[ "$dry_run" = true ] && bold "DRY RUN - files are reverted after encrypting, nothing committed"
confirm "Copy $todo secret(s)?" || die "aborted"

declare -a changed_files
revert() { [ "${#changed_files[@]}" -eq 0 ] || git checkout -- "${changed_files[@]}"; }

for k in "${keys[@]}"; do
  step "$k"
  value="$(bash scripts/eyaml-get.sh "$from" "$k")" || { revert; die "could not decrypt $k on $from"; }
  [ -n "$value" ] || { revert; die "$k decrypts to an empty value on $from"; }
  sum="$(printf '%s' "$value" | sha256sum)"
  for t in $targets; do
    [ -n "${WANT["$t $k"]:-}" ] || continue
    certname="${HOST_CERTNAME[$t]}"
    d="/etc/puppetlabs/puppet/eyaml/hosts/${certname}"
    cipher="$(printf '%s' "$value" | ssh "root@${HOST_SSH[$t]}" \
      "/opt/puppetlabs/puppet/bin/eyaml encrypt --pkcs7-public-key='${d}/public_key.pkcs7.pem' -o string --stdin" \
      2>/dev/null)" || { revert; die "eyaml encrypt failed on $t"; }
    cipher="${cipher%$'\n'}"
    [[ "$cipher" =~ ^ENC\[PKCS7,[A-Za-z0-9+/=]+\]$ ]] || { revert; die "unexpected eyaml output on $t, refusing to write it"; }
    back="$(ssh "root@${HOST_SSH[$t]}" "/opt/puppetlabs/puppet/bin/eyaml decrypt -s '${cipher}' \
      --pkcs7-private-key=${d}/private_key.pkcs7.pem --pkcs7-public-key=${d}/public_key.pkcs7.pem" 2>/dev/null)" \
      || { revert; die "verification decrypt failed on $t"; }
    [ "$(printf '%s' "$back" | sha256sum)" = "$sum" ] || { revert; die "verification failed on $t: decrypted value differs"; }
    unset back
    file="${secrets_dir}/${certname}.eyaml"
    [ -z "$(tail -c1 "$file")" ] || echo >> "$file"
    printf '"%s": "%s"\n' "$k" "$cipher" >> "$file"
    [[ " ${changed_files[*]:-} " == *" $file "* ]] || changed_files+=("$file")
    info "$t: encrypted, verified, added"
  done
  unset value sum
done

step "Changed (ciphertext only)"
git diff --stat -- "${changed_files[@]}"

if [ "$dry_run" = true ]; then
  revert
  bold "Dry run complete - files reverted."
  exit 0
fi

branch="secret/copy-${from}-to-${to//,/-}-$(date +%Y%m%d%H%M)"
current_branch="$(git branch --show-current)"
[ "$current_branch" = "main" ] || confirm "Not on main (on '$current_branch') - branch off here anyway?" || { revert; die "aborted"; }
git checkout -q -b "$branch" || { revert; die "could not create $branch"; }
git add "${changed_files[@]}"
git commit -q -m "chore: copy ${keys[*]} from ${from} to ${to}" || die "commit failed"
confirm "Push $branch and open a PR?" || die "left committed locally on $branch, not pushed"
git push -q -u origin "$branch" || die "push failed"
pr_url="$(gh pr create --head "$branch" --title "chore: copy secrets from ${from} to ${to}" \
  --body "Copies ${keys[*]} from ${from} to ${to} (scripts/copy-eyaml-secret.sh: decrypted on ${from}, encrypted with each target's public key, round trip verified there). Keys already present on a target were skipped.")"
bold "PR opened: $pr_url"
info "After merge, deploy the target hosts one at a time."
