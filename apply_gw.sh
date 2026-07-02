#!/usr/bin/env bash
# Like apply.sh but runs only the greasewood role — faster for iterative dev.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://gitlab.com/cschlick/postinstall.git"

PROFILE="${PROFILE:-$(cat /etc/postinstall-profile 2>/dev/null || echo base)}"

ansible-galaxy collection install -r "$ROOT/ansible/requirements.yml"

sudo mkdir -p /var/log/ansible-apply
ANSIBLE_LOG_PATH=/var/log/ansible-apply/latest.log \
  ansible-pull -U "$REPO" -d "$ROOT" -i 'localhost,' -c local -l localhost \
    -e "profile=$PROFILE" --tags greasewood ansible/site.yml
