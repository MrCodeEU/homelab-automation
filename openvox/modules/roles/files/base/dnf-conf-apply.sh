#!/usr/bin/env bash
# dnf's solver evaluates i686 multilib candidates for "best" completeness
# even though no i686 packages are actually needed here - when a mirror's
# i686 metadata has a gap it blocks the entire transaction. best=False also
# lets dnf settle for whatever's actually mirrored instead of blocking on
# theoretical-newest-everywhere. Same reasoning as ansible/roles/base.
set -euo pipefail
grep -qxF 'exclude = *.i686' /etc/dnf/dnf.conf || echo 'exclude = *.i686' >> /etc/dnf/dnf.conf
grep -qxF 'best = False' /etc/dnf/dnf.conf || echo 'best = False' >> /etc/dnf/dnf.conf
