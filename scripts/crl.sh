#!/bin/sh
# Certificate revocation list (CRL) of the local CA.
# Usage: crl.sh update          rebuild crl.pem from the revocation records
#        crl.sh add <cert.pem>  record a certificate as revoked, then rebuild
#        crl.sh legacy          record serial 01 as revoked (every certificate
#                               issued before random serial numbers), rebuild
# Records are public certificates in /etc/ocserv/cert/revoked/<serial>.pem.
# A running ocserv loads the new list on 'occtl reload', done here.
set -eu

CERT_DIR="/etc/ocserv/cert"
CA_PEM="$CERT_DIR/ca.pem"
CA_KEY="$CERT_DIR/ca-key.pem"
CRL="$CERT_DIR/crl.pem"
REVOKED_DIR="$CERT_DIR/revoked"
LOCK_DIR="/etc/ocserv/auth/clients"

die() { echo "[ERR] $*" >&2; exit 1; }

[ -f "$CA_PEM" ] && [ -f "$CA_KEY" ] || die "Missing CA: $CA_PEM / $CA_KEY (the CRL is signed with the CA key)"

umask 077
# Client certificate operations share one lock; ocs takes it and sets
# OCS_LOCK_HELD for the scripts it runs.
if [ -z "${OCS_LOCK_HELD:-}" ]; then
  mkdir -p "$LOCK_DIR"
  exec 9>"$LOCK_DIR/.lock"
  i=0
  until flock -n 9; do
    i=$((i + 1)); [ "$i" -lt 30 ] || die "Another client certificate operation is running; try again"
    sleep 1
  done
fi
mkdir -p "$REVOKED_DIR"

issued_by_ca() { openssl verify -no_check_time -CAfile "$CA_PEM" "$1" >/dev/null 2>&1; }
serial_of()    { openssl x509 -in "$1" -noout -serial | sed 's/^serial=//'; }

# Keep only the certificate (no key) under its serial number.
record() {
  serial="$(serial_of "$1")"
  [ -n "$serial" ] || die "Cannot read the serial number of $1"
  openssl x509 -in "$1" -out "$REVOKED_DIR/.$serial.pem"
  mv -f "$REVOKED_DIR/.$serial.pem" "$REVOKED_DIR/$serial.pem"
  echo "[INFO] Revoked: serial $serial ($(openssl x509 -in "$1" -noout -subject | sed 's/^subject= *//'))"
}

update() {
  work="$(mktemp -d "$CERT_DIR/.crl-XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  : > "$work/revoked.pem"
  n=0
  for f in "$REVOKED_DIR"/*.pem; do
    [ -f "$f" ] || continue
    if issued_by_ca "$f"; then
      cat "$f" >> "$work/revoked.pem"; n=$((n + 1))
    else
      echo "[WARN] Skipping $f: not issued by the current CA" >&2
    fi
  done
  # GnuTLS keeps using a CRL after its next update date; it is set far
  # ahead and the list is rebuilt on every change.
  echo "crl_next_update = 3650" > "$work/crl.tmpl"
  set -- --generate-crl --load-ca-privkey "$CA_KEY" --load-ca-certificate "$CA_PEM" \
    --template "$work/crl.tmpl" --outfile "$work/crl.pem"
  [ "$n" -eq 0 ] || set -- "$@" --load-certificate "$work/revoked.pem"
  certtool "$@" >"$work/certtool.log" 2>&1 || { cat "$work/certtool.log" >&2; die "Cannot generate the CRL"; }
  chmod 644 "$work/crl.pem"
  mv -f "$work/crl.pem" "$CRL"
  echo "[OK] $CRL: $n revoked certificate(s)"
  if occtl show status >/dev/null 2>&1; then
    occtl reload >/dev/null || die "The CRL is updated, but 'occtl reload' failed; restart the container"
    echo "[OK] ocserv reloaded"
  fi
}

case "${1:-}" in
  update)
    update ;;
  add)
    [ -f "${2:-}" ] || die "Usage: $0 add <cert.pem>"
    issued_by_ca "$2" || die "$2 is not issued by the CA $CA_PEM"
    record "$2"
    update ;;
  legacy)
    # certtool lists certificates, not bare serial numbers: sign a
    # placeholder with serial 01 that stands for all of them.
    work="$(mktemp -d "$CERT_DIR/.legacy-XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    printf 'cn = "serial 01: certificates issued before random serial numbers"\nserial = 1\nexpiration_days = 3650\ntls_www_client\n' \
      > "$work/legacy.tmpl"
    certtool --generate-privkey --outfile "$work/key.pem" >/dev/null 2>&1
    certtool --generate-certificate --load-privkey "$work/key.pem" \
      --load-ca-certificate "$CA_PEM" --load-ca-privkey "$CA_KEY" \
      --template "$work/legacy.tmpl" --outfile "$work/legacy.pem" >/dev/null 2>&1 \
      || die "Cannot create the serial 01 placeholder"
    record "$work/legacy.pem"
    rm -rf "$work"; trap - EXIT
    update ;;
  *)
    echo "Usage: $0 update | add <cert.pem> | legacy" >&2; exit 1 ;;
esac
