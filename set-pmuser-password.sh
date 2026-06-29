#!/usr/bin/env bash
# Rotate pmuser's emergency console password.
#
# Hashes the password you type and updates pmuser_password_hash directly in
# ansible/group_vars/all.yml, which you then commit. SSH password auth is off,
# so this password is only usable at the Vultr web console / serial.
#
# Save the plaintext in your password manager — only its one-way hash is stored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_YML="$ROOT/ansible/group_vars/all.yml"

command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; exit 1; }

read -rsp "New emergency password for pmuser: " PW; echo
read -rsp "Confirm password: " PW2; echo
[ -n "$PW" ]       || { echo "Empty password — aborting." >&2; exit 1; }
[ "$PW" = "$PW2" ] || { echo "Passwords did not match — aborting." >&2; exit 1; }

# sha512crypt ($6$) hash. -stdin keeps the plaintext off the process list.
HASH="$(printf '%s' "$PW" | openssl passwd -6 -stdin)"
unset PW PW2

# Replace the hash in-place inside group_vars/all.yml.
sed -i "s|^pmuser_password_hash:.*|pmuser_password_hash: '$HASH'|" "$ALL_YML"

echo
echo "Updated pmuser_password_hash in $ALL_YML"
echo "Commit and re-run apply.sh to apply."
