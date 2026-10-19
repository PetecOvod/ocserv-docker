#!/bin/sh
# Issue (or reissue) a client certificate signed by the local CA.
# Usage: make-client.sh <name> [export]
# Files: /etc/ocserv/auth/clients/<name>-key.pem, <name>-cert.pem and, with
# "export", <name>.p12. Valid for CLIENT_CERT_DAYS days (default 3650).
# A reissue replaces the key and the certificate together; a run that fails
# leaves the previous pair as it was. A reissue does not revoke the previous
# certificate: 'ocs client renew' does.
set -eu

OCSERV_DIR="/etc/ocserv"
CERT_DIR="$OCSERV_DIR/cert"
CLIENTS_DIR="$OCSERV_DIR/auth/clients"
CLIENT_TMPL="$OCSERV_DIR/templates/client.tmpl"
CA_KEY="$CERT_DIR/ca-key.pem"
CA_PEM="$CERT_DIR/ca.pem"

usage() {
  echo "Usage: $0 <name> [export]"
  echo "Creates a client certificate signed by the local CA and stores it under $CLIENTS_DIR"
}

NAME="${1:-}"
EXPORT="${2:-}"
[ -n "$NAME" ] || { usage; exit 1; }

# The name becomes part of file paths and of the certificate template, so
# only plain names are accepted (also when this script is run without ocs).
case "$NAME" in
  -*|.*|*[!A-Za-z0-9._-]*)
    echo "[ERR] Invalid name '$NAME' (letters, digits, . _ -; not starting with - or .)" >&2
    exit 1 ;;
esac

DAYS="${CLIENT_CERT_DAYS:-3650}"
case "$DAYS" in
  ''|0*|*[!0-9]*) DAYS=0 ;;
esac
if [ "${#DAYS}" -gt 4 ] || [ "$DAYS" -lt 1 ] || [ "$DAYS" -gt 3650 ]; then
  echo "[ERR] Invalid validity '${CLIENT_CERT_DAYS:-}' days (a whole number from 1 to 3650)" >&2
  exit 1
fi

[ -f "$CLIENT_TMPL" ] || { echo "[ERR] Missing template: $CLIENT_TMPL" >&2; exit 1; }
[ -f "$CA_KEY" ] && [ -f "$CA_PEM" ] || { echo "[ERR] Missing CA: $CA_PEM / $CA_KEY" >&2; exit 1; }

umask 077
mkdir -p "$CLIENTS_DIR"

# One client certificate operation at a time, so two runs cannot mix their
# files; ocs takes this lock itself and sets OCS_LOCK_HELD.
if [ -z "${OCS_LOCK_HELD:-}" ]; then
  exec 9>"$CLIENTS_DIR/.lock"
  i=0
  until flock -n 9; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || { echo "[ERR] Another client certificate operation is running; try again" >&2; exit 1; }
    sleep 1
  done
fi

KEY="$CLIENTS_DIR/${NAME}-key.pem"
CERT="$CLIENTS_DIR/${NAME}-cert.pem"
P12="$CLIENTS_DIR/${NAME}.p12"

# Build the new pair in a scratch directory; the live files are replaced
# only when everything has succeeded.
WORK="$(mktemp -d "$CLIENTS_DIR/.issue-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$CERT" ]; then
  echo "[INFO] Replacing the existing certificate for $NAME"
  [ -n "${OCS_LOCK_HELD:-}" ] || echo "[WARN] The previous certificate stays valid; 'ocs client renew $NAME' also revokes it" >&2
fi
echo "[INFO] Generating key for $NAME"
certtool --generate-privkey --outfile "$WORK/key.pem"

sed -e "s/@CN@/${NAME}/g" -e "s/@DAYS@/${DAYS}/g" "$CLIENT_TMPL" > "$WORK/client.tmpl"

echo "[INFO] Signing client certificate"
certtool --generate-certificate --load-privkey "$WORK/key.pem" \
  --load-ca-certificate "$CA_PEM" --load-ca-privkey "$CA_KEY" \
  --template "$WORK/client.tmpl" --outfile "$WORK/cert.pem"

if [ "$EXPORT" = "export" ]; then
  echo "[INFO] Exporting to PKCS#12: $P12"
  certtool --to-p12 --load-privkey "$WORK/key.pem" --load-certificate "$WORK/cert.pem" \
    --pkcs-cipher 3des-pkcs12 --outfile "$WORK/bundle.p12" --outder
fi

mv -f "$WORK/key.pem" "$KEY"
mv -f "$WORK/cert.pem" "$CERT"
if [ -f "$WORK/bundle.p12" ]; then
  mv -f "$WORK/bundle.p12" "$P12"
  echo "[OK] Exported: $P12"
elif [ -f "$P12" ]; then
  # A bundle left from the previous certificate would carry the old key.
  rm -f "$P12"
  echo "[INFO] Removed the old $P12 (it held the previous certificate)"
fi

echo "[OK] Client cert created: $CERT"
echo "[OK] CA: $CA_PEM"
