#!/usr/bin/env bash
#
# security_report.sh — dump security-relevant configuration and state from a
# headless Debian system into a single text file for OFFLINE review by a
# security-audit agent (the agent never runs on this machine).
#
# Usage:  sudo ./security_report.sh [output_file]
#
# Design notes:
#   * Read-only. It does NOT change system state (no apt-get update, no service
#     restarts). Run `apt-get update` yourself beforehand if you want accurate
#     "upgradable packages" output.
#   * Each section prints the exact command that produced it, then its output.
#   * Secrets are handled carefully: WireGuard/PSK key material is redacted,
#     password hashes are never printed (only `passwd -S` status), and private
#     key *files* are listed by permission only — never dumped.
#   * REVIEW before sharing. Even redacted, this maps your whole attack surface
#     (open ports, users, package versions, public keys, IPs, hostnames).

set -o pipefail
umask 077   # the report itself must not be world-readable

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This script must be run as root (sudo)." >&2
  exit 1
fi

OUT="${1:-security_report_$(hostname -s 2>/dev/null || echo host)_$(date +%Y%m%d_%H%M%S).txt}"

have() { command -v "$1" >/dev/null 2>&1; }

# stdin filter: mask private / pre-shared key material so configs are shareable
redact() {
  sed -E 's/((Private|Preshared)Key[[:space:]]*=).*/\1 <REDACTED>/I'
}

# Section header. The "#=== SECTION:" sentinel is chosen so it can't collide
# with dumped config-file content (many files contain lines starting with "# "
# or "#  "); grep '^#=== SECTION:' reliably extracts the section list.
banner() {
  {
    echo
    echo
    echo "#========================================================================"
    echo "#=== SECTION: $*"
    echo "#========================================================================"
  } >>"$OUT"
}

# run "<shell command>" — record the command, then its combined output
run() {
  local cmd="$1"
  {
    echo
    echo "\$ $cmd"
    echo "----------------------------------------------------------------"
    eval "$cmd" 2>&1
  } >>"$OUT"
}

note() { printf '\n[note] %s\n' "$*" >>"$OUT"; }

# ---------------------------------------------------------------- header ----
{
  echo "SECURITY REPORT"
  echo "Generated : $(date -Is 2>/dev/null || date)"
  echo "Host      : $(hostname -f 2>/dev/null || hostname)"
  echo "Kernel    : $(uname -srm)"
  echo
  echo "Secrets (private keys, password hashes) are redacted or omitted."
  echo "This file describes the system's attack surface — review before sharing."
} >"$OUT"

# ============================================================ SYSTEM ========
banner "SYSTEM IDENTITY & KERNEL"
run 'uname -a'
run 'cat /etc/os-release'
run 'hostnamectl 2>/dev/null'
run 'uptime'
run 'cat /proc/cmdline'                    # boot params: mitigations, audit=1, etc.
run 'cat /sys/kernel/security/lockdown 2>/dev/null'
run 'grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null'

# ============================================================ KERNEL MODS ===
banner "KERNEL MODULES & BLACKLISTS"
run 'lsmod'
run 'tail -v -n +1 /etc/modprobe.d/*.conf /lib/modprobe.d/*.conf 2>/dev/null'

# ============================================================ SYSCTL ========
banner "SYSCTL (kernel/network tunables)"
run 'sysctl -a 2>/dev/null'
run 'tail -v -n +1 /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null'

# ============================================================ USERS/AUTH ====
banner "USERS, GROUPS & AUTHENTICATION"
run 'getent passwd'
run 'getent group'
run 'echo "UID 0 (root-equivalent) accounts:"; grep -E "^[^:]*:[^:]*:0:" /etc/passwd'
run 'echo "Accounts with a login shell:"; grep -vE "(/nologin|/false)\$" /etc/passwd'
run 'echo "Accounts with EMPTY password field (should be none):"; grep -E "^[^:]*::" /etc/shadow'
run 'passwd -Sa'                            # per-account status (L/P/NP), no hashes
run 'grep -E "^[^#]*(PASS_|UMASK|ENCRYPT_METHOD|LOGIN_RETRIES|LOGIN_TIMEOUT)" /etc/login.defs'
run 'tail -v -n +1 /etc/sudoers /etc/sudoers.d/* 2>/dev/null'
run 'echo "sudo/admin group members:"; getent group sudo admin wheel 2>/dev/null'
run 'last -wn 25 2>/dev/null'               # recent logins
run 'lastb -wn 25 2>/dev/null'              # recent FAILED logins
run 'who -a 2>/dev/null'

# ============================================================ SSH ===========
banner "SSH SERVER"
run 'sshd -T 2>/dev/null'                   # effective, fully-resolved config
run 'tail -v -n +1 /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null'
run 'ls -l /etc/ssh/ssh_host_*'             # host key file permissions
run 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f" 2>/dev/null; done'
run 'for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do [ -f "$f" ] && { echo "== $f =="; ls -l "$f"; ssh-keygen -lf "$f" 2>/dev/null; }; done'

# ============================================================ FIREWALL ======
banner "FIREWALL"
if have nft; then
  run 'nft list ruleset'                    # live ruleset
fi
run 'cat /etc/nftables.conf 2>/dev/null'
run 'iptables -S 2>/dev/null; echo; iptables -L -n -v 2>/dev/null'
run 'ip6tables -S 2>/dev/null'
have ufw       && run 'ufw status verbose'
have firewall-cmd && run 'firewall-cmd --list-all 2>/dev/null'

# ============================================================ NETWORK =======
banner "NETWORK: INTERFACES, ROUTES, LISTENERS"
run 'ip -br addr; echo; ip addr'
run 'ip route; echo; ip -6 route'
run 'ss -tulpnH 2>/dev/null | sort'         # all LISTENING sockets + owning process
run 'ss -tupnH state established 2>/dev/null'
run 'cat /etc/hosts'
run 'tail -v -n +1 /etc/hosts.allow /etc/hosts.deny 2>/dev/null'
run 'cat /etc/resolv.conf'
have resolvectl && run 'resolvectl status 2>/dev/null'

# systemd-networkd is the assumed network manager; WireGuard tunnels are
# defined as .netdev/.network units (no wg-quick, no /etc/wireguard/*.conf).
have networkctl && run 'networkctl list 2>/dev/null'
have networkctl && run 'networkctl status -a 2>/dev/null'
# Both go through redact: the WireGuard PrivateKey lives in the .netdev (and
# the .network may carry one too), so neither may be dumped unredacted.
run 'tail -v -n +1 /etc/systemd/network/*.netdev 2>/dev/null | redact'    # incl. wireguard [WireGuard] PrivateKey
run 'tail -v -n +1 /etc/systemd/network/*.network 2>/dev/null | redact'   # incl. any per-link DNS / addressing
have wg && run 'wg show 2>/dev/null'        # public keys / peers only; no private keys

# ============================================================ AUDITD ========
banner "AUDITD"
if have auditctl; then
  run 'systemctl is-active auditd; systemctl is-enabled auditd 2>/dev/null'
  run 'auditctl -s'                          # status (enabled, backlog, failure mode)
  run 'auditctl -l'                          # active rules
  run 'tail -v -n +1 /etc/audit/auditd.conf /etc/audit/rules.d/*.rules 2>/dev/null'
  have aureport && run 'aureport --summary -i 2>/dev/null'
  have aureport && run 'aureport --auth -i --summary 2>/dev/null'
  have aureport && run 'aureport --login -i --summary 2>/dev/null'
else
  note "auditctl not found — auditd is not installed."
fi

# ============================================================ SERVICES ======
banner "SERVICES & UNITS"
run 'systemctl list-units --type=service --state=running --no-legend --no-pager'
run 'systemctl list-unit-files --state=enabled --no-legend --no-pager'
run 'systemctl list-unit-files --state=masked --no-legend --no-pager'
run 'systemctl --failed --no-legend --no-pager'
run 'systemctl list-sockets --no-legend --no-pager 2>/dev/null'

# ============================================================ SCHEDULED =====
banner "SCHEDULED TASKS (cron / timers / at)"
run 'tail -v -n +1 /etc/crontab /etc/cron.d/* 2>/dev/null'
run 'ls -la /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null'
run 'for u in $(cut -f1 -d: /etc/passwd); do c=$(crontab -l -u "$u" 2>/dev/null); [ -n "$c" ] && { echo "== crontab: $u =="; echo "$c"; }; done'
run 'systemctl list-timers --all --no-legend --no-pager 2>/dev/null'
have atq && run 'atq 2>/dev/null'

# ============================================================ PACKAGES ======
banner "PACKAGES & UPDATES"
note "Run 'apt-get update' before this script for an accurate upgradable list."
run 'apt list --upgradable 2>/dev/null'
run 'apt-get -s dist-upgrade 2>/dev/null | grep -iE "^Inst.*security" '
run 'tail -v -n +1 /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null'
run 'tail -v -n +1 /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null'
run 'dpkg -l'                               # full installed package inventory + versions
note "dpkg --verify lists files whose checksum/perms/owner differ from the package (may be slow)."
run 'dpkg --verify 2>/dev/null'

# ============================================================ FILE PERMS ====
banner "FILESYSTEM PERMISSIONS (root filesystem only, -xdev)"
run 'ls -l /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/ssh/sshd_config 2>/dev/null'
run 'ls -ld /root /etc/cron* /boot/grub/grub.cfg 2>/dev/null'
run 'echo "SUID/SGID binaries:"; find / -xdev -type f -perm /6000 -ls 2>/dev/null'
run 'echo "World-writable files:"; find / -xdev -type f -perm -0002 -ls 2>/dev/null'
run 'echo "World-writable dirs without sticky bit:"; find / -xdev -type d -perm -0002 ! -perm -1000 -ls 2>/dev/null'
run 'echo "Files with no owner/group:"; find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null'
have getcap && run 'echo "File capabilities:"; getcap -r / 2>/dev/null'

# ============================================================ MOUNTS ========
banner "MOUNTS & FSTAB"
run 'findmnt -A 2>/dev/null || mount'
run 'cat /etc/fstab'

# ============================================================ PAM/POLICY ====
banner "PAM & PASSWORD POLICY"
run 'tail -v -n +1 /etc/pam.d/common-auth /etc/pam.d/common-password /etc/pam.d/common-account /etc/pam.d/login /etc/pam.d/sshd 2>/dev/null'
run 'cat /etc/security/faillock.conf 2>/dev/null'
run 'cat /etc/security/pwquality.conf 2>/dev/null'
run 'tail -v -n +1 /etc/security/limits.conf /etc/security/limits.d/* 2>/dev/null'

# ============================================================ MAC ===========
banner "MANDATORY ACCESS CONTROL (AppArmor / SELinux)"
have aa-status && run 'aa-status 2>/dev/null'
have getenforce && run 'getenforce 2>/dev/null'
have sestatus && run 'sestatus 2>/dev/null'

# ============================================================ COREDUMP ======
banner "CORE DUMPS"
run 'sysctl fs.suid_dumpable kernel.core_pattern 2>/dev/null'
run 'tail -v -n +1 /etc/systemd/coredump.conf /etc/systemd/coredump.conf.d/* 2>/dev/null'

# ============================================================ MISC ===========
banner "TIME SYNC, LOGGING, BANNERS, PROCESSES"
have timedatectl && run 'timedatectl 2>/dev/null'
run 'tail -v -n +1 /etc/systemd/journald.conf 2>/dev/null'
run 'ls -ld /var/log/journal 2>/dev/null; journalctl --disk-usage 2>/dev/null'
run 'journalctl --no-pager -n 100 -g "Failed password|Invalid user|authentication failure" 2>/dev/null'
run 'tail -v -n +1 /etc/issue /etc/issue.net /etc/motd 2>/dev/null'
run 'grep -rE "umask" /etc/profile /etc/profile.d/ /etc/login.defs /etc/bash.bashrc 2>/dev/null'
run 'ps -eo user,pid,ppid,stime,cmd --sort=user 2>/dev/null'

# ---------------------------------------------------------------- done ----
chmod 600 "$OUT" 2>/dev/null
echo
echo "Security report written to: $OUT"
echo "Permissions set to 600. Review it before sharing with any external tool."
