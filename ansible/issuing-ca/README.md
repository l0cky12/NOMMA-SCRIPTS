# NOMMA Online Issuing CA — Ansible Project

**Part of the [NOMMA PKI Infrastructure](../README.md)**

---

## Overview

This Ansible project deploys and secures a complete online Issuing Certificate Authority (Intermediate CA) on Debian 13 (Trixie). The Issuing CA is responsible for all day-to-day certificate operations for `nomma.tech` and `nomma.lan`.

---

## What Gets Deployed

| Component | Role | Description |
|-----------|------|-------------|
| System User | `user_setup` | Creates `ldecareaux` user with vault-encrypted password |
| SSH Access | `ssh_setup` | Installs public key with hardened permissions |
| Firewall | `ufw` | UFW: deny inbound, allow SSH/HTTPS/HTTP |
| Intrusion Prevention | `fail2ban` | Fail2Ban SSH jail (5 attempts/60s = 1hr ban) |
| CA Infrastructure | `issuing_ca` | OpenSSL config, CA database, cert chain import |
| Certificate Issuance | `certificate_issuance` | Key generation, CSR, cert profiles |
| CRL Management | `crl_management` | CRL generation, publishing, auto-renewal |
| OCSP (optional) | `ocsp` | OCSP responder behind Nginx |

---

## Quick Start

### Prerequisites

1. **Root CA artifacts must be available** in `root-ca/artifacts/`:
   - `nomma-root-ca.cert.pem`
   - `nomma-issuing-ca.cert.pem`
   - `nomma-ca-chain.cert.pem`

2. **Target server:** Debian 13 (Trixie), minimal install, reachable via SSH

3. **Control node:** Any machine with Ansible installed

### Deployment

```bash
# 1. Navigate to the issuing-ca directory
cd issuing-ca/

# 2. Edit inventory to point to your server
vim inventory/hosts.yml

# 3. Create Ansible Vault password
echo "your-strong-vault-password" > ~/.ansible/vault-password.txt
chmod 600 ~/.ansible/vault-password.txt

# 4. Create encrypted vault file
cp inventory/group_vars/all/vault.example.yml inventory/group_vars/all/vault.yml
# Generate a proper password hash:
python3 -c 'import crypt; print(crypt.crypt("password", crypt.mksalt(crypt.METHOD_SHA512)))'
# Edit vault.yml with the real hash
ansible-vault edit inventory/group_vars/all/vault.yml \
  --vault-id default@~/.ansible/vault-password.txt

# 5. Run the playbook
ansible-playbook playbooks/site.yml \
  --vault-id default@~/.ansible/vault-password.txt

# 6. Dry run first (recommended)
ansible-playbook playbooks/site.yml \
  --vault-id default@~/.ansible/vault-password.txt --check --diff
```

---

## Certificate Operations

After deployment, all certificate operations happen on the Issuing CA server.

### Issue a Server Certificate

```bash
# On the Issuing CA server:
cd /opt/nomma-issuing-ca

# 1. Generate private key
openssl genrsa -out issued/server.nomma.tech.key.pem 2048
chmod 400 issued/server.nomma.tech.key.pem

# 2. Generate CSR using the server profile
openssl req -new \
  -config profiles/server-cert-profile.cnf \
  -key issued/server.nomma.tech.key.pem \
  -out requests/server.nomma.tech.csr.pem

# 3. Issue the certificate
openssl ca -config openssl.cnf \
  -extensions v3_server_cert \
  -days 397 -notext \
  -in requests/server.nomma.tech.csr.pem \
  -out issued/server.nomma.tech.cert.pem

# 4. Verify
openssl verify -CAfile certs/nomma-ca-chain.cert.pem \
  issued/server.nomma.tech.cert.pem
```

### Issue a Client Certificate

```bash
cd /opt/nomma-issuing-ca

openssl genrsa -out issued/user.key.pem 2048
openssl req -new \
  -config profiles/client-cert-profile.cnf \
  -key issued/user.key.pem \
  -out requests/user.csr.pem

openssl ca -config openssl.cnf \
  -extensions v3_client_cert \
  -days 397 -notext \
  -in requests/user.csr.pem \
  -out issued/user.cert.pem
```

### Issue an Infrastructure Certificate (LDAP, RADIUS, etc.)

```bash
cd /opt/nomma-issuing-ca

openssl genrsa -out issued/ldap.nomma.lan.key.pem 2048
openssl req -new \
  -config profiles/infra-cert-profile.cnf \
  -key issued/ldap.nomma.lan.key.pem \
  -out requests/ldap.nomma.lan.csr.pem

openssl ca -config openssl.cnf \
  -extensions v3_infra_cert \
  -days 397 -notext \
  -in requests/ldap.nomma.lan.csr.pem \
  -out issued/ldap.nomma.lan.cert.pem
```

### Renew a Certificate

```bash
# Certificates can be renewed by re-issuing with the same key:
openssl ca -config openssl.cnf \
  -extensions v3_server_cert \
  -days 397 -notext \
  -in requests/server.nomma.tech.csr.pem \
  -out issued/server.nomma.tech.cert.pem
```

### Revoke a Certificate

```bash
cd /opt/nomma-issuing-ca

# 1. Revoke
openssl ca -config openssl.cnf \
  -revoke issued/server.nomma.tech.cert.pem

# 2. Regenerate CRL
openssl ca -config openssl.cnf \
  -gencrl -out crl/nomma-issuing-ca.crl.pem

# 3. Publish CRL
cp crl/nomma-issuing-ca.crl.pem /var/www/html/crl/

# Or use the helper script:
nomma-generate-crl
```

### Verify Certificate Status

```bash
# Check certificate against CRL
openssl verify -CAfile certs/nomma-ca-chain.cert.pem \
  -CRLfile crl/nomma-issuing-ca.crl.pem \
  -crl_check issued/server.nomma.tech.cert.pem

# Check revocation status
openssl ca -config openssl.cnf -status <serial_number>
```

---

## Directory Layout (on the Issuing CA server)

```
/opt/nomma-issuing-ca/
├── certs/           ← CA certificates, chain files
├── crl/             ← Certificate Revocation Lists
├── csr/             ← Certificate Signing Requests (intermediate)
├── newcerts/        ← Certificates issued with serial filenames
├── private/         ← CA PRIVATE KEY (0700, restricted)
├── issued/          ← Issued end-entity certificates
├── requests/        ← Incoming CSRs from services
├── revoked/         ← Revoked certificates (copies)
├── profiles/        ← Certificate profile templates
├── index.txt        ← CA database of all issued/revoked certs
├── index.txt.attr   ← CA database attributes
├── serial           ← Next certificate serial number
├── crlnumber        ← Next CRL number
└── openssl.cnf      ← OpenSSL CA configuration
```

---

## CRL Auto-Renewal

CRLs are regenerated daily via cron (`/etc/cron.daily/nomma-crl-renew`). The CRL is published to `/var/www/html/crl/` for HTTP distribution.

Manual CRL generation:
```bash
nomma-generate-crl
```

---

## OCSP Responder (Optional)

To enable OCSP:
1. Set `ocsp_enabled: true` in `inventory/group_vars/all.yml`
2. Issue the OCSP signing certificate (uncomment tasks in the OCSP role)
3. Re-run the playbook

The OCSP responder listens on port 9080 (plain HTTP) with Nginx providing TLS termination on port 443.

---

## Backup

### What to back up

| Priority | Path | Contains |
|----------|------|----------|
| **CRITICAL** | `/opt/nomma-issuing-ca/private/` | CA private key — without this, you cannot issue certs |
| **CRITICAL** | `/opt/nomma-issuing-ca/index.txt` | Certificate database |
| **CRITICAL** | `/opt/nomma-issuing-ca/serial` | Certificate serial counter |
| **HIGH** | `/opt/nomma-issuing-ca/issued/` | All issued certificates |
| **HIGH** | `/opt/nomma-issuing-ca/openssl.cnf` | CA configuration |
| MEDIUM | `/opt/nomma-issuing-ca/certs/` | CA certificates and chains |
| MEDIUM | `/opt/nomma-issuing-ca/crl/` | Certificate Revocation Lists |

### Backup procedure

```bash
# Create encrypted backup
tar -czf - /opt/nomma-issuing-ca/private \
  /opt/nomma-issuing-ca/index.txt \
  /opt/nomma-issuing-ca/serial \
  /opt/nomma-issuing-ca/issued \
  /opt/nomma-issuing-ca/openssl.cnf \
  /opt/nomma-issuing-ca/certs \
  | gpg --symmetric --output nomma-issuing-ca-backup-$(date +%Y%m%d).tar.gz.gpg

# Store encrypted backup off-server
```

---

## Debian 13 (Trixie) Notes

- Package names are standard Debian — no changes from Bookworm
- `fail2ban` uses `systemd` backend by default
- `ufw` package is included in the base repository
- `python3-apt` is required for Ansible's `apt` module
- All services use `systemd` for management

---

## Troubleshooting

### "Cannot open CA private key"
The Intermediate CA private key has not been imported. Transfer it from the offline Root CA (where it was generated) to `/opt/nomma-issuing-ca/private/nomma-issuing-ca.key.pem` and set permissions to `0400`.

### "Unable to load certificate" during chain verification
Ensure the Root CA certificate exists at `/opt/nomma-issuing-ca/certs/nomma-root-ca.cert.pem` and the chain file is properly built.

### "TXT_DB error number 2" on certificate issuance
A certificate with the same subject already exists. Set `unique_subject = no` in `index.txt.attr` if you need to issue multiple certs with the same DN (not recommended for production).