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
- [ ] **Port the 3 remaining ansible-only roles to OpenVox — CORRECTED
      2026-08-29.** Previously marked here as "confirm these are
      intentionally bootstrap-only" — wrong call, reversed after reading
      the actual role code. All three do real ongoing reconciliation, not
      one-time setup, and leaving them ansible-only means a from-scratch
      DR still needs a working Ansible toolchain, defeating the point of
      migrating at all. `ansible/` is slated for eventual removal, so
      these are real migration debt, not accepted scope:
      - `syncthing-nas-key`: reads the NAS's live Syncthing API key
        (`/mnt/user/appdata/syncthing/config.xml`) via SSH-proxy (nas has
        no agent), for `roles::services_nas`/`ugreen_tailscale`-style
        cross-play to consume — same shape as the existing
        `unraid_host_facts_proxy` pattern, port as another nuc-side proxy
        class.
      - `unraid-bootstrap`: installs/maintains a User Scripts boot-hook
        entry + merges `schedule.json` idempotently on nas every apply
        (array-started guard, retired-script cleanup) — reconciled state,
        not bootstrap. Port as `roles::unraid_bootstrap_proxy` alongside
        the other nas proxy classes on nuc's node block.
      - `wd-mycloud-tailscale`: checks installed vs latest Tailscale
        version every run, updates the binary + watchdog script + cron +
        clamAV boot hook on wd_mycloud (busybox, no agent) — this is
        exactly what `roles::wd_mycloud_proxy`/`wd_mycloud_node_exporter_proxy`
        already do for that host's other pieces, just missing this one.
        Port as `roles::wd_mycloud_tailscale_proxy`.
- [ ] **Remove active ansible references outside `ansible/`.** Full
      classification audit run 2026-08-29 (414 matches across ~110
      files) — most are fine (provenance comments like "ported from
      ansible/roles/x", kept deliberately). These are NOT fine — each
      documents or runs Ansible as if it were still the live tool, and
      `ansible/` is slated for eventual removal:
      - `Makefile`: `make test` silently runs an Ansible syntax check
        against `ansible/playbooks/site.yml` if `ansible-playbook`
        happens to be installed; `make test-e2e` is a fully separate
        Ansible-only Docker/SSH harness (`tests/`) with zero OpenVox
        equivalent — needs a decision: port it to drive
        `puppet apply`/`openvox-sync.sh` instead, or retire it and accept
        the coverage gap; top-of-file usage comment lists legacy
        `deploy*`/`ANSIBLE_*` targets undifferentiated from the real
        `openvox-*` ones.
      - `scripts/deploy-local.sh`: full runnable `ansible-playbook`
        wrapper in top-level `scripts/`, undeprecated, redundant with
        `openvox-sync.sh`. Delete or move under `ansible/`.
      - `.github/workflows/README.md`: opens by calling Ansible legacy,
        then documents it as the live workflow in full detail (ARA, vault
        secrets, commands) for the rest of the doc. Rewrite around
        OpenVox as primary.
      - `docs/DEPLOYMENT_OPTIMIZATION.md`: entirely Ansible-specific
        tuning (Mitogen, fact caching, callback plugins) that doesn't
        apply to OpenVox's masterless model at all. Delete or explicitly
        retitle as historical-only.
      - `docs/ANSIBLE_TOOLING.md`: entirely about ARA, a dead tool. Delete.
      - `docs/DISASTER_RECOVERY.md`: the eyaml/bootstrap section was
        fixed 2026-08-29, but nas/ugreen/Home-Assistant sections still
        say "Ansible-managed subset only" / "untouched by Ansible" —
        **factually wrong now**, those hosts are reached via OpenVox's
        own `roles::unraid_proxy`/`unraid_backup_proxy`/etc exec-proxy
        classes already (verified live 2026-08-29). Needs another pass.
      - `.github/workflows/iac-security.yml`: triggers on `ansible/**`
        changes that Checkov then skips anyway per `.checkov.yml` —
        wasted runs, drop `ansible/**` from the trigger paths.
      - `.checkov.yml`: dead skip-path entry for `docs/ansible-map.md`
        (already deleted elsewhere) — remove the stale line.
      - `tools/cmd/build-deploy-status` + `.github/workflows/deploy.yml`:
        CLI flag/JSON key literally named `--ansible-log`/`ansible-log`,
        fed an OpenVox log path already — naming-only, rename to
        `--deploy-log` in both places together.
      - `openvox/modules/roles/manifests/services.pp` +
        `tools/cmd/provision-kuma/main.go`: real coupling, not just a
        comment — emitted keys named `inventory_hostname`/`ansible_host`,
        consumed by matching Go struct tags. Internal-only format
        (regenerated every apply, no external consumers) — safe to
        rename to something OpenVox-neutral (e.g. `node_name`/
        `node_host`), but both sides must change atomically.
      - `.githooks/pre-commit`: actively checks
        `ansible/inventory/group_vars/all/vault.yml`'s `$ANSIBLE_VAULT`
        encryption header on every commit. Harmless while `ansible/`
        stays read-only reference; drop this check when `ansible/` is
        actually removed.
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
- [x] **Audit the 34 `roles::*` classes for ansible-task-list smell.**
      DONE 2026-08-29 — full pass, every exec-bearing class checked for
      guards/relationship metaparameters against the `roles::firewalld`
      reference model. Result: this migration is in much better shape
      than the premise assumed. One real bug found:
      `roles::authelia`'s users-database exec has no guard and always
      `notify`s a restart, so Authelia restarts on every single apply
      (inherited from Ansible, documented in the class's own comment as a
      known-but-unfixed limitation) — fix pending discussion (see below).
      One minor inefficiency: `roles::services`/`services_nas` dockerhub/
      ghcr login execs run unconditionally but idempotently, no cascading
      effect, low priority. Everything else — `base`, `caddy`, `mailcow`,
      `tutabridge_cli`, `backup`, `grafana_alloy`, and the rest — already
      follows the check/apply guard convention correctly, no action
      needed.
- [ ] **Fix `roles::authelia`'s restart-on-every-apply.** Found during
      the audit above. Not a migration-introduced bug — ported faithfully
      from identical Ansible behavior (random argon2 salt every run means
      the rendered users_database.yml always looks "changed"). Needs a
      decision on the actual fix (e.g. guard with `creates` so the file
      generates once — trade-off: rotating `vault_authelia_admin_password`
      then needs a manual file delete to take effect) before landing it.
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
