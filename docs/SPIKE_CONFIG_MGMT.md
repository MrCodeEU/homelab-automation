# Spike: config management after Tailscale (CFEngine, glidesh, OpenVox)

Status: planned 2026-11-11. Open-ended, decided by the owner.

## Question

Without Tailscale, CI has no root SSH path to the hosts. Before we build
one (option A: OIDC to Ziti and opkssh) or switch to pull (option C), find
out whether a different tool fits better. The candidates:

- **CFEngine 3.27 LTS**: a pull agent with a policy hub, C, mature.
- **glidesh 2.1**: SSH push, Rust, KDL plans, young (7 stars, 3
  contributors, v2.0.0 2026-10-06).
- **OpenVox** as the baseline, on the same targets, both as a push (today's
  `openvox-sync.sh`) and as a pull (option C).

Rejected without a spike: OpenVox server and agents (the server needs every
host's eyaml key), OpenBolt `apply()` (compiles on the controller, same
problem), Ansible (Python), NixOS (rewrite of the OS). See the 2026-11-11
discussion in the session log and docs/ZERO_TRUST_PLAN.md "Config
management".

## Criteria

| | measured by |
|---|---|
| a) authoring | lines and files for the slice, how a change reads, error messages, docs |
| b) apply | run time (cold, warm, no change), output, partial failure, rerun |
| c) architecture | trust model, where secrets are decrypted, push or pull, what runs permanently on the host, how CI and the laptop trigger it, DR from a fresh OS |
| d) rewrite | the slice extrapolated to the 26 roles, plus what has no equivalent |
| e) dry run | the dependency case (a guard script created in the same run), diffs of files and templates, whether a dry run can be trusted |

Also noted: monitoring (last success, drift), Ziti fit, failure of the
tool itself (agent down, controller down), upgrade path, licence.

## The slice

The same four parts in every tool, each modelled on a real role:

1. **Service with config**: package `iperf3`, a systemd unit with a
   templated `ExecStart`, enabled and running, restart on change only
   (`roles::iperf3`).
2. **Compose stack with a secret**: a small stack (whoami or similar), its
   `.env` with one secret from the tool's secret store, a post-deploy hook,
   redeploy only on change (`roles::services`, `speedtest-metrics`).
3. **sshd drop-in with validation**: a drop-in checked with `sshd -t`
   before it goes live, a guard script created in the same run (this
   week's noop failure on ugreen), reload only on change
   (`roles::host_facts_endpoint`).
4. **Per-host data**: one file whose content differs per host (hiera-like
   data), and one host-only secret that the other host must not be able to
   read.

## Environment

- Two **Rocky Linux 10** VMs on nuc (`spike-a`, `spike-b`), plus a third
  for the CFEngine hub (`spike-hub`). KVM/libvirt, disks under
  `/home/spike-vms` (391 GB free; `/` has only 14 GB).
- **NAT only** (libvirt's default network): the VMs reach the internet
  outbound (packages, Ziti routers) and nothing reaches them inbound. No
  port forwarding, no LAN bridge.
- **Ziti only**, no Tailscale on the VMs:
  - each VM gets a Ziti identity and hosts `spike-ssh-<vm>` (127.0.0.1:22)
  - the hub also hosts `spike-cfengine` (5308) for the CFEngine clients
  - the laptop dials them through its tunneler
  - definitions in `ziti/tofu/spike.tf`, tag `spike`, removed at the end
- SSH login to the VMs with opkssh (Authelia) where it fits, otherwise a
  spike-only key that is deleted afterwards.

### Changes to nuc (production)

- packages `qemu-kvm libvirt virt-install` (not via OpenVox: removed
  again after the spike, and nuc's role knows nothing about them)
- libvirt adds a `virbr0` bridge and a firewalld zone `libvirt` for NAT;
  nothing on nuc's own zones or published ports changes
- about 3 x 4 GB RAM and 3 x 20 GB disk while the VMs run

### Teardown

`virsh destroy` and `undefine --remove-all-storage` for the three VMs,
`dnf remove` of the packages, check that firewalld is back to its zones,
delete `ziti/tofu/spike.tf` (tofu destroys the identities and services),
delete the spike key, and leave this file with the results.

## Steps

1. nuc: libvirt, the three VMs from the Rocky 10 cloud image (cloud-init:
   user, key, Ziti tunneler).
2. Ziti: `spike.tf`, enrolment, and SSH to each VM over Ziti from the
   laptop (check: the VMs have no other inbound path).
3. Baseline: the slice in OpenVox. Push with `openvox-sync.sh` over Ziti,
   then pull (a timer, `git verify-commit`, `puppet apply`).
4. CFEngine: hub on `spike-hub`, clients bootstrap through Ziti, the slice
   in policy, masterfiles from git.
5. glidesh: inventory and plans for the slice, run from the laptop over
   Ziti.
6. For each tool, criteria a to e: the dry run with the dependency case, a
   change to each part, a deliberate failure (bad sshd drop-in), a rerun
   without changes.
7. Write-up below, then a recommendation.

## Setup notes (2026-11-11)

What the plan did not foresee, in the order it came up:

- The VM disks under `/home/spike-vms` need the SELinux type
  `virt_image_t` (`semanage fcontext` + `restorecon`). Without it, qemu
  gets `Permission denied` on every disk read and the VMs never boot.
- Docker's `iptables -P FORWARD DROP` on nuc also drops libvirt NAT
  traffic. Four runtime rules in `DOCKER-USER` allow `virbr0` out to the
  internet but drop 192.168.50.0/24 (LAN) and 100.64.0.0/10 (tailnet),
  and let only return traffic in. Not persistent; removed at teardown.
- OpenZiti ships no `ziti-edge-tunnel` RPM for EL. The VMs run the
  `openziti` package (`ziti` 2.0.8, the controller's version) as a
  systemd unit: `ziti tunnel host` on the hub, `ziti tunnel proxy
  spike-cfengine:5308` on the clients (proxy mode also hosts the SSH
  service). Identities in `/etc/ziti/<vm>.json`.
- The Rocky 10 GenericCloud image lacks `kernel-modules-extra`
  (`xt_addrtype`); Docker fails to start without it.
- Docker CE, git and rsync are installed by hand on both clients, the
  same for every tool, so part 2 of the slice compares the stack itself.

## Results

### OpenVox (baseline)

Code: `spike/openvox/` on branch `spike/pull` (module `spike`, own
`hiera.yaml`, per-host eyaml under `data/eyaml/`, `push.sh`,
`spike-pull.sh`). About 190 lines of Puppet for the four parts.

**a) authoring.** The slice reads like the production roles. Gotcha:
`\$` in a heredoc is only an escape with the `/$` flag (`@("END"/$)`);
without it the compile fails with `Resource type not found: WHOAMI_NAME`,
which does not point at the cause. A compose stack is an `exec
refreshonly` (production uses `docker_compose` from the Forge).

**b) apply.** Push over Ziti, spike-a: cold apply 7.8 s (catalog 3.9 s),
rerun without changes 3.4 s (catalog 0.08 s; the rest is rsync and Ruby
start-up). spike-b cold: 7.4 s. Partial failure (bad sshd drop-in): the
failing file keeps its old content, its dependents are skipped with
`Skipping because of failed dependencies`, unrelated resources still
apply.

**c) architecture.** Secrets: each host decrypts only its own file;
spike-b on spike-a's file gives `bad decrypt`. Push needs SSH to every
host (here over Ziti). Pull (option C) prototype: a systemd timer runs
`spike-pull.sh`: fetch the branch, `git verify-commit` against an
allowed-signers file, `puppet apply`, write `last-success`. 4.0 s for a
run without changes. An unsigned head is refused (`refusing <sha>: not
signed by an allowed key`) and nothing applies.

**Finding (pull):** checking only the head is not enough. An unsigned
commit with a signed commit on top was applied. A real agent must check
every commit from the last applied one to the new head and accept a fast
forward only. On `main` every commit is a GitHub-signed squash merge, so
this holds there.

**e) dry run.** Three limits, all reproduced:

1. **Dependency case fails.** On a fresh host `--noop` ends with
   `Exec[sshd-reload]: Could not evaluate: Could not find command
   '/usr/local/sbin/spike-sshd-check.sh'` (exit 4), because the guard
   script is created in the same run. The same failure as ugreen on
   2026-11-10; the workaround is the `test -f && exec` guard.
2. **`validate_cmd` does not run in noop.** A typo in the sshd drop-in
   (`ForceComand`) shows as "content changed" in noop; only the real
   apply rejects it (`Bad configuration option: ForceComand`).
3. **No diff without `--show_diff`.** Plain `--noop` shows only sha256
   checksums; `--show_diff` gives a real diff. `openvox-sync.sh` does
   not pass it, so the PR live noop never shows file diffs. Sensitive
   values show as `[redacted]`.
