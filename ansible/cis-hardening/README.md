# NOMMA CIS Hardening — Ansible

CIS Benchmark hardening roles for Debian/Ubuntu Linux servers at NOMMA.

## Quick Start

```bash
# From the cis-hardening directory:
cd ansible/cis-hardening

# Install required Ansible collections:
ansible-galaxy collection install -r requirements.yml

# Edit inventory to target your hosts:
vi inventory/hosts.yml

# Run everything (all CIS controls):
ansible-playbook -i inventory/hosts.yml playbooks/site.yml

# Dry run first (check mode, no changes):
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --check

# Run a specific control by tag:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --tags cis-5.2.7

# Run multiple controls:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --tags "cis-5.2.7,cis-5.2.8"

# Run a category:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --tags cis_ssh

# Skip a control:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --skip-tags apparmor

# List all available tags:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --list-tags

# Target a single host:
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --limit NOMMA-ROOTCA01
```

## Implemented CIS Controls

| CIS Control | Role | Tag | Description |
|---|---|---|---|
| Baseline | `baseline_hardening` | `baseline` | Packages, users, sudo, service enablement |
| 1.3.1.2 | `apparmor_grub` | `cis-1.3.1.2` | AppArmor enabled via GRUB |
| 1.6.1 | `motd_hardening` | `cis-1.6.1` | MOTD warning banner configured |
| 1.6.2 | `login_banner` | `cis-1.6.2` | Local console banner (/etc/issue) |
| 1.6.3 | `login_banner` | `cis-1.6.3` | Remote SSH banner (/etc/issue.net) |
| 1.6.4 | `motd_permissions` | `cis-1.6.4` | /etc/motd permissions (root:root) |
| 1.7.1 | `banner_permissions` | `cis-1.7.1` | /etc/issue permissions (root:root) |
| 1.7.2 | `banner_permissions` | `cis-1.7.2` | /etc/issue.net permissions (root:root) |
| — | `crontab_permissions` | `crontab_perms` | /etc/crontab root:root 0600 |
| — | `cron_dir_permissions` | `cron_dir_perms` | Cron dirs root:root 0700 |
| 5.2.7 | `ssh_permit_root_login` | `cis-5.2.7` | Disable direct root SSH login |
| 5.2.8 | `ssh_access` | `cis-5.2.8` | Restrict SSH to authorized users |
| 5.2.12 | `ssh_idle_timeout` | `cis-5.2.12` | SSH idle timeout (15s × 3 = 45s) |
| 5.2.14 | `ssh_macs` | `cis-5.2.14` | Remove weak MAC algorithms |
| 5.2.15 | `ssh_maxstartups` | `cis-5.2.15` | Rate-limit unauthenticated SSH |
| 5.2.19 | `ssh_disable_forwarding` | `cis-5.2.19` | Disable all SSH forwarding |
| 5.3.1 | `sudo_logfile` | `cis-5.3.1` | Dedicated sudo log file |
| 5.3.2 | `sudo_timeout` | `cis-5.3.2` | sudo credential timeout (15 min) |
| 5.3.3 | `su_restriction` | `cis-5.3.3` | Restrict su to sudo group via pam_wheel |
| 5.4.1 | `baseline_hardening` | `baseline` | libpam-pwquality installed |
| 6.1.1 | `root_gid0` | `cis-6.1.1` | Only root has GID 0 |
| 6.1.2 | `root_account` | `cis-6.1.2` | Random root password + lock account |
| — | `ufw` | `ufw` | Firewall: deny inbound, allow SSH, disable nftables |
| — | `fail2ban` | `fail2ban` | SSH brute-force protection |

## Tag Categories

| Tag | Scope |
|---|---|
| `cis` | All CIS controls |
| `hardening` | All hardening roles |
| `baseline` | Packages, users, sudo |
| `cis_ssh` | All SSH-related controls (5.2.x) |
| `cis_sudo` | All sudo/su controls (5.3.x) |
| `cis_accounts` | Account controls (6.1.x) |
| `cron` | Cron permissions |
| `apparmor` | AppArmor/GRUB |
| `ufw` | Firewall |

## Inventory

Edit `inventory/hosts.yml` to define target hosts:

```yaml
all:
  hosts:
    NOMMA-ROOTCA01:
      ansible_host: 10.1.2.97
      ansible_user: ldecareaux
    Snipe-IT:
      ansible_host: 10.1.2.81
      ansible_user: ldecareaux
  vars:
    ansible_python_interpreter: /usr/bin/python3
```

## Variables

Default values are in each role's `defaults/main.yml`. Override in `group_vars/all.yml` or per-host:

```yaml
# group_vars/all.yml

# SSH access (CIS 5.2.8)
ssh_allow_users:
  - liam
  - ldecareaux
  - dcooper

# SSH idle timeout (CIS 5.2.12)
ssh_client_alive_interval: 15
ssh_client_alive_count_max: 3

# sudo timeout (CIS 5.3.2)
sudo_timestamp_timeout: 15

# UFW (CIS firewall)
ufw_allow_ssh: true
ufw_remove_nftables: true

# Root account (CIS 6.1.2)
root_account_set_password: true
root_account_lock: true
```

## Role Execution Order

Roles run in the order defined in `playbooks/site.yml`:

1. **baseline** — packages, users, sudo (must be first)
2. **motd** — MOTD content
3. **login_banner** — banner content
4. **apparmor** — GRUB params
5. **motd_perms** — MOTD permissions
6. **banner_perms** — banner permissions
7. **crontab_perms** — /etc/crontab permissions
8. **cron_dir_perms** — cron dir permissions
9. **ssh_access** — restrict SSH users
10. **ssh_idle_timeout** — SSH timeout
11. **ssh_disable_forwarding** — disable forwarding
12. **ssh_macs** — remove weak MACs
13. **ssh_maxstartups** — rate-limit SSH
14. **ssh_permit_root_login** — disable root SSH
15. **sudo_logfile** — sudo audit log
16. **sudo_timeout** — sudo credential timeout
17. **su_restriction** — restrict su
18. **root_gid0** — only root has GID 0
19. **root_account** — lock root account

Content is deployed before permissions are locked down. GRUB changes come before verification. SSH controls are grouped together. sudo/su controls are grouped. Account controls are last.

## Safety

- All tasks are **idempotent** — safe to rerun
- `backup: yes` on config file modifications
- `validate: sshd -t` / `visudo -cf` before writing service configs
- UFW allows SSH **before** enabling the firewall (no lockout)
- `sshd` is **reloaded** (not restarted) — active sessions survive
- Root account is locked with a random password — `sudo su -` still works
- No destructive disk/partition changes without explicit confirmation

## Requirements

- Ansible 2.13+ (ansible-core)
- Collections: `ansible.posix`, `community.general`
- Target: Debian 12 / Ubuntu 22.04+
- SSH key access to target hosts
- `sudo` on target hosts (installed by baseline role if missing)

## Not Implemented

This is not a complete CIS Benchmark implementation. Major gaps:

- **1.1.x** — Filesystem mount options (tmp, var, home, dev/shm)
- **1.4.x** — Bootloader password
- **2.x** — Service disablement (cups, nfs, rsync, etc.)
- **3.x** — Network configuration (IPv6, bluetooth, forwarding)
- **4.x** — Logging and auditing (rsyslog config, auditd rules)
- **5.4.2+** — PAM password quality configuration
- **6.2.x** — File permissions and ownership (passwd, shadow, etc.)
- **7.x** — User accounts and environment (umask, PATH, shell timeout)

Do not claim full CIS compliance based on this playbook alone.
