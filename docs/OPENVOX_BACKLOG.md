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
- [x] **Port the 3 remaining ansible-only roles to OpenVox — RESOLVED
      2026-08-29, false alarm on the second look too.** Two separate
      grep-based checks (this session's original review, then a
      "corrected" backlog entry) both concluded these needed porting by
      matching literal ansible role names against openvox class names —
      both wrong. Reading the actual manifest bodies found all three
      already covered, ported earlier via an intermediate `migration/spot`
      branch under different class names, predating this session's
      openvox cutover:
      - `wd-mycloud-tailscale` → `roles::wd_mycloud_proxy`
        (`wd_mycloud_proxy.pp`), already live in `role::nuc`. Class
        comment: "Logic-port of spot/playbooks/wd-mycloud-tailscale.yml
        (migration/spot, already validated live in production)".
      - `unraid-bootstrap` → `roles::unraid_proxy` (`unraid_proxy.pp`),
        already live in `role::nuc`. Same spot-port lineage, same
        array-precondition/bootstrap-script/schedule-merge logic.
      - `syncthing-nas-key` → not a proxy class, but functionally
        covered: the NAS's Syncthing API key is a static vault secret
        (`vault_syncthing_nas_api_key`, real encrypted value present in
        `data/common.eyaml`) consumed directly in `roles::services`'
        `syncthing-ugreen` catalog entry. Architecturally different from
        Ansible's live SSH-read (the key is stable, doesn't rotate, so a
        one-time captured secret is equivalent with less machinery).
      Nothing to port. Lesson for future audits in this repo: grep for
      behavior/content, not just class-name string matches — this repo
      has more than one migration lineage (`migration/spot` predates the
      main `openvox` cutover) and names don't line up 1:1.
- [x] **Remove active ansible references outside `ansible/`.** DONE
      2026-08-29. Full classification audit run same day (414 matches
      across ~110 files) — most were fine (provenance comments like
      "ported from ansible/roles/x", kept deliberately). All findings
      below fixed: `Makefile` rewritten (syntax check retargeted to
      `puppet parser validate`, `test-e2e`/`view-ara`/`deploy*` targets
      removed, header/help text rewritten OpenVox-first);
      `scripts/deploy-local.sh` deleted; `.github/workflows/README.md`
      fully rewritten around OpenVox as the only live deploy path;
      `docs/DEPLOYMENT_OPTIMIZATION.md` and `docs/ANSIBLE_TOOLING.md`
      deleted; `docs/DISASTER_RECOVERY.md` nas/ugreen/Home-Assistant/nuc
      sections fixed to name the real `roles::*` proxy classes;
      `.github/workflows/iac-security.yml` dropped `ansible/**` from
      trigger paths; `.checkov.yml` dead `docs/ansible-map.md` skip-path
      removed; `tools/cmd/build-deploy-status` +
      `.github/workflows/deploy.yml` flags renamed `--ansible-log` →
      `--deploy-log`, `--ara-artifact` → `--log-artifact`;
      `openvox/modules/roles/manifests/services.pp` +
      `tools/cmd/provision-kuma/main.go` renamed
      `inventory_hostname`/`ansible_host` → `node_name`/`node_host`;
      `tools/internal/deploystatus/page.go` `ARA` label → `Log`;
      `.githooks/pre-commit` swapped its `$ANSIBLE_VAULT` header check
      for an `ENC[PKCS7` check on `openvox/data/common.eyaml`, and
      `ansible/inventory/group_vars/all/vault.yml` was deleted
      (git-history-recoverable; `.example` kept — still documents key
      names for `docs/DISASTER_RECOVERY.md`); `tests/` e2e harness
      deleted rather than ported (see new P2 item below) since it only
      exercised Ansible's own now-removed deploy path. Historical
      "ported from ansible/roles/x"-style comments were deliberately
      left alone per the user's own "except for historical how-did-we-
      get-here stuff" carve-out. Original bucket-C findings, for
      reference:
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
- [x] **Live-noop CI boundary for fork/external PRs.** CLOSED 2026-08-29 —
      intentional security design: forks receive offline validation only and
      never receive Tailscale credentials or production-check access. The
      sole maintainer reviews any external contribution before merge, so the
      absence of a live noop is an accepted validation-coverage trade-off,
      not an infrastructure attack path.

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
- [x] **Fix `roles::authelia`'s restart-on-every-apply.** DONE
      2026-08-29 — guarded the users-database exec with
      `creates => "${config_path}/users_database.yml"`. Verified live on
      mljr: noop change-line count dropped by exactly one, and the real
      apply afterward left `authelia`'s container uptime untouched (no
      restart). Trade-off accepted: rotating
      `vault_authelia_admin_password` now needs a manual
      `rm users_database.yml` to take effect, documented in the class's
      own comment.
- [x] **rspec-puppet P2 seed for classes with real logic.** DONE
      2026-08-30 — `roles::firewalld` and `roles::backup` compile in
      VoxBox without host access. Backup coverage exercises selected-service
      rendering, timer schedules, CPU limits, recovery guards, logical-DB
      volume skips, and no-diff handling for rclone credentials. The next
      P3 item expands this to other non-trivial roles.
- [x] **Port the useful part of the `tests/` e2e harness to OpenVox.** DONE
      2026-08-29 — the deleted Ansible Docker/SSH harness only rendered its
      retired templates and checked for empty snippets. Its OpenVox-native
      replacement compiles a varied Caddy fixture catalog in pinned VoxBox,
      exports the real EPP-generated files to a temporary directory, and
      validates the assembled result using pinned Caddy 2.11.2. It covers
      local/remote upstreams, Authelia, HTTPS backends, custom blocks,
      staging routes, and disabled services without SSH, Tailscale, secrets,
      or host mutation. `make test-openvox-caddy-render` and the unprivileged
      `OpenVox Caddy render test` CI job run it before live noop.
- [x] **Fix `ParseFailedServices` for OpenVox log shape.** DONE 2026-08-29 —
      parses host-prefixed `Error:` resource paths from `puppet apply`, maps
      `Roles::Services::Service[name]` (and service exec fallback) to the
      catalog entry, preserves legacy Ansible-log readability, and avoids
      falsely attributing host/catalog failures to an arbitrary service.

## P3 — net-new capability

- [x] **Fleet-state reporting into existing monitoring.** DONE 2026-08-29 —
      the deployment workflow emits per-host production/noop success,
      timestamp, duration, changed-resource, and error-line gauges directly
      to existing VictoriaMetrics. The Homelab Overview dashboard shows the
      latest production apply state; no PuppetDB, extra host daemon, or
      stored CI credential was added.
- [x] **Daily drift-detection noop + ntfy alert.** DONE 2026-08-30 —
      `openvox-drift.yml` runs an isolated, read-only noop daily, publishes
      `mode="drift"` metrics, and alerts ntfy only when drift/failure state
      changes or recovers; Grafana shows the latest result and proposed count.
- [x] **Atomic environment swap** — DONE 2026-08-29, same change as the
      P1 rollback item above; the enabling piece for safe
      drift-remediation applies too.
- [x] **Profile layer** — DONE 2026-08-29 under P2. The existing
      technology-specific `roles::*` classes deliberately serve as profiles;
      `role::*` supplies node-archetype composition.
- [ ] **rspec-puppet coverage expansion** — `roles::services`,
      `roles::backup_remote_target`, `roles::caddy`, and
      `roles::crowdsec_firewall_bouncer`, `roles::authelia`, and
      `roles::mailcow`, appliance proxy roles, `roles::healthreport`, and
      `roles::host_facts_endpoint`, and `roles::grafana_alloy` DONE
      2026-08-30/31, plus `roles::backup_dashboard`: catalog fixtures cover
      service deployment filtering, critical hooks, safe orphan cleanup,
      appliance cleanup opt-out, staging selection/rejection, secret `.env`
      no-diff handling, Ugreen SFTP account/chroot/key/snapshot containment,
      Caddy firewall/stage-validate-promote ordering, CrowdSec bouncer
      credential protection/local-LAPI/nftables/service ordering, Authelia
      secret protection/deny-by-default/restart guard, and Mailcow
      localhost binding/certificate-key/timer/startup-chain safeguards, plus
      Unraid/WD check-apply guard, precondition, ordering, and timeout
      contracts, plus Health Report state/private-key preservation and its
      forced-command facts endpoint containment, plus Grafana Alloy secret
      redaction, remote-write, host-specific scrape, and socket-remount
      contracts, plus Backup Dashboard state/catalog/destination/schedule
      contracts. Next target: remaining base and monitoring support roles.

## Notes

- `nas` (Unraid) and `wd_mycloud` (busybox) are proxy-managed via `exec`
  over SSH from `nuc`'s node block, not real Puppet agents — no drift
  protection from OpenVox itself on those two hosts. Out of scope for
  P1-P3 above (vendor-appliance constraint), but worth remembering when
  reasoning about "is the fleet actually converged."
- CI/secrets design (hiera-eyaml, Puppetfile pinning, puppet-lint,
  live-noop) reviewed as solid — no backlog items needed there.
