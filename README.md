# postinstall

Ansible-based hardening for a fresh **headless Debian 13 (trixie)** host. Run
the playbook once on a new box (or bake it into an image) and it applies a
drop-by-default firewall, SSH hardening, kernel/sysctl tightening, auditing,
and a set of smaller service-hardening steps — each as its own role, each
behind a tag so you can run any subset.

> This repo was previously an interactive Python script (`postinstall.py`). That
> component has been removed; everything now lives under `ansible/`. The only
> non-Ansible piece kept is `security_report.sh` (a read-only audit reporter).

## Layout

```
ansible/
  site.yml                 # the playbook — all roles, each tagged
  ansible.cfg              # inventory path, roles path, yaml stdout
  requirements.yml         # Galaxy collections (ansible.posix, community.general)
  inventory/hosts.yml      # targets (empty by default — uses localhost)
  group_vars/all.yml       # tunables (ssh authorized_keys, AllowUsers, fail2ban_ignoreip, …)
  roles/<role>/            # one role per hardening concern
    defaults/ meta/ tasks/ handlers/ templates/
    molecule/default/      # per-role Molecule test scenario
apply.sh                   # install Ansible + collections, then apply ansible/site.yml (idempotent)
fleet.sh                   # run the playbook across the Vultr fleet (wraps inventory + vault flags)
security_report.sh         # read-only attack-surface report (see below)
```

## Quick start

> ### 🔑 Where do my SSH keys go?
> Put your **public** key in **`ansible/group_vars/all.yml`**, under
> `ssh_authorized_keys` (a map of *unix-user → public key*):
>
> ```yaml
> ssh_authorized_keys:
>   pmuser: "ssh-ed25519 AAAA...your-key... you@laptop"
> ```
>
> Re-run `bash apply.sh` and the `ssh` role installs the key **and** switches
> password auth off automatically. Public keys only (never a private key); the
> user must already exist. More detail in [SSH password auth → key-only](#ssh-password-auth--key-only-automatic).

### 1. Install Ansible + collections

The convenience script apt-installs Ansible, installs the required Galaxy
collections, and applies the playbook to the local host — i.e. steps 1 and 2 in
one go. It's idempotent, so re-running is safe. Each run writes its own
timestamped log to `./logs/apply-<timestamp>.log`. Run it from the repo root; it
finds `ansible/` itself:

```bash
bash apply.sh          # fully non-interactive
```

It runs unattended, so `become` needs **passwordless sudo** — or run the whole
script as root:

```bash
sudo bash apply.sh
```

…or do it by hand:

```bash
sudo apt-get install -y ansible
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 2. Run it

The inventory is empty by default, so target the local machine over a local
connection. `-K` prompts for the sudo (become) password:

```bash
cd ansible
ansible-playbook -i 'localhost,' -c local site.yml -K
```

To manage **remote** hosts instead, add them under `all:` in
`inventory/hosts.yml` and drop the `-i/-c` flags:

```yaml
all:
  hosts:
    vps01:
      ansible_host: 203.0.113.10
      ansible_user: deploy
```

```bash
ansible-playbook site.yml -K          # or rely on SSH keys / become config
```

### Dry run first

```bash
ansible-playbook -i 'localhost,' -c local site.yml -K --check --diff
```

(`--check` may report errors on tasks that depend on an earlier task having
actually run — normal for a no-op dry run.)

## SSH password auth → key-only (automatic)

> **🔑 Your public key goes in `ansible/group_vars/all.yml`**, under
> `ssh_authorized_keys`:
> ```yaml
> ssh_authorized_keys:
>   pmuser: "ssh-ed25519 AAAA...your-key... you@laptop"
> ```

There's no mode to choose. The `ssh` role disables password authentication
**automatically once a key is present** in `ssh_authorized_keys`, and keeps it
on until then — so the same command does the right thing on every run:

```bash
# First run — no key yet -> password auth stays ON
bash apply.sh

# Add your key to ansible/group_vars/all.yml, e.g.:
#   ssh_authorized_keys:
#     pmuser: "ssh-ed25519 AAAA... you@laptop"

# Re-run — key present -> key installed AND password auth turned OFF
bash apply.sh
```

Mechanically, `ssh_password_authentication` defaults to
`{{ 'no' if ssh_authorized_keys | length > 0 else 'yes' }}`; set it explicitly
to `"yes"`/`"no"` to override (e.g. if you manage keys out of band). Because the
switch is driven by the key being present, you **can't lock yourself out by
forgetting a key** — only by installing a *wrong* one, so test key login in a
separate session before trusting it.

## ⚠️ Disruptive roles

A few roles can interrupt connectivity or lock you out. Apply them with console
access, or last, once you've confirmed the safe roles:

- **`networkd`** — switches networking to systemd-networkd. **Drops the live
  link briefly** (an SSH session usually survives if DHCP returns the same IP; a
  reboot finalises it cleanly).
- **`nftables`** — installs a **drop-by-default** firewall (only loopback,
  established, essential ICMP, and SSH/22 are allowed).
- **`ssh`** — rewrites `sshd_config`, removes the ECDSA host key, restarts ssh.
  Disables password auth automatically once `ssh_authorized_keys` has a key —
  **make sure that key works first**.

Run only the safe subset, then the rest from a console:

```bash
ansible-playbook -i 'localhost,' -c local site.yml -K \
  --skip-tags ssh,nftables,networkd
```

## Running subsets

Every role is tagged. Run or skip any combination:

```bash
ansible-playbook ... --tags sysctl,auditd,pwquality        # just these
ansible-playbook ... --skip-tags system_upgrade            # skip the one-off apt upgrade
```

## Roles

Applied in this order (see `site.yml`). Tag = role name unless noted.

| Role | What it does |
| --- | --- |
| **hostname** | Sets the hostname via `hostnamectl` (no-op unless `system_hostname` is set). |
| **system_upgrade** | `apt update` + `apt upgrade --with-new-pkgs` (one-off catch-up patch). Skip with `--skip-tags system_upgrade`. |
| **ssh** | Hardened `sshd_config`: no root login, strong KEX/ciphers/MACs, no NIST ECDSA host key, `MaxAuthTries`/grace limits, forwarding/X11 off. Auth-critical settings also written to `sshd_config.d/00-hardening.conf` (sorts before cloud-init's drop-in). Password auth turns off automatically once `ssh_authorized_keys` has a key. |
| **sysctl** | Network + kernel hardening drop-in (rp_filter, SYN cookies, no source routing/redirects, `kptr_restrict`, ptrace scope, unprivileged-eBPF/userns off, kexec disabled, RFC 1337, per-interface `accept_redirects=0`, …). |
| **nftables** | Drop-by-default `inet filter`: loopback, established/related, essential ICMP/ICMPv6, SSH/22. `forward` drop, `output` accept. Extra ports via `nftables_extra_tcp_ports`. |
| **packages** | Installs a base set (`packages_install`) and purges desktop/X/locale cruft + `ufw` (`packages_remove`); disables apt Recommends/Suggests. |
| **auditd** | `auditd` + a hardened ruleset (time/account/login changes, sudo/su, module loads, mounts, key config files); loginuid locked; bumped log retention. Optional immutable (`-e 2`) via `auditd_immutable`. |
| **pwquality** | `libpam-pwquality` policy drop-in (`minlen=12`, `minclass=3`, dictionary/sequence checks, `enforce_for_root`). Enforced at password-change time. |
| **pam** | Strips `nullok` from `pam_unix` (no empty-password auth) and wires `pam_faillock` into `common-auth`/`common-account` — locks an account after repeated failures on the local console/sudo path (`deny=5`, 15-min window/auto-unlock; root excluded). Tunable via `pam_faillock_*`. |
| **group_prune** | Removes a user from peripheral/desktop supplementary groups it doesn't need on a headless box (cdrom/floppy/audio/dip/video/plugdev/users/netdev). Configured via `group_prune`; never touches `sudo` or the primary group. |
| **networkd** | Switches networking to systemd-networkd (DHCP on `en*`), neutralises ifupdown. **Disruptive** — see above. |
| **resolved** | Enables systemd-resolved, applies split-DNS routing domains, disables LLMNR/mDNS, points `/etc/resolv.conf` at the stub. |
| **coredump** | Disables core dumps: `fs.suid_dumpable=0`, `hard core 0` limits, `Storage=none` for systemd-coredump. |
| **mounts** | `noexec,nosuid,nodev` for `/dev/shm`, `/tmp` (tmpfs), `/var/tmp` (bind) via `/etc/fstab`. |
| **unattended_upgrades** | Installs/configures `unattended-upgrades` — `unattended_upgrades_mode: security` (default) or `all`. |
| **timesync** | `systemd-timesyncd` pointed at the Debian NTP pool (+ Cloudflare fallback); enables network time sync. |
| **fail2ban** | `fail2ban` with an `[sshd]` jail reading the journal and **banning via nftables**. Set `fail2ban_ignoreip` to your admin subnet. |
| **module_blacklist** | Blacklists desktop/peripheral kernel modules (audio, bluetooth, webcam, joystick) and rebuilds the initramfs. GPU/DRM left commented (don't blind a VM console). Reboot to apply. |
| **disable_mdns** | Stops, masks and purges `avahi-daemon`. |
| **disable_cups** | Stops, disables and masks `cups`, `cups-browsed`, and `cups.socket`. |
| **cloudinit_cleanup** | Strips stale `options ipv6 … disable=1` modprobe lines, deletes cloud-init's `50-cloud-init.conf` sshd drop-in (so it can't re-assert password auth), and optionally disables cloud-init (`cloudinit_disable`). |
| **cloud_init** | *(image builds only)* Installs cloud-init, points it at the **Vultr** datasource, disables cloud-init networking (networkd owns the link), suppresses the distro default user / password auth (pmuser is baked in), and regenerates only ed25519+rsa host keys per instance. |
| **image_generalize** | *(image builds only — runs **last**)* Syspreps the box for snapshotting: `cloud-init clean`, deletes SSH host keys, blanks `/etc/machine-id`, clears logs/cache/history — so every instance deployed from the snapshot is unique and re-provisions on first boot. |

### Not included (by design)

User account management (create/remove/set-password), dotfiles, WireGuard, NFS
mounts, and "disable root password" are intentionally **not** ported — they're
interactive or per-host provisioning concerns rather than headless hardening.

## Key variables

Set in `group_vars/all.yml`, `host_vars/<name>.yml`, or `-e`. The most important:

```yaml
# ssh role — add a key and password auth turns off automatically (see above)
ssh_authorized_keys: {}       # { deploy: "ssh-ed25519 AAAA… user@host" }
ssh_allow_users: []           # e.g. ["deploy"] => AllowUsers restriction
# ssh_password_authentication: "no"   # optional explicit override (default: auto)

# fail2ban role — add your admin subnet so a typo can't ban you
fail2ban_ignoreip: ["127.0.0.1/8", "::1"]

# unattended_upgrades role
unattended_upgrades_mode: security   # or: all

# hostname role
system_hostname: ""           # empty => leave hostname unchanged
```

Each role's `defaults/main.yml` documents the rest.

## Building a Vultr image

`IMAGE_BUILD=1 bash apply.sh` runs the full hardening **plus** the `cloud_init`
and `image_generalize` roles, producing a generalized, cloud-init-ready disk you
can snapshot into a reusable Vultr image.

```bash
# On a throwaway Debian box (a Vultr instance, or any Debian 13 VM):
sudo IMAGE_BUILD=1 bash apply.sh
# ...then snapshot it from the Vultr panel (Snapshots → Take Snapshot).
```

What the image build adds on top of the normal run:

- **cloud-init + the Vultr datasource** — on first boot each deployed instance
  pulls its hostname from Vultr metadata and grows the root filesystem. Vultr
  hands out the primary IPv4 over **DHCP**, which your baked `systemd-networkd`
  unit already does, so cloud-init networking is left disabled.
- **Baked identity, deferred uniqueness** — `pmuser` + your key + `AllowUsers
  pmuser` (key-only) are baked in, so you log in the same way on every instance
  (the Vultr-panel SSH key is ignored). Host keys and `machine-id` are wiped at
  the end and regenerated uniquely on first boot.
- **Sysprep last** — `image_generalize` clears cloud-init state, host keys,
  machine-id, logs and history. It runs **only** with `image_build=true`, so a
  normal `apply.sh` never touches them.

> **Snapshot right after the build run.** The box is "generalized" afterward
> (no host keys / machine-id) and shouldn't be used as-is — it's meant to be
> imaged. Optionally `image_generalize_poweroff: true` powers it off at the end.

## Managing a running fleet (Vultr dynamic inventory)

`inventory/vultr.yml` discovers your running Vultr instances from the API, so you
can apply the playbook (or rotate keys) across the whole fleet — no hand-kept
host list. Requires the `vultr.cloud` collection (in `requirements.yml`).

### One-time control-machine setup

Do this **once on the machine you'll run the fleet from** (your admin/control box
— *not* the hardened targets):

**1. Install Ansible + collections** (incl. the `vultr.cloud` inventory plugin):

```bash
git clone https://github.com/cschlick/postinstall && cd postinstall
sudo apt-get update && sudo apt-get install -y ansible python3-requests
ansible-galaxy collection install -r ansible/requirements.yml
```

**2. Vault your Vultr API key** (encrypted at rest, never plaintext):

```bash
cd ansible
# choose a vault passphrase, stash it locally (git-ignored); add the export to
# your shell profile so it persists
echo 'your-vault-passphrase' > ../.vault_pass && chmod 600 ../.vault_pass
export ANSIBLE_VAULT_PASSWORD_FILE="$PWD/../.vault_pass"

# encrypt the API key into a vars file (safe to commit — it's encrypted)
ansible-vault create inventory/vault.yml
#   add one line in the editor that opens:
#     vultr_api_key: your-real-vultr-api-key
```

> `.vault_pass` is git-ignored — **never commit it**. `inventory/vault.yml` is
> safe to commit (encrypted). No-vault alternative: `export VULTR_API_KEY=…` —
> the inventory falls back to the env var.

**3. SSH access to the fleet.** The hardening is key-only + `AllowUsers pmuser`,
so the control machine needs:

- **pmuser's private key** loaded (ssh-agent or `~/.ssh/`) — the counterpart of
  the public key in `ssh_authorized_keys` (baked into your image).
- **passwordless sudo for pmuser** on the targets (runs are non-interactive).
- instances **tagged** in Vultr (e.g. `production`, `canary`) so `--limit
  tag_<name>` works.

Then `./fleet.sh list` should show your instances, and you're ready to go.

### The `fleet.sh` wrapper

`fleet.sh` bundles the `-i inventory/vultr.yml`, `-e @inventory/vault.yml`, and
vault-password flags so you don't repeat them. With the vault set up above (or
`VULTR_API_KEY` exported), it auto-detects auth — `inventory/vault.yml` +
`.vault_pass` means zero prompts. Run `./fleet.sh help` for the full reference.

```bash
./fleet.sh list                          # discovered hosts + groups
./fleet.sh ping                          # are they reachable as pmuser?
./fleet.sh check --limit tag_canary      # dry-run one group
./fleet.sh apply --limit tag_canary      # apply to one group...
./fleet.sh apply                         # ...then the whole fleet
```

Extra args after the command pass straight through to ansible (`--limit`,
`--check`, `-e ...`, etc.). The raw equivalents are below if you prefer them.

It connects as **pmuser** (set in `group_vars`) over each host's public IPv4, and
auto-creates groups by region and tag (`region_ewr`, `tag_production`, …) for
targeting subsets (see control-machine setup above for the SSH/sudo prereqs).

Roll out safely (raw commands; all also accept `-e @inventory/vault.yml`):

```bash
ansible-playbook -i inventory/vultr.yml site.yml --limit tag_canary   # one group first
ansible-playbook -i inventory/vultr.yml site.yml --check --diff       # dry-run all hosts
# add `serial: 10` (or `30%`) to the play to update in rolling batches
```

### Rotating SSH keys across the fleet

`ssh_authorized_keys` is the source of truth, and the `ssh` role can make a
host's `authorized_keys` *exactly* that set. Rotate **without lockout risk** by
adding the new key first, verifying, then dropping the old:

```bash
# 1. Add NEW alongside OLD (a list value) — additive, so OLD still works:
#      ssh_authorized_keys:
#        pmuser: ["ssh-ed25519 AAAA... OLD", "ssh-ed25519 BBBB... NEW"]
./fleet.sh rotate-keys --limit tag_canary    # try a canary first

# 2. Confirm the NEW key logs in (test a canary host).

# 3. Drop OLD — keep only NEW and run exclusively (removes anything not listed):
#      ssh_authorized_keys:
#        pmuser: "ssh-ed25519 BBBB... NEW"
./fleet.sh rotate-keys -e ssh_authorized_keys_exclusive=true
```

`ssh_authorized_keys_exclusive` defaults to **false** (routine runs never remove
a key by surprise); pass `true` only for the deliberate removal step. ⚠️ Test the
new key first — an exclusive run with a wrong key replaces the only key
fleet-wide.

## Host profiles: bastion vs gw_node

SSH exposure is chosen per host by a **Vultr tag**, via the dynamic inventory
(`group_vars/tag_<tag>.yml` attaches to the auto-created `tag_<tag>` group).

| Tag | SSH reachable on | Forwarding |
|-----|------------------|------------|
| `bastion` | public internet **and** `gw-mesh` | TCP forwarding for ProxyJump (`PermitOpen *:22`), no agent forwarding |
| `gw_node` | `gw-mesh` overlay only | none (`DisableForwarding yes`) |
| *(untagged)* | public internet (the lockout-safe **default**) | none |

The default is permissive on purpose: a brand-new or untagged node always comes
up publicly reachable, so you can never lock yourself out. Lock a node down only
**after** it is reachable over `gw-mesh`:

```bash
# A fresh instance comes up untagged (public). Once it's on the mesh:
#   tag it gw_node in Vultr (web console or API), then:
./fleet.sh check --limit tag_gw_node     # dry-run the locked-down group
./fleet.sh apply --limit tag_gw_node
./fleet.sh apply                         # whole fleet; each host self-selects its profile
```

Tag a node **either** `bastion` **or** `gw_node`, never both. `./fleet.sh
check|apply` warns about any host carrying neither tag (it would sit on the
public default). The first instance (the bastion) is bootstrapped locally and
needs no tag — it gets the default/bastion profile:

```bash
bash apply.sh            # on the box: pulls the repo, applies the default profile
./fleet.sh local         # alt: apply the working tree to THIS host (no Vultr key)
```

### Reaching gw_nodes through the bastion (ProxyJump)

gw_nodes accept SSH only over the mesh, so hop through the bastion. ProxyJump
keeps your private keys on your laptop (the bastion only forwards the TCP
connection — it never sees your agent), which is why agent forwarding is off.

```bash
ssh -J pmuser@<bastion-public-ip> pmuser@<gw_node-mesh-addr>
```

Or make it automatic in `~/.ssh/config`:

```sshconfig
Host bastion
    HostName <bastion-public-ip>
    User pmuser

# Any mesh node: ssh gw-<name> and it jumps via the bastion automatically.
Host gw-*
    User pmuser
    ProxyJump bastion
```

```bash
ssh gw-web01      # = ssh -J bastion, transparently
```

(The bastion's `ssh_permit_open` is `*:22` — it can only forward to SSH, nothing
else. Tighten to `<gw-mesh-cidr>:22` if you want to restrict it to mesh hosts.)

## Testing (Molecule)

Every role has a Molecule scenario (`roles/<role>/molecule/default/`) that spins
up a systemd Docker container, applies the role, and asserts the result — without
touching your host. The scenarios set each role's `*_apply: false` guard so
host-global actions (the clock, the kernel, the firewall) are staged, not run.

```bash
sudo apt-get install -y docker.io && sudo usermod -aG docker "$USER"   # log out/in after
pip install molecule "molecule-plugins[docker]" ansible
docker build -t molecule-trixie-systemd ansible/roles/ssh/molecule/default   # once
cd ansible/roles/fail2ban && molecule test                              # per role
```

Quick static checks without Docker:

```bash
cd ansible
ansible-playbook -i 'localhost,' -c local site.yml --syntax-check
```

## Security report

`security_report.sh` is a **read-only** reporter — it changes nothing — that
dumps the host's attack surface (kernel, modules, sysctl, users, SSH, firewall,
listeners, auditd, services, cron, packages, PAM, MAC, …) to a timestamped file
for review:

```bash
sudo bash security_report.sh        # writes security_report_<host>_<ts>.txt (mode 0600)
```

The output maps your whole attack surface, so **review it before sharing**. It's
git-ignored (`security_report_*.txt`).
