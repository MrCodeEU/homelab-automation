#!/usr/bin/env bash
set -euo pipefail
grep -qxF 'exclude = *.i686' /etc/dnf/dnf.conf
grep -qxF 'best = False' /etc/dnf/dnf.conf
