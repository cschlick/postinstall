#!/usr/bin/env bash
# fleet.sh — run the hardening playbook (and ad-hoc checks) across the fleet
# over plain SSH, using the static inventory (ansible/inventory/hosts.yml).
#
# Hosts are keyed to profiles by inventory GROUP (bastion / dev / gw_node);
# the matching group_vars/<profile>.yml applies automatically. The control
# machine needs pmuser's private key (ssh-agent or ~/.ssh) and passwordless
# sudo on the targets. gw_nodes are reached over the mesh via the bastion —
# see the ProxyJump note in group_vars/gw_node.yml.
#
# Commands (extra args after the command pass straight through to ansible):
#   list                 list inventory hosts + groups
#   ping                 connectivity check (are they reachable as pmuser?)
#   check                DRY RUN of site.yml (--check --diff) — start here
#   apply                apply site.yml to the fleet
#   rotate-keys          apply only the ssh role (--tags ssh)
#   local                apply the WORKING TREE to THIS host (-c local).
#                        Gets the default profile unless you opt in, e.g.
#                        ./fleet.sh local -e nftables_ssh_public=true
#   help                 this message
#
# Examples:
#   ./fleet.sh list
#   ./fleet.sh local --check --diff               # dry-run against localhost
#   ./fleet.sh check --limit gw_node              # dry-run one profile group
#   ./fleet.sh apply --limit dev                  # apply to one group first
#   ./fleet.sh apply                              # ...then the whole fleet
#   # SSH key rotation (after editing ssh_authorized_keys in group_vars):
#   ./fleet.sh rotate-keys --limit bastion                            # 1. add new key, test
#   ./fleet.sh rotate-keys -e ssh_authorized_keys_exclusive=true      # 2. drop the old key
#
# Safety: prefer `check` and `--limit` before a fleet-wide `apply`. The disruptive
# roles (ssh/nftables/networkd) can drop connections; roll out in batches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$ROOT/$(basename "${BASH_SOURCE[0]}")"   # absolute path (we cd away below)
cd "$ROOT/ansible"

INV="inventory/hosts.yml"

# Print the header comment block (everything between the shebang and the code).
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$SELF"; }

cmd="${1:-help}"; shift || true

# Warn about hosts in no profile group: they fall through to the permissive
# default profile (public SSH), which is a lockout-safe default but a silent
# exposure if left that way. Non-fatal — just a heads-up.
preflight_groups() {
  local json stragglers
  json="$(ansible-inventory -i "$INV" --list 2>/dev/null)" || return 0
  stragglers="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
allh = set(d.get("_meta", {}).get("hostvars", {}))
grouped = set()
for g in ("open", "bastion", "dev", "gw_node"):
    grouped |= set(d.get(g, {}).get("hosts", []))
print("\n".join(sorted(allh - grouped)))
' 2>/dev/null)" || return 0
  if [ -n "$stragglers" ]; then
    echo "fleet.sh: WARNING — these hosts are in no profile group (open/bastion/dev/gw_node)" >&2
    echo "          and will use the permissive DEFAULT profile (public SSH):" >&2
    printf '            %s\n' $stragglers >&2
    echo >&2
  fi
}

case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
  local)       exec ansible-playbook -i 'localhost,' -c local -l localhost site.yml "$@" ;;
  list)        exec ansible-inventory -i "$INV" --graph "$@" ;;
  ping)        exec ansible          -i "$INV" all -m ansible.builtin.ping "$@" ;;
  check)       preflight_groups; exec ansible-playbook -i "$INV" site.yml --check --diff "$@" ;;
  apply)       preflight_groups; exec ansible-playbook -i "$INV" site.yml "$@" ;;
  rotate-keys) preflight_groups; exec ansible-playbook -i "$INV" site.yml --tags ssh "$@" ;;
  *) echo "fleet.sh: unknown command '$cmd'" >&2; echo >&2; usage; exit 2 ;;
esac
