# Ziti PKI: offline root CA on YubiKeys

The root CA of the OpenZiti overlay (docs/ZERO_TRUST_PLAN.md, Phase 3, C12).
It only ever signs the intermediate CA that lives on the controller (mljr).
It is never on a server.

## Where the root key lives

| Copy | Location | Unlock |
|---|---|---|
| 1 | YubiKey 1 (serial 34717587), PIV slot `9c` | PIV PIN + touch |
| 2 | YubiKey 2 (serial 26724345), PIV slot `9c` | PIV PIN + touch |
| 3 | Bitwarden item `homelab ziti root CA`, passphrase-encrypted PEM | Bitwarden + key passphrase |

A key generated *on* a YubiKey can never be exported, so it could not be
backed up or copied to the second YubiKey. The key is therefore generated
once on the offline laptop, imported into both YubiKeys and backed up to
Bitwarden. Losing all three copies means a new root and re-enrolling every
Ziti identity and router.

The root certificate is public and lives in the repo at
`ziti/pki/root-ca.crt`:

- Subject and issuer: `O=homelab, CN=homelab Ziti Root CA`, ECC P-384
- Valid 2026-11-05 to 2036-11-02
- SHA-256 fingerprint:
  `B8:12:04:6A:A5:EE:D0:01:96:70:72:C4:4D:54:0D:69:2F:56:2D:4F:21:9C:E5:02:0D:AA:2E:28:AB:3F:B3:5B`

Compare this fingerprint with the Bitwarden item before trusting a copy.

## Parameters

- ECC P-384. YubiKey 2 (firmware 5.4.3) does not support Ed25519 or RSA-4096
  in PIV; P-384 works on both keys and with Ziti.
- Root valid 10 years, the controller intermediate 3 years.
- PIV slot `9c` (digital signature), PIN policy `ALWAYS`, touch policy
  `ALWAYS`.
- PIV is a separate YubiKey application from FIDO2. The SSH break-glass
  keys (docs/BREAKGLASS.md) are not affected.

## Ceremony

Run on the laptop. Tools: `ykman`, `openssl`, `pkcs11-provider` and OpenSC
(`/usr/lib64/opensc-pkcs11.so`), all already installed.

`scripts/ziti-root-ca-ceremony.sh` runs steps 1-6 in order, interactively.
Run it in your own terminal, not through an agent: it asks for PINs,
touches and the passphrase. Disconnect networking yourself when it asks
(it checks that no default route is left); it does not toggle networking,
because `nmcli networking on` did not reliably reconnect. Stay offline
until it says the plain key is shredded. It stops on any error and always
shreds the plain key. The manual steps below are the same thing, for
reference or if the script fails.

Use `/usr/bin/openssl` (system OpenSSL 3.5). A linuxbrew `openssl` earlier in
`PATH` cannot load Fedora's `pkcs11-provider`, which step 5 needs.

### 1. Set PIV PIN, PUK and management key (each YubiKey, once)

Plug in one YubiKey at a time. Defaults are PIN `123456`, PUK `12345678`.
Store the new PIN and PUK in Bitwarden (`homelab yubikey PIV`).

```
ykman piv info
ykman piv access change-pin
ykman piv access change-puk
ykman piv access change-management-key --generate --protect
```

`--protect` stores a random management key on the YubiKey, unlocked by the
PIN, so there is no extra secret to keep.

### 2. Generate the root offline

Disconnect networking first (airplane mode in the KDE applet) and check
that `ip route show default` prints nothing.

```
umask 077
W=$(mktemp -d -p /dev/shm ziti-root.XXXX) && cd "$W"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -pkeyopt ec_param_enc:named_curve -out root.key

openssl req -x509 -new -key root.key -sha384 -days 3650 \
  -subj "/O=homelab/CN=homelab Ziti Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -out root-ca.crt

openssl x509 -in root-ca.crt -noout -subject -enddate -fingerprint -sha256
```

### 3. Back up to Bitwarden

```
openssl pkey -in root.key -aes256 -out root.key.enc.pem
```

Choose a new long passphrase. Put the contents of `root.key.enc.pem` and
`root-ca.crt` into the Bitwarden item `homelab ziti root CA`, the passphrase
in its own field, and the SHA-256 fingerprint in the notes.

### 4. Import into both YubiKeys

With YubiKey 1, then YubiKey 2:

```
ykman piv keys import --pin-policy ALWAYS --touch-policy ALWAYS 9c root.key
ykman piv certificates import 9c root-ca.crt
ykman piv info
```

### 5. Prove each YubiKey can sign

With each YubiKey plugged in, sign a throwaway CSR and verify it against
the root:

```
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes \
  -keyout test.key -subj "/CN=ceremony test" -out test.csr

cat > p11.cnf <<'EOF'
openssl_conf = openssl_init
[openssl_init]
providers = provider_sect
[provider_sect]
default = default_sect
pkcs11 = pkcs11_sect
[default_sect]
activate = 1
[pkcs11_sect]
module = /usr/lib64/ossl-modules/pkcs11.so
pkcs11-module-path = /usr/lib64/opensc-pkcs11.so
pkcs11-module-login-behavior = always
pkcs11-module-cache-pins = cache
activate = 1
EOF

OPENSSL_CONF=p11.cnf /usr/bin/openssl x509 -req -in test.csr -CA root-ca.crt \
  -CAkey "pkcs11:id=%02;type=private" -days 1 -sha384 -out test.crt

openssl verify -CAfile root-ca.crt test.crt
```

Expect one PIN prompt and a touch. Why the config is needed:

- OpenSC maps PIV slot `9c` to PKCS#11 object id `02`, but only shows the
  private key after a PIN login. The provider's default
  (`login-behavior = auto`) searches before logging in and reports
  "Could not find CA private key"; `always` logs in first.
- The imported key is flagged "always authenticate", so each signature
  needs a second, context-specific PIN login. `cache-pins = cache` reuses
  the PIN typed once.
- Select the key by id, not label: `pkcs11-tool --list-objects` without
  `--login` shows no private key at all.

### 6. Clean up and commit the public certificate

```
mkdir -p ~/Projekte/homelab-automation/ziti/pki
cp root-ca.crt ~/Projekte/homelab-automation/ziti/pki/root-ca.crt
shred -u root.key test.key && cd / && rm -rf "$W"
```

Reconnect networking only after the plain key is shredded.

Commit `ziti/pki/root-ca.crt` and record the fingerprint in this file.

## Signing the controller intermediate

`scripts/ziti-sign-intermediate.sh`, run on the laptop with one YubiKey
plugged in and networking on:

1. mljr generates a P-384 key and a CSR in `/opt/ziti-controller/data/pki.new`.
   The key never leaves mljr.
2. The laptop checks the CSR (signature, P-384, subject
   `O=homelab, CN=homelab Ziti Intermediate CA mljr`) and signs it with the
   YubiKey, as in step 5: `basicConstraints=critical,CA:TRUE,pathlen:0`,
   `keyUsage=critical,keyCertSign,cRLSign`, `subjectAltName=URI:spiffe://ziti.mljr.eu`,
   SHA-384, 1095 days.
3. It verifies the certificate against the root and the CSR key.
4. mljr gets the root and intermediate certificates, the chain and the
   index files in the layout of the image's bootstrap
   (`pki/root/certs/root.cert`, `pki/intermediate/{certs,keys}/intermediate.*`),
   owned by the container user (uid 2171). It restarts the controller if it
   runs.

The controller's own server and client certificates are not signed here:
the container entrypoint issues them from the intermediate on every start
(1 year, `spiffe://ziti.mljr.eu/controller/mljr`).

The SPIFFE URI on the intermediate sets the trust domain. Ziti reads it from
the signing CA, so the root needs none. Never change it: every enrolled
identity and router depends on it.

### Re-issue

`scripts/ziti-sign-intermediate.sh --reissue` writes a CSR from the
existing intermediate key and installs the new certificate in place (the old
one is kept as `intermediate.cert.<timestamp>`). Same key and subject, so
every router and identity certificate the intermediate signed stays valid.
Re-issue well before expiry; the healthreport `pki` collector warns from
365 days (C12).

## Status

| Item | Done |
|---|---|
| PIV PIN/PUK/management key set, YubiKey 1 | yes (2026-11-05) |
| PIV PIN/PUK/management key set, YubiKey 2 | yes (2026-11-05) |
| Root generated, backed up to Bitwarden | yes (2026-11-05) |
| Imported and test-signed, YubiKey 1 | yes (2026-11-05) |
| Imported and test-signed, YubiKey 2 | yes (2026-11-05) |
| `ziti/pki/root-ca.crt` committed, fingerprint recorded | yes (2026-11-05) |
| Controller intermediate issued on mljr (serial `73DC5346…52C8`, valid to 2029-11-04) | yes (2026-11-05) |
