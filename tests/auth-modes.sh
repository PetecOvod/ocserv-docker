#!/usr/bin/env bash
# Authentication modes (AUTH_MODE): for each mode, which logins are accepted
# and which are rejected; an existing ocserv.conf is never changed and a
# mode that contradicts it stops the start.
#
# Usage: tests/auth-modes.sh [image]        (default image: ocserv:ci)
# Needs on the host: docker, /dev/net/tun, openconnect, openssl, timeout.
# The containers use host networking and port 443; run it on a CI runner or
# a throwaway VM, not at the same time as tests/smoke.sh.
set -euo pipefail

IMAGE="${1:-ocserv:ci}"
NAME="ocserv-auth"
PREFIX="ocserv-auth-test"
WORK="$(mktemp -d)"
URL="https://127.0.0.1:443/"
ALICE_PASS="alice-$RANDOM$RANDOM"
BOB_PASS="bob-$RANDOM$RANDOM"
VOLUMES=()

log()  { echo "[auth] $*"; }
fail() { echo "[auth] FAIL: $*" >&2; exit 1; }

cleanup() {
  status=$?
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

# Start ocserv with the shared certificates and users and the given config
# volume; extra arguments go to docker run (e.g. -e AUTH_MODE=cert).
start() {
  conf="$1"; shift
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --network host \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -v "$PREFIX-cert:/etc/ocserv/cert" -v "$PREFIX-auth:/etc/ocserv/auth" \
    -v "$PREFIX-$conf:/etc/ocserv/config" \
    -e SRV_CN=vpn.example.test -e SRV_CA="Auth Test CA" -e ENABLE_DTLS=false \
    -e USE_IPTABLES_NFT="${USE_IPTABLES_NFT:-true}" \
    "$@" "$IMAGE" >/dev/null
  for _ in $(seq 60); do
    docker logs "$NAME" 2>&1 | grep "initialized OpenConnect VPN Server" >/dev/null && return 0
    docker inspect -f '{{.State.Running}}' "$NAME" | grep -q true || fail "container exited: $*"
    sleep 1
  done
  fail "ocserv did not start in 60 s: $*"
}
stop() { docker stop -t 15 "$NAME" >/dev/null; docker rm "$NAME" >/dev/null; }

# Run the image once on a config volume, expecting it to refuse to start.
refuses() {
  conf="$1"; want="$2"; shift 2
  if timeout 60 docker run --rm --cap-add NET_ADMIN --device /dev/net/tun \
       -v "$PREFIX-cert:/etc/ocserv/cert" -v "$PREFIX-auth:/etc/ocserv/auth" \
       -v "$PREFIX-$conf:/etc/ocserv/config" \
       -e SRV_CN=vpn.example.test -e SRV_CA="Auth Test CA" "$@" "$IMAGE" >"$WORK/refuse.log" 2>&1; then
    fail "the container started: $*"
  fi
  grep -qF -- "$want" "$WORK/refuse.log" || { cat "$WORK/refuse.log" >&2; fail "no '$want' in the output: $*"; }
}

conf_sum() {
  docker run --rm -v "$PREFIX-$1:/c" --entrypoint sha256sum "$IMAGE" /c/ocserv.conf | cut -d' ' -f1
}
conf_edit() {
  docker run --rm -v "$PREFIX-$1:/c" --entrypoint sh "$IMAGE" -c "$2"
}

# One login attempt. Usage: login <user|-> <password|-> <cert name|->
# Prints "accepted" (exit 0 and a cookie) or "rejected" (no cookie while the
# server stays up). Anything else fails the test. The client's messages go
# to $WORK/login.err; the server log lines from before the attempt are
# counted in $LOG_LINES.
login() {
  user="$1"; pass="$2"; cert="$3"
  args=(--non-inter --servercert "$PIN" --authenticate)
  [ "$user" = - ] || args+=(-u "$user")
  [ "$cert" = - ] || args+=(-c "$WORK/$cert-cert.pem" -k "$WORK/$cert-key.pem")
  if [ "$pass" = - ]; then : > "$WORK/stdin"; else echo "$pass" > "$WORK/stdin"; args+=(--passwd-on-stdin); fi
  rc=0
  timeout 30 openconnect "${args[@]}" "$URL" <"$WORK/stdin" >"$WORK/login.out" 2>"$WORK/login.err" || rc=$?
  [ "$rc" -ne 124 ] || fail "openconnect timed out ($*)"
  if [ "$rc" -eq 0 ] && grep -q "^COOKIE='..*'" "$WORK/login.out"; then
    echo accepted
    return
  fi
  docker exec "$NAME" occtl show status 2>/dev/null | grep "Status: online" >/dev/null \
    || fail "server is down after a login attempt ($*)"
  echo rejected
}

# Usage: expect <accepted|rejected> <label> <user> <password> <cert> [reason...]
# A rejection must show every reason (fixed strings) in the client's or the
# new server log lines, so that it is not rejected for something else.
expect() {
  want="$1"; label="$2"; user="$3"; pass="$4"; cert="$5"; shift 5
  LOG_LINES="$(docker logs "$NAME" 2>&1 | wc -l)"
  got="$(login "$user" "$pass" "$cert")"
  if [ "$got" != "$want" ]; then
    cat "$WORK/login.err" >&2
    fail "$MODE: $label: $got, expected $want"
  fi
  for reason in "$@"; do
    for _ in $(seq 10); do
      { cat "$WORK/login.err"; docker logs "$NAME" 2>&1 | tail -n +"$((LOG_LINES + 1))"; } > "$WORK/why.log"
      grep -qF -- "$reason" "$WORK/why.log" && break
      sleep 1
    done
    grep -qF -- "$reason" "$WORK/why.log" || { cat "$WORK/why.log" >&2; fail "$MODE: $label: no '$reason'"; }
  done
  why="$(printf '%s; ' "$@")"; why="${why%; }"
  log "  $MODE: $label: $got${why:+ ($why)}"
}

[ -c /dev/net/tun ] || fail "/dev/net/tun is missing"
for v in cert auth; do volume "$v"; done

log "setup: CA, server certificate, users alice and bob, client certificates"
volume setup
start setup
docker exec "$NAME" sh -c "
  printf '%s:*:%s\n' alice \"\$(openssl passwd -6 '$ALICE_PASS')\" >> /etc/ocserv/auth/passwd
  printf '%s:*:%s\n' bob \"\$(openssl passwd -6 '$BOB_PASS')\" >> /etc/ocserv/auth/passwd"
docker exec "$NAME" ocs client issue alice >/dev/null 2>&1 || fail "ocs client issue alice failed"
docker exec "$NAME" sh -c 'cd /tmp &&
  printf "organization = \"OCSERV\"\nexpiration_days = 2\nsigning_key\ntls_www_client\nencryption_key\n" > nocn.tmpl &&
  certtool --generate-privkey --outfile nocn-key.pem 2>/dev/null &&
  certtool --generate-certificate --load-privkey nocn-key.pem --template nocn.tmpl \
    --load-ca-certificate /etc/ocserv/cert/ca.pem --load-ca-privkey /etc/ocserv/cert/ca-key.pem \
    --outfile nocn-cert.pem 2>/dev/null' || fail "could not issue a certificate without CN"
docker cp -q "$NAME:/etc/ocserv/auth/clients/alice-cert.pem" "$WORK/alice-cert.pem"
docker cp -q "$NAME:/etc/ocserv/auth/clients/alice-key.pem" "$WORK/alice-key.pem"
docker cp -q "$NAME:/tmp/nocn-cert.pem" "$WORK/nocn-cert.pem"
docker cp -q "$NAME:/tmp/nocn-key.pem" "$WORK/nocn-key.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=alice" \
  -keyout "$WORK/foreign-key.pem" -out "$WORK/foreign-cert.pem" >/dev/null 2>&1
PIN="pin-sha256:$(docker exec "$NAME" cat /etc/ocserv/cert/server-cert.pem \
  | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64)"
docker logs "$NAME" 2>&1 | grep -F "Authentication: password-or-cert - a password OR a client certificate is enough" >/dev/null \
  || fail "no line about the default authentication mode in the log"
docker exec "$NAME" grep -Fx 'enable-auth = "certificate"' /etc/ocserv/config/ocserv.conf >/dev/null \
  || fail "the default config does not allow a certificate instead of a password"
stop

for MODE in password cert password-or-cert password-and-cert; do
  log "mode $MODE"
  volume "$MODE"
  # First start writes ocserv.conf; turn banning off so that the rejected
  # attempts below do not block the next ones, and start again with the
  # same AUTH_MODE on the existing file.
  start "$MODE" -e AUTH_MODE="$MODE"
  docker logs "$NAME" 2>&1 | grep -F "Authentication: $MODE - " >/dev/null || fail "$MODE: no mode line in the log"
  stop
  conf_edit "$MODE" "sed -i 's/^max-ban-score = .*/max-ban-score = 0/' /c/ocserv.conf"
  start "$MODE" -e AUTH_MODE="$MODE"

  case "$MODE" in
    password)
      expect accepted "password" alice "$ALICE_PASS" -
      expect accepted "bob's password" bob "$BOB_PASS" -
      expect rejected "wrong password" alice "$BOB_PASS" - "Login failed."
      expect rejected "certificate only" - - alice "Please enter your username and password."
      ;;
    cert)
      expect accepted "certificate" - - alice
      expect rejected "password only" alice "$ALICE_PASS" - "no certificate provided"
      expect rejected "certificate from another CA" - - foreign "issuer is unknown"
      ;;
    password-or-cert)
      expect accepted "password" alice "$ALICE_PASS" -
      expect accepted "certificate" - - alice
      expect rejected "wrong password" alice "$BOB_PASS" - "Login failed."
      expect rejected "certificate from another CA" - - foreign "issuer is unknown"
      ;;
    password-and-cert)
      expect accepted "certificate and password" alice "$ALICE_PASS" alice
      expect rejected "password only" alice "$ALICE_PASS" - "no certificate provided"
      expect rejected "certificate only" - - alice \
        "client certificate verification succeeded" "Please enter your username and password."
      expect rejected "certificate and wrong password" alice "$BOB_PASS" alice "Login failed."
      expect rejected "alice's certificate, bob's password" bob "$BOB_PASS" alice \
        "presented a certificate which is for user 'alice'"
      expect rejected "certificate without CN and a password" alice "$ALICE_PASS" nocn "cannot determine username"
      expect rejected "certificate from another CA and a password" alice "$ALICE_PASS" foreign "issuer is unknown"
      ;;
  esac
  stop
done

log "an existing ocserv.conf: AUTH_MODE that contradicts it stops the start, the file stays"
before="$(conf_sum password-or-cert)"
refuses password-or-cert "ERROR: AUTH_MODE=cert, but /etc/ocserv/config/ocserv.conf is set up for password-or-cert" -e AUTH_MODE=cert
[ "$(conf_sum password-or-cert)" = "$before" ] || fail "ocserv.conf was changed"

log "method names in any case: auth = \"CERTIFICATE\" is the cert mode"
conf_edit cert "sed -i 's/^auth = \"certificate\"/auth = \"CERTIFICATE\"/' /c/ocserv.conf"
start cert -e AUTH_MODE=cert
docker logs "$NAME" 2>&1 | grep -F "Authentication: cert - " >/dev/null || fail "CERTIFICATE is not read as the cert mode"
stop

log "an invalid AUTH_MODE stops the start"
volume fresh
refuses fresh "AUTH_MODE='two-factor' is not valid" -e AUTH_MODE=two-factor
docker run --rm -v "$PREFIX-fresh:/c" --entrypoint sh "$IMAGE" -c '[ ! -e /c/ocserv.conf ]' \
  || fail "ocserv.conf was written for an invalid AUTH_MODE"

log "a config set up by hand: starts without AUTH_MODE (or with an empty one), refuses with one"
volume custom
start custom
stop
conf_edit custom "sed -i -e 's/^auth = .*/auth = \"certificate\"/' \
  -e 's/^enable-auth = .*/enable-auth = \"plain[passwd=\/etc\/ocserv\/auth\/passwd]\"/' /c/ocserv.conf"
before="$(conf_sum custom)"
start custom -e AUTH_MODE=
docker logs "$NAME" 2>&1 | grep -F "Authentication: custom" >/dev/null || fail "custom config: no mode line in the log"
docker logs "$NAME" 2>&1 | grep -F 'enable-auth = "plain[passwd=/etc/ocserv/auth/passwd]"' >/dev/null \
  || fail "custom config: its auth lines are not in the log"
stop
refuses custom "is set up for custom" -e AUTH_MODE=password-or-cert
[ "$(conf_sum custom)" = "$before" ] || fail "ocserv.conf was changed"

log "OK"
