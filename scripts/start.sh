#!/bin/sh

set -e
CERT_DIR="/etc/ocserv"

if [ ! -f "$CERT_DIR/ca.pem" ]; then
  echo "[INFO] Generating CA certificate..."
  envsubst < "$CERT_DIR/ca.tmpl" > /tmp/ca.tmpl
  certtool --generate-privkey --outfile "$CERT_DIR/ca-key.pem"
  certtool --generate-self-signed --load-privkey "$CERT_DIR/ca-key.pem" \
           --outfile "$CERT_DIR/ca.pem" --template /tmp/ca.tmpl
fi

if [ ! -f "$CERT_DIR/server-cert.pem" ]; then
  echo "[INFO] Generating server certificate..."
  envsubst < "$CERT_DIR/server.tmpl" > /tmp/server.tmpl
  certtool --generate-privkey --outfile "$CERT_DIR/server-key.pem"
  certtool --generate-certificate \
           --load-privkey "$CERT_DIR/server-key.pem" \
           --load-ca-certificate "$CERT_DIR/ca.pem" \
           --load-ca-privkey "$CERT_DIR/ca-key.pem" \
           --outfile "$CERT_DIR/server-cert.pem" \
           --template /tmp/server.tmpl
fi

echo "[INFO] Starting OpenConnect VPN server..."
exec ocserv -f -c "$CERT_DIR/ocserv.conf"
