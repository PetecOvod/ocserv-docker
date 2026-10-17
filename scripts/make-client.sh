#!/bin/sh
# Issue (or reissue) a client certificate signed by the local CA.
# Usage: make-client.sh <name> [export]
# Files: /etc/ocserv/auth/clients/<name>-key.pem, <name>-cert.pem and, with
# "export", <name>.p12. A reissue replaces the key and the certificate
# together; a run that fails leaves the previous pair as it was.
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

[ -f "$CLIENT_TMPL" ] || { echo "[ERR] Missing template: $CLIENT_TMPL" >&2; exit 1; }
[ -f "$CA_KEY" ] && [ -f "$CA_PEM" ] || { echo "[ERR] Missing CA: $CA_PEM / $CA_KEY" >&2; exit 1; }

umask 077
mkdir -p "$CLIENTS_DIR"

# One issue at a time, so two runs for the same name cannot mix their files.
exec 9>"$CLIENTS_DIR/.lock"
flock -n 9 || { echo "[ERR] Another client certificate is being issued; try again" >&2; exit 1; }

KEY="$CLIENTS_DIR/${NAME}-key.pem"
CERT="$CLIENTS_DIR/${NAME}-cert.pem"
P12="$CLIENTS_DIR/${NAME}.p12"

# Build the new pair in a scratch directory; the live files are replaced
# only when everything has succeeded.
WORK="$(mktemp -d "$CLIENTS_DIR/.issue-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -f "$CERT" ] && echo "[INFO] Replacing the existing certificate for $NAME"
echo "[INFO] Generating key for $NAME"
certtool --generate-privkey --outfile "$WORK/key.pem"

sed "s/@CN@/${NAME}/g" "$CLIENT_TMPL" > "$WORK/client.tmpl"

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
