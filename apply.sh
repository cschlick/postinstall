#!/usr/bin/env bash
# Pull the latest repo from GitLab and apply site.yml against this host.
# Idempotent — safe to re-run. Requires ansible to already be installed
# (the boot script handles that on first run).
#
# IMAGE_BUILD=1 bash apply.sh  -> also runs the cloud_init + image_generalize
# roles to produce a generalized, cloud-init-ready Vultr image. Snapshot afterward.
#
# Profiles (no flag = bastion: public SSH over IPv4+IPv6, key-only, ProxyJump):
#   DEV=1 bash apply.sh      -> dev profile: bastion + password SSH
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

# Vault password: ansible-pull auto-reads ANSIBLE_VAULT_PASSWORD_FILE. pmdeploy
# writes it to /root/.ansible-vault-pass at provision time but only exports it in
# that shell — so a manual re-run (sudo … apply.sh) has none. If we're root and
# that file is present, adopt it, so `sudo FLUTTER=1 bash apply.sh` Just Works.
if [ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ] && [ "$(id -u)" = 0 ] \
   && [ -r /root/.ansible-vault-pass ]; then
  export ANSIBLE_VAULT_PASSWORD_FILE=/root/.ansible-vault-pass
fi

# Load a service profile's ansible-vault file, but REQUIRE it when the profile is
# enabled: a missing vault otherwise degrades into a confusing "token empty" role
# assert several tasks later (been there). Fail loudly, here, at the real cause.
# $1 = the profile flag's value, $2 = vault filename under ansible/.
require_vault() {
  [ "$1" = 1 ] || return 0
  local f="$ROOT/ansible/$2"
  if [ ! -f "$f" ]; then
    echo "apply.sh: this profile needs ansible/$2, which is missing. Create it from" \
         "ansible/$2.example, 'ansible-vault encrypt' it, then 'git add -f ansible/$2'" \
         "and push (it's gitignored). Aborting." >&2
    exit 1
  fi
  EXTRA+=(-e @"$f")
}
[ "${DEV:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/dev.yml")
[ "${GW_NODE:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/gw_node.yml")
# Default base = bastion (no DEV/GW_NODE flag). ansible-pull runs against
# `localhost,`, which is in no inventory group, so group_vars/bastion.yml would
# NEVER auto-load — load it explicitly for the base's SSH/firewall (public v4+v6
# SSH, ProxyJump). Loaded before the service group_vars so a bastion-based service
# box (e.g. bastion+nats) gets the base first, then the service layers on.
[ "${DEV:-0}" != 1 ] && [ "${GW_NODE:-0}" != 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/bastion.yml")
[ "${NATS:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/nats.yml")
[ "${POSTGRES:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/postgres.yml")
# The account profile carries secrets in an ansible-vault file (group_vars/account/
# vault.yml). Provide the vault password via ANSIBLE_VAULT_PASSWORD_FILE (ansible-pull
# auto-uses it). vars.yml is committed; vault.yml is operator-placed + gitignored.
[ "${ACCOUNT:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/account/vars.yml")
# Each service vault lives OUTSIDE group_vars so molecule/CI never auto-load (and
# try to decrypt) it; apply loads it explicitly and REQUIRES it when the profile
# is on (see require_vault). Needs the vault password via ANSIBLE_VAULT_PASSWORD_FILE.
require_vault "${ACCOUNT:-0}" vault-account.yml
[ "${CHAT:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/chat.yml")
require_vault "${CHAT:-0}" vault-chat.yml
[ "${SEED:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/seed.yml")
require_vault "${SEED:-0}" vault-seed.yml
[ "${FLUTTER:-0}" = 1 ] && EXTRA+=(-e @"$ROOT/ansible/group_vars/flutter.yml")
require_vault "${FLUTTER:-0}" vault-flutter.yml
# Deploy-time extra vars (pmdeploy --var / --local-db writes this). Lives outside
# the repo so it survives ansible-pull's checkout reset. e.g. a local-DB box:
#   postgres_socket_only: true  /  account_db_local: true
[ -f /etc/postinstall/extra-vars.yml ] && EXTRA+=(-e @/etc/postinstall/extra-vars.yml)

# Ensure galaxy collections are present (idempotent; fast when already installed).
ansible-galaxy collection install -r "$ROOT/ansible/requirements.yml"

sudo mkdir -p /var/log/ansible-apply
ANSIBLE_LOG_PATH=/var/log/ansible-apply/latest.log \
  ansible-pull -U "$REPO" -d "$ROOT" -i 'localhost,' -c local -l localhost "${EXTRA[@]}" ansible/site.yml
