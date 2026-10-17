#!/usr/bin/env sh
# acme.sh DNS hook for tests: publishes the DNS-01 TXT record in
# pebble-challtestsrv instead of a real DNS provider.
# shellcheck disable=SC2034
dns_ctst_info='pebble-challtestsrv (tests only)'

dns_ctst_add() {
  _info "challtestsrv: set TXT $1"
  curl -fsS -d "{\"host\":\"$1.\",\"value\":\"$2\"}" "${CTST_URL:-http://127.0.0.1:8055}/set-txt" >/dev/null
}

dns_ctst_rm() {
  _info "challtestsrv: clear TXT $1"
  curl -fsS -d "{\"host\":\"$1.\"}" "${CTST_URL:-http://127.0.0.1:8055}/clear-txt" >/dev/null
}
