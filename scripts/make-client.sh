#!/bin/sh
set -euo pipefail
OCSERV_DIR="/etc/ocserv"
CERT_DIR="$OCSERV_DIR/cert"
AUTH_DIR="$OCSERV_DIR/auth"
CLIENTS_DIR="$AUTH_DIR/clients"
TEMPL_DIR="$OCSERV_DIR/templates"
CA_KEY="$CERT_DIR/ca-key.pem"
CA_PEM="$CERT_DIR/ca.pem"
CRT="$CLIENTS_DIR"

usage() {
  echo "Usage: $0 <username> [export]"
  echo "Creates a client certificate signed by the local CA and stores it under $CLIENTS_DIR"
}

if [[ "${1:-}" == "" ]]; then usage; exit 1; fi
USER="$1"
EXPORT="${2:-}"

mkdir -p "$CLIENTS_DIR"

# Ensure templates
CLIENT_TMPL="$TEMPL_DIR/client.tmpl"
if [[ ! -f "$CLIENT_TMPL" ]]; then
  echo "[ERR] Missing template: $CLIENT_TMPL" >&2
  exit 1
fi

# Create CA if not exists
if [[ ! -f "$CA_KEY" || ! -f "$CA_PEM" ]]; then
  echo "[ERR] Missing CA: $CA_KEY" >&2
  exit 1
fi

KEY="$CRT/${USER}-key.pem"
CSR="$CRT/${USER}.csr"
CERT="$CRT/${USER}-cert.pem"
P12="$CRT/${USER}.p12"

echo "[INFO] Generating key for $USER"
certtool --generate-privkey --outfile "$KEY"

# Fill CN/email via template variables
TMP_TMPL="$(mktemp)"
sed "s/@CN@/${USER}/g" "$CLIENT_TMPL" > "$TMP_TMPL"

echo "[INFO] Signing client certificate"
certtool --generate-certificate   --load-privkey "$KEY"  --load-ca-certificate "$CA_PEM" --load-ca-privkey "$CA_KEY" --template "$TMP_TMPL" --outfile "$CERT"

rm -f "$TMP_TMPL" "$CSR"
chmod 600 "$KEY" "$CERT"

echo "[OK] Client cert created: $CERT"
echo "[OK] CA: $CA_PEM"

if [[ "$EXPORT" == "export" ]]; then
  echo "[INFO] Exporting to PKCS#12: $P12"
  # shellcheck disable=SC2086
  certtool --to-p12 --load-privkey "$KEY" --load-certificate "$CERT" --pkcs-cipher 3des-pkcs12 --outfile "$P12" --outder
  chmod 600 "$P12"
  echo "[OK] Exported: $P12"
fi
