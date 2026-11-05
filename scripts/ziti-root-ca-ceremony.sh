#!/usr/bin/env bash
# Interactive ceremony for the offline Ziti root CA (docs/ZITI_PKI.md).
# Run it yourself in a normal terminal on the laptop (it turns networking off,
# asks for PINs, touches and a passphrase). It never prints secrets.
#
# Order:
#   1. preflight, networking off, work dir in /dev/shm
#   2. generate the P-384 root key + self-signed root certificate
#   3. write a passphrase-encrypted copy of the key and prove it decrypts
#   4. per YubiKey (one plugged in at a time): set PIV PIN/PUK/management key
#      if still default, import the key into slot 9c, check the public key,
#      test-sign a throwaway CSR through PKCS#11 and verify it
#   5. shred the plain key, networking back on
#   6. you store the encrypted key + certificate in Bitwarden, then the copy
#      in /dev/shm is shredded and the public certificate is put into the repo
#
# Any error stops the script. The plain key is always shredded on exit; rerun
# from the start (a rerun overwrites slot 9c with a new key).
set -euo pipefail

YK1=34717587
YK2=26724345
MOD=/usr/lib64/opensc-pkcs11.so
# System OpenSSL: Fedora's pkcs11-provider is built for it (a linuxbrew openssl
# earlier in PATH cannot load it).
OSSL=/usr/bin/openssl
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DEST="$REPO/ziti/pki/root-ca.crt"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
confirm() { local a; read -rp "    $1 [y/N] " a; [[ "$a" =~ ^[yY] ]]; }

# --- preflight --------------------------------------------------------------
for t in ykman "$OSSL" pkcs11-tool nmcli shred; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
[ -e "$MOD" ] || die "missing $MOD (OpenSC)"
PKCS11_PROVIDER_MODULE="$MOD" "$OSSL" list -providers -provider pkcs11 >/dev/null 2>&1 || die "OpenSSL pkcs11 provider not available"
[ -e "$CERT_DEST" ] && die "$CERT_DEST already exists; the root was created before. Move it away first if you really want a new root."

say "Ziti root CA ceremony"
info "YubiKey 1: $YK1, YubiKey 2: $YK2. Have both and Bitwarden ready."
info "Networking is switched off until the plain key is shredded."
confirm "Start?" || exit 0

net_off=false
W=""
backup_done=false
cleanup() {
  if [ -n "$W" ] && [ -d "$W" ]; then
    for f in root.key test.key; do [ -f "$W/$f" ] && shred -u "$W/$f"; done
    if [ -f "$W/root.key.enc.pem" ] && [ "$backup_done" = false ]; then
      install -m 600 "$W/root.key.enc.pem" "$HOME/ziti-root.key.enc.pem"
      printf '\033[1;33mKept the ENCRYPTED key at %s - store it in Bitwarden or delete it.\033[0m\n' "$HOME/ziti-root.key.enc.pem"
    fi
    rm -rf -- "$W"
  fi
  if [ "$net_off" = true ]; then nmcli networking on && echo "networking back on"; fi
}
trap cleanup EXIT

nmcli networking off && net_off=true
umask 077
W=$(mktemp -d -p /dev/shm ziti-root.XXXXXX)
cd "$W"

# --- generate ---------------------------------------------------------------
say "Generating root key and certificate (offline, in $W)"
"$OSSL" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
  -pkeyopt ec_param_enc:named_curve -out root.key
"$OSSL" req -x509 -new -key root.key -sha384 -days 3650 \
  -subj "/O=homelab/CN=homelab Ziti Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -out root-ca.crt
"$OSSL" x509 -in root-ca.crt -noout -subject -enddate
FPR=$("$OSSL" x509 -in root-ca.crt -noout -fingerprint -sha256 | cut -d= -f2)
info "SHA-256 fingerprint: $FPR"
"$OSSL" x509 -in root-ca.crt -noout -pubkey > root.pub

# --- encrypted backup -------------------------------------------------------
say "Encrypted backup for Bitwarden (choose a new long passphrase)"
"$OSSL" pkey -in root.key -aes256 -out root.key.enc.pem
info "Proving the backup decrypts (enter the passphrase again):"
"$OSSL" pkey -in root.key.enc.pem -pubout | cmp -s - root.pub \
  || die "encrypted backup does not match the root key"
info "backup OK"

# Throwaway CSR for the signing test.
"$OSSL" req -new -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes \
  -keyout test.key -subj "/CN=ceremony test" -out test.csr 2>/dev/null

# --- per YubiKey ------------------------------------------------------------
wait_for_only() {
  local want="$1" s
  while :; do
    mapfile -t s < <(ykman list --serials 2>/dev/null)
    if [ "${#s[@]}" -eq 1 ] && [ "${s[0]}" = "$want" ]; then return; fi
    read -rp "    Plug in ONLY YubiKey $want (now: ${s[*]:-none}), then press Enter "
  done
}

do_key() {
  local name="$1" serial="$2" pinfo label
  say "$name ($serial)"
  wait_for_only "$serial"
  pinfo=$(ykman --device "$serial" piv info)

  if grep -qi "default" <<<"$pinfo"; then
    info "PIV still uses a default PIN/PUK/management key. Changing them now."
    info "Current defaults: PIN 123456, PUK 12345678. Store the new ones in Bitwarden."
    ykman --device "$serial" piv access change-pin
    ykman --device "$serial" piv access change-puk
    ykman --device "$serial" piv access change-management-key --generate --protect
  else
    info "PIV PIN/PUK/management key already changed."
  fi

  if grep -qi "slot 9c" <<<"$pinfo"; then
    confirm "Slot 9c on $name is not empty. Overwrite it?" || die "aborted"
  fi

  info "Importing key and certificate into slot 9c (PIN, maybe touch):"
  ykman --device "$serial" piv keys import --pin-policy ALWAYS --touch-policy ALWAYS 9c root.key
  ykman --device "$serial" piv certificates import 9c root-ca.crt
  ykman --device "$serial" piv keys export 9c - | cmp -s - root.pub \
    || die "public key in slot 9c of $name does not match the root"
  info "public key matches"

  label=$(pkcs11-tool --module "$MOD" --list-objects --type privkey 2>/dev/null \
    | awk '/label:/{sub(/^[^:]*:[ \t]*/,""); l=$0} /ID:/{if($2=="02"){print l; exit}}')
  [ -n "$label" ] || die "no PKCS#11 private key with ID 02 (slot 9c) on $name"
  info "Test-signing through PKCS#11 (object '$label'; PIN + touch):"
  PKCS11_PROVIDER_MODULE="$MOD" "$OSSL" x509 -req -in test.csr -CA root-ca.crt \
    -CAkey "pkcs11:object=${label// /%20};type=private" \
    -provider pkcs11 -provider default -days 1 -sha384 -out "test-$serial.crt"
  "$OSSL" verify -CAfile root-ca.crt "test-$serial.crt" >/dev/null \
    || die "test certificate from $name does not verify"
  info "$name signs correctly"
}

do_key "YubiKey 1" "$YK1"
do_key "YubiKey 2" "$YK2"

# --- shred plain key, back online -------------------------------------------
say "Shredding the plain key"
shred -u root.key test.key
nmcli networking on && net_off=false
info "networking back on"

# --- Bitwarden --------------------------------------------------------------
say "Store in Bitwarden item 'homelab ziti root CA'"
info "1. Contents of $W/root.key.enc.pem (encrypted key)"
info "2. Contents of $W/root-ca.crt (certificate)"
info "3. The passphrase, in its own field"
info "4. Fingerprint in the notes: $FPR"
read -rp "    Type 'stored' once all four are saved in Bitwarden: " a
[ "$a" = "stored" ] || die "not confirmed; the encrypted key is kept in \$HOME"
backup_done=true

# --- repo -------------------------------------------------------------------
mkdir -p "$(dirname "$CERT_DEST")"
cp root-ca.crt "$CERT_DEST"
shred -u root.key.enc.pem
say "Done"
info "Public certificate: $CERT_DEST"
info "Fingerprint: $FPR"
info "Commit the certificate and tick the status table in docs/ZITI_PKI.md."
