# postinstall

Ansible-based hardening for a fresh **headless Debian 13 (trixie)** host on
Vultr: drop-by-default firewall, key-only SSH, kernel/sysctl tightening,
auditing, and a set of smaller service-hardening steps — one role per concern,
each behind a tag so you can run any subset.

## Cheat sheet

```bash
bash apply.sh                     # pull latest from GitLab + apply to THIS host (bastion, the default)
DEV=1 bash apply.sh               # same, dev profile (open dev box: IPv4+pw SSH, Claude Code)
GW_NODE=1 bash apply.sh           # same, gw_node profile (mesh-only SSH, locked down)
NATS=1 GW_NODE=1 bash apply.sh    # gw_node + nats service profile (mesh-only JetStream, mTLS)
POSTGRES=1 GW_NODE=1 bash apply.sh  # gw_node + postgres service profile (mesh-only, mTLS)
ACCOUNT=1 GW_NODE=1 bash apply.sh    # gw_node + account plane (GHCR container/quadlet, remote PG); needs the vault pw
IMAGE_BUILD=1 bash apply.sh       # image build (then snapshot in the Vultr panel)
bash apply_gw.sh                  # greasewood role only — fast iteration

./fleet.sh list                   # fleet mode: list inventory hosts + groups
./fleet.sh check --limit gw_node  # dry-run one profile group
./fleet.sh apply                  # apply to the whole fleet over SSH
./fleet.sh rotate-keys            # apply only the ssh role (key rotation)

bash set-pmuser-password.sh       # rotate pmuser's console password (updates repo)
sudo bash security_report.sh      # read-only attack-surface report
```

`apply.sh` is an `ansible-pull` wrapper: it fetches the latest commit from
GitLab, then applies `ansible/site.yml` locally. Ansible must already be
installed (the boot script handles that on a fresh box). Each run logs to
`/var/log/ansible-apply/latest.log`, summarized in the login MOTD.

To birth a new locked-down mesh node, paste the `gw_node` script into the
Vultr startup-script field (fill in a single-use enrollment token first).

## Fleet mode

**Inventory does not live in this repo.** The deploy repo
([postmodern-you/postmodern-deploy](https://github.com/postmodern-you/postmodern-deploy),
private) creates instances via the Vultr API, records them, and renders an
ansible hosts file where each host sits in its profile group(s) — the
matching `group_vars/<profile>.yml` applies automatically. Point fleet.sh at
it with `FLEET_INVENTORY`.
Connections are plain SSH as **pmuser**: the control machine needs pmuser's
private key, and runs need `-K` (sudo prompts for pmuser's password — the
emergency console password; only `gw` is NOPASSWD). gw_nodes are listed by
their mesh address and reached via the bastion (ProxyJump — see
`group_vars/gw_node.yml`).

Roll out safely — one group first:

```bash
export FLEET_INVENTORY=~/software/postmodern-deploy/inventory/ansible-hosts.yml
./fleet.sh list                          # what's in the inventory?
./fleet.sh ping                          # reachable as pmuser?
./fleet.sh check --limit dev             # dry-run one profile group
./fleet.sh apply --limit dev             # apply to it
./fleet.sh apply                         # then the whole fleet
./fleet.sh local                         # apply the WORKING TREE to this host
```

Extra args pass through to ansible (`--limit`, `--check`, `-e ...`).
`check`/`apply` warn about hosts that sit in no profile group.

## Profiles

Profiles decide a host's SSH exposure. Each is a vars file in
`ansible/group_vars/`; you select one **locally** with an env flag on
`apply.sh`, or **fleet-wide** via the host's group membership in the deploy
repo's rendered inventory (`pmdeploy create --profile …`):

| Profile | SSH reachable on | Password SSH | Claude Code | Purges accounts | Apply to localhost | Apply via fleet |
|---------|------------------|--------------|-------------|-----------------|--------------------|-----------------|
| **bastion** *(default)* | public internet (IPv6) **and** `gw-*` | no (key-only) | no | yes | `bash apply.sh` | group `bastion` (ungrouped hosts behave the same) |
| **dev** | public internet (IPv4 **and** IPv6) **and** `gw-*` | **yes** (emergency password) | **yes** | **no** | `DEV=1 bash apply.sh` | group `dev` |
| **gw_node** | `gw-*` overlay only | no | no | yes | `GW_NODE=1 bash apply.sh` | group `gw_node` |

All profiles except gw_node serve ProxyJump (SSH-only local forwarding,
`PermitOpen *:22`; agent forwarding off everywhere). **bastion** is the
network-hardened default — a brand-new or unlisted node always comes up this
way, publicly reachable and key-only, so you can't lock yourself out.
**dev** is the very open development box (faillock and PerSourcePenalties
still throttle password guessing). **gw_node** is fully locked down: no
public SSH at all — move a host there only **after** it is reachable over
the mesh (the Vultr console is the fallback). Reach gw_nodes through the
bastion:

```sshconfig
Host bastion
    HostName <bastion-public-ip>
    User pmuser

Host gw-*
    User pmuser
    ProxyJump bastion
```

ProxyJump only forwards the TCP connection — your keys never touch the
bastion (agent forwarding is off everywhere).

**Service profiles stack on the exposure profiles**: `nats` adds a mesh-only
NATS JetStream server (mutual TLS via the mesh CA, ports 4222/8222 open on
the overlay interface only); `postgres` adds a mesh-only PostgreSQL the same
way (mTLS-only pg_hba, port 5432); `account` runs the postmodern account plane
as a GHCR **container** (podman quadlet) against a **remote** Postgres, client-
facing on :8766. Put the host in **both** its base group and the service group
in the inventory, or e.g. `NATS=1 GW_NODE=1 bash apply.sh` locally. Stacking
several service profiles on ONE host needs a host_vars override listing all
their mesh ports (group_vars lists don't merge): `nftables_mesh_tcp_ports:
[4222, 8222, 5432]`.

Unlike the native mesh infra above, `account` is an **application workload** —
it runs the CI-published image (`ghcr.io/postmodern-you/postmodern-accounts:<tag>`)
rather than an apt/venv service. Its secrets (voucher seed, anon-issuer key, GHCR
pull token) live in an ansible-vault file (`group_vars/account/vault.yml`, from
the `.example`); provide the vault password via `ANSIBLE_VAULT_PASSWORD_FILE`.

## SSH keys

Public keys live in `ansible/group_vars/all.yml` under `ssh_authorized_keys`
(unix-user → key string or list of key strings):

```yaml
ssh_authorized_keys:
  pmuser: "ssh-ed25519 AAAA...your-key... you@laptop"
```

The `ssh` role installs the key **and switches password auth off
automatically once a key is present** (on until then, so you can't lock
yourself out by forgetting a key — only by installing a wrong one; test it in
a separate session first). Override with `ssh_password_authentication: "yes"/"no"`.

Rotate without lockout risk: add the NEW key alongside the OLD (list value),
`./fleet.sh rotate-keys`, verify the new key logs in, then keep only NEW and
run `./fleet.sh rotate-keys -e ssh_authorized_keys_exclusive=true` to drop
everything not listed. ⚠️ Exclusive mode replaces the only key fleet-wide —
test first.

## ⚠️ Disruptive roles

Apply these with console access handy:

- **`networkd`** — switches to systemd-networkd; drops the live link briefly.
- **`nftables`** — drop-by-default firewall (loopback, established, essential
  ICMP, SSH, and the greasewood/WireGuard ports only).
- **`ssh`** — rewrites `sshd_config`, restarts ssh, disables password auth
  once a key is present — **make sure that key works first**.

```bash
ansible-playbook -i 'localhost,' -c local site.yml -K --skip-tags ssh,nftables,networkd
```

## Roles

Applied in this order (see `site.yml`). Tag = role name. Run subsets with
`--tags sysctl,auditd` / `--skip-tags system_upgrade`.

| Role | What it does |
| --- | --- |
| **hostname** | Sets the hostname (no-op unless `system_hostname` is set). |
| **accounts** | Ensures pmuser exists (sudo with password — NOPASSWD only for `gw` — ed25519 keypair, emergency console password from `pmuser_password_hash`); fully purges `linuxuser`. |
| **system_upgrade** | One-off `apt upgrade --with-new-pkgs` catch-up. |
| **ssh** | Hardened `sshd_config`: no root login, strong algos only, `PerSourcePenalties` brute-force throttle, `AllowUsers pmuser`, forwarding per host profile (ProxyJump on bastion, none elsewhere). Password auth off automatically once a key is present. |
| **sysctl** | Network + kernel hardening (rp_filter, SYN cookies, `kptr_restrict`, ptrace scope, unprivileged-eBPF/userns off, kexec disabled, …). |
| **nftables** | Drop-by-default `inet filter`: loopback, established, essential ICMP/ICMPv6, SSH (public or mesh-only per `nftables_ssh_public`), greasewood/WireGuard ports. |
| **packages** | Installs a base set, purges desktop/X/build cruft + ufw + fail2ban; disables apt Recommends. |
| **greasewood** | Installs the greasewood mesh CLI into `/opt/greasewood` (force-reinstalled from GitLab each apply → always current), symlinks `gw`, installs systemd units (daemon starts itself once a config appears). |
| **claude_code** | *(dev profile only)* Installs Claude Code for pmuser via the native installer; re-run each apply so it stays current. Symlinks `claude` into `/usr/local/bin`. |
| **nats** | *(nats profile only)* NATS JetStream bound to the mesh overlay address only, mutual TLS via the mesh CA (`gw cert-request --profile nats`, auto-renewed by the gw daemon). Firewall opens 4222/8222 on the overlay interface only. |
| **postgres** | *(postgres profile only)* PostgreSQL bound to the mesh overlay address only; pg_hba is mTLS-only (`hostssl` + `clientcert=verify-ca`, no plain-TCP path). Cert via `gw cert-request --profile postgres`. Firewall opens 5432 on the overlay interface only. |
| **account_server** | *(account profile only)* The postmodern account plane as a pinned GHCR container via a podman quadlet (`Network=host`, remote Postgres, `/healthz` deploy gate). Secrets from ansible-vault. Runtime contract: `postmodern-accounts/CONTAINER.md`. |
| **auditd** | Hardened audit ruleset (account/login changes, sudo, module loads, mounts, key files); locked loginuid; optional immutable mode. |
| **pwquality** | Password-quality policy (`minlen=12`, `minclass=3`, dictionary checks). |
| **pam** | Strips `nullok` from pam_unix; wires `pam_faillock` lockout into the console/sudo path. |
| **root_password** | Locks root's shadow password field to `!` (no password login path, no usable hash). |
| **group_prune** | Drops pmuser from peripheral/desktop groups it doesn't need. |
| **networkd** | Switches to systemd-networkd (DHCP on `en*`). **Disruptive.** |
| **resolved** | systemd-resolved with split-DNS, LLMNR/mDNS off. |
| **coredump** | Disables core dumps system-wide. |
| **mounts** | `noexec,nosuid,nodev` on `/dev/shm`, `/tmp`, `/var/tmp`. |
| **unattended_upgrades** | Auto-applies security updates; auto-reboots at 02:00 when a kernel update needs it. |
| **timesync** | systemd-timesyncd → Debian NTP pool. |
| **module_blacklist** | Blacklists desktop/peripheral kernel modules; reboot to apply. |
| **disable_mdns** | Stops, masks and purges avahi. |
| **disable_cups** | Stops, disables and masks cups. |
| **motd** | Dynamic login MOTD: cloud-init status (with error detail) + last-apply summary. |
| **cloud_init** | *(image builds only)* cloud-init with the Vultr datasource; networking left to networkd. |
| **cloudinit_cleanup** | Removes cloud-init's sshd drop-in and stale ipv6-disable lines, masks the Vultr image's root log-reader TTY, deletes root's authorized_keys, points cloud-init's default_user at pmuser. |
| **image_generalize** | *(image builds only — last)* Sysprep: wipes host keys, machine-id, cloud-init state, logs. Snapshot right after. |

Not ported by design (interactive / per-host provisioning): dotfiles,
per-user passwords beyond pmuser's emergency hash, NFS mounts.

Key tunables live in `ansible/group_vars/all.yml` (SSH keys, AllowUsers,
`pmuser_password_hash`, upgrade mode); each role's `defaults/main.yml`
documents the rest.

## Layout

```
ansible/
  site.yml                 # the playbook — all roles, each tagged
  requirements.yml         # Galaxy collections
  group_vars/all.yml       # main tunables (SSH keys, AllowUsers, password hash, …)
  group_vars/<profile>.yml # host profiles (bastion, dev, gw_node)
  roles/<role>/            # one role per hardening concern (+ molecule/ test)
apply.sh                   # ansible-pull wrapper: fetch latest + apply locally
apply_gw.sh                # like apply.sh, greasewood role only
fleet.sh                   # fleet mode wrapper (applies site.yml over SSH)
gw_node                    # Vultr startup script: birth a locked-down mesh node
set-pmuser-password.sh     # rotate pmuser's console password hash (in-repo)
security_report.sh         # read-only attack-surface report
```

## Building a Vultr image

```bash
sudo IMAGE_BUILD=1 bash apply.sh    # on a throwaway Debian 13 box
# ...then snapshot it from the Vultr panel.
```

- Adds the `cloud_init` + `image_generalize` roles: cloud-init pulls the
  hostname and grows the filesystem on first boot; networkd owns the link.
- pmuser + your key are baked in; host keys and machine-id are wiped and
  regenerate uniquely per instance.
- **Snapshot immediately** — the box is generalized (no host keys) afterward.

## Testing (Molecule)

Each role has a Molecule scenario that applies it in a systemd Docker
container and asserts the result:

```bash
sudo apt-get install -y docker.io && sudo usermod -aG docker "$USER"
pip install molecule "molecule-plugins[docker]" ansible
docker build -t molecule-trixie-systemd ansible/roles/ssh/molecule/default   # once
cd ansible/roles/accounts && molecule test                                   # per role
cd ansible && molecule test -s profiles     # FULL site.yml, one container per profile
```

The `profiles` scenario is the end-to-end check: three systemd containers
join the bastion / dev / gw_node inventory groups, converge the real
`site.yml` (host-global actions staged via the `*_apply` guards), prove
idempotence, and assert the profile-differentiating end state — firewall
rules, sshd config, account purges, Claude Code. If the docker bridge has no
egress (some sandboxes), prefix commands with `MOLECULE_NETWORK_MODE=host`.

Static check: `cd ansible && ansible-playbook -i 'localhost,' -c local site.yml --syntax-check`

## Security report

`sudo bash security_report.sh` writes a read-only attack-surface dump
(kernel, sysctl, users, SSH, firewall, listeners, auditd, …) to a timestamped,
git-ignored file. It maps your whole attack surface — review before sharing.
