#!/usr/bin/env bash
# Apply the hardening playbook to THIS host. Idempotent — safe to re-run; each
# run only changes what's drifted (e.g. add a key to ssh_authorized_keys and
# re-run to switch SSH to key-only).
#
# Fully non-interactive: become runs without a password prompt, so it needs
# passwordless sudo — or run the whole script as root:  sudo bash apply.sh
# Operates on the ansible/ dir beside this script (run it from anywhere). Each
# run writes its own timestamped log to ./logs/apply-<timestamp>.log.
#
# SSH password auth switches off automatically once a key is set in
# ssh_authorized_keys (ansible/group_vars/all.yml); until then it stays on.
#
# IMAGE_BUILD=1 bash apply.sh  -> also runs the cloud_init + image_generalize
# roles to produce a generalized, cloud-init-ready Vultr image (syspreps the box:
# clears host keys, machine-id, cloud-init state). Snapshot the box afterward.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT/ansible"

LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/apply-$(date +%Y%m%d-%H%M%S).log"

EXTRA=()
[ "${IMAGE_BUILD:-0}" = 1 ] && EXTRA+=(-e image_build=true)

sudo apt-get update && sudo apt-get install -y ansible
ansible-galaxy collection install -r requirements.yml
echo "==> logging this run to $LOG${IMAGE_BUILD:+  (IMAGE BUILD)}"
ANSIBLE_LOG_PATH="$LOG" ansible-playbook -i 'localhost,' -c local site.yml "${EXTRA[@]}"

# Expose the latest log at a fixed path so the dynamic MOTD can find it.
sudo mkdir -p /var/log/ansible-apply
sudo ln -sf "$LOG" /var/log/ansible-apply/latest.log
