# NOMMA Offline Root CA

This directory contains the offline Root CA Ansible workflow for the NOMMA PKI hierarchy.

The configured Root CA host is:

```text
ldecareaux@192.168.122.58
```

Run this only against the designated dedicated offline or isolated Root CA host. The playbook creates:

- encrypted Root CA private key
- self-signed Root CA certificate
- encrypted Issuing CA private key
- Issuing CA CSR
- signed Issuing CA certificate
- public CA chain
- public artifacts for transfer to the online Issuing CA

## Ordering

**IMPORTANT:** Run this playbook BEFORE the Issuing CA (issuing-ca/).
This playbook creates the Root CA cert and signed Intermediate CA cert
which the online Issuing CA needs to operate.

After this playbook completes successfully:
- Public artifacts are fetched to `root-ca/artifacts/`
- The issuing-ca playbook imports them from there automatically

## Important security rules

Never commit or transfer private CA material.

Safe to transfer to the online Issuing CA:

- `artifacts/nomma-root-ca.cert.pem`
- `artifacts/nomma-issuing-ca.cert.pem`
- `artifacts/nomma-ca-chain.cert.pem`

Never transfer or commit:

- `/home/ldecareaux/nomma-root-ca/pki/root-ca/private/nomma-root-ca.key.pem`
- `/home/ldecareaux/nomma-root-ca/pki/root-ca/private/nomma-issuing-ca.key.pem`
- `inventory/group_vars/all/vault.yml`
- vault password files
- CA database files under `/home/ldecareaux/nomma-root-ca/pki/root-ca/db/`

## Disaster Recovery

### Lost Vault Password

If you lose the vault password, you cannot decrypt `inventory/group_vars/all/vault.yml`.
Recovery requires recreating the vault file:

```bash
rm inventory/group_vars/all/vault.yml
cp inventory/group_vars/all/vault.example.yml inventory/group_vars/all/vault.yml
# Edit with new passphrases
ansible-vault encrypt inventory/group_vars/all/vault.yml \
  --vault-id default@~/.ansible/vault-password.txt
```

The Root CA private keys will still be encrypted with their original passphrases.
You cannot rotate them online — that requires running the Root CA key ceremony again.

### Root CA Compromise

If the Root CA private key is compromised, the entire PKI must be rebuilt:

1. Build a new Root CA on a fresh offline host
2. Generate a new Intermediate CA key and CSR
3. Sign the new Intermediate CA
4. Re-deploy the Issuing CA playbook with new certificates
5. Re-issue ALL end-entity certificates
6. Distribute the new Root CA certificate to all clients and devices

### Issuing CA Compromise

If the Intermediate CA is compromised:

1. Revoke the old Intermediate CA certificate from the Root CA
2. Generate a new Intermediate CA key and CSR on the offline Root CA
3. Sign the new Intermediate CA
4. Re-run the issuing-ca playbook
5. Re-issue all end-entity certificates

## First run

### 1. Create the vault password file

```bash
mkdir -p ~/.ansible
echo "your-strong-vault-password-here" > ~/.ansible/vault-password.txt
chmod 600 ~/.ansible/vault-password.txt
```

### 2. Create and encrypt the vault variables

```bash
cd root-ca
cp inventory/group_vars/all/vault.example.yml inventory/group_vars/all/vault.yml
```

Edit `inventory/group_vars/all/vault.yml` and replace the CHANGEME placeholders with real passphrases:

```yaml
vault_root_ca_key_passphrase: "your-real-root-ca-passphrase"
vault_issuing_ca_key_passphrase: "your-real-issuing-ca-passphrase"
```

Then encrypt it:

```bash
ansible-vault encrypt inventory/group_vars/all/vault.yml \
  --vault-id default@~/.ansible/vault-password.txt
```

### 3. Confirm SSH works

```bash
ssh -i ~/.ssh/id_rsa_work ldecareaux@192.168.122.58 'hostname && openssl version'
```

### 4. Install Ansible requirements

```bash
ansible-galaxy collection install -r requirements.yml
```

### 5. Run the playbook

```bash
ansible-playbook playbooks/site.yml \
  --vault-id default@~/.ansible/vault-password.txt
```

## Output locations

Private CA state stays on the remote Root CA host under:

```text
/home/ldecareaux/nomma-root-ca/pki/root-ca/
```

Public transfer files are staged on the remote host under:

```text
/home/ldecareaux/nomma-root-ca/artifacts/
```

The playbook also fetches those public files back to this repo on the control node under:

```text
root-ca/artifacts/
```

Copy only the public artifacts into the online Issuing CA workflow.
