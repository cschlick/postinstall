#!/usr/bin/env bash
# Pull the latest repo from GitLab and apply site.yml against this host.
# Idempotent — safe to re-run. Requires ansible to already be installed
# (the boot script handles that on first run).
#
# IMAGE_BUILD=1 bash apply.sh  -> also runs the cloud_init + image_generalize
# roles to produce a generalized, cloud-init-ready Vultr image. Snapshot afterward.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://gitlab.com/cschlick/postinstall.git"

EXTRA=()
[ "${IMAGE_BUILD:-0}" = 1 ] && EXTRA+=(-e image_build=true)

# Ensure galaxy collections are present (idempotent; fast when already installed).
ansible-galaxy collection install -r "$ROOT/ansible/requirements.yml"

sudo mkdir -p /var/log/ansible-apply
ANSIBLE_LOG_PATH=/var/log/ansible-apply/latest.log \
  ansible-pull -U "$REPO" -d "$ROOT" -i 'localhost,' -c local -l localhost "${EXTRA[@]}" ansible/site.yml
