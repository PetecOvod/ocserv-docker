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
#   ACME_DNS_SHA256=<sha256>  # optional: pin the DNS plugin file (dns mode)
#
# After a new certificate is installed, a running ocserv is told to reload it
# (occtl reload): connected users stay connected, new connections get the new
# certificate. No container restart is needed.
#
# Exit codes: 0 = issued or not due yet (both fine), anything else = failure.
#
# Internal defaults (do not expose via compose):
#   ACME_HOME=/etc/acme
#   HTTP_PORT=80
#   ECC=true, STAGING=false

MODE="$1"
[ -z "$MODE" ] && { echo "Usage: $0 <http|dns>"; exit 1; }

# Keys and acme.sh state are private; also keeps the check below from
# rejecting files this script creates itself.
umask 077

# One run at a time (a scheduled run and a manual one must not interleave).
exec 9>/run/get-cert.lock
flock -n 9 || { echo "[ERR] Another get-cert.sh run is in progress"; exit 9; }

# --- defaults ---
ACME_HOME="/etc/acme"
ACME_WORKDIR="${ACME_WORKDIR:-/usr/local/share}"
DNSAPI_DIR="${DNSAPI_DIR:-$ACME_WORKDIR/dnsapi}"
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

# acme.sh and this script run files from $ACME_HOME as shell code, as root
# (account.conf, the domain configs, provider.env). Whoever can edit them
# runs code here, so none of them may be writable by group or others, and
# none may be a symlink (its target could be anywhere).
_unsafe="$(find "$ACME_HOME" \( -type l -o -perm -020 -o -perm -002 \) 2>/dev/null)"
if [ -n "$_unsafe" ]; then
  echo "[ERR] Symlink, or writable by group or others (fix with: chmod -R go-w $ACME_HOME):"
  echo "$_unsafe" | sed 's/^/      /'
  exit 7
fi

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
    CURRENT_EMAIL="$(sed -n "s/^ACCOUNT_EMAIL='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$ACME_HOME/account.conf" | tail -n 1)"
    if [ "$CURRENT_EMAIL" != "$ACME_ACCOUNT_EMAIL" ]; then
      echo "[INFO] Updating ACME account email: '$CURRENT_EMAIL' -> '$ACME_ACCOUNT_EMAIL'"
      "$ACME_BIN" --home "$ACME_HOME" --update-account --server "$SERVER" -m "$ACME_ACCOUNT_EMAIL"
    fi
  fi
fi

# acme.sh --issue exits with 2 when the certificate is not due for renewal
# yet; that is not an error, and the install step below still runs.
ISSUE_RC=0
case "$MODE" in
  http)
    echo "[INFO] Issuing via HTTP-01 (standalone) on port $HTTP_PORT for $DOMAIN"
    "$ACME_BIN" --home "$ACME_HOME" --server "$SERVER" \
      --issue --standalone --httpport "$HTTP_PORT" -d "$DOMAIN" $EFLAG $SFLAG || ISSUE_RC=$?
    ;;
  dns)
    PROVIDER_ENV="$ACME_HOME/provider.env"
    if [ -f "$PROVIDER_ENV" ]; then
      # Auto-export all variables from provider.env so acme.sh and dnsapi see them
      set -a
      # shellcheck source=/dev/null
      . "$PROVIDER_ENV"
      set +a
    fi
    if [ -z "${ACME_DNS:-}" ]; then
      echo "[ERR] DNS mode selected but ACME_DNS is not set."
      echo "      Put provider settings into $PROVIDER_ENV, e.g.:"
      echo "        ACME_DNS=dns_cf"
      echo "        CF_Token=..."
      exit 3
    fi
    # ACME_DNS becomes a file name: allow only acme.sh plugin names.
    case "$ACME_DNS" in
      *[!a-z0-9_]*|dns_) _dns_ok=false ;;
      dns_*) _dns_ok=true ;;
      *) _dns_ok=false ;;
    esac
    if [ "$_dns_ok" != true ]; then
      echo "[ERR] ACME_DNS='$ACME_DNS' is not a DNS plugin name (expected dns_<provider>)"
      exit 3
    fi
    # Ensure required dnsapi hook script exists for selected ACME_DNS provider
    if [ -n "${ACME_DNS:-}" ]; then
      _plugin_file="${ACME_DNS}.sh"
      _plugin_path="$DNSAPI_DIR/$_plugin_file"
      # A plugin already in the volume is checked on every run, not only
      # when it is downloaded: it runs with the DNS API token.
      if [ -f "$_plugin_path" ] && [ -n "${ACME_DNS_SHA256:-}" ]; then
        if ! echo "$ACME_DNS_SHA256  $_plugin_path" | sha256sum -c - >/dev/null 2>&1; then
          echo "[ERR] $_plugin_path sha256 does not match ACME_DNS_SHA256; delete it to download it again"
          exit 6
        fi
        echo "[INFO] $_plugin_file sha256 verified"
      fi
      if [ ! -f "$_plugin_path" ]; then
        echo "[INFO] DNS API plugin $ACME_DNS not found at $_plugin_path, downloading..."
        mkdir -p "$DNSAPI_DIR"
        # Same release as the acme.sh in the image (ACME_VERSION), not master.
        _plugin_url="https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_VERSION:?ACME_VERSION is not set}/dnsapi/$_plugin_file"
        if ! curl -fsSLo "$_plugin_path.tmp" "$_plugin_url"; then
          rm -f "$_plugin_path.tmp"
          echo "[ERR] Failed to download DNS API plugin from $_plugin_url"
          exit 5
        fi
        # Optional: ACME_DNS_SHA256 pins the exact plugin file (provider.env or compose environment)
        if [ -n "${ACME_DNS_SHA256:-}" ]; then
          if ! echo "$ACME_DNS_SHA256  $_plugin_path.tmp" | sha256sum -c - >/dev/null 2>&1; then
            rm -f "$_plugin_path.tmp"
            echo "[ERR] $_plugin_file sha256 does not match ACME_DNS_SHA256; not using it"
            exit 6
          fi
          echo "[INFO] $_plugin_file sha256 verified"
        else
          echo "[WARN] ACME_DNS_SHA256 not set; plugin is not checksum-verified"
        fi
        mv "$_plugin_path.tmp" "$_plugin_path"
        chmod +x "$_plugin_path"
        echo "[INFO] Downloaded DNS API plugin $ACME_DNS ($ACME_VERSION) from $_plugin_url"
      fi
    fi
    echo "[INFO] Issuing via DNS-01 using plugin: $ACME_DNS for $DOMAIN"
    "$ACME_BIN" --home "$ACME_HOME" --server "$SERVER" \
      --issue --dns "$ACME_DNS" -d "$DOMAIN" $EFLAG $SFLAG || ISSUE_RC=$?
    ;;
  *)
    echo "[ERR] Unknown mode: $MODE"; exit 4;;
esac

case "$ISSUE_RC" in
  0) echo "[INFO] Certificate issued" ;;
  2) echo "[INFO] Certificate is not due for renewal yet" ;;
  *) echo "[ERR] acme.sh --issue failed (exit $ISSUE_RC)"; exit "$ISSUE_RC" ;;
esac

# --- install: stage, check, swap, reload ---
# The certificate goes to a staging directory first and replaces the live
# files only if it is valid, its key matches, and it differs from them.
CERT_DIR=/etc/ocserv/cert
STAGE="$CERT_DIR/.staging"
rm -rf "$STAGE"
mkdir -m 700 "$STAGE"
"$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$DOMAIN" \
  --key-file       "$STAGE/server-key.pem" \
  --fullchain-file "$STAGE/server-cert.pem" \
  $EFLAG

_pub_of_cert() { openssl x509 -in "$1" -noout -pubkey | openssl sha256; }
_pub_of_key()  { openssl pkey -in "$1" -pubout | openssl sha256; }
if ! openssl x509 -in "$STAGE/server-cert.pem" -noout -checkend 0 >/dev/null 2>&1; then
  echo "[ERR] New certificate is invalid or expired; live certificate left as is"
  rm -rf "$STAGE"; exit 8
fi
if [ "$(_pub_of_cert "$STAGE/server-cert.pem")" != "$(_pub_of_key "$STAGE/server-key.pem")" ]; then
  echo "[ERR] New key does not match the new certificate; live certificate left as is"
  rm -rf "$STAGE"; exit 8
fi

# Set while a new certificate is installed but not yet loaded by ocserv, so
# that a failed reload is retried on the next run.
PENDING="$CERT_DIR/.reload-pending"

_reload() {
  if occtl reload >/dev/null 2>&1; then
    echo "[INFO] ocserv reloaded the certificate"
  elif [ -s /run/ocserv.pid ] && kill -HUP "$(cat /run/ocserv.pid)" 2>/dev/null; then
    echo "[INFO] ocserv reloaded the certificate (SIGHUP)"
  elif pgrep ocserv >/dev/null 2>&1; then
    echo "[ERR] ocserv is running but did not accept the reload; it will be retried on the next run"
    exit 10
  else
    echo "[INFO] ocserv is not running; it will use the new certificate when it starts"
  fi
  rm -f "$PENDING"
}

if cmp -s "$STAGE/server-cert.pem" "$CERT_DIR/server-cert.pem" &&
   cmp -s "$STAGE/server-key.pem" "$CERT_DIR/server-key.pem"; then
  rm -rf "$STAGE"
  if [ -f "$PENDING" ]; then
    echo "[INFO] Installed certificate is current, but its reload is still pending"
    _reload
  else
    echo "[INFO] Installed certificate is already current; nothing to reload"
  fi
  exit 0
fi

chmod 600 "$STAGE/server-key.pem"
chmod 644 "$STAGE/server-cert.pem"
: > "$PENDING"
mv -f "$STAGE/server-key.pem" "$CERT_DIR/server-key.pem"
mv -f "$STAGE/server-cert.pem" "$CERT_DIR/server-cert.pem"
rm -rf "$STAGE"
echo "[INFO] Installed the new certificate to $CERT_DIR"

# ocserv reloads its certificate and key on "occtl reload" (or SIGHUP to
# the main process); sessions in progress are not interrupted.
_reload
