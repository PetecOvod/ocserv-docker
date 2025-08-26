#!/bin/sh
set -e

CERT_DIR="/etc/ocserv"
TEMPL_DIR="$CERT_DIR/templates"
AUTH_DIR="$CERT_DIR/auth"

log() { echo "[START.SH] $*"; }

# -----------------------------
# iptables selector via env
# -----------------------------
# USE_IPTABLES_NFT: true|false (default: true)
USE_IPTABLES_NFT="${USE_IPTABLES_NFT:-true}"
_lower="$(echo "$USE_IPTABLES_NFT" | tr '[:upper:]' '[:lower:]')"
if [ "$_lower" = "false" ] || [ "$_lower" = "0" ] || [ "$_lower" = "no" ]; then
  IPT="$(command -v iptables-legacy 2>/dev/null || echo /usr/sbin/iptables-legacy)"
else
  IPT="$(command -v iptables 2>/dev/null || echo /usr/sbin/iptables)"
fi
IPT_VER="$($IPT -V 2>/dev/null | head -n1 || true)"
log "Using iptables binary: $IPT ${IPT_VER:+($IPT_VER)}"

# -----------------------------
# VPN_SUBNET handling (CIDR)
# -----------------------------
VPN_SUBNET="${VPN_SUBNET:-10.10.10.0/24}"

# Auto-detect egress interface from default route
detect_wan_if() {
  ip -4 route list default 2>/dev/null | awk '
    /default/ {
      for (i=1; i<=NF; i++) if ($i=="dev") { print $(i+1); exit }
    }'
}
WAN_IF="$(detect_wan_if)"; [ -z "$WAN_IF" ] && WAN_IF="eth0"
log "Using WAN_IF='${WAN_IF}', VPN_SUBNET='${VPN_SUBNET}'"

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
# iptables helpers + dedicated chains
# -------------------------------------
NAT_CHAIN="OCSERV_NAT"
FWD_CHAIN="OCSERV_FWD"

ipt_exists_chain() { $IPT -t "$1" -L "$2" >/dev/null 2>&1; }  # table, chain
ipt_ensure_chain() { ipt_exists_chain "$1" "$2" || { $IPT -t "$1" -N "$2"; log "➕ [CHAIN] ($1) $2"; }; }
ipt_flush_del_chain() {
  if ipt_exists_chain "$1" "$2"; then
    $IPT -t "$1" -F "$2" || true
    $IPT -t "$1" -X "$2" || true
    log "🗑️ [CHAIN] ($1) $2 flushed & deleted"
  fi
}

ipt_has_rule() { $IPT -t "$1" -C $2 >/dev/null 2>&1; }       # table, "CHAIN ...rule..."
ipt_add_rule() { ipt_has_rule "$1" "$2" || { $IPT -t "$1" -A $2; log "➕ [ADD]   ($1) $2"; }; }
ipt_ins_rule() { ipt_has_rule "$1" "$2" || { $IPT -t "$1" -I $2; log "➕ [INS]   ($1) $2"; }; }
ipt_del_rule() { $IPT -t "$1" -D $2 >/dev/null 2>&1 && log "🗑️ [DEL]   ($1) $2" || true; }

apply_iptables() {
  # clean possible leftovers first
  cleanup_iptables quiet

  # create dedicated chains
  ipt_ensure_chain nat   "$NAT_CHAIN"
  ipt_ensure_chain filter "$FWD_CHAIN"

  # jump rules (insert near top for FORWARD, append for POSTROUTING)
  ipt_ins_rule filter "FORWARD -j $FWD_CHAIN"
  ipt_add_rule nat    "POSTROUTING -j $NAT_CHAIN"

  # actual rules inside chains
  # NAT: MASQUERADE traffic from VPN_SUBNET going out via WAN_IF
  ipt_add_rule nat    "$NAT_CHAIN -s $VPN_SUBNET -o $WAN_IF -j MASQUERADE"
  # FORWARD: tunnel -> WAN
  ipt_add_rule filter "$FWD_CHAIN -i vpns+ -o $WAN_IF -s $VPN_SUBNET -j ACCEPT"
  # FORWARD: WAN -> tunnel (responses)
  ipt_add_rule filter "$FWD_CHAIN -i $WAN_IF -o vpns+ -d $VPN_SUBNET -m state --state RELATED,ESTABLISHED -j ACCEPT"
  log "iptables rules applied"
}

cleanup_iptables() {
  [ "$1" = "quiet" ] || log "Cleaning iptables rules..."
  # remove jumps if present
  ipt_del_rule filter "FORWARD -j $FWD_CHAIN"
  ipt_del_rule nat    "POSTROUTING -j $NAT_CHAIN"
  # delete our chains
  ipt_flush_del_chain filter "$FWD_CHAIN"
  ipt_flush_del_chain nat    "$NAT_CHAIN"
}

# -------------------------------------
# Files & templates
# -------------------------------------
# Ensure passwd exists (when auth volume is empty)
if [ ! -f "$AUTH_DIR/passwd" ]; then
  : > "$AUTH_DIR/passwd"
  chmod 600 "$AUTH_DIR/passwd"
  log "Created empty $AUTH_DIR/passwd"
fi

# Self-signed certs if none
if [ ! -f "$CERT_DIR/cert/ca.pem" ] && [ -f "$TEMPL_DIR/ca.tmpl" ]; then
  log "Generating CA certificate..."
  envsubst < "$TEMPL_DIR/ca.tmpl" > /tmp/ca.tmpl
  certtool --generate-privkey --outfile "$CERT_DIR/cert/ca-key.pem"
  certtool --generate-self-signed \
    --load-privkey "$CERT_DIR/cert/ca-key.pem" \
    --outfile "$CERT_DIR/cert/ca.pem" \
    --template /tmp/ca.tmpl
fi
if [ ! -f "$CERT_DIR/cert/server-cert.pem" ] && [ -f "$TEMPL_DIR/server.tmpl" ]; then
  log "Generating server certificate..."
  envsubst < "$TEMPL_DIR/server.tmpl" > /tmp/server.tmpl
  certtool --generate-privkey --outfile "$CERT_DIR/cert/server-key.pem"
  certtool --generate-certificate \
    --load-privkey "$CERT_DIR/cert/server-key.pem" \
    --load-ca-certificate "$CERT_DIR/cert/ca.pem" \
    --load-ca-privkey "$CERT_DIR/cert/ca-key.pem" \
    --outfile "$CERT_DIR/cert/server-cert.pem" \
    --template /tmp/server.tmpl
fi

# Render ocserv.conf from template (if present)
if [ -f "$TEMPL_DIR/ocserv.conf.tmpl" ]; then
  log "Rendering ocserv.conf from template..."
  envsubst < "$TEMPL_DIR/ocserv.conf.tmpl" > "$CERT_DIR/ocserv.conf"
fi

# -------------------------------------
# Trap & lifecycle: apply/cleanup iptables, forward signals
# -------------------------------------
ocserv_pid=""
shutdown() {
  code=$?
  log "Shutting down (code=$code)"
  # stop ocserv if still running
  if [ -n "$ocserv_pid" ] && kill -0 "$ocserv_pid" 2>/dev/null; then
    kill -TERM "$ocserv_pid" 2>/dev/null || true
    wait "$ocserv_pid" 2>/dev/null || true
  fi
  # cleanup iptables
  cleanup_iptables
  exit $code
}
on_term() {
  log "Received termination signal, stopping ocserv..."
  [ -n "$ocserv_pid" ] && kill -TERM "$ocserv_pid" 2>/dev/null || true
}
trap on_term TERM INT
trap shutdown EXIT

# Apply rules before starting ocserv
apply_iptables

# Start ocserv in background (not exec, so traps will run)
log "Starting OpenConnect VPN server..."
ocserv -f -c "$CERT_DIR/ocserv.conf" -d 2 &
ocserv_pid=$!

# Wait for ocserv to exit (container exits with same code; cleanup runs in trap)
wait "$ocserv_pid"