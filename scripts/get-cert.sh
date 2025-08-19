#!/bin/sh
DOMAIN="$1"
EMAIL="$2"
CERT_DIR="/etc/ocserv"

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo "Usage: $0 <domain> <email>"
  exit 1
fi

pkill ocserv || true
sleep 2

certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"

cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem "$CERT_DIR/cert/server-cert.pem"
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem "$CERT_DIR/cert/server-key.pem"

exec ocserv -f -c "$CERT_DIR/ocserv.conf"
