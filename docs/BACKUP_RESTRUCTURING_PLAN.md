# Backup Restructuring and 3-2-1 Plan

Status: **partially postponed**. Measured 2026-07-31.

> **2026-07-31 update - ugreen is unrecoverable.** The btrfs filesystem could not
> be repaired; data that existed only on ugreen is being recovered with photorec,
> ETA ~17 days (~2026-08-17), writing ~2 TB onto the Unraid array.
>
> - **Phase 1 (dedupe) and Phase 2 (restructure) are postponed** until recovery
>   finishes. Both remove or relocate copies, and both consume array space that
>   photorec needs.
> - **Phase 3's additive work proceeds**: it only adds copies, touches no existing
>   data, and does not depend on ugreen. The current incident is the argument for
>   doing it sooner, not later - data that was single-copy on ugreen is now in a
>   17-day recovery.
> - **AppdataBackup exclusions + retention proceed**, because they are the only
>   lever on array pressure during the recovery window. Config-only, reversible,
>   nothing deleted by hand.

Goal: get every irreplaceable dataset to three copies on two kinds of media with
one off-site, without paying to store data that is duplicated or regenerable.

The headline finding is that the raw sizes are misleading. Roughly 570 GiB of
user data exists in two or three places on the array, and 324 GiB of what the
appdata backup captures every week is regenerable derivative data. Deduplicating
first shrinks the problem by more than the entire backup set costs.

---

## 1. Measured inventory

All figures GiB, as reported by `du -h` (1024-based). pCloud capacity 3072.

### Capacity

| Target | Total | Used | Free |
|---|---|---|---|
| pCloud | 3072 | 867 | 2205 |
| ugreen | ~12000 | - | (down: btrfs `chunk-recover` in progress) |
| Unraid array | 7.3T | 4.9T (67%) | 2.5T |

### What is already on pCloud

Reconciles exactly against the reported 867.252 used.

| Path | Size | Objects |
|---|---|---|
| `Fotos` | 587.7 | 161,568 |
| `Fotos-Videos` | 222.7 | 167 |
| `Musik` | 42.8 | 11,457 |
| `Backups` | 8.9 | 366 |
| `HASS_Backup` | 2.6 | 30 |
| `Fotos-Wichtiges-Scans-Adressen` | 1.5 | 618 |
| `homelab-backups` | 1.1 | 4,759 |

`homelab-backups` is **every container backup from every host**. Host coverage is
effectively free; storage is never the reason to skip a service.

### Growth

`Fotos/Fotos` by mtime: 2023 59.5, 2024 55.9, 2025 117.1, 2026 95.6 (7 months).
2022's 217.4 is a bulk import, not a trend. Planning figure: **~150 GiB/year**.

---

## 2. Duplication found (all verified by content, not assumed)

| Pair | Verified how | Redundant |
|---|---|---|
| `raid-backup/WD_Cloud` vs `Fotos` | filename+size; distinct inodes on different disks | 254 |
| `Sync/WD_Cloud` vs `Fotos` | 0 unique Musik files, 7 unique videos (6.9 GiB) | 247 |
| `Fotos/Music` vs `Fotos/Musik` | 132 unique files totalling 0.4 GiB | 36 |
| `Sync/7_2025WS` vs `JKU Semester 7` | extra 78,129 files are a committed Python venv | 30 |
| `Sync/8_2025WS` vs `JKU Semester 8` | one unique file: `DigiBil/Zusammengefügt.pdf` | 2.2 |
| 5 dirs in both `Sync` and `raid-backup` | identical file counts, separate inodes | 4.3 |
| `raid-backup/JKU` vs Sync semesters | 58.0 GiB unique of 175 | 117 |

Regenerable data captured by AppdataBackup every run:

| Path | Size | Why it must not be backed up |
|---|---|---|
| `appdata/immich/data/thumbs` | 235 | previews for the external library; rebuildable |
| `appdata/photon` | 89 | public geocoder dump; re-downloadable |
| `appdata/ollama` models | 4.9 | re-pullable |

Immich stores nothing of its own: `data/upload` and `data/library` are empty and
`/mnt/user/Fotos/Fotos` is mounted read-only as an external library. So 324 of
live appdata's 374 GiB is derivative.

Retention was **not** the lever for appdata size while `keepMinBackups: 5` held
five archives: the 2025 ones total 36 GiB while the four 2026 ones are
320+277+277+276. Per-archive exclusions are the primary lever, ~280 GiB -> ~50.

Decided 2026-07-31: the user wants **only the newest archive**, so retention gets
cut as well. Recommendation is `keepMinBackups: 2` rather than 1 - the three most
recent runs all failed, and a single retained archive means a corrupted or
truncated newest backup leaves nothing behind it. At ~50 GiB post-exclusion the
second copy is a rounding error. The plugin only prunes after a *successful* run
(`RETENTION WILL NOT BE CHECKED` on failure), so pruning is self-limiting.

---

## 3. Plan

### Phase 1 - deduplicate

Nothing is deleted while ugreen is down. Every step below is a **move-aside**,
reversed only after a successful backup proves the survivor.

1. Copy the 7 unique videos (6.9 GiB) from a `WD_Cloud` copy into `Fotos/Videos`;
   they inherit the existing pCloud + WD + ugreen coverage.
2. Copy `8_2025WS/DigiBil/Zusammengefügt.pdf` into `JKU Semester 8`.
3. Merge the 132 unique `Fotos/Music` files into `Fotos/Musik`.
4. Move aside: both `WD_Cloud` copies (~508), `Fotos/Music` (36),
   `Sync/7_2025WS` + `Sync/8_2025WS` (32), one of each duplicated small dir (4.3).
5. Move aside the leftovers from the June/July Nextcloud work:
   `nextcloud-db-recovery-test` (6.4), `nextcloud-db-snapshot-20260706` (0.5),
   `exif-fix` (4.9). Today's successful `REINDEX` made the first two moot.
6. **DONE 2026-08-01.** Excluded `immich/data/thumbs` from AppdataBackup and cut
   retention to 14 days / `keepMinBackups: 3`. `Photon` was already `skip: yes`
   and `ollama` is not in the plugin's container list, so `thumbs` (235 GiB) was
   the whole exclusion. Expect ~280 GiB -> ~50 GiB per archive from the Sunday
   05:00 run, and the first prune once that run succeeds.
   Note: `exclude` is stored as a `\r\n`-separated **string**, not a JSON array
   - the plugin explodes it at load and throws a fatal `TypeError` on an array.

Array reclaim: ~1.5 TB (67% -> ~47%).

### Phase 2 - restructure

7. Create an `Archive` share, not Syncthing-synced but covered by the rclone
   backup.
8. Move the non-synced archives out of `Sync`: `appdata` (96, retired containers,
   nothing newer than 2025-07-27) and the surviving old-system dirs.
9. `Sync` then contains only real Syncthing folders. 12 of its 29 top-level
   entries are currently not Syncthing folders at all.

### Phase 3 - apply 3-2-1

10. **All container services critical.** Only 6 of 34 deployed services have a
    backup config today. Add at least: `forgejo` (self-hosted Git - the mirror
    target for your own code, currently unprotected), `umami` (analytics DB),
    `grafana` (dashboards), `newsletter` (subscribers), `goaccess` (history from
    rotated Caddy logs), `crowdsec` (decisions + machine credentials).
    The stateless ones (`sudoku`, `wordwiz`, `gameoflife`, `cglab`, `regex`,
    `codec`, `ui-showcase`, `hellpot`, `endlessh`, `spidertrap`, `diun`) need
    nothing.
11. NAS paths to `tier: critical`: `backup/borg` (118), `Archive` (~100),
    surviving `raid-backup` (~80), `Fotos/Backup` (30), `backup/origami` (20).
12. appdata archives: **ugreen only**. Regenerable-ish service state, and the
    precious parts are already covered by borg and Fotos.
13. Sync folders: **deferred**. See open questions.

### Resulting pCloud position

```
already there                    867
+ borg (Nextcloud)               118
+ Archive share                 ~100
+ raid-backup (unique)            80
+ Fotos/Backup                    30
+ origami                         20
+ all container services          ~2
                               -----
                                1217  = 40% of 3072, ~1855 free, ~12 years at 150/yr
```

---

## 4. Open questions

- **`Sync/Projects` is 327 GiB**, 70% of the Sync total. If it carries
  `node_modules`, venvs or datasets - as `7_2025WS` and `raid-backup/JKU` both
  did - a `.stignore` would cut it substantially and change the Sync tier
  decision. Not yet inspected.
- The six archive semesters (`1_2021WS`..`6_2024SS`, ~88 GiB) have **no
  `.stignore` at all**, so their build output syncs to every peer.
- `raid-backup/JKU`'s 58 GiB "unique" remainder still shows SvelteKit
  docs/`node_modules` patterns; a finer pass would shrink it further.
- Whether `mailcow`'s 1.9 MB `vmail` volume is legitimately small because mail
  forwards off-host. Assumed yes; worth confirming, because "mailcow backed up
  successfully" would otherwise be false comfort.

## 5. Cleanup noted along the way

- Orphaned Docker volumes on mljr, 626 MB, from services since moved to nuc:
  `keycloak_keycloak-db-data` (67M), `nightscout_mongo-data` (535M),
  `kuma_uptime-kuma-data` (24M).
- `Fotos/Manuell` is empty; `Sync` holds stray `apps.txt`, `test.txt` and a
  `{102ed8c5-...}` directory.
