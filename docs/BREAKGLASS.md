# Break-glass SSH access

How to get a root shell on any host when Tailscale, the laptop, or both are
gone. Part of Phase 1 in [ZERO_TRUST_PLAN.md](ZERO_TRUST_PLAN.md). Daily
access stays on Tailscale SSH; nothing here is needed while that works.

## Keys

The keys are listed in `breakglass_pubkeys` in `openvox/data/common.yaml`.

| Key | Where the private half lives | What a login needs |
|---|---|---|
| `homelab-breakglass-yk1` | FIDO2 resident key on YubiKey 1 (5C NFC, serial 34717587), carried on person (off site) | the YubiKey, its FIDO2 PIN, a touch |
| `homelab-breakglass-yk2` | FIDO2 resident key on YubiKey 2 (5C NFC, serial 26724345), kept at home | the YubiKey, its FIDO2 PIN, a touch |
| `homelab-recovery` | software key, private half and passphrase in Bitwarden | Bitwarden access |

The YubiKey keys were created with (YubiKey 2: `yk2` and
`application=ssh:homelab-breakglass-yk2` instead):

```
ssh-keygen -t ed25519-sk -O resident -O verify-required \
  -O application=ssh:homelab-breakglass \
  -C "homelab-breakglass-yk1" -f ~/.ssh/id_ed25519_sk_homelab_yk1
```

- `resident`: the key handle is stored on the YubiKey, so any machine can
  recover it (see [From a different machine](#from-a-different-machine)).
- `verify-required`: every login needs the PIN as well as a touch, so a
  stolen YubiKey alone is useless.

Use YubiKey 1 first, YubiKey 2 if YubiKey 1 is lost or broken, and the
Bitwarden key only if both are unavailable. The two keys live apart:
YubiKey 1 stays on person (so it is the off-site copy), YubiKey 2 stays
at home. Every command below works with YubiKey 2 by swapping `yk1` for
`yk2` in the key file name.

## Where each host accepts the keys

| Host | Address without Tailscale | User | How the keys get there |
|---|---|---|---|
| mljr | `157.173.97.107` port **2299** (public) | `root` | OpenVox, `roles::ssh_hardening` |
| nuc | `192.168.50.30` port 22 (home LAN) | `root` | OpenVox, `roles::ssh_hardening` |
| ugreen | `192.168.50.86` port 22 (home LAN) | `mrcode` (root login is off) | OpenVox, `roles::ssh_hardening` |
| nas | `192.168.50.80` port 22 (home LAN) | `root` | by hand, in `/root/.ssh/authorized_keys` (on the flash drive) |
| wd_mycloud | `192.168.50.176` port 22 (home LAN) | `root` (or `sshd`, same uid-0 account) | OpenVox proxy on nuc (`roles::wd_mycloud_proxy`), keys and sshd hardening restored at boot from the clamAV hook |
| homeassistant | `192.168.50.31` port 22 (home LAN) | `hassio` | by hand, Advanced SSH & Web Terminal add-on config |

The home LAN addresses only work on site. From outside, the home hosts
are reachable only through Tailscale; mljr also through its Contabo panel
(console), which needs no key at all.

## From this laptop

```
ssh -i ~/.ssh/id_ed25519_sk_homelab_yk1 -o IdentitiesOnly=yes -p 2299 root@157.173.97.107  # mljr
ssh -i ~/.ssh/id_ed25519_sk_homelab_yk1 -o IdentitiesOnly=yes root@192.168.50.30            # nuc
ssh -i ~/.ssh/id_ed25519_sk_homelab_yk1 -o IdentitiesOnly=yes mrcode@192.168.50.86          # ugreen
ssh -i ~/.ssh/id_ed25519_sk_homelab_yk1 -o IdentitiesOnly=yes root@192.168.50.80            # nas
ssh -i ~/.ssh/id_ed25519_sk_homelab_yk1 -o IdentitiesOnly=yes hassio@192.168.50.31          # Home Assistant
ssh -i ~/.ssh/id_ed25519_sk_homelab_yk1 -o IdentitiesOnly=yes root@192.168.50.176           # wd_mycloud
```

Enter the FIDO2 PIN when asked, then touch the YubiKey when it blinks.
`-o IdentitiesOnly=yes` stops ssh from offering other keys first, which
can use up the server's `MaxAuthTries` before the YubiKey key is tried.

## From a different machine

Any machine with OpenSSH 8.2 or newer and FIDO2 support works: Fedora and
most Linux distributions (`libfido2`, installed by default on Fedora),
Windows 10/11 with the built-in OpenSSH 8.9 or newer, and macOS with
OpenSSH from Homebrew (`brew install openssh`; Apple's bundled ssh may
lack FIDO2 support, not tested here). Check first with `ssh -V`.

1. Plug in the YubiKey.
2. Recover the key handle from the YubiKey (asks for the FIDO2 PIN):
   ```
   cd ~/.ssh
   ssh-keygen -K
   ```
   This writes `id_ed25519_sk_rk_homelab-breakglass` (YubiKey 1) or
   `id_ed25519_sk_rk_homelab-breakglass-yk2` (YubiKey 2) and its `.pub`,
   named after the key's `application`. Older OpenSSH versions write
   `id_ed25519_sk_rk` instead.
3. Log in exactly as from the laptop, with the recovered file:
   ```
   ssh -i ~/.ssh/id_ed25519_sk_rk_homelab-breakglass -o IdentitiesOnly=yes -p 2299 root@157.173.97.107
   ```
4. On a machine you don't own, delete both files afterwards:
   ```
   rm ~/.ssh/id_ed25519_sk_rk_homelab-breakglass ~/.ssh/id_ed25519_sk_rk_homelab-breakglass.pub
   ```
   The file is only a handle and useless without the YubiKey and the PIN,
   but there is no reason to leave it behind.

To check what is stored on the YubiKey: `ykman fido credentials list`
(asks for the PIN).

## With the Bitwarden recovery key

If both YubiKeys are lost or broken:

1. Copy the private key from Bitwarden into a file, for example
   `~/.ssh/homelab-recovery`, and `chmod 600` it.
2. `ssh -i ~/.ssh/homelab-recovery -o IdentitiesOnly=yes <user>@<host>`,
   with the passphrase from the same Bitwarden entry.
3. Delete the file afterwards.
4. Remove the lost YubiKey's key from every host (see below).

## Adding or replacing a key

1. Create the new key as in [Keys](#keys), with a new comment, file name
   and `application` (for example `homelab-breakglass-yk3`). A unique
   `application` keeps `ssh-keygen -K` from writing two keys to the same
   file name.
2. Add its public key to `breakglass_pubkeys` in
   `openvox/data/common.yaml`. To revoke a lost key, remove its line.
3. Deploy mljr, nuc and ugreen (`roles::ssh_hardening`) and nuc
   (`roles::wd_mycloud_proxy`, which updates wd_mycloud):
   `gh workflow run deploy.yml --ref main -f limit=all`.
4. By hand, because these hosts have no OpenVox agent:
   - **nas:** edit `/root/.ssh/authorized_keys` (it resolves to
     `/boot/config/ssh/root/authorized_keys` on the flash drive). Back it
     up first.
   - **Home Assistant:** Settings > Add-ons > Advanced SSH & Web Terminal >
     Configuration > ⋮ > Edit in YAML, then edit `ssh.authorized_keys`.
     The list button in the UI did not work for pasting keys; the YAML
     editor does. Restart the add-on afterwards.
5. Test a login on every host with the new key before relying on it.

## Status (2026-11-04)

| Host | YubiKey 1 tested | YubiKey 2 tested | Password login |
|---|---|---|---|
| mljr | yes | yes | off |
| nuc | yes | yes | off |
| ugreen | yes | yes | off |
| nas | yes | yes | off |
| homeassistant | yes | yes | off (empty `password` in the add-on) |
| wd_mycloud | yes | yes | off (set at boot by the clamAV hook) |
