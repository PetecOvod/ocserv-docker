#!/bin/sh
set -e

# One-command certificate issuance via acme.sh
# Usage:
#   ./scripts/get-cert.sh http
#   ./scripts/get-cert.sh dns
#
# Domain:
#   DOMAIN := SRV_CN (if contains a dot)
#          or "${SRV_CN}.${ACME_TLD}" (if SRV_CN has no dot and ACME_TLD is set)
#
# External env:
#   ACME_ACCOUNT_EMAIL=you@example.com
#   ACME_SERVER=letsencrypt   # or zerossl, buypass, ...
#
# Internal defaults (do not expose via compose):
#   ACME_HOME=/etc/acme
#   HTTP_PORT=80
#   ECC=true, STAGING=false

MODE="$1"
[ -z "$MODE" ] && { echo "Usage: $0 <http|dns>"; exit 1; }

# --- defaults ---
ACME_HOME="/etc/acme"
HTTP_PORT=80
ECC=true
STAGING=false

# --- resolve DOMAIN ---
if [ -z "${SRV_CN:-}" ]; then
  echo "[ERR] SRV_CN is not set"; exit 2
fi
DOMAIN="$SRV_CN"
echo "$SRV_CN" | grep -q '\.' || { [ -n "${ACME_TLD:-}" ] && DOMAIN="${SRV_CN}.${ACME_TLD}"; }
echo "$DOMAIN" | grep -q '\.' || { echo "[ERR] could not derive FQDN from SRV_CN/ACME_TLD"; exit 2; }

SERVER="${ACME_SERVER:-letsencrypt}"

# --- acme.sh must be present ---
ACME_BIN="$(command -v acme.sh 2>/dev/null || true)"
if [ -z "$ACME_BIN" ]; then
  echo "[ERR] acme.sh not found in PATH. Install it in the image and symlink to /usr/local/bin/acme.sh."; exit 127
fi

mkdir -p "$ACME_HOME" /etc/ocserv/cert

# flags
_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
EFLAG=""; [ "$(_lower "$ECC")" = "true" ] && EFLAG="--ecc"
SFLAG=""; [ "$(_lower "$STAGING")" = "true" ] && SFLAG="--staging"

echo "[INFO] DOMAIN=$DOMAIN  SERVER=$SERVER  ECC=$ECC  STAGING=$STAGING  ACME_HOME=$ACME_HOME"

# --- register / update account ---
if [ ! -f "$ACME_HOME/account.conf" ]; then
  echo "[INFO] Registering ACME account"
  if [ -n "${ACME_ACCOUNT_EMAIL:-}" ]; then
    "$ACME_BIN" --home "$ACME_HOME" --register-account --server "$SERVER" -m "$ACME_ACCOUNT_EMAIL" $SFLAG
  else
    echo "[WARN] ACME_ACCOUNT_EMAIL not set; registering without contact email"
    "$ACME_BIN" --home "$ACME_HOME" --register-account --server "$SERVER" $SFLAG
  fi
else
  if [ -n "${ACME_ACCOUNT_EMAIL:-}" ]; then
    CURRENT_EMAIL="$(. "$ACME_HOME/account.conf"; echo "${ACCOUNT_EMAIL:-}")"
    if [ "$CURRENT_EMAIL" != "$ACME_ACCOUNT_EMAIL" ]; then
      echo "[INFO] Updating ACME account email: '$CURRENT_EMAIL' -> '$ACME_ACCOUNT_EMAIL'"
      "$ACME_BIN" --home "$ACME_HOME" --update-account --server "$SERVER" -m "$ACME_ACCOUNT_EMAIL"
    fi
  fi
fi

case "$MODE" in
  http)
    echo "[INFO] Issuing via HTTP-01 (standalone) on port $HTTP_PORT for $DOMAIN"
    "$ACME_BIN" --home "$ACME_HOME" --server "$SERVER" \
      --issue --standalone --httpport "$HTTP_PORT" -d "$DOMAIN" $EFLAG $SFLAG
    ;;
  dns)
    PROVIDER_ENV="$ACME_HOME/provider.env"
    [ -f "$PROVIDER_ENV" ] && . "$PROVIDER_ENV"
    if [ -z "${ACME_DNS:-}" ]; then
      echo "[ERR] DNS mode selected but ACME_DNS is not set."
      echo "      Put provider settings into $PROVIDER_ENV, e.g.:"
      echo "        ACME_DNS=dns_cf"
      echo "        CF_Token=..."
      exit 3
    fi
    echo "[INFO] Issuing via DNS-01 using plugin: $ACME_DNS for $DOMAIN"
    "$ACME_BIN" --home "$ACME_HOME" --server "$SERVER" \
      --issue --dns "$ACME_DNS" -d "$DOMAIN" $EFLAG $SFLAG
    ;;
  *)
    echo "[ERR] Unknown mode: $MODE"; exit 4;;
esac

echo "[INFO] Installing certs to /etc/ocserv/cert"
"$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$DOMAIN" \
  --key-file       /etc/ocserv/cert/server-key.pem \
  --fullchain-file /etc/ocserv/cert/server-cert.pem \
  $EFLAG

echo "[INFO] Done. Restart container: docker restart ocserv"