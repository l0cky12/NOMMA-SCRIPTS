# NOMMA Automation

**Organization:** NOMMA — New Orleans Military & Maritime Academy
**Location:** New Orleans, Louisiana, USA
**Repository:** `nomma-automation`

---

## Overview

This repository contains automation and infrastructure-as-code for NOMMA IT operations, including:

- **PKI Infrastructure** — Two-tier Certificate Authority (Root CA + Issuing CA) deployed via Ansible
- **PowerShell Automation** — PC rename scripts for Autopilot enrollment and other Windows automation tasks
- **Bash Utilities** — Google Admin/GAM and CSV helper scripts
- **Python Scripts** — Google Admin → Snipe-IT ChromeOS asset sync

---

## Directory Structure

```
nomma-automation/
├── README.md                    ← This file
├── .gitignore
│
├── ansible/                     ← Infrastructure automation
│   ├── root-ca/                 ← Offline Root CA Ansible project
│   │   ├── ansible.cfg
│   │   ├── inventory/
│   │   ├── playbooks/
│   │   ├── roles/
│   │   └── artifacts/           ← Root CA certs (exported TO issuing-ca)
│   │
│   └── issuing-ca/              ← Online Issuing CA Ansible project
│       ├── ansible.cfg
│       ├── inventory/
│       ├── playbooks/
│       ├── roles/
│       └── README.md
│
├── bash/                        ← Linux/macOS/admin helper scripts
│   ├── combine-autopilot-csv.sh — Combine Autopilot CSV exports
│   ├── find-chromebook-by-asset-tag.sh — Lookup Chromebook serial/model by asset tag using GAM
│   └── README.md                — Bash script documentation
│
├── python/                      ← Python automation scripts
│   ├── chromeos-snipeit-sync/   — Add-only Google Admin ChromeOS → Snipe-IT sync
│   └── README.md                — Python script documentation
│
└── powershell/                  ← Windows automation scripts
    ├── rename-pc.ps1            — Auto-rename PCs during Autopilot enrollment
    ├── windows-dhcp-server/     — Windows DHCP Server automation scripts
    └── README.md                — Script documentation
```

---

## PKI Infrastructure

### CA Hierarchy

```
┌─────────────────────────────────────┐
│     Offline Root CA (root-ca/)      │
│   - Kept offline, powered off       │
│   - Signs Intermediate CA cert      │
│   - Signs CRLs only                 │
│   - Private key NEVER on network    │
└──────────────┬──────────────────────┘
               │ signs
               ▼
┌─────────────────────────────────────┐
│   Online Issuing CA (issuing-ca/)   │
│   - Always online, 24/7             │
│   - Issues server/client certs      │
│   - Generates CRLs                  │
│   - Optional OCSP responder         │
│   - Private key on server (secured) │
└─────────────────────────────────────┘
```

### Security Model

- **Root CA private key** — Never touches the network, air-gapped system
- **Issuing CA private key** — Online, protected with `0400` permissions
- **Secrets** — Encrypted with Ansible Vault
- **SSH** — Key-only auth, hardened with Fail2Ban
- **Firewall** — UFW denies all inbound except SSH, HTTP, HTTPS

---

## PowerShell Scripts

### rename-pc.ps1

Renames computers during Autopilot enrollment based on serial number and asset tag from a CSV file.

**Naming convention:** `L5-SERIAL(7)-ASSETTAG(4)`

**Example:** Serial `ABC1234567890` + AssetTag `1001` → `L5-567890-1001`

See [`powershell/README.md`](powershell/README.md) for full documentation.

---

## Bash Scripts

### find-chromebook-by-asset-tag.sh

Interactive GAM lookup of Google Admin ChromeOS devices by 4-digit asset tag. Prints serial number, model, and device ID, then logs confirmed results to `device_lookup_results.csv`.

```bash
cd bash/
./find-chromebook-by-asset-tag.sh
```

See [`bash/README.md`](bash/README.md) for full documentation.

---

## Python Scripts

### chromeos-snipeit-sync

Add-only sync of ACTIVE Google Admin ChromeOS devices into Snipe-IT: creates
missing assets (serial, asset tag, model, status "Ready to Deploy") and never
updates existing ones. Supports interactive and cron modes, dry-run, CSV run
reports, and problem emails.

```bash
cd python/chromeos-snipeit-sync/
python3 -m venv venv && venv/bin/pip install -r requirements.txt
venv/bin/python chromeos_snipeit_sync.py --dry-run
```

See [`python/chromeos-snipeit-sync/README.md`](python/chromeos-snipeit-sync/README.md) for full documentation.

---

## Initial Setup Workflow

### PKI Deployment

1. **Deploy the Offline Root CA** — Run the `ansible/root-ca/` project on an air-gapped Debian system
2. **Sign the Intermediate CA** — On the offline Root CA, generate and sign the Intermediate CA cert
3. **Export Artifacts** — Copy only public certs to `ansible/root-ca/artifacts/`
4. **Deploy the Issuing CA** — Run the `ansible/issuing-ca/` project on the target server

```bash
cd ansible/issuing-ca/
ansible-playbook playbooks/site.yml --vault-id default@~/.ansible/vault-password.txt
```

### PC Rename Deployment

1. Prepare CSV with `SerialNumber,AssetTag` columns
2. Deploy `powershell/rename-pc.ps1` as an Intune Win32 app
3. Target Autopilot device group

---

## Domains Covered

- `nomma.tech` — Public-facing services
- `nomma.lan` — Internal infrastructure

## Disaster Recovery

If the Issuing CA is compromised:
1. Revoke the Intermediate CA certificate from the Root CA
2. Generate a new Intermediate CA key and certificate
3. Re-deploy the Issuing CA
4. Re-issue all end-entity certificates

If the Root CA is compromised:
1. The entire PKI must be rebuilt from scratch
2. All certificates must be re-issued
3. This is why the Root CA stays offline
