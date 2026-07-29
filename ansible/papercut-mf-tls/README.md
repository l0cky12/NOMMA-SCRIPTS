# PaperCut MF AD CS TLS workflow

Idempotently manages the TLS certificate lifecycle for a **non-domain-joined
Debian 12** PaperCut MF host. The controller runs Ansible from this directory;
the repository is **not** expected to exist on PaperCut.

The validated PaperCut configuration convention is:

```properties
# relative to /home/papercut/server/
server.keystore.path=custom/papercut-tls.p12
server.keystore.password=<vault-supplied password>
server.keystore.type=PKCS12
```

The playbook uses the configurable `papercut_service_name` (default:
`papercut`) and verifies the certificate served by `127.0.0.1:9191` after a
changed import.

## Prerequisites

1. On the controller, set the target SSH user in `inventory/hosts.yml`; it must
   be able to `sudo` on the PaperCut host.
2. Set a real DNS name in an inventory variable (there is deliberately no
   FQDN default):

   ```yaml
   # inventory/group_vars/papercut_mf/main.yml (example; do not commit secrets)
   papercut_server_fqdn: papercut.example.nomma.lan
   papercut_server_ip: 10.1.0.113
   # Optional if the systemd unit differs:
   # papercut_service_name: papercut
   ```

3. Create `inventory/group_vars/papercut_mf/vault.yml` from
   `vault.example.yml`, replace the password, and encrypt it. This file is
   ignored by Git.

   ```bash
   cp inventory/group_vars/papercut_mf/vault.example.yml \
      inventory/group_vars/papercut_mf/vault.yml
   ansible-vault encrypt inventory/group_vars/papercut_mf/vault.yml \
      --vault-id default@~/.ansible/vault-password.txt
   ```

## Run stages

From this directory, generate or re-use the **server-local** RSA-2048 key and
produce the CSR:

```bash
ansible-playbook playbooks/papercut-adcs-tls.yml --tags csr
```

The output gives the exact CSR path. Copy **only** that CSR to a
Windows domain-joined workstation. Do not copy `/home/papercut/ssl/papercut-tls.key`.
Submit manually (replace the template if your CA uses another name):

```powershell
certreq -submit -attrib "CertificateTemplate:WebServer" papercut-tls.csr papercut-tls.cer
```

Return a PEM leaf certificate to `/home/papercut/ssl/papercut-tls.crt` and a
separate PEM CA chain (issuing CA followed by root CA) to
`/home/papercut/ssl/nomma-ca-chain.pem`. `certutil -ca.chain ca-chain.p7b`
can retrieve a Windows chain; convert P7B to PEM on Debian before import:

```bash
openssl pkcs7 -print_certs -in ca-chain.p7b \
  -out /home/papercut/ssl/nomma-ca-chain.pem
```

Validate, build/deploy the PKCS#12 keystore, configure PaperCut, restart only
when certificate/key/chain/password/configuration inputs changed, and compare
the served leaf serial/fingerprint on port 9191:

```bash
ansible-playbook playbooks/papercut-adcs-tls.yml --tags import \
  --vault-id default@~/.ansible/vault-password.txt
```

Use check mode to preview managed-file/configuration changes. Commands that
need target-returned certificate files or create cryptographic material are
intentionally skipped or cannot fully predict change in check mode:

```bash
ansible-playbook playbooks/papercut-adcs-tls.yml --tags import --check \
  --vault-id default@~/.ansible/vault-password.txt
```

## Security and behavior

- The key is created only when absent, is mode `0600`, and is never copied off
  the managed host.
- The import stage fails before deployment if files are missing, the PEM leaf or
  CA chain is malformed, the RSA modulus differs, or OpenSSL cannot validate
  the returned chain.
- The PKCS#12 password is required from an Ansible Vault-compatible variable,
  is not committed, and is suppressed from task output with `no_log`.
- PaperCut must be stopped/restarted only by the changed import handler; this
  repository task does not run against production during development.
