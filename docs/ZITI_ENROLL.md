# OpenZiti: enrol a new Linux host

Runbook for putting a Docker-capable Linux host on the overlay
(docs/ZERO_TRUST_PLAN.md C1). Design rule from C6: every host that can run
Ziti hosts its own services, with its own router in host-mode tunnel; the
router also takes LAN clients on its edge listener. Example values are for
ugreen, the host this was first run on.

| Placeholder | Meaning | ugreen |
|---|---|---|
| `<h>` | short host name, as in `openvox/data/nodes/<h>.int.mljr.eu.yaml` | `ugreen` |
| `<ip>` | LAN address | `192.168.50.86` |
| `<base>` | `roles::services::base_path` of the host | `/volume1/homelab` |

Prerequisites: the host is managed by OpenVox (`roles::services`) and
reachable over SSH as root from the laptop; mljr's controller is up.

## 1. Router service (repo)

```sh
h=ugreen ip=192.168.50.86
mkdir -p services/ziti-router-$h/hooks
for f in docker-compose.yml config.yml hooks/post-deploy.sh; do
  sed -e "s/ziti-router-nuc/ziti-router-$h/g" -e "s/ZITI_ROUTER_NAME=nuc/ZITI_ROUTER_NAME=$h/" \
      -e "s#/ziti-router/nuc\.#/ziti-router/$h.#g" -e "s/192\.168\.50\.30/$ip/g" \
      -e "s/data\/nuc\.cert/data\/$h.cert/" -e "s/router nuc/router $h/g" \
      -e "s/ziti-enroll-router.sh nuc/ziti-enroll-router.sh $h/" -e "s/on nuc/on $h/g" \
      -e "s/hosts nuc's/hosts $h's/" -e "s/edge router \"nuc\"/edge router \"$h\"/" \
      services/ziti-router-nuc/$f > services/ziti-router-$h/$f
done
chmod +x services/ziti-router-$h/hooks/post-deploy.sh
git add services/ziti-router-$h && git update-index --chmod=+x services/ziti-router-$h/hooks/post-deploy.sh
```

Read the three files through once: comments that describe nuc
specifically (firewalld zone, "outbound to mljr") may need a word changed.

## 2. Wiring (repo)

- `openvox/data/common.yaml`, `services:` catalog: an entry like
  `ziti-router-nuc` with `name: ziti-router-<h>`, `host: <h>`.
- `openvox/modules/roles/manifests/services.pp`:
  `ziti-router-<h>` in `post_deploy_hook_services`.
- `scripts/ziti-enroll-router.sh`: a `case` line for `<h>` (host, service,
  attribute `lan`, base path).
- `ziti/tofu/routers.tf`: `<h>.int.mljr.eu` in the router list;
  `ziti/tofu/services.tf`: `<h>` in `ssh_hosts` (intercept and bind).
- `tools/internal/healthreport/collectors/pki.go`: a `pkiTargets` entry
  `<ip>:8442` / `router-<h>` (rebuild the binary:
  `scripts/service-binary.sh`).

Then `mkdir openvox/modules/roles/files/services/ziti-router-<h>` (the
sync only fills existing destinations), `scripts/sync-openvox-service-files.sh sync`, `PATH=/usr/bin:$PATH
make test`, PR, merge, `gh workflow run deploy.yml -f limit=<h>`. The
router container restart-loops until it is enrolled; that is expected.

Host firewall: the router dials the host's own services on `127.0.0.1`.
If the host filters loopback (UGOS does for port 22, see
`roles::ugreen_ssh_loopback`), allow it before the check in step 4.

## 3. Enrol

```sh
scripts/ziti-enroll-router.sh <h>    # token from mljr straight into the container's data dir
scripts/ziti-tofu.sh apply          # ssh service now also on <h>
```

## 4. Check

```sh
ssh <h>.int.mljr.eu true             # from the laptop, with the tunneler up: over Ziti
```

The first connection asks for the host key: compare it with the one
already known for the host (`ssh-keygen -F <h>.tail33930.ts.net -l`)
before accepting.

`ziti edge list edge-routers` shows `<h>.int.mljr.eu` online, `ziti
fabric list links` a connected link `<h> -> mljr`.

## 5. Alerts (repo, after enrolment)

The router id exists only now (`ziti edge list edge-routers`). Add it to
`services/grafana/provisioning/alerting/ziti.yml`: a branch in
`ziti-router-offline` and one in `ziti-link-down` for `<h> -> mljr`,
then sync, PR and deploy nuc.
