#!/usr/bin/env bash
# Interactive ceremony for the offline Ziti root CA (docs/ZITI_PKI.md).
# Run it yourself in a normal terminal on the laptop (you disconnect networking
# yourself; it asks for PINs, touches and a passphrase). It never prints secrets.
#
# Order:
#   1. preflight, you disconnect networking (checked), work dir in /dev/shm
#   2. generate the P-384 root key + self-signed root certificate
#   3. write a passphrase-encrypted copy of the key and prove it decrypts
#   4. per YubiKey (one plugged in at a time): set PIV PIN/PUK/management key
#      if still default, import the key into slot 9c, check the public key,
#      test-sign a throwaway CSR through PKCS#11 and verify it
#   5. shred the plain key, you may reconnect
#   6. you store the encrypted key + certificate in Bitwarden, then the copy
#      in /dev/shm is shredded and the public certificate is put into the repo
#
# Any error stops the script. The plain key is always shredded on exit; rerun
# from the start (a rerun overwrites slot 9c with a new key).
set -euo pipefail

YK1=34717587
YK2=26724345
MOD=/usr/lib64/opensc-pkcs11.so
# pkcs11-provider config: log in before searching (OpenSC only shows PIV
# private keys after a PIN login) and reuse the typed PIN for the extra
# per-signature login that the "always authenticate" slot 9c key needs.
p11_conf() {
  printf '%s\n' 'openssl_conf = openssl_init' '[openssl_init]' 'providers = provider_sect' \
    '[provider_sect]' 'default = default_sect' 'pkcs11 = pkcs11_sect' '[default_sect]' 'activate = 1' \
    '[pkcs11_sect]' 'module = /usr/lib64/ossl-modules/pkcs11.so' "pkcs11-module-path = $MOD" \
    'pkcs11-module-login-behavior = always' 'pkcs11-module-cache-pins = cache' 'activate = 1' > "$1"
}
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
for t in ykman "$OSSL" shred; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
[ -e "$MOD" ] || die "missing $MOD (OpenSC)"
pc=$(mktemp -p /dev/shm p11.XXXXXX) && p11_conf "$pc"
OPENSSL_CONF="$pc" "$OSSL" list -providers 2>/dev/null | grep -q pkcs11 || { rm -f "$pc"; die "OpenSSL pkcs11 provider not available"; }
rm -f "$pc"
[ -e "$CERT_DEST" ] && die "$CERT_DEST already exists; the root was created before. Move it away first if you really want a new root."

say "Ziti root CA ceremony"
info "YubiKey 1: $YK1, YubiKey 2: $YK2. Have both and Bitwarden ready."
info "Networking must stay off until the plain key is shredded."
confirm "Start?" || exit 0

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
}
trap cleanup EXIT

say "Disconnect networking"
info "Switch off Wi-Fi/Ethernet yourself (e.g. airplane mode in the KDE applet)."
info "The script does not toggle it: nmcli networking on did not reliably reconnect."
read -rp "    Press Enter once disconnected "
if [ -n "$(ip route show default 2>/dev/null)" ]; then
  confirm "A default route still exists (still online). Continue anyway?" || exit 0
fi
umask 077
W=$(mktemp -d -p /dev/shm ziti-root.XXXXXX)
cd "$W"
p11_conf p11.cnf

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
  local name="$1" serial="$2" pinfo
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

  info "Test-signing through PKCS#11 (slot 9c = object id 02; PIN + touch):"
  OPENSSL_CONF=p11.cnf "$OSSL" x509 -req -in test.csr -CA root-ca.crt \
    -CAkey "pkcs11:id=%02;type=private" \
    -days 1 -sha384 -out "test-$serial.crt"
  "$OSSL" verify -CAfile root-ca.crt "test-$serial.crt" >/dev/null \
    || die "test certificate from $name does not verify"
  info "$name signs correctly"
}

do_key "YubiKey 1" "$YK1"
do_key "YubiKey 2" "$YK2"

# --- shred plain key, back online -------------------------------------------
say "Shredding the plain key"
shred -u root.key test.key
info "You can reconnect networking now."

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
