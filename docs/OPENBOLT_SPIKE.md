# OpenBolt spike: criteria

Status: criteria written 2026-11-22, before any test ran. Phase 5 item of
docs/ZERO_TRUST_PLAN.md. Results get added below the criteria, which stay as
written.

## Question

The config-mgmt spike (docs/SPIKE_CONFIG_MGMT.md) chose OpenVox with the pull
deploy agent and rejected OpenBolt `apply()` for the main hosts: it compiles
on the controller, so the controller needs every host's eyaml key. This spike
asks whether OpenBolt still adds a measurable benefit as a **laptop tool** for
bootstrap, enrolment and the appliance work that runs today as proxy `exec`
on nuc. Adopt it only for a clear win; otherwise drop it.

## State of OpenBolt (researched 2026-11-22)

- Current release 9.1.0 (2026-11-19). 9.0.0 (2026-11-11) renumbered 5.x to 9
  to match OpenVox; 5.x goes end of life (openbolt#356). Active: releases
  every few weeks, Choria transport under heavy development.
- Bundles OpenVox 9.3.0, Ruby 4.0.9, OpenSSL 3.5.9. Plans and `apply` compile
  with OpenVox 9; targets keep their agent ("OpenVox 9 is not required on
  your targets"). Ours run OpenVox 8 (mljr and nuc 8.34.0, ugreen 8.28.1).
- Packages for Fedora 43-45 in the `openvox9` repos. The container image
  `ghcr.io/openvoxproject/openbolt` has only `5.6.0-latest`, no 9.x yet.
- `apply` still compiles on the OpenBolt host and needs an OpenVox agent on
  the target (`apply_prep` installs one with `openvox_bootstrap`, which does
  not support Unraid or the WD MyCloud). nas and wd_mycloud only get tasks,
  commands and scripts over SSH.
- `native-ssh` (the system `ssh`, so `~/.ssh/config`: opkssh, Ziti names,
  `nas-mgmt`) is still listed under experimental features.
- `Deferred` functions are resolved on the target during `apply`
  (libexec/apply_catalog.rb calls `DeferredResolver.resolve_and_replace`;
  covered by openbolt's spec/integration/apply_spec.rb, `basic::defer`).
- Secret plugins: `pkcs7` (`bolt secret`) and `vault` resolve on the
  controller.

## Current baseline (measured 2026-11-22)

- Appliance glue on nuc: 3162 lines of shell in 11 directories under
  `openvox/modules/roles/files/` (unraid, unraid_backup, unraid_host_facts,
  unraid_aoostar, canary_decoys_nas, services_nas, nas_mgmt,
  nas_ziti_tcp_proxy, wd_mycloud, wd_mycloud_node_exporter, wd_mycloud_ziti),
  30 proxy `exec` resources, 66 `ssh` calls. Runs on every nuc apply (deploy
  agent, weekly maintenance window), not from the laptop.
- Laptop scripts: 718 lines (`scripts/ziti-enroll-{caddy,phone,proxy,router,wd-mycloud}.sh`,
  `scripts/openvox-sync.sh`, `scripts/install-openvox.sh`).

## Setup

OpenBolt 9.1.0 from the `openvox9` repo in a throwaway Fedora container on
the laptop (no 9.x image exists; nothing installed on the laptop itself),
`native-ssh` with the laptop's `~/.ssh/config`, so targets are reached as
today: `root@<host>.ziti` with opkssh, nas through nuc's `nas-mgmt`.

## Test cases

1. **Appliance.** Port one nas proxy class (`roles::canary_decoys_nas`, or
   `roles::unraid_host_facts_proxy` if that is too small to say anything) to
   an OpenBolt plan or tasks over `nas-mgmt`. Measure lines before and after,
   how the check-before-apply (idempotence, noop) is expressed, wall time, and
   what a failure looks like compared to an `exec` failure in the Puppet
   report.
2. **Enrolment.** Rewrite `scripts/ziti-enroll-proxy.sh` (including its nas
   branch through nuc) as a plan. Measure lines and steps before and after,
   and check that the private key still never leaves the target.
3. **Secrets with `apply`.** On nuc or ugreen, `apply` a resource whose value
   comes from an eyaml ciphertext that only the target decrypts:
   `Deferred('<our function>', [$ciphertext])`, with the target's own key in
   `/etc/puppetlabs/puppet/eyaml/`. The laptop's hiera has no eyaml backend
   and no key. Measure whether it works on our OpenVox 8 agents, and what a
   role with secrets in templates (`.env` files) would need.

## Conditions (all must hold for an adopt)

- Nothing new on any target: no agent on nas or wd_mycloud, only what is
  there today (bash/sh, ssh).
- No new secret on the laptop: no eyaml private key, no host key. Secrets
  are either decrypted on the target (`Deferred`, test case 3) or not
  handled by OpenBolt at all.
- Works from the laptop over Ziti with opkssh (`native-ssh`); no Tailscale.
- Installable and pinnable on the laptop and in DR (package version or
  image digest).

## Decision rule

- **Adopt** only if test case 1 or 2 is clearly smaller or simpler, and every
  condition holds.
- **Drop** otherwise, also when appliance management would then live in two
  places (Puppet on nuc for the automatic runs, OpenBolt on the laptop by
  hand) without removing one of them.
- Test case 3 decides only whether `apply` could ever be used without eyaml
  keys on the laptop; it does not reopen the main-host decision on its own.

## Results

Not run yet.
