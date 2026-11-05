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
`ziti/pki/root-ca.crt`.

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
Run it in your own terminal, not through an agent: it switches networking
off until the plain key is shredded, and asks for PINs, touches and the
passphrase. It stops on any error and always shreds the plain key. The
manual steps below are the same thing, for reference or if the script fails.

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

```
nmcli networking off
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

export PKCS11_PROVIDER_MODULE=/usr/lib64/opensc-pkcs11.so
pkcs11-tool --module "$PKCS11_PROVIDER_MODULE" --list-objects --type privkey

/usr/bin/openssl x509 -req -in test.csr -CA root-ca.crt \
  -CAkey "pkcs11:object=SIGN%20key;type=private" \
  -provider pkcs11 -provider default -days 1 -sha384 -out test.crt

openssl verify -CAfile root-ca.crt test.crt
```

If the object label differs, use the one `pkcs11-tool` lists for slot `9c`.
Expect a PIN prompt and a touch.

### 6. Clean up and commit the public certificate

```
mkdir -p ~/Projekte/homelab-automation/ziti/pki
cp root-ca.crt ~/Projekte/homelab-automation/ziti/pki/root-ca.crt
shred -u root.key test.key && cd / && rm -rf "$W"
nmcli networking on
```

Commit `ziti/pki/root-ca.crt` and record the fingerprint in this file.

## Signing the controller intermediate

Done during the Phase 3 build: the controller creates the intermediate key
and CSR on mljr, the CSR comes to the laptop, step 5's `openssl x509 -req`
signs it with `-extfile` setting `basicConstraints=critical,CA:TRUE,pathlen:0`
and `keyUsage=critical,keyCertSign,cRLSign`, `-days 1095`, and the
certificate goes back to mljr. The exact commands and the re-issue
procedure are added here once the PoC has run them (C12).

## Status

| Item | Done |
|---|---|
| PIV PIN/PUK/management key set, YubiKey 1 | no |
| PIV PIN/PUK/management key set, YubiKey 2 | no |
| Root generated, backed up to Bitwarden | no |
| Imported and test-signed, YubiKey 1 | no |
| Imported and test-signed, YubiKey 2 | no |
| `ziti/pki/root-ca.crt` committed, fingerprint recorded | no |
