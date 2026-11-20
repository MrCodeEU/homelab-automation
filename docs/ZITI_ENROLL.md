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

The deploy agent on mljr would apply the ssh change with the next mljr
deploy too; running it here makes it immediate for the check below.

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

## Phone (Android, Ziti Mobile Edge)

The phone is identity `phone-mrcode` (`ziti/tofu/phone.tf`, attribute
`mobile`). It dials every `#admin-services` service. There is no second
factor: the Android app cannot enrol TOTP (an MFA posture check locked it
out of everything). The phone's screen lock and the non-exportable key are
the protection.

1. Install **Ziti Mobile Edge** (Play Store). Android runs one VPN app at a
   time: Tailscale has to be off while Ziti is on.
2. In your own terminal (the QR code is a credential, not for an agent or
   CI): `scripts/ziti-enroll-phone.sh phone-mrcode`. In the app, tap `+`,
   then scan the QR code. Press Enter in the terminal once the app shows
   the identity.
3. Check: with Tailscale off and on mobile data, open `http://kuma.ziti`
   (type the `http://`, or the browser may search for it).

Short names: every catalog service on Ziti is also `http://<name>.ziti`
on port 80 (`ziti/tofu/catalog.tf`), forwarded to its real port on
whichever host runs it; `ssh root@<host>.ziti` reaches mljr, nuc and
ugreen (`ziti/tofu/services.tf`, ssh_short). Ziti Mobile Edge answers
these names itself; they do not exist in public DNS and only work while
Ziti is on. Plain HTTP is fine for the transport (Ziti encrypts and
authenticates end to end), but apps that need a secure context (cookies
marked `Secure`, passkeys) may refuse to log in over it. The
`<name>.<host>.int.mljr.eu:<port>` names stay for machines; a browser
cannot open those: `mljr.eu` sends HSTS with `includeSubDomains`, so it
forces HTTPS on them.

### SSH from the phone (Termux + opkssh)

No SSH key lives on the phone: `opkssh login` signs in at Authelia (two
factors) and writes a key that is valid for 24 h, as on the laptop
(`scripts/opkssh-laptop.sh`, docs/ZERO_TRUST_PLAN.md C14). Termux traffic
goes through Ziti Mobile Edge's VPN, so plain `ssh` reaches the `ssh`
service. Tested 2026-11-20 against nuc.

1. In Termux: `pkg install openssh opkssh`. The Termux package builds
   the same opkssh version as `roles::opkssh` (0.19.2 at the time of
   writing).
2. Client config, the same as the laptop's:

   ```
   mkdir -p ~/.opk && chmod 700 ~/.opk
   cat > ~/.opk/config.yml <<'YAML'
   ---
   default_provider: authelia
   providers:
     - alias: authelia
       issuer: https://auth.mljr.eu
       client_id: opkssh
       scopes: openid email profile
       redirect_uris:
         - http://localhost:3000/login-callback
         - http://localhost:10001/login-callback
         - http://localhost:11110/login-callback
   YAML
   chmod 600 ~/.opk/config.yml
   ```

3. Once a day: `opkssh login`. It opens the browser at Authelia (if it
   does not, open the URL it prints); the redirect lands on Termux's
   `localhost` listener. The key goes to `~/.ssh/id_ecdsa` with its
   certificate.
4. `ssh root@nuc.ziti` (or the full `root@nuc.int.mljr.eu`).

`roles::opkssh` runs on nuc, mljr and ugreen: `ssh root@nuc.ziti`,
`ssh root@mljr.ziti`, `ssh root@ugreen.ziti` (or `mrcode@ugreen.ziti`).
UGOS keeps root SSH off and root from 127.0.0.1 is the facts endpoint's
ForceCommand, so `ugreen.ziti` arrives from 127.0.0.2, where an sshd
drop-in allows root with a key (`roles::opkssh::root_match_address`).

New phone: `scripts/ziti-enroll-phone.sh phone-mrcode --reenroll`. This
drops the old certificate, so the old phone loses access at the same time.
Lost phone: remove `ziti_identity.phone` from `phone.tf` and apply.
