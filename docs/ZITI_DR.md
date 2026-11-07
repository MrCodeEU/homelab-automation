# OpenZiti controller: backup and restore

Runbook for losing the controller on mljr (docs/ZERO_TRUST_PLAN.md C2,
"DR bootstrap order"). Tested 2026-11-07, results in the plan under C2.
PKI background: [ZITI_PKI.md](ZITI_PKI.md).

## What a backup is

A **cold copy** of `/opt/ziti-controller/data/pki` and
`/opt/ziti-controller/data/raft`, taken with the controller stopped. The
stop takes under a second (452 ms measured); routers and clients keep
their circuits and reconnect on their own.

```sh
cd /opt/ziti-controller
docker stop ziti-controller
(umask 077; tar -czf /root/ziti-controller-$(date +%F).tgz -C data --exclude='events*.log' pki raft)
docker start ziti-controller
```

The bundle holds the intermediate CA's private key
(`pki/intermediate/keys/intermediate.key`): anyone with it can sign
routers and identities for the overlay. Store it only where the eyaml
keys may go, never on an unencrypted cloud remote.

The nightly backup on mljr (`roles::backup`, service `ziti-controller`,
`sensitive_paths`) does exactly this in its pre-hook and then keeps two
copies:

| Copy | Where | For |
|---|---|---|
| plain | `ugreen:mljr/sensitive/ziti-controller/ziti-controller.tgz` | the normal restore |
| age-encrypted | pCloud `homelab-backups/sensitive/ziti-controller.tar.age`, plus daily/weekly/monthly history under `homelab-backups-history/mljr/<timestamp>/ziti-controller/` | when ugreen is lost too |

The age private key is only in Bitwarden (`homelab ziti backup age key`);
the public key is `roles::backup::sensitive_age_recipient`. wd-cloud gets
no copy.

Do not use `ziti fabric db snapshot` with `ziti agent cluster
restore-from-db`. A controller restored that way works until its leaf
certificate is re-issued, which the container does on every start
(`ZITI_AUTO_RENEW_CERTS`, image default). From then on it rejects its own
OIDC access tokens: SDK and CLI logins fail with `UNAUTHORIZED`, only the
legacy `zt-session` login still works. Seen on nuc and on mljr.

## Getting the bundle

From ugreen (normal case), on mljr:

```sh
rclone copyto --sftp-key-file /opt/backup-remote/ssh/id_ed25519 \
  ugreen:mljr/sensitive/ziti-controller/ziti-controller.tgz /root/ziti-controller-restore.tgz
```

From pCloud (ugreen lost): on the laptop, with the age key from Bitwarden
in a file that is deleted afterwards:

```sh
rclone copyto pcloud:homelab-backups/sensitive/ziti-controller.tar.age ./zc.tar.age
age -d -i ziti-backup.age.key zc.tar.age | tar -xf -   # gives ziti-controller/ziti-controller.tgz
```

Copy `ziti-controller.tgz` to mljr as root, mode 0600, and delete every
local copy afterwards.

## Restore onto a rebuilt mljr

1. Converge mljr with OpenVox as usual. That creates
   `/opt/ziti-controller` with `config.yml`, `docker-compose.yml` and
   `.env`; the controller restart-loops without `data/pki`, which is
   expected.
2. Restore the bundle into an empty data directory and start:

   ```sh
   cd /opt/ziti-controller
   docker compose down
   rm -rf data && install -d -m 700 -o 2171 -g 2171 data
   tar -xzf /root/ziti-controller-restore.tgz -C data && chown -R 2171:2171 data
   docker compose up -d
   ```

3. Check: `ziti edge list edge-routers` shows both routers online,
   `ziti fabric list links` one connected link, and a client connects
   (`curl http://alloy.nuc.int.mljr.eu:12345/metrics` from the laptop).
   Nothing is re-enrolled: identities, routers and policies are in the
   raft data, `ctrl.ziti.mljr.eu` still points at mljr.

Measured: restore 15 s, routers back 9 s later.

## Degraded mode: controller on nuc

Only while mljr cannot be rebuilt. LAN only: nuc is behind the
FRITZ!Box, and outside clients would need a temporary port forward of
8441.

1. Copy the newest bundle to nuc (root, 0600) and start the controller
   from `services/ziti-controller/` (same `docker-compose.yml`,
   `config.yml`, an `.env` with `TZ`) with the bundle restored into
   `data/` as above.
2. Point `ctrl.ziti.mljr.eu` at nuc for the LAN clients. With public DNS
   (TTL 3600) that takes up to an hour; a local override is faster. Docker
   containers in host networking get their own copy of `/etc/hosts` when
   they are created, so an entry in nuc's `/etc/hosts` does not reach the
   running router: add it to the file `docker inspect -f
   '{{.HostsPath}}' <container>` names as well (append, do not replace
   the file). The router and the tunnelers use Go's resolver, which reads
   `/etc/hosts` before DNS.
3. Measured: nuc's router online 8 s after the flip, an existing client
   identity logged in fresh and connected after 13 s.
4. Back: remove the overrides, stop the nuc controller (the router only
   moves back when its control channel drops), start the mljr controller.
   Anything changed on the nuc controller in between is lost.
