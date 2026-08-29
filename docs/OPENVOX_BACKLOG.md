# OpenVox Backlog

Working backlog from the 2026-08-29 review of `openvox/` (post-migration
from `ansible/`). Three buckets: **P1** correctness/risk items, **P2**
1:1-migration debt (ansible patterns that should become idiomatic Puppet),
**P3** net-new capability. Check items off as they land; leave a one-line
note (commit/PR ref) instead of deleting, same convention as the
DISASTER_RECOVERY.md backlog section.

## P1 — correctness / risk

- [x] **Rewrite `docs/DISASTER_RECOVERY.md` for OpenVox.** DONE
      2026-08-29 — bootstrap steps now cover OpenVox install + eyaml key
      deployment instead of `ansible-vault`/`ANSIBLE_VAULT_PASSWORD`;
      mljr deploy command updated; credentials-checklist wording fixed;
      flagged the eyaml private key as the new single point of failure
      and added a follow-up item in the doc's own backlog section to
      verify it has a real outside-Git backup.
- [x] **Add rollback for `openvox-sync.sh`.** DONE 2026-08-29 — real
      applies now sync into `releases/<timestamp>/` and atomically
      symlink-swap `production` onto it (keeps last `OPENVOX_RELEASE_KEEP`,
      default 5); `scripts/openvox-rollback.sh` /
      `make openvox-rollback HOST=<host> [STEPS=n]` swaps back and
      re-applies. Forge modules moved to a persistent shared
      `environments/vendor-modules` dir so a release swap doesn't need a
      full Forge reinstall or duplicate modules per release. See
      `openvox/README.md` "Releases and rollback".
- [ ] **Confirm the 3 unported ansible roles are intentionally
      ansible-only**, not forgotten: `syncthing-nas-key`,
      `unraid-bootstrap`, `wd-mycloud-tailscale`. If confirmed
      bootstrap-only, note that explicitly in `openvox/README.md` so it
      doesn't look like migration debt to future-you.
- [ ] **Live-noop CI gap for fork/external PRs.** `openvox-pr-check.yml`
      only runs the live-noop leg for owner PRs from the same repo — fork
      PRs get offline validation only. Decide if that's acceptable
      long-term or needs a manual-approval gate to unlock live-noop.

## P2 — migration debt (ansible-shaped Puppet → idiomatic Puppet)

- [x] **Introduce roles/profiles layering.** DONE 2026-08-29 — new
      `role` module (`role::mljr`/`role::nuc`/`role::ugreen`, one per
      node archetype), `site.pp` node blocks now one-liners. No separate
      `profile::*` module: `roles::*` already fills that role (hand-rolled,
      technology-specific) — a 1:1 wrapper would be pure indirection at
      3-host scale. See `openvox/README.md` "Roles and profiles".
- [x] **Move per-host variance from `site.pp` params into hiera.** DONE
      2026-08-29, same change — added the `nodes/%{trusted.certname}.yaml`
      hiera layer, every `class { 'roles::x': param => val }` in `site.pp`
      became `include roles::x` with data in
      `data/nodes/<certname>.yaml`, bound via Puppet's automatic
      class-parameter hiera lookup. `roles::base`'s
      docker_prune_enabled/reboot_if_needed now self-compute from the
      `openvox_weekly_maintenance` fact instead of being passed in.
      Verified byte-identical catalogs via noop on all 3 hosts before a
      real `make openvox-deploy-<host>` on each (0 errors, matching
      pre-refactor resource-change counts).
- [ ] **Audit the 34 `roles::*` classes for ansible-task-list smell**
      (ordered `exec`/`file` chains instead of declarative resources,
      missing `unless`/`onlyif` idempotency guards, no use of Puppet
      relationship metaparameters). Go class-by-class; fix worst
      offenders first (firewalld already fixed — use as the model).
- [ ] **rspec-puppet for classes with real logic.** Start with
      `roles::firewalld` and `roles::backup` (highest blast radius) —
      catch bugs before they reach the live-noop stage, let alone apply.

## P3 — net-new capability

- [ ] **Fleet-state reporting into existing monitoring.** Push
      last-apply status/timestamp per host into VictoriaMetrics/Grafana
      (already deployed) instead of relying on `deploy-logs/` grep.
      Doesn't need full PuppetDB — a small JSON-per-host + exporter is
      enough at 3 hosts.
- [ ] **Daily drift-detection noop + ntfy alert.** Weekly cron + manual
      dispatch means drift can go up to a week unseen. Add a daily
      noop-only run that diffs resource-count and pings ntfy (already in
      use elsewhere) above a threshold.
- [x] **Atomic environment swap** — DONE 2026-08-29, same change as the
      P1 rollback item above; the enabling piece for safe
      drift-remediation applies too.
- [ ] **Profile layer** — tracked above under P2 as the correctness fix;
      re-confirm it also unlocks clean multi-host scaling before adding
      a 4th/5th agent host.
- [ ] **rspec-puppet coverage expansion** — once the P2 seed (firewalld,
      backup) is in place, extend to remaining `roles::*` classes with
      non-trivial logic.

## Notes

- `nas` (Unraid) and `wd_mycloud` (busybox) are proxy-managed via `exec`
  over SSH from `nuc`'s node block, not real Puppet agents — no drift
  protection from OpenVox itself on those two hosts. Out of scope for
  P1-P3 above (vendor-appliance constraint), but worth remembering when
  reasoning about "is the fleet actually converged."
- CI/secrets design (hiera-eyaml, Puppetfile pinning, puppet-lint,
  live-noop) reviewed as solid — no backlog items needed there.
