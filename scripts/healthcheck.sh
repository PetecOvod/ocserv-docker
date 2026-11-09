#!/bin/sh
# Container health check: ocserv's main process answers occtl. With occtl
# turned off in ocserv.conf there is nothing to ask; the container runs as
# long as ocserv does, so it counts as healthy.
CONF_FILE="/etc/ocserv/config/ocserv.conf"

conf_value() {
  awk -v key="$1" '
    /^[ \t]*\[/ { exit }
    $0 ~ "^[ \t]*" key "[ \t]*=" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v)
                                   if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2); print v; exit }
  ' "$CONF_FILE" 2>/dev/null
}

case "$(conf_value use-occtl)" in
  false|no|0) exit 0 ;;
esac
sock="$(conf_value occtl-socket-file)"
if [ -n "$sock" ]; then
  occtl -s "$sock" show status >/dev/null 2>&1
else
  occtl show status >/dev/null 2>&1
fi
