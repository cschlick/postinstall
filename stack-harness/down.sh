#!/usr/bin/env bash
# Tear down a stack (suffix, default dev): containers + cert volume + network, and
# the per-suffix mTLS postgres images. The suffix-agnostic app images (h_accounts,
# h_chat, h_seed) are kept for fast re-up; `podman rmi h_chat h_accounts h_seed
# h_chat_base h_accounts_base h_seed_base` to force a from-source rebuild.
set -euo pipefail
SUF="${1:-dev}"; cd "$(dirname "$0")"
for c in seed_$SUF chat_$SUF accounts_$SUF db_chat_$SUF db_accounts_$SUF nats_$SUF; do podman rm -f "$c" >/dev/null 2>&1 || true; done
podman volume rm -f pmcerts_$SUF >/dev/null 2>&1 || true
podman network rm harness_$SUF >/dev/null 2>&1 || true
podman rmi -f h_pg_accounts_$SUF h_pg_chat_$SUF >/dev/null 2>&1 || true
echo "torn down: suffix=$SUF"
