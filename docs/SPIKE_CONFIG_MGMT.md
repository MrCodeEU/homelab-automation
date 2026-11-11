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
`spike-pull.sh`). 221 lines (manifests, template, hiera, data) for the four parts.

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

### CFEngine 3.29.0

Code: `spike/cfengine/` (`def.json` augments, `services/spike/main.cf`,
`data/spike.json`, per-host `hostsecrets/<host>/*.dat`, `hub-pull.sh`).
276 lines of policy plus 17 of data. 3.27 LTS is not in the yum repo for
EL10 (only 3.28 and 3.29), so this is the current non-LTS release.

**Ziti fit: poor until tproxy.** Three things broke with a local proxy:

1. `cf-agent --bootstrap 127.0.0.1:<port>` makes the client a hub
   (`am_policy_hub`): any local address counts as "self".
2. A dummy-interface address is local too; the client then talked to its
   own `cf-serverd` (`Incoming 10.254.0.1 spike-a` in `cf-key -s`) and
   failed with `TRUST FAILED, server presented untrusted key`.
3. `ziti tunnel proxy` listens on `0.0.0.0`, not loopback, and collides
   with the client's own `cf-serverd` on 5308.

It works with `ziti tunnel tproxy` on the clients: the hub name resolves
to an intercept address (100.64.0.2), which is not local. That is how a
host with `ziti-edge-tunnel` would look. On the hub every client arrives
from 127.0.0.1, so the MPF `acl` must admit 127.0.0.1/32: IP ACLs say
nothing any more, Ziti's dial policy decides who reaches the hub and
CFEngine's keys say who it is. The MPF cannot bind `cf-serverd` to
loopback without editing `controls/cf_serverd.cf`; an nft rule on the
hub drops 5308 from anything but `lo`. The clients run `cf-serverd` too
(`*:5308`), which they do not need.

**a) authoring.** Promise theory reads differently: a fixed order per
bundle (classes, users, files, packages, commands, services), three
passes, and state between promises through classes. Gotchas, each found
by running it:

- The augment key in 3.29 is `control_common_bundlesequence_end`;
  `bundlesequence_end` is accepted and silently overwritten with an empty
  list, so the policy never ran and the run reported nothing.
- `content =>` logs the whole new content at info level: the `.env`
  secret appeared in `cf-agent -I` output and syslog. A template only logs
  "Updated rendering". No equivalent of `Sensitive`.
- Edits leave `.cf-before-edit` and copies `.cfsaved` backups, including
  `.env.cf-before-edit` and `host-secret.cfsaved`. `edit_defaults =>
  no_backup` and `copy_backup => "false"` on every promise that touches a
  secret.
- The decrypted secrets stay on disk (`/var/cfengine/spike/secrets/`,
  0600): `cf-secret` is a CLI, the policy decrypts with a command.
- MPF package modules are Python (`cfengine-selected-python`); fine for a
  vendor part, but Python on every host.

**The validation trap (the important one).** The first sshd design
staged the drop-in, set a class from `returnszero("sshd -t -f staged")`
and copied it live when the class was set. cf-agent evaluates functions
once in a pre-evaluation, before any promise runs, and caches the result.
With a typo (`ForceComand`) the class described the old, valid staging
file, so the broken drop-in was copied live, the SIGHUP killed sshd
(`status=255`), and systemd's restarts failed on the same file. sshd was
down from 17:11:14 to 17:13:20, until the next run fixed the file. On a
real host without an open session that is a lockout. The same design
also reloaded before the copy on a fresh host (reload 17:08:24.713, file
17:08:24.8). The fix is one command that checks, installs and reloads
(`spike-sshd-activate`), the same shape as the production apply scripts;
with it a typo is refused (`fails sshd -t, ... left as it is`) and sshd
stays up. Puppet's `validate_cmd` has this built in.

**b) apply.** Through Ziti, spike-a: cold run 3.5 to 3.9 s, reruns 1.5
to 1.8 s (no Ruby start). `cf-execd` runs it every 5 minutes; killed with
`kill -9` it was back after 10 s (systemd `Restart=always`). With the
hub's `cf-serverd` stopped, the client still enforced its cached policy
and repaired drift; the update step took 22 s of TLS timeouts. A policy
with a syntax error never reached the clients: the hub's `cf-promises`
rejected it and they kept the last valid one. `promise_summary.log`
gives kept/repaired/not repaired per run, a ready source for a metric.

**c) architecture.** Pull by design: the hub fetches git (`hub-pull.sh`:
every commit since the last one applied must be signed, fast forward
only), the clients pull from the hub over Ziti. CI needs no host access;
the laptop needs none either for normal changes. Secrets: `cf-secret`
encrypts per host key, the ciphertext is in git, the hub serves it and
cannot read it; spike-b on spike-a's file: `Decryption failed`. Bootstrap
trusts the hub's key on first contact (`implicitly trusting server`).
After `--bootstrap` the daemons were inactive once and had to be started
with `systemctl start cfengine3`.

**e) dry run (`--dry-run`).** Lists every planned action ("Should create
file", "Would execute"), but no diffs: for `content` the new text, for a
template only "Should update rendering". Dependency case: does not abort;
`returnszero` on the not-yet-created script logs two errors and the
class is false. `users` fails in dry-run (`Failed to create user`), so
that bundle shows as failed although nothing is wrong. Function results
are those of the current state, so a dry run cannot predict anything that
depends on a file the same run would write.

### glidesh 2.1.0

Code: `spike/glidesh/` (`inventory.kdl`, `plan.kdl`, `files/`,
`secrets.kdl` age-wrapped to the spike key). 111 lines of KDL plus 34 of
files. Run from the laptop over Ziti; the release binary is checked
against `checksums-sha256.txt`.

**a) authoring.** The easiest of the three to read: steps run top to
bottom, `subscribe` for handlers, `check=` for idempotent shell commands,
and `glidesh validate` catches undefined template variables before a
run. Gaps found:

- Structured variables (lists) work in plan vars but not in inventory
  host vars (`loops over 'peers', which is not a defined list`), so
  per-host lists need a different shape.
- No `validate_cmd`: the sshd drop-in uses the same "stage, then one
  command checks, installs and reloads" as CFEngine, with `check="cmp
  -s staged live"`.
- A unit created by the `systemd` module is reloaded but not restarted
  when it changes; that needs a handler step (`state="restarted"`).
- `secret set` needs a TTY; without one it stores nothing and says
  nothing. `secret encrypt` (stdin to a token) works.
- `container` manages single containers, not compose; part 2 is a file
  step plus a `shell` with `check` and `subscribe`.

**b) apply.** Fail-stop per host: when the sshd activation failed
(`Bad configuration option: ForceComand`), the rest of that host's plan
did not run (the colour change in the same run was not applied); other
hosts carry on. The staged file then differs from the live one, so the
next run retries. Slow over Ziti: one command on an open SSH connection
takes about 145 ms (laptop, mljr, nuc, VM), and every task needs a few.
Cold run 26 s for both hosts, a run without changes 20.8 s (one host
alone 7.8 s); OpenVox's push needed 3.4 s for the same no-change run.

**c) architecture.** Push only, no agent: the laptop (or CI) needs SSH
to every host and holds the key that decrypts every host's secrets; the
hosts only ever receive their own rendered values (spike-b's
`/etc/spike/host-secret` differs from spike-a's, and spike-b never sees
spike-a's token). That is weaker than eyaml or `cf-secret`, where a host
key is needed to read a host's secret. Per-host isolation would need one
secrets file per host, wrapped to that host's SSH key (the docs mention
this; not tried). A pull variant would be glidesh run on each host
against itself from a timer; not tried either.

**e) dry run (`--dry-run --diff`).** The best of the three. Unified
diffs for every file, `would change` with the reason, handlers predicted
(`restart (triggered)`), files that are not world-readable shown as
`diff hidden (not readable by other users)`, and no secret value in the
output or in the run logs (`~/.glidesh/runs/`). The dependency case is
clean: a `check` on a script the same run creates simply fails, so the
task shows as `would change`, no error. Limits: a 0600 staging file
hides its diff, so the typo did not show, and a `check` that compares
two files is evaluated against the current state, so the dry run did
not predict that the activation would fail.

## Comparison

| | OpenVox | CFEngine | glidesh |
|---|---|---|---|
| Slice size | 221 lines | 293 lines | 145 lines |
| No-change run (one host) | 3.4 s push, 4.0 s pull | 1.5-1.8 s (local) | 7.8 s (over Ziti) |
| Dry run diff | only with `--show_diff` | none | unified diff |
| Dependency case in dry run | fails (`Could not evaluate`) | errors logged, continues | clean |
| Built-in validation | `validate_cmd` | none (and a trap) | none |
| Partial failure | dependents skipped, rest applies | rest applies | rest of the host stops |
| Secrets | per-host key, `Sensitive`, `[redacted]` | per-host key; logged by `content =>`, backup copies | controller key reads all; redacted in logs |
| Push / pull | both (pull: prototype) | pull | push |
| Ziti fit | plain SSH | needs tproxy, IP ACLs meaningless | plain SSH, latency-bound |
| Maturity | Puppet lineage, Forge | 30 years, 3.27 LTS not on EL10 repo | 7 stars, 2.0 on 2026-10-06 |

**d) rewrite.** Production is 37 role manifests (5951 lines) and 13
templates (3519 lines); by resource type mostly `file` (169) and `exec`
(123), then `service` (19) and `package` (11). That is files plus
scripts, which maps one to one onto glidesh's `file` and `shell check=`,
and onto CFEngine's `files` and `commands`. A CFEngine port also needs a
new mental model (fixed promise order, passes, function caching); every
`exec` that validates something has to be rebuilt as one command, or it
becomes the trap above. A glidesh port is the more mechanical one, but
gives up per-host secret isolation and the pull path. Neither has an
equivalent of the Forge modules in use (`docker`, `augeas_core`).

## Recommendation

Keep OpenVox; go for option C (pull), with the laptop push as the
fallback. The spike gives no reason to rewrite:

- CFEngine's robust agent and hub-side validation (a broken policy never
  left the hub) are real, but the Ziti fit needed workarounds, three
  authoring traps exposed secrets or killed sshd, and its dry run is the
  weakest of the three.
- glidesh has the dry run we want and reads well, but it is push-only,
  slow over Ziti, and its secrets model puts every host's secrets on
  whoever runs it, which for CI means GitHub. It is also very young.
  Worth another look in 2027.
- OpenVox's dry-run gaps are cheaper to fix than to leave: pass
  `--show_diff` in `openvox-sync.sh` (the PR live noop then shows
  diffs), keep the `test -f && exec` guard for scripts created in the
  same run, and use `validate_cmd` wherever a file can be checked.

For option C, the pull agent must, from what the spike showed:

1. verify every commit from the last applied one to the new head, and
   accept a fast forward only (checking the head alone let an unsigned
   commit through);
2. record the last success as a metric and alert on it;
3. leave the push path from the laptop untouched for bootstrap, DR and
   a broken agent.
