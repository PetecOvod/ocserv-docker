#!/bin/sh
set -e

CERT_DIR="/etc/ocserv"
TEMPL_DIR="$CERT_DIR/templates"

log() { echo "[START.SH] $*"; }

# -----------------------------
# iptables selector via env
# -----------------------------
# USE_IPTABLES_NFT: true|false (default: true)
USE_IPTABLES_NFT="${USE_IPTABLES_NFT:-true}"
_lower="$(echo "$USE_IPTABLES_NFT" | tr '[:upper:]' '[:lower:]')"
if [ "$_lower" = "false" ] || [ "$_lower" = "0" ] || [ "$_lower" = "no" ]; then
  IPT="$(command -v iptables-legacy 2>/dev/null || echo iptables-legacy)"
else
  IPT="$(command -v iptables 2>/dev/null || echo iptables)"
fi
IPT_VER="$($IPT -V 2>/dev/null | head -n1 || true)"
log "Using iptables binary: $IPT ${IPT_VER:+($IPT_VER)}"

# -----------------------------
# VPN_SUBNET handling (CIDR)
# -----------------------------
VPN_SUBNET="${VPN_SUBNET:-10.10.10.0/24}"

# Auto-detect egress interface from default route (no env override)
detect_wan_if() {
  ip -4 route list default 2>/dev/null | awk '
    /default/ {
      for (i=1; i<=NF; i++) if ($i=="dev") { print $(i+1); exit }
    }'
}

# -------------------------------------
# CIDR → network + netmask (pure /bin/sh)
# -------------------------------------
ip2int() { IFS=.; set -- $1; echo $(( ($1<<24)+($2<<16)+($3<<8)+$4 )); }
int2ip() { a=$(( ($1>>24)&255 )); b=$(( ($1>>16)&255 )); c=$(( ($1>>8)&255 )); d=$(( $1&255 )); echo "$a.$b.$c.$d"; }
prefix2mask() {
  p=$1
  for i in 1 2 3 4; do
    if [ $p -ge 8 ]; then o=255; p=$((p-8))
    elif [ $p -gt 0 ]; then o=$((256 - (1 << (8-p)))); p=0
    else o=0; fi
    printf "%s" "$o"; [ $i -lt 4 ] && printf "."
  done
}
cidr_network_mask() {
  cidr="$1"; ip="${cidr%/*}"; pref="${cidr#*/}"
  mask="$(prefix2mask "$pref")"
  ipi="$(ip2int "$ip")"; mi="$(ip2int "$mask")"
  neti=$(( ipi & mi ))
  echo "$(int2ip "$neti") $mask"
}

set -- $(cidr_network_mask "$VPN_SUBNET")
IPV4_NETWORK="$1"; IPV4_NETMASK="$2"
export IPV4_NETWORK IPV4_NETMASK
log "Computed IPV4_NETWORK='${IPV4_NETWORK}', IPV4_NETMASK='${IPV4_NETMASK}'"

# -------------------------------------
# iptables helper (idempotent add/check/del)
# -------------------------------------
ipt() {
  table="$1"; action="$2"; shift 2
  rule="$*"
  if [ "$action" = "-C" ]; then
    $IPT -t "$table" -C $rule 2>/dev/null       && log "✅ [CHECK] ($table) $rule"       || log "❌ [MISS]  ($table) $rule"
  elif [ "$action" = "-A" ]; then
    $IPT -t "$table" -C $rule 2>/dev/null || {
      $IPT -t "$table" -A $rule
      log "➕ [ADD]   ($table) $rule"
    }
  elif [ "$action" = "-D" ]; then
    $IPT -t "$table" -C $rule 2>/dev/null && {
      $IPT -t "$table" -D $rule
      log "🗑️ [DEL]   ($table) $rule"
    }
  fi
}

# -------------------------------------
# NAT & FORWARD rules using WAN_IF/VPN_SUBNET
# -------------------------------------
ipt nat    -A POSTROUTING -s "$VPN_SUBNET" -o eth0 -j MASQUERADE
ipt filter -A FORWARD -i vpns+ -o eth0 -s "$VPN_SUBNET" -j ACCEPT
ipt filter -A FORWARD -i eth0 -o vpns+ -d "$VPN_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT

# -------------------------------------
# Ensure passwd exists even if auth/ is an empty bind-mount
# -------------------------------------
if [ ! -f /etc/ocserv/auth/passwd ]; then
  touch /etc/ocserv/auth/passwd
  chmod 600 /etc/ocserv/auth/passwd
  log "Created empty /etc/ocserv/auth/passwd"
fi

# -------------------------------------
# Self-signed cert generation (first run)
# -------------------------------------
if [ ! -f "$CERT_DIR/cert/ca.pem" ]; then
  log "Generating CA certificate..."
  if [ -f "$TEMPL_DIR/ca.tmpl" ]; then
    envsubst < "$TEMPL_DIR/ca.tmpl" > /tmp/ca.tmpl
    certtool --generate-privkey --outfile "$CERT_DIR/cert/ca-key.pem"
    certtool --generate-self-signed       --load-privkey "$CERT_DIR/cert/ca-key.pem"       --outfile "$CERT_DIR/cert/ca.pem"       --template /tmp/ca.tmpl
  else
    log "WARNING: $TEMPL_DIR/ca.tmpl not found, skipping CA generation."
  fi
fi

if [ ! -f "$CERT_DIR/cert/server-cert.pem" ]; then
  log "Generating server certificate..."
  if [ -f "$TEMPL_DIR/server.tmpl" ]; then
    envsubst < "$TEMPL_DIR/server.tmpl" > /tmp/server.tmpl
    certtool --generate-privkey --outfile "$CERT_DIR/cert/server-key.pem"
    certtool --generate-certificate       --load-privkey "$CERT_DIR/cert/server-key.pem"       --load-ca-certificate "$CERT_DIR/cert/ca.pem"       --load-ca-privkey "$CERT_DIR/cert/ca-key.pem"       --outfile "$CERT_DIR/cert/server-cert.pem"       --template /tmp/server.tmpl
  else
    log "WARNING: $TEMPL_DIR/server.tmpl not found, skipping server cert generation."
  fi
fi

# -------------------------------------
# Render ocserv.conf from template (if present)
# -------------------------------------
if [ -f "$TEMPL_DIR/ocserv.conf.tmpl" ]; then
  log "Rendering ocserv.conf from template..."
  envsubst < "$TEMPL_DIR/ocserv.conf.tmpl" > "$CERT_DIR/ocserv.conf"
fi

# -------------------------------------
# Start ocserv (foreground)
# -------------------------------------
log "Starting OpenConnect VPN server..."
exec ocserv -f -c "$CERT_DIR/ocserv.conf" -d 2
