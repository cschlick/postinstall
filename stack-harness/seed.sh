#!/usr/bin/env bash
# Run the one-shot seeder against an up stack (suffix, default dev). Populates a
# demo world: users, halls, boards, polls, inbox, nested rooms, contacts.
# SEED_SMALL=0 ./seed.sh <suffix>  → the big/slow world instead of the fast preset.
set -euo pipefail
SUF="${1:-dev}"; cd "$(dirname "$0")"
NET="harness_$SUF"; VOL="pmcerts_$SUF"
DSN="postgresql://pm@db_chat_$SUF:5432/chat?sslmode=verify-full&sslrootcert=/etc/pki/pm/ca.crt&sslcert=/etc/pki/pm/client.crt&sslkey=/etc/pki/pm/client.key"
podman rm -f seed_$SUF >/dev/null 2>&1 || true
exec podman run --rm --name seed_$SUF --network "$NET" -v "$VOL:/etc/pki/pm:ro" \
  -e CHAT_WS_URL="ws://chat_$SUF:8765" -e ACCOUNT_WS_URL="ws://accounts_$SUF:8766" \
  -e CHAT_DB_URL="$DSN" -e CHAT_BOT_CLAIM_SECRET=harness-bot-claim \
  -e SEED_PW="${SEED_PW:-harness-pass-1234}" -e SEED_SMALL="${SEED_SMALL:-1}" h_seed
