#!/usr/bin/env bash
# Certificate issuance and renewal test: get-cert.sh against Pebble (a test
# ACME server) with DNS-01 through pebble-challtestsrv.
#
# Usage: tests/acme.sh [image]        (default image: ocserv:ci)
# Needs on the host: docker, /dev/net/tun, openssl. Uses host networking and
# ports 443, 8053, 8055, 14000 and 15000; run it on a CI runner or a
# throwaway VM, not next to a running ocserv.
set -euo pipefail

IMAGE="${1:-ocserv:ci}"
NAME="ocserv-acme"
PEBBLE="ghcr.io/letsencrypt/pebble:2.10.1@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199"
CTST="ghcr.io/letsencrypt/pebble-challtestsrv:2.10.1@sha256:12ce21884def456bcf9786542113949e1f19dc7738d2c70e156c2d0c38a1405b"
DOMAIN="vpn.acme.test"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"

log()  { echo "[acme] $*"; }
fail() { echo "[acme] FAIL: $*" >&2; exit 1; }

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    for f in "$WORK"/*.log; do [ -f "$f" ] && { echo "----- $f -----" >&2; cat "$f" >&2; }; done
    echo "----- container log -----" >&2
    docker logs "$NAME" >&2 2>&1 || true
  fi
  docker rm -f "$NAME" acme-pebble acme-ctst >/dev/null 2>&1 || true
  # files written by the container belong to root
  docker run --rm -v "$WORK:/w" --entrypoint sh "$IMAGE" -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Run get-cert.sh in the container; prints its exit code.
get_cert() {
  rc=0
  docker exec "$NAME" /scripts/get-cert.sh dns >"$WORK/$1.log" 2>&1 || rc=$?
  echo "$rc"
}
served_fp() {
  echo | timeout 10 openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256
}

log "starting Pebble and challtestsrv"
docker pull -q "$CTST" >/dev/null
docker pull -q "$PEBBLE" >/dev/null
docker run -d --name acme-ctst --network host "$CTST" \
  -defaultIPv4 127.0.0.1 -defaultIPv6 "" -dnsserver :8053 \
  -http01 "" -https01 "" -tlsalpn01 "" -doh "" >/dev/null
docker run -d --name acme-pebble --network host -e PEBBLE_VA_NOSLEEP=1 "$PEBBLE" \
  -config test/config/pebble-config.json -dnsserver 127.0.0.1:8053 >/dev/null
for _ in $(seq 30); do curl -sk -o /dev/null https://127.0.0.1:14000/dir && break; sleep 1; done
curl -sk -o /dev/null https://127.0.0.1:14000/dir || fail "Pebble did not start"

mkdir "$WORK/acme" "$WORK/cert"
printf 'ACME_DNS=dns_ctst\nCTST_URL=http://127.0.0.1:8055\n' > "$WORK/acme/provider.env"
chmod 700 "$WORK/acme"; chmod 600 "$WORK/acme/provider.env"

log "starting $IMAGE"
docker run -d --name "$NAME" --network host \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -e SRV_CN="$DOMAIN" -e SRV_CA="ACME Test CA" -e ENABLE_DTLS=false \
  -e USE_IPTABLES_NFT="${USE_IPTABLES_NFT:-true}" \
  -e ACME_SERVER=https://127.0.0.1:14000/dir -e HTTPS_INSECURE=1 -e Le_DNSSleep=1 \
  -v "$WORK/acme:/etc/acme" -v "$WORK/cert:/etc/ocserv/cert" \
  -v "$HERE/acme/dns_ctst.sh:/usr/local/share/dnsapi/dns_ctst.sh:ro" \
  "$IMAGE" >/dev/null
for _ in $(seq 60); do
  docker logs "$NAME" 2>&1 | grep "initialized OpenConnect VPN Server" >/dev/null && break
  sleep 1
done
docker logs "$NAME" 2>&1 | grep "initialized OpenConnect VPN Server" >/dev/null || fail "ocserv did not start in 60 s"
before="$(served_fp)"

log "issue: new certificate is installed and served without a restart"
rc="$(get_cert issue)"
[ "$rc" = 0 ] || fail "get-cert.sh exited with $rc"
grep "ocserv reloaded the certificate" "$WORK/issue.log" >/dev/null || fail "no reload after the install"
after=""
for _ in $(seq 10); do after="$(served_fp)"; [ "$after" != "$before" ] && break; sleep 1; done
[ "$after" != "$before" ] || fail "ocserv still serves the old certificate"
echo | timeout 10 openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -issuer \
  | grep -i pebble >/dev/null || fail "the served certificate is not from Pebble"
[ "$(docker inspect -f '{{.RestartCount}}' "$NAME")" = 0 ] || fail "the container restarted"

log "second run, nothing due: exit 0, nothing reloaded"
rc="$(get_cert again)"
[ "$rc" = 0 ] || fail "second run exited with $rc"
grep "already current" "$WORK/again.log" >/dev/null || fail "second run did not report the certificate as current"

log "a key that does not match is not installed"
live="$(served_fp)"
key="$(docker exec "$NAME" sh -c "ls /etc/acme/${DOMAIN}_ecc/${DOMAIN}.key")"
docker exec "$NAME" cp "$key" "$key.orig"
docker exec "$NAME" openssl ecparam -name prime256v1 -genkey -noout -out "$key"
rc="$(get_cert mismatch)"
[ "$rc" = 8 ] || fail "mismatched key: exit $rc, expected 8"
[ "$(served_fp)" = "$live" ] || fail "the live certificate changed"
docker exec "$NAME" mv "$key.orig" "$key"

log "DNS plugin hash is checked on every run"
echo "ACME_DNS_SHA256=$(printf '0%.0s' $(seq 64))" >> "$WORK/acme/provider.env"
rc="$(get_cert badhash)"
[ "$rc" = 6 ] || fail "wrong plugin hash: exit $rc, expected 6"
sed -i '$d' "$WORK/acme/provider.env"
echo "ACME_DNS_SHA256=$(sha256sum "$HERE/acme/dns_ctst.sh" | cut -d' ' -f1)" >> "$WORK/acme/provider.env"
rc="$(get_cert goodhash)"
[ "$rc" = 0 ] || fail "right plugin hash: exit $rc, expected 0"

log "files in /etc/acme writable by others are refused"
chmod 660 "$WORK/acme/provider.env"
rc="$(get_cert writable)"
[ "$rc" = 7 ] || fail "group-writable provider.env: exit $rc, expected 7"
chmod 600 "$WORK/acme/provider.env"

log "OK"
