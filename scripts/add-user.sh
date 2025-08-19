#!/bin/sh
USER="$1"
PASS="$2"
PASSWD_FILE="/etc/ocserv/auth/passwd"

if [ -z "$USER" ] || [ -z "$PASS" ]; then
  echo "Usage: $0 <username> <password>"
  exit 1
fi

echo "$USER:$PASS" >> "$PASSWD_FILE"
echo "User $USER added."
