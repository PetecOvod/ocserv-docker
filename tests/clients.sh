#!/usr/bin/env bash
# Client certificates: issue, list, renew, revoke (with the sessions and
# cookies of the revoked user), certificates with the old shared serial 01,
# and the revocation list (CRL) that start.sh keeps in place.
#
# Usage: tests/clients.sh [image]        (default image: ocserv:ci)
# Needs on the host: docker, /dev/net/tun, openconnect, ocproxy, openssl,
# timeout. The containers use host networking and port 443; run it on a CI
# runner or a throwaway VM, not at the same time as the other tests.
set -euo pipefail

IMAGE="${1:-ocserv:ci}"
NAME="ocserv-clients"
PREFIX="ocserv-clients-test"
WORK="$(mktemp -d)"
URL="https://127.0.0.1:443/"
VOLUMES=()
OC_PIDS=()
SOCKS=11180

log()  { echo "[clients] $*"; }
fail() { echo "[clients] FAIL: $*" >&2; exit 1; }

cleanup() {
  status=$?
  for p in "${OC_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  if [ "$status" -ne 0 ]; then
    echo "----- container log -----" >&2
    docker logs "$NAME" >&2 2>&1 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  [ "${#VOLUMES[@]}" -eq 0 ] || docker volume rm -f "${VOLUMES[@]}" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

volume() { docker volume create "$PREFIX-$1" >/dev/null; VOLUMES+=("$PREFIX-$1"); }

# Usage: run_args <cert volume>: docker run options shared by every start.
run_args() {
  echo --network host --cap-add NET_ADMIN --device /dev/net/tun \
    -v "$PREFIX-$1:/etc/ocserv/cert" -v "$PREFIX-auth:/etc/ocserv/auth" -v "$PREFIX-conf:/etc/ocserv/config" \
    -e SRV_CN=vpn.example.test -e SRV_CA=Clients-Test-CA -e ENABLE_DTLS=false -e AUTH_MODE=cert \
    -e USE_IPTABLES_NFT="${USE_IPTABLES_NFT:-true}"
}
start() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # shellcheck disable=SC2046
  docker run -d --name "$NAME" $(run_args cert) "$IMAGE" >/dev/null
  for _ in $(seq 60); do
    docker logs "$NAME" 2>&1 | grep "initialized OpenConnect VPN Server" >/dev/null && return 0
    docker inspect -f '{{.State.Running}}' "$NAME" | grep -q true || fail "container exited"
    sleep 1
  done
  fail "ocserv did not start in 60 s"
}
x() { docker exec "$NAME" sh -c "$1"; }
started_with() { docker logs "$NAME" 2>&1 | grep -F -- "$1" >/dev/null || fail "no '$1' in the log"; }

# Copy a client's certificate and key out as $WORK/<as>-cert.pem/-key.pem.
fetch() {
  docker cp -q "$NAME:/etc/ocserv/auth/clients/$1-cert.pem" "$WORK/${2:-$1}-cert.pem"
  docker cp -q "$NAME:/etc/ocserv/auth/clients/$1-key.pem" "$WORK/${2:-$1}-key.pem"
}

# Usage: login <cert name>: prints accepted or rejected.
login() {
  rc=0
  timeout 30 openconnect --non-inter --servercert "$PIN" --authenticate \
    -c "$WORK/$1-cert.pem" -k "$WORK/$1-key.pem" "$URL" </dev/null >"$WORK/login.out" 2>"$WORK/login.err" || rc=$?
  [ "$rc" -ne 124 ] || fail "openconnect timed out ($1)"
  if [ "$rc" -eq 0 ] && grep -q "^COOKIE='..*'" "$WORK/login.out"; then echo accepted; else echo rejected; fi
}
# Usage: expect <accepted|rejected> <cert name> [reason in the server log]
expect() {
  LOG_LINES="$(docker logs "$NAME" 2>&1 | wc -l)"
  got="$(login "$2")"
  [ "$got" = "$1" ] || { cat "$WORK/login.err" >&2; fail "$2: $got, expected $1"; }
  if [ -n "${3:-}" ]; then
    for _ in $(seq 10); do
      docker logs "$NAME" 2>&1 | tail -n +"$((LOG_LINES + 1))" | grep -F -- "$3" >/dev/null && break
      sleep 1
    done
    docker logs "$NAME" 2>&1 | tail -n +"$((LOG_LINES + 1))" | grep -F -- "$3" >/dev/null \
      || fail "$2: rejected, but no '$3' in the server log"
  fi
  log "  $2: $got${3:+ ($3)}"
}

# Usage: connect <cert name> [user]: open a tunnel in the background and
# wait for the user's session; sets OC_PID.
connect() {
  user="${2:-$1}"
  SOCKS=$((SOCKS + 1))
  openconnect --non-inter --servercert "$PIN" -c "$WORK/$1-cert.pem" -k "$WORK/$1-key.pem" \
    --script-tun --script "ocproxy -D $SOCKS" "$URL" </dev/null >"$WORK/$1-tunnel.log" 2>&1 &
  OC_PID=$!; OC_PIDS+=("$OC_PID")
  for _ in $(seq 20); do
    x "occtl show users" | grep -w "$user" >/dev/null && return 0
    kill -0 "$OC_PID" 2>/dev/null || { cat "$WORK/$1-tunnel.log" >&2; fail "$1: tunnel exited"; }
    sleep 1
  done
  fail "$1: no session"
}

# Usage: legacy <name>: a certificate with serial 01, as issued before
# random serial numbers, in clients/ as if made by make-client.sh.
legacy() {
  x "cd /etc/ocserv/auth/clients &&
     sed -e 's/@CN@/$1/' -e 's/@DAYS@/30/' /etc/ocserv/templates/client.tmpl > /tmp/legacy.tmpl &&
     echo 'serial = 1' >> /tmp/legacy.tmpl &&
     certtool --generate-privkey --outfile $1-key.pem 2>/dev/null &&
     certtool --generate-certificate --load-privkey $1-key.pem --template /tmp/legacy.tmpl \
       --load-ca-certificate /etc/ocserv/cert/ca.pem --load-ca-privkey /etc/ocserv/cert/ca-key.pem \
       --outfile $1-cert.pem 2>/dev/null"
  fetch "$1"
}

ocs_fails() {
  want="$1"; shift
  if docker exec "$NAME" ocs "$@" >"$WORK/ocs.out" 2>&1; then fail "'ocs $*' succeeded"; fi
  grep -qF -- "$want" "$WORK/ocs.out" || { cat "$WORK/ocs.out" >&2; fail "'ocs $*': no '$want'"; }
}

[ -c /dev/net/tun ] || fail "/dev/net/tun is missing"
for v in cert auth conf; do volume "$v"; done

log "first start: random serial numbers, revocation on"
start
started_with "Client certificate revocation: on (/etc/ocserv/cert/crl.pem)"
x "grep -qx 'crl = /etc/ocserv/cert/crl.pem' /etc/ocserv/config/ocserv.conf" || fail "no crl line in the new ocserv.conf"
for c in ca server-cert; do
  [ "$(x "openssl x509 -in /etc/ocserv/cert/$c.pem -noout -serial")" != "serial=01" ] || fail "$c has serial 01"
done
PIN="pin-sha256:$(x 'cat /etc/ocserv/cert/server-cert.pem' | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"

log "issue: names, validity, no silent reissue"
for n in alice carol; do docker exec "$NAME" ocs client issue "$n" >/dev/null || fail "issue $n"; fetch "$n"; done
docker exec "$NAME" ocs client issue bob --days 30 >/dev/null || fail "issue bob --days 30"
fetch bob
openssl x509 -in "$WORK/bob-cert.pem" -noout -checkend $((29 * 86400)) >/dev/null || fail "bob expires within 29 days"
openssl x509 -in "$WORK/bob-cert.pem" -noout -checkend $((31 * 86400)) >/dev/null && fail "bob is valid for more than 30 days"
[ "$(openssl x509 -in "$WORK/alice-cert.pem" -noout -serial)" != "$(openssl x509 -in "$WORK/carol-cert.pem" -noout -serial)" ] \
  || fail "two clients have the same serial number"
ocs_fails "already has a certificate" client issue alice
for d in 0 012 abc 3651 99999999999; do ocs_fails "Invalid validity" client issue dave --days "$d"; done
docker exec "$NAME" ocs client list | grep -E '^alice +[0-9-]+ +[0-9A-F]+ +valid$' >/dev/null || fail "ocs client list: alice is not valid"
expect accepted alice
expect accepted bob

log "revoke: login refused, session closed, cookie refused, key deleted"
connect alice; alice_tunnel=$OC_PID
timeout 30 openconnect --non-inter --servercert "$PIN" --authenticate \
  -c "$WORK/alice-cert.pem" -k "$WORK/alice-key.pem" "$URL" </dev/null >"$WORK/cookie.out" 2>/dev/null
COOKIE="$(sed -n "s/^COOKIE='\(.*\)'$/\1/p" "$WORK/cookie.out")"
[ -n "$COOKIE" ] || fail "no cookie for alice"
docker exec "$NAME" ocs client revoke alice >"$WORK/revoke.out" 2>&1 || { cat "$WORK/revoke.out" >&2; fail "revoke alice"; }
for _ in $(seq 20); do kill -0 "$alice_tunnel" 2>/dev/null || break; sleep 1; done
kill -0 "$alice_tunnel" 2>/dev/null && fail "alice's session is still connected"
x "occtl show users" | grep -w alice >/dev/null && fail "occtl still lists alice"
echo "$COOKIE" | timeout 20 openconnect --non-inter --servercert "$PIN" --cookie-on-stdin \
  --script-tun --script "ocproxy -D 11199" "$URL" >"$WORK/cookie.log" 2>&1 &
cookie_pid=$!; OC_PIDS+=("$cookie_pid")
for _ in $(seq 10); do kill -0 "$cookie_pid" 2>/dev/null || break; sleep 1; done
kill -0 "$cookie_pid" 2>/dev/null && fail "alice's old cookie still opens a session"
grep -q "Cookie was rejected" "$WORK/cookie.log" || { cat "$WORK/cookie.log" >&2; fail "no 'Cookie was rejected'"; }
log "  alice's cookie: rejected"
expect rejected alice "revoked"
expect accepted carol
x "[ ! -e /etc/ocserv/auth/clients/alice-key.pem ] && [ ! -e /etc/ocserv/auth/clients/alice-cert.pem ]" \
  || fail "alice's key or certificate is still in clients/"
docker exec "$NAME" ocs client list | grep -E '^alice .* revoked$' >/dev/null || fail "ocs client list: alice is not revoked"
ocs_fails "has no certificate" client revoke alice
cp "$WORK/alice-cert.pem" "$WORK/alice-old-cert.pem"; cp "$WORK/alice-key.pem" "$WORK/alice-old-key.pem"
docker exec "$NAME" ocs client issue alice >/dev/null || fail "issue alice again after revoke"
fetch alice
expect accepted alice

log "renew: the old certificate is revoked, the active session stays"
cp "$WORK/bob-cert.pem" "$WORK/bob-old-cert.pem"; cp "$WORK/bob-key.pem" "$WORK/bob-old-key.pem"
connect bob-old bob; bob_tunnel=$OC_PID
docker exec "$NAME" ocs client renew bob >/dev/null 2>&1 || fail "renew bob"
fetch bob
sleep 2
kill -0 "$bob_tunnel" 2>/dev/null || fail "renew closed bob's active session"
expect rejected bob-old "revoked"
expect accepted bob
kill "$bob_tunnel" 2>/dev/null || true

log "old shared serial 01"
legacy old1; legacy old2
expect accepted old1
ocs_fails "old shared serial 01" client revoke old1
ocs_fails "would be blocked: old1 old2" client revoke-legacy
docker exec "$NAME" ocs client renew old1 >"$WORK/renew.out" 2>&1 || fail "renew old1"
grep -q "stays valid" "$WORK/renew.out" || fail "renew old1: no warning that the old certificate stays valid"
cp "$WORK/old1-cert.pem" "$WORK/old1-old-cert.pem"; cp "$WORK/old1-key.pem" "$WORK/old1-old-key.pem"
fetch old1
expect accepted old1-old
ocs_fails "would be blocked: old2" client revoke-legacy
docker exec "$NAME" ocs client revoke-legacy --force >/dev/null 2>&1 || fail "revoke-legacy --force"
expect rejected old1-old "revoked"
expect rejected old2 "revoked"
expect accepted old1
expect accepted carol
x "[ ! -e /etc/ocserv/auth/clients/old2-key.pem ]" || fail "revoke-legacy --force kept old2's key"
ocs_fails "usage" client revoke-legacy --force extra

log "restart without crl.pem: rebuilt from the records"
x "rm /etc/ocserv/cert/crl.pem"
docker restart -t 15 "$NAME" >/dev/null
for _ in $(seq 60); do
  [ "$(docker logs "$NAME" 2>&1 | grep -c "initialized OpenConnect VPN Server")" -ge 2 ] && break
  sleep 1
done
[ "$(docker logs "$NAME" 2>&1 | grep -c "initialized OpenConnect VPN Server")" -ge 2 ] || fail "no restart"
started_with "Building /etc/ocserv/cert/crl.pem from the revocation records"
expect rejected alice-old "revoked"
expect rejected bob-old "revoked"
expect rejected old2 "revoked"
expect accepted alice
expect accepted carol

log "ocserv.conf without crl: revocation off, and ocs says so"
docker stop -t 15 "$NAME" >/dev/null
docker run --rm -v "$PREFIX-conf:/c" --entrypoint sed "$IMAGE" -i '/^crl = /d' /c/ocserv.conf
start
started_with "Client certificate revocation: off"
docker exec "$NAME" ocs client revoke carol >"$WORK/off.out" 2>&1 || fail "revoke carol"
grep -q "NOT enforced" "$WORK/off.out" || { cat "$WORK/off.out" >&2; fail "no warning that revocation is not enforced"; }
expect accepted carol
docker stop -t 15 "$NAME" >/dev/null
docker run --rm -v "$PREFIX-conf:/c" --entrypoint sh "$IMAGE" -c \
  'echo "crl = /etc/ocserv/cert/crl.pem" >> /c/ocserv.conf'

log "missing crl.pem and no CA key: the start stops with a clear error"
volume nokey
docker run --rm -v "$PREFIX-cert:/from" -v "$PREFIX-nokey:/to" --entrypoint sh "$IMAGE" -c \
  'cp /from/ca.pem /from/server-cert.pem /from/server-key.pem /to/'
# shellcheck disable=SC2046
if timeout 60 docker run --rm $(run_args nokey) "$IMAGE" >"$WORK/nokey.log" 2>&1; then
  fail "the container started without crl.pem and the CA key"
fi
grep -q "cannot build /etc/ocserv/cert/crl.pem" "$WORK/nokey.log" || { cat "$WORK/nokey.log" >&2; fail "no clear error"; }

log "OK"
