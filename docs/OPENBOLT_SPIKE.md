# OpenBolt spike: criteria and results

Status: criteria written 2026-11-22, before any test ran; run the same day.
Result: **drop** (see Results). Phase 5 item of docs/ZERO_TRUST_PLAN.md. The
criteria stay as written; the results are below them.

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

## Results (2026-11-22)

**Recommendation: drop.** All three test cases work and every condition
holds, but neither test case 1 nor 2 is a clear win, and adopting it would put
appliance management in two places. That is the drop case of the decision
rule.

### Setup as run

- The `openvox9` RPM for Fedora 44 in a Containerfile (`openbolt-9.1.0`,
  `openssh-clients`, `jq`). The package bundles openvox 9.4.1, not the 9.3.0
  the release notes name.
- `native-ssh` with the laptop's `~/.ssh` mounted read-only. Targets are
  `root@<host>.ziti` (nuc, mljr, ugreen) and `root@nas-ssh.ziti`, all logged
  in with the opkssh key over Ziti.
- **Setup change (#694):** nas had no opkssh, and nuc's `nas-mgmt` key may not
  leave nuc, so the laptop could not reach nas at all. #694 added opkssh on
  nas (`roles::nas_opkssh`). That was the Phase 3 C14 gap for nas anyway, not
  OpenBolt-specific. Since then nas is reached directly; the hop through nuc
  is gone.
- **Two native-ssh details:**
  - A pinned known_hosts file has to be set in both `ssh-command` and
    `copy-command`. Otherwise `upload_file` ignores it and fails with
    `Host key verification failed`.
  - OpenBolt parses JSON stdout of a task into the result's `value` itself
    (there is no `_output`).

### 1. Appliance (`roles::canary_decoys_nas`)

| | Puppet on nuc (today) | OpenBolt plan |
|---|---|---|
| Code lines (no comments/blank) | 30 (class + 2 scripts) | 17, plus an 18-line inventory shared by all plans |
| Idempotence | `unless` check script (`cmp` over ssh) | sha256 compare in the plan; noop is an explicit `noop` parameter |
| Wall time | part of the nuc apply | 1.7 s in sync, 8.8 s placing the file |
| Runs | automatically, every nuc apply, drift reported | by hand from the laptop |

- **Results:** apply, second run ("in sync"), and a failure test (bad
  destination: `mv: cannot move ... No such file or directory`, target named)
  all behaved correctly. The failure message is as clear as the `exec` error
  in the Puppet report.
- **Assessment:** smaller, but the class is already small. The automatic
  drift correction and the healthreport's view of failed resources go away
  unless OpenBolt is also run on a schedule. That would be a second runner
  next to the deploy agent.

### 2. Enrolment (`scripts/ziti-enroll-proxy.sh`)

- **Size:** 83 code lines today. The plan and its two tasks (`zcli` on mljr,
  `enroll` on the target) are 46 lines plus 5 lines of task metadata.
  - That is not like for like. The plan leaves out what the script derives
    from the repo (destination from the compose file and node yaml, router
    image pin), the opk-ready check, and creating a token when none is open.
  - With those, it would be about 60-65 lines.
- **Read-only runs** (no enrolment, live identities):
  - dry run on ugreen and nas;
  - "exists, rerun with reenroll" on nas;
  - "identity not found".

  Same three branches as the script. The real enrolment step is written but
  was not run, since it needs a new tofu identity.
- **Secrets:** the one-time token goes to the target as a `sensitive` task
  parameter over stdin. `bolt-debug.log` had neither a JWT nor the controller
  admin password. Enrolment still runs on the target, so the private key does
  not leave it.
- **Time:** 6-20 s per run against 2.8 s for the script. Every `run_task`
  uploads the task again.
- **Assessment:** about the same size, slower, and the shell is still there,
  now split into tasks. The real simplification (nas without the nuc hop)
  came from opkssh on nas, and the script can use it too.

### 3. Secrets with `apply` (`Deferred` on nuc)

- **Test:** a random dummy value (no real secret) was encrypted to nuc's
  public key (`openvox/keys/nuc/public_key.pkcs7.pem`). A 15-line Ruby
  function decrypts `ENC[PKCS7,...]` with
  `/etc/puppetlabs/puppet/eyaml/hosts/nuc.int.mljr.eu/` and returns
  `Sensitive`. A class puts it into a 0600 file through `Deferred`.
- **Result: works on nuc's OpenVox 8.34 agent.**
  - The file is correct and 0600.
  - The report says `changed [redacted] to [redacted]`, and the second run
    makes no change.
  - The plaintext appears nowhere on the laptop (debug log, project dir).
  - On nuc it appears only in the target file (`/tmp`, `/var/tmp`, the agent
    cache, `/etc/puppetlabs`, `/var/log` checked).
  - The laptop container had no eyaml key.
- **Bug:** `Deferred` written inline in an `apply` block does not compile in
  OpenBolt 9.1.0. Even `Deferred('sprintf', ...)` fails with
  `no implicit conversion of Puppet::Pops::Types::PBinaryType::Binary into String`.
  The serialised AST carries the source file name as `Binary`. Workaround:
  the `Deferred` sits in a module class and the apply block only declares
  the class. Worth an upstream issue.
- **What a role with secrets in templates would need:** every template that
  holds a secret (the `.env` files) would have to be rendered on the target,
  `Deferred('inline_epp', [...])` with the decrypted values as `Sensitive`
  arguments. Any logic in the template that uses a secret's value runs only
  there. That is a rewrite of every such role, so test case 3 does not
  reopen the main-host decision.

### Conditions

| Condition | Held |
|---|---|
| Nothing new on any target | yes: only ssh and sh/bash (opkssh on nas is C14, not OpenBolt) |
| No new secret on the laptop | yes: test case 3 decrypts on the target, test case 2 keeps the token sensitive |
| Laptop over Ziti with opkssh, no Tailscale | yes, with the `copy-command` detail above |
| Installable and pinnable | yes as an RPM version; no 9.x image, so our own Containerfile |

### What stays from the spike

- opkssh on nas (#694): admin SSH to nas over Ziti without nuc.
- Laptop scripts and nas tools could use `root@nas-ssh.ziti` directly instead
  of going through `nas-mgmt` on nuc. That is a separate cleanup.
- If secrets ever have to be rendered without the deploy agent, the
  `Deferred` + target-key pattern works with our OpenVox 8 agents.
