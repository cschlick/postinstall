#!/usr/bin/env bash
# Pull the latest repo from GitLab and apply site.yml against this host.
# Idempotent — safe to re-run. Requires ansible to already be installed
# (the boot script handles that on first run).
#
# IMAGE_BUILD=1 bash apply.sh  -> also runs the cloud_init + image_generalize
# roles to produce a generalized, cloud-init-ready Vultr image. Snapshot afterward.
#
# Profiles (no flag = bastion: public IPv6 SSH, key-only, ProxyJump):
#   DEV=1 bash apply.sh      -> dev profile: bastion + IPv4 SSH + password SSH
#                               + Claude Code; purges no accounts
#   GW_NODE=1 bash apply.sh  -> gw_node profile: SSH only on the mesh overlay (gw-*),
#                               no forwarding. The Vultr console is your fallback
#                               if mesh SSH isn't up yet.
#   NATS=1 bash apply.sh     -> nats service profile (STACKS on a base profile,
#                               e.g. NATS=1 GW_NODE=1): mesh-only JetStream, mTLS
#   POSTGRES=1 bash apply.sh -> postgres service profile (stacks like nats):
#                               mesh-only PostgreSQL, mTLS
#   ACCOUNT=1 bash apply.sh  -> account service profile (stacks like nats): the
#                               account plane as a GHCR container (podman quadlet),
#                               remote Postgres. Needs the vault password (see below).
#   CHAT=1 bash apply.sh     -> chat service profile (stacks like account): the chat
#                               plane as a GHCR container (podman quadlet); backbone
#                               NATS + Postgres + R2. Needs the vault password.
#   SEED=1 bash apply.sh     -> seed service profile (stacks on gw_node): a one-shot
#                               demo-world seeder (GHCR container). Installs but does
#                               NOT start it; run `systemctl start pm-seed`. Needs the vault.
#   FLUTTER=1 bash apply.sh  -> flutter (web client) service profile (stacks on
#                               gw_node): the Flutter web build via nginx (GHCR
#                               container), public on :8080. Needs the vault (GHCR token).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://gitlab.com/cschlick/postinstall.git"

EXTRA=()
[ "${IMAGE_BUILD:-0}" = 1 ] && EXTRA+=(-e image_build=true)
[ "${DEV:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/dev.yml")
[ "${GW_NODE:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/gw_node.yml")
[ "${NATS:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/nats.yml")
[ "${POSTGRES:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/postgres.yml")
# The account profile carries secrets in an ansible-vault file (group_vars/account/
# vault.yml). Provide the vault password via ANSIBLE_VAULT_PASSWORD_FILE (ansible-pull
# auto-uses it). vars.yml is committed; vault.yml is operator-placed + gitignored.
[ "${ACCOUNT:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/account/vars.yml")
# The vault lives OUTSIDE group_vars so molecule/CI never auto-load (and try to
# decrypt) it; apply loads it explicitly. Needs the vault password via
# ANSIBLE_VAULT_PASSWORD_FILE. Guarded so a non-account run without it is fine.
[ "${ACCOUNT:-0}" = 1 ] && [ -f "$ROOT/ansible/vault-account.yml" ] && EXTRA+=(-e @"$ROOT/ansible/vault-account.yml")
[ "${CHAT:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/chat.yml")
[ "${CHAT:-0}" = 1 ] && [ -f "$ROOT/ansible/vault-chat.yml" ] && EXTRA+=(-e @"$ROOT/ansible/vault-chat.yml")
[ "${SEED:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/seed.yml")
[ "${SEED:-0}" = 1 ] && [ -f "$ROOT/ansible/vault-seed.yml" ] && EXTRA+=(-e @"$ROOT/ansible/vault-seed.yml")
[ "${FLUTTER:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/flutter.yml")
[ "${FLUTTER:-0}" = 1 ] && [ -f "$ROOT/ansible/vault-flutter.yml" ] && EXTRA+=(-e @"$ROOT/ansible/vault-flutter.yml")
# Deploy-time extra vars (pmdeploy --var / --local-db writes this). Lives outside
# the repo so it survives ansible-pull's checkout reset. e.g. a local-DB box:
#   postgres_socket_only: true  /  account_db_local: true
[ -f /etc/postinstall/extra-vars.yml ] && EXTRA+=(-e @/etc/postinstall/extra-vars.yml)

# Ensure galaxy collections are present (idempotent; fast when already installed).
ansible-galaxy collection install -r "$ROOT/ansible/requirements.yml"

sudo mkdir -p /var/log/ansible-apply
ANSIBLE_LOG_PATH=/var/log/ansible-apply/latest.log \
  ansible-pull -U "$REPO" -d "$ROOT" -i 'localhost,' -c local -l localhost "${EXTRA[@]}" ansible/site.yml
