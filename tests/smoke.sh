#!/usr/bin/env bash
# Smoke test for the image: start ocserv, log in with a password and with a
# client certificate, pass traffic through the tunnel, reload a new server
# certificate without dropping the session, stop ocserv and check
# that its iptables rules are gone.
#
# Usage: tests/smoke.sh [image]        (default image: ocserv:ci)
# Needs on the host: docker, /dev/net/tun, openconnect, ocproxy, curl,
# openssl, python3, timeout, iptables-save (run as root or with sudo -n).
# The container uses host networking and port 443 and adds NAT rules on the
# host; run it on a CI runner or a throwaway VM.
set -euo pipefail
# Under pipefail, "cmd | grep -q" fails when grep exits early and cmd gets
# SIGPIPE on a later write; read the whole output (grep >/dev/null) instead.

IMAGE="${1:-ocserv:ci}"
NAME="ocserv-smoke"
SOCKS_PORT=11080
HTTP_PORT=18080
USER_NAME="smoke"
USER_PASS="smoke-pass-$RANDOM$RANDOM"
WORK="$(mktemp -d)"
OC_PID=""
HTTP_PID=""

log()  { echo "[smoke] $*"; }
fail() { echo "[smoke] FAIL: $*" >&2; exit 1; }
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }

stop_client() {
  [ -n "$OC_PID" ] || return 0
  kill "$OC_PID" 2>/dev/null || true
  for _ in $(seq 10); do kill -0 "$OC_PID" 2>/dev/null || break; sleep 1; done
  kill -9 "$OC_PID" 2>/dev/null || true
  OC_PID=""
}

cleanup() {
  status=$?
  stop_client
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
  if [ "$status" -ne 0 ]; then
    echo "----- container log -----" >&2
    docker logs "$NAME" >&2 2>&1 || true
  fi
  docker stop -t 15 "$NAME" >/dev/null 2>&1 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Address of this host as seen through the tunnel (traffic to it is
# delivered locally, so the check does not depend on the internet).
HOST_IP="$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
[ -n "$HOST_IP" ] || fail "cannot find the host address"
[ -c /dev/net/tun ] || fail "/dev/net/tun is missing"

TOKEN="smoke-$RANDOM$RANDOM"
mkdir "$WORK/www" && echo "$TOKEN" > "$WORK/www/token"
python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 --directory "$WORK/www" >/dev/null 2>&1 &
HTTP_PID=$!

docker rm -f "$NAME" >/dev/null 2>&1 || true
log "starting $IMAGE"
docker run -d --name "$NAME" --network host \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -e SRV_CN=vpn.example.test -e SRV_CA="Smoke Test CA" \
  -e VPN_SUBNET=10.10.10.0/24 -e ENABLE_DTLS=false \
  -e USE_IPTABLES_NFT="${USE_IPTABLES_NFT:-true}" \
  "$IMAGE" >/dev/null

for _ in $(seq 60); do
  docker logs "$NAME" 2>&1 | grep "initialized OpenConnect VPN Server" >/dev/null && break
  docker inspect -f '{{.State.Running}}' "$NAME" | grep -q true || fail "container exited"
  sleep 1
done
docker logs "$NAME" 2>&1 | grep "initialized OpenConnect VPN Server" >/dev/null || fail "ocserv did not start in 60 s"
log "ocserv started: $(docker exec "$NAME" ocserv --version 2>&1 | grep -m1 "OpenConnect")"

log "generated server certificate names the server in subjectAltName"
docker exec "$NAME" openssl x509 -in /etc/ocserv/cert/server-cert.pem -noout -ext subjectAltName \
  | grep -q "DNS:vpn.example.test" || fail "no subjectAltName DNS:vpn.example.test in the server certificate"

docker exec "$NAME" sh -c "printf '%s:*:%s\n' '$USER_NAME' \"\$(openssl passwd -6 '$USER_PASS')\" >> /etc/ocserv/auth/passwd"

PIN="pin-sha256:$(docker exec "$NAME" cat /etc/ocserv/cert/server-cert.pem \
  | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64)"
URL="https://127.0.0.1:443/"
OC=(openconnect --non-inter --servercert "$PIN")

# Start a tunnel with the given openconnect options and check traffic.
# Usage: tunnel_check <label> <stdin file> <openconnect options...>
# (a background job would otherwise get /dev/null as stdin).
tunnel_check() {
  label="$1"; input="$2"; shift 2
  "${OC[@]}" "$@" --script-tun --script "ocproxy -D $SOCKS_PORT" "$URL" <"$input" >"$WORK/oc.log" 2>&1 &
  OC_PID=$!
  got=""
  for _ in $(seq 30); do
    got="$(curl -s -m 5 --socks5 "127.0.0.1:$SOCKS_PORT" "http://$HOST_IP:$HTTP_PORT/token" || true)"
    [ "$got" = "$TOKEN" ] && break
    kill -0 "$OC_PID" 2>/dev/null || { cat "$WORK/oc.log" >&2; fail "$label: openconnect exited"; }
    sleep 1
  done
  [ "$got" = "$TOKEN" ] || { cat "$WORK/oc.log" >&2; fail "$label: no traffic through the tunnel"; }
}

log "wrong password is rejected"
if echo "wrong-$USER_PASS" | timeout 30 "${OC[@]}" --passwd-on-stdin -u "$USER_NAME" --authenticate "$URL" >"$WORK/bad.log" 2>&1; then
  fail "login with a wrong password succeeded"
fi

log "password login, traffic through the tunnel"
echo "$USER_PASS" > "$WORK/pass"
tunnel_check "password" "$WORK/pass" --passwd-on-stdin -u "$USER_NAME"
docker exec "$NAME" occtl show users | grep -w "$USER_NAME" >/dev/null || fail "occtl does not list the password session"

log "internet through the tunnel (NAT)"
code=""
for target in https://example.com/ https://www.google.com/generate_204 https://cloudflare.com/cdn-cgi/trace; do
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' --socks5-hostname "127.0.0.1:$SOCKS_PORT" "$target" || true)"
  case "$code" in 2??) break ;; esac
done
case "$code" in 2??) ;; *) fail "no internet through the tunnel (last HTTP code '$code')" ;; esac

log "certificate reload keeps the session"
served_pin() {
  echo | timeout 10 openssl s_client -connect 127.0.0.1:443 2>/dev/null \
    | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | base64
}
docker exec "$NAME" sh -c 'cd /etc/ocserv/cert &&
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj /CN=vpn.example.test -keyout new-key.pem -out new-cert.pem 2>/dev/null &&
  mv new-key.pem server-key.pem && mv new-cert.pem server-cert.pem && occtl reload' >/dev/null \
  || fail "could not replace the certificate"
NEW_PIN="pin-sha256:$(docker exec "$NAME" cat /etc/ocserv/cert/server-cert.pem \
  | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64)"
for _ in $(seq 10); do [ "pin-sha256:$(served_pin)" = "$NEW_PIN" ] && break; sleep 1; done
[ "pin-sha256:$(served_pin)" = "$NEW_PIN" ] || fail "ocserv still serves the old certificate after reload"
kill -0 "$OC_PID" 2>/dev/null || fail "the session was dropped by the reload"
[ "$(curl -s -m 5 --socks5 "127.0.0.1:$SOCKS_PORT" "http://$HOST_IP:$HTTP_PORT/token")" = "$TOKEN" ] \
  || fail "no traffic through the tunnel after the reload"
PIN="$NEW_PIN"
OC=(openconnect --non-inter --servercert "$PIN")
stop_client

log "certificate login, traffic through the tunnel"
docker exec "$NAME" ocs client issue smoke-cert >/dev/null 2>&1 || fail "ocs client issue failed"
docker cp -q "$NAME:/etc/ocserv/auth/clients/smoke-cert-cert.pem" "$WORK/cert.pem"
docker cp -q "$NAME:/etc/ocserv/auth/clients/smoke-cert-key.pem" "$WORK/key.pem"
tunnel_check "certificate" /dev/null -c "$WORK/cert.pem" -k "$WORK/key.pem"
docker exec "$NAME" occtl show users | grep -w "smoke-cert" >/dev/null || fail "occtl does not list the certificate session"
stop_client

log "reissued client certificate: a matching new pair that logs in"
docker exec "$NAME" ocs client issue smoke-cert >/dev/null 2>&1 || fail "reissue failed"
docker cp -q "$NAME:/etc/ocserv/auth/clients/smoke-cert-cert.pem" "$WORK/cert2.pem"
docker cp -q "$NAME:/etc/ocserv/auth/clients/smoke-cert-key.pem" "$WORK/key2.pem"
cmp -s "$WORK/cert.pem" "$WORK/cert2.pem" && fail "reissue kept the old certificate"
[ "$(openssl x509 -in "$WORK/cert2.pem" -noout -pubkey | openssl sha256)" = \
  "$(openssl pkey -in "$WORK/key2.pem" -pubout | openssl sha256)" ] || fail "reissued key does not match its certificate"
tunnel_check "reissued certificate" /dev/null -c "$WORK/cert2.pem" -k "$WORK/key2.pem"
stop_client

log "ocs matches user names literally"
docker exec "$NAME" sh -c "printf 'axb:*:x\n' >> /etc/ocserv/auth/passwd"
if docker exec "$NAME" ocs user del a.b >/dev/null 2>&1; then fail "'ocs user del a.b' acted on user 'axb'"; fi
users="$(docker exec "$NAME" ocs user list)"
echo "$users" | grep -qw axb || fail "user 'axb' is gone"
for bad in ../x -x .hidden; do
  if docker exec "$NAME" sh /scripts/make-client.sh "$bad" >/dev/null 2>&1; then
    fail "make-client.sh accepted the name '$bad'"
  fi
done

log "a certificate from another CA is rejected"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$USER_NAME" \
  -keyout "$WORK/foreign-key.pem" -out "$WORK/foreign-cert.pem" >/dev/null 2>&1
if timeout 30 "${OC[@]}" -c "$WORK/foreign-cert.pem" -k "$WORK/foreign-key.pem" --authenticate "$URL" \
     </dev/null >"$WORK/foreign.log" 2>&1 && grep -q '^COOKIE=' "$WORK/foreign.log"; then
  fail "login with a certificate from another CA succeeded"
fi

docker exec "$NAME" occtl show status | grep "Status: online" >/dev/null || fail "occtl status is not online"

log "stop: iptables rules are removed"
docker stop -t 15 "$NAME" >/dev/null
rules="$( { as_root iptables-save 2>/dev/null; as_root iptables-legacy-save 2>/dev/null; } | grep -c OCSERV || true)"
[ "$rules" = "0" ] || fail "$rules OCSERV iptables rules left after stop"

log "a server key that does not match the certificate stops the start"
mkdir "$WORK/pair"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=a \
  -keyout "$WORK/pair/server-key.pem" -out "$WORK/pair/server-cert.pem" >/dev/null 2>&1
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/pair/server-key.pem"
chmod 644 "$WORK/pair/server-key.pem"
if timeout 60 docker run --rm -v "$WORK/pair:/etc/ocserv/cert" \
     -e SRV_CN=vpn.example.test -e SRV_CA="Smoke Test CA" "$IMAGE" >"$WORK/pair.log" 2>&1; then
  fail "the container started with a mismatched server key"
fi
grep -q "does not match" "$WORK/pair.log" || { cat "$WORK/pair.log" >&2; fail "no clear error for a mismatched server key"; }

log "OK"
