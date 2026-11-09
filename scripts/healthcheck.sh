#!/bin/sh
# Container health check: the ocserv that start.sh runs answers occtl.
# Healthy without a check when there is nothing to ask: the container was
# started with another command (no marker from start.sh), or occtl is off
# in ocserv.conf; the container runs only as long as ocserv does.
MARKER="/run/ocserv-healthcheck"

[ -f "$MARKER" ] || exit 0
CONF_FILE="$(cat "$MARKER")"

# The last value of a top-level option of ocserv.conf, quotes removed.
conf_value() {
  awk -v key="$1" '
    /^[ \t]*\[/ { exit }
    $0 ~ "^[ \t]*" key "[ \t]*=" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v)
                                   if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2) }
    END { print v }
  ' "$CONF_FILE" 2>/dev/null
}

# Whether ocserv turns occtl on, read as ocserv does, line by line: off when
# unset; use-occtl sets it ("true" or "yes" in any case is on); the older
# use-dbus can only turn it on.
occtl_on() {
  awk '
    /^[ \t]*\[/ { exit }
    /^[ \t]*use-(occtl|dbus)[ \t]*=/ {
      key = $0; sub(/[ \t]*=.*/, "", key); gsub(/[ \t]/, "", key)
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      v = tolower(v); t = (v == "true" || v == "yes")
      if (key == "use-occtl" || t) on = t
    }
    END { exit !on }
  ' "$CONF_FILE" 2>/dev/null
}

occtl_on || exit 0
sock="$(conf_value occtl-socket-file)"
if [ -n "$sock" ]; then
  occtl -s "$sock" show status >/dev/null 2>&1
else
  occtl show status >/dev/null 2>&1
fi
