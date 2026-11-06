#!/usr/bin/env bash
# Issue (or re-issue) the Ziti controller's intermediate CA on mljr, signed by
# the offline root on a YubiKey (docs/ZITI_PKI.md). Run it yourself on the
# laptop with one YubiKey plugged in: it asks for the PIV PIN and a touch.
# Networking stays on; the root key never leaves the YubiKey and the
# intermediate key never leaves mljr.
#
# Order:
#   1. preflight (tools, pkcs11 provider, root cert, ssh to mljr)
#   2. mljr writes a CSR: first issue from a new P-384 key in a staging dir
#      under data/, re-issue from the existing intermediate key
#   3. the laptop checks the CSR (P-384, expected subject) and signs it with
#      the YubiKey: CA:TRUE pathlen:0, keyCertSign/cRLSign, the SPIFFE trust
#      domain as URI SAN, 3 years
#   4. the certificate is verified against the root and the CSR key
#   5. mljr installs it (first issue: the staging dir becomes data/pki, owned
#      by the container user; re-issue: the old certificate is kept as
#      intermediate.cert.<timestamp>) and restarts the controller if it runs;
#      its entrypoint re-issues the leaf certs
#
# Usage: scripts/ziti-sign-intermediate.sh [--reissue]
#   --reissue  renew the existing intermediate (otherwise refused). The key
#              and subject stay the same, so every router and identity
#              certificate it already signed stays valid.
# Remote commands are built locally on purpose (paths and subject are local
# constants), hence SC2029.
# shellcheck disable=SC2029
set -euo pipefail

HOST=root@mljr.tail33930.ts.net
DATA=/opt/ziti-controller/data
ZUID=2171 # ziggy, the image user
TRUST_DOMAIN=ziti.mljr.eu
SUBJECT="/O=homelab/CN=homelab Ziti Intermediate CA mljr"
DAYS=1095
MOD=/usr/lib64/opensc-pkcs11.so
# Same pkcs11-provider config as scripts/ziti-root-ca-ceremony.sh: log in
# before searching, reuse the PIN for the per-signature login.
p11_conf() {
  printf '%s\n' 'openssl_conf = openssl_init' '[openssl_init]' 'providers = provider_sect' \
    '[provider_sect]' 'default = default_sect' 'pkcs11 = pkcs11_sect' '[default_sect]' 'activate = 1' \
    '[pkcs11_sect]' 'module = /usr/lib64/ossl-modules/pkcs11.so' "pkcs11-module-path = $MOD" \
    'pkcs11-module-login-behavior = always' 'pkcs11-module-cache-pins = cache' 'activate = 1' > "$1"
}
OSSL=/usr/bin/openssl
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$REPO/ziti/pki/root-ca.crt"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
confirm() { local a; read -rp "    $1 [y/N] " a; [[ "$a" =~ ^[yY] ]]; }

reissue=false
case "${1:-}" in
  '') ;;
  --reissue) reissue=true ;;
  *) die "usage: $0 [--reissue]" ;;
esac

# --- 1. preflight -----------------------------------------------------------
for t in ykman "$OSSL" ssh; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
[ -e "$MOD" ] || die "missing $MOD (OpenSC)"
[ -s "$ROOT" ] || die "missing $ROOT"
W=$(mktemp -d -p /dev/shm ziti-int.XXXXXX)
trap 'rm -rf -- "$W"' EXIT
p11_conf "$W/p11.cnf"
OPENSSL_CONF="$W/p11.cnf" "$OSSL" list -providers 2>/dev/null | grep -q pkcs11 || die "OpenSSL pkcs11 provider not available"
[ "$(ykman list --serials | wc -l)" -eq 1 ] || die "plug in exactly one YubiKey"
ssh -o BatchMode=yes "$HOST" true || die "cannot ssh to $HOST"

if ssh "$HOST" "test -s $DATA/pki/intermediate/certs/intermediate.cert"; then
  $reissue || die "mljr already has an intermediate; rerun with --reissue to replace it"
  info "Current intermediate on mljr:"
  ssh "$HOST" "openssl x509 -in $DATA/pki/intermediate/certs/intermediate.cert -noout -subject -enddate" | sed 's/^/    /'
fi

say "Signing a new Ziti intermediate CA for mljr (trust domain $TRUST_DOMAIN)"
confirm "Start?" || exit 0

# --- 2. CSR on mljr ---------------------------------------------------------
# First issue: a staging dir in the bootstrap's pki/ layout. Re-issue: the
# live key; the CSR is only read, nothing on mljr changes until step 5.
STAGE="$DATA/pki.new"
if $reissue; then
  say "Writing a CSR from the existing key on mljr"
  ssh "$HOST" "openssl req -new -key $DATA/pki/intermediate/keys/intermediate.key -subj '$SUBJECT'" \
    > "$W/int.csr" || die "CSR generation on mljr failed"
else
  say "Generating key and CSR on mljr"
  ssh "$HOST" "set -eu; umask 077
    rm -rf $STAGE
    mkdir -p $STAGE/root/certs $STAGE/intermediate/certs $STAGE/intermediate/keys $STAGE/intermediate/crls
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
      -pkeyopt ec_param_enc:named_curve -out $STAGE/intermediate/keys/intermediate.key 2>/dev/null
    openssl req -new -key $STAGE/intermediate/keys/intermediate.key -subj '$SUBJECT'" \
    > "$W/int.csr" || die "key/CSR generation on mljr failed"
fi

# --- 3. check + sign the CSR ------------------------------------------------
"$OSSL" req -in "$W/int.csr" -noout -verify 2>/dev/null || die "CSR signature invalid"
csr_subject=$("$OSSL" req -in "$W/int.csr" -noout -subject -nameopt compat)
[ "$csr_subject" = "subject=$SUBJECT" ] || die "unexpected CSR subject: $csr_subject"
"$OSSL" req -in "$W/int.csr" -noout -text | grep -q 'NIST CURVE: P-384' || die "CSR key is not P-384"

cat > "$W/ext.cnf" <<EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
subjectAltName=URI:spiffe://$TRUST_DOMAIN
EOF

say "Signing with the YubiKey (PIV PIN, then touch it when it blinks)"
OPENSSL_CONF="$W/p11.cnf" "$OSSL" x509 -req -in "$W/int.csr" -CA "$ROOT" \
  -CAkey "pkcs11:id=%02;type=private" -set_serial "0x$("$OSSL" rand -hex 16)" \
  -days "$DAYS" -sha384 -extfile "$W/ext.cnf" -out "$W/int.crt" \
  || die "signing failed"

# --- 4. verify --------------------------------------------------------------
"$OSSL" verify -CAfile "$ROOT" "$W/int.crt" >/dev/null || die "certificate does not verify against the root"
[ "$("$OSSL" x509 -in "$W/int.crt" -noout -pubkey)" = "$("$OSSL" req -in "$W/int.csr" -noout -pubkey)" ] \
  || die "certificate key does not match the CSR"
"$OSSL" x509 -in "$W/int.crt" -noout -subject -enddate -ext subjectAltName,basicConstraints | sed 's/^/    /'

# --- 5. install on mljr -----------------------------------------------------
say "Installing on mljr"
if $reissue; then
  P="$DATA/pki"
  scp -q "$W/int.crt" "$HOST:$P/intermediate/certs/intermediate.cert.new"
  ssh "$HOST" "set -eu
    cd $P/intermediate/certs
    cp -p intermediate.cert intermediate.cert.\$(date +%Y%m%dT%H%M%S)
    mv intermediate.cert.new intermediate.cert
    cat intermediate.cert ../../root/certs/root.cert > intermediate.chain.pem
    chown $ZUID:$ZUID intermediate.cert intermediate.chain.pem" || die "install on mljr failed"
else
  # Plus the index files `ziti pki create server/client --ca-name
  # intermediate` expects.
  scp -q "$ROOT" "$HOST:$STAGE/root/certs/root.cert"
  scp -q "$W/int.crt" "$HOST:$STAGE/intermediate/certs/intermediate.cert"
  ssh "$HOST" "set -eu
    cd $STAGE/intermediate
    cat certs/intermediate.cert ../root/certs/root.cert > certs/intermediate.chain.pem
    : > index.txt
    echo 'unique_subject = no' > index.txt.attr
    echo 01 > serial
    echo 01 > crlnumber
    chown -R $ZUID:$ZUID $STAGE $DATA
    if [ -d $DATA/pki ]; then mv $DATA/pki $DATA/pki.\$(date +%Y%m%dT%H%M%S); fi
    mv $STAGE $DATA/pki" || die "install on mljr failed"
fi
ssh "$HOST" "if docker ps --format '{{.Names}}' | grep -qx ziti-controller; then
    docker restart ziti-controller >/dev/null && echo '    controller restarted, leaf certs re-issued'
  fi"

say "Done. Intermediate installed at $DATA/pki on mljr."
info "Record the new expiry in docs/ZITI_PKI.md (Status)."
