#!/usr/bin/env bash
# Compile the production catalogs of one openvox/ tree without any host:
#
#   catalog-compile.sh <openvox-dir> <out-dir> [certname ...]
#
# writes <out-dir>/<certname>.json (and .err) per host, by default every host
# with facts in openvox/ci/facts/. Runs `puppet catalog compile` in the pinned
# VoxBox image (as make test-openvox-unit does), with:
#   - facts from openvox/ci/facts/ (scripts/catalog-facts.sh)
#   - hiera from the tree's data/, except secrets: every vault_* key of the
#     tree's data/secrets/<certname>.eyaml gets the placeholder
#     "ci-placeholder-<key>" (no private key is needed or used)
#   - openvox/ci/overrides.yaml for parameters whose defaults run generate()
#     against host state
#   - the tree's Puppetfile modules plus openvox/ci/vendor-modules (core
#     types the agent package vendors)
# The CI config (facts, overrides, vendor list) always comes from this
# script's checkout, so a base tree from before it existed compiles too.
# Used by scripts/catalog-diff.sh and the "Catalog diff" PR check.
set -euo pipefail

voxbox="ghcr.io/voxpupuli/voxbox@sha256:704dfe406a3f2f16d0b2a4d71fb4de4b72a9768df1e1cda06134240e5f01dc3c"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ci="${repo}/openvox/ci"

tree="$(cd "${1:?usage: catalog-compile.sh <openvox-dir> <out-dir> [certname ...]}" && pwd)"
mkdir -p "${2:?out-dir missing}"
out="$(cd "$2" && pwd)"
shift 2
certs=("$@")
if [ "${#certs[@]}" -eq 0 ]; then
  for f in "$ci"/facts/*.json; do certs+=("$(basename "$f" .json)"); done
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/secrets"
for c in "${certs[@]}"; do
  [[ "$c" =~ ^[a-z0-9.-]+$ ]] || { echo "invalid certname: $c" >&2; exit 2; }
  [ -f "$ci/facts/$c.json" ] || { echo "no facts for $c in $ci/facts" >&2; exit 2; }
  : > "$work/secrets/$c.yaml"
  if [ -f "$tree/data/secrets/$c.eyaml" ]; then
    grep -oE '^"?vault_[A-Za-z0-9_]+"?:' "$tree/data/secrets/$c.eyaml" | tr -d '":' |
      awk '{ printf "%s: \"ci-placeholder-%s\"\n", $1, $1 }' > "$work/secrets/$c.yaml"
  fi
done
cat > "$work/hiera.yaml" <<'EOF'
version: 5
hierarchy:
  - name: "CI overrides (compile-time generate())"
    data_hash: yaml_data
    datadir: /ci
    path: "overrides.yaml"
  - name: "Per-node data"
    data_hash: yaml_data
    datadir: /tree/data
    path: "nodes/%{trusted.certname}.yaml"
  - name: "Common data"
    data_hash: yaml_data
    datadir: /tree/data
    path: "common.yaml"
  - name: "Secret placeholders"
    data_hash: yaml_data
    datadir: /work/secrets
    path: "%{trusted.certname}.yaml"
EOF

# Runs in VoxBox. The first argument is the list of certnames.
# shellcheck disable=SC2016 # expanded inside the container
inner='
set -eu
cd /opt/voxbox
P="bundle exec puppet"
mkdir -p /work/home /work/mods /work/vendor /work/var/yaml/facts
sed -nE "s/^[[:space:]]*mod[[:space:]]+'"'"'([a-zA-Z0-9_-]+\/[a-zA-Z0-9_-]+)'"'"',[[:space:]]*'"'"'([0-9.]+)'"'"'.*/\1 \2/p" /tree/Puppetfile |
  while read -r m v; do $P module install "$m" --version "$v" --target-dir /work/mods --force --ignore-dependencies >/dev/null; done
grep -vE "^[[:space:]]*(#|$)" /ci/vendor-modules |
  while read -r m v; do $P module install "$m" --version "$v" --target-dir /work/vendor --force --ignore-dependencies >/dev/null; done
rc=0
for c in $1; do
  bundle exec ruby -rjson -rpuppet -e "d = JSON.parse(File.read(ARGV[0])); File.write(\"/work/var/yaml/facts/#{d[%q(name)]}.yaml\", Puppet::Node::Facts.new(d[%q(name)], d[%q(values)]).to_yaml)" "/ci/facts/$c.json"
  if $P catalog compile "$c" --certname "$c" --render-as json --log_level warning \
      --vardir /work/var --confdir /work/conf --codedir /work/code \
      --modulepath /tree/modules:/work/mods:/work/vendor --manifest /tree/manifests/site.pp \
      --hiera_config /work/hiera.yaml --facts_terminus yaml --node_terminus plain \
      > "/out/$c.json" 2> "/out/$c.err"; then
    echo "compiled $c"
  else
    echo "FAILED $c:"; sed "s/\x1b\[[0-9;]*m//g" "/out/$c.err"; rc=1
  fi
done
exit $rc
'
# As the caller, so everything under $work and $out stays removable.
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/work/home \
  -v "$tree:/tree:ro,z" -v "$ci:/ci:ro,z" -v "$work:/work:z" -v "$out:/out:z" \
  --entrypoint sh "$voxbox" -c "$inner" sh "${certs[*]}"
