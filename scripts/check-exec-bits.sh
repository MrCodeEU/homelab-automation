#!/usr/bin/env bash
# Fail when a script under scripts/ has a shebang but is not executable in
# git (mode 100644). Checks the index, not the working tree: a clone with
# core.fileMode=false records new files as 100644 whatever chmod did on
# disk, and CI checks out exactly what the index says.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

bad=()
while IFS=$'\t' read -r meta path; do
  mode=${meta%% *}
  [ "$mode" = 100644 ] || continue
  [ "$(head -c 2 "$path")" = '#!' ] && bad+=("$path")
done < <(git ls-files -s -- scripts/)

if [ ${#bad[@]} -gt 0 ]; then
  printf 'FAIL  not executable in git (has a shebang):\n' >&2
  printf '  %s\n' "${bad[@]}" >&2
  printf 'Fix: git update-index --chmod=+x <file>; and git config core.fileMode true\n' >&2
  exit 1
fi
echo "OK  every script with a shebang under scripts/ is 100755"
