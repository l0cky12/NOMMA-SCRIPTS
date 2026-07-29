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
server.port.ssl=9191
```

`papercut_service_name` defaults to `papercut` and `papercut_ssl_port` defaults
to `9191`. Both may be overridden by normal inventory/group-vars or extra-vars
precedence. The playbook verifies the certificate served by the configured
`127.0.0.1` TLS port after a non-check import.

## Prerequisites

1. On the controller, set the target SSH user in `inventory/hosts.yml`; it must
   be able to `sudo` on the PaperCut host.
2. Set a real DNS name explicitly in inventory/group variables or extra-vars.
   It has no default because it is both the CSR DNS SAN and the TLS SNI name used
   by the import verification. The remaining connection/service defaults can be
   overridden normally:

   ```yaml
   # inventory/group_vars/papercut_mf/main.yml (example; do not commit secrets)
   papercut_server_fqdn: papercut.example.nomma.lan # required; no guessed default
   papercut_server_ip: 10.1.0.113                   # optional default shown
   papercut_service_name: papercut                  # optional default shown
   papercut_ssl_port: 9191                          # optional default shown
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

Export the CA chain separately on Windows and return the issuing CA followed by
root CA as PEM. For example, retrieve it as a P7B with
`certutil -ca.chain ca-chain.p7b`, then convert it on Debian:

```bash
openssl pkcs7 -print_certs -in ca-chain.p7b \
  -out /home/papercut/ssl/nomma-ca-chain.pem
```

Return a PEM leaf certificate to `/home/papercut/ssl/papercut-tls.crt` and the
separate PEM CA chain to `/home/papercut/ssl/nomma-ca-chain.pem`.

Validate, build/deploy the PKCS#12 keystore, configure PaperCut, restart only
when certificate/key/chain/password/configuration inputs changed, wait for the
configured TLS listener, and compare the served leaf serial/fingerprint:

```bash
ansible-playbook playbooks/papercut-adcs-tls.yml --tags import \
  --vault-id default@~/.ansible/vault-password.txt
```

## Check mode

Check mode is intentionally a safe, limited preview; it does not execute
OpenSSL commands, build or activate a PKCS#12 file, restart PaperCut, or connect
to the TLS listener.

- `--tags csr --check` reports when missing key/CSR material would be created,
  while skipping creation and file enforcement for absent files. It can preview
  the OpenSSL configuration change.
- `--tags import --check` confirms required remote paths exist and previews
  managed file and `server.properties` changes. It does **not** validate the
  returned certificate/key/chain, calculate change state, or predict whether a
  keystore would be rebuilt.

```bash
ansible-playbook playbooks/papercut-adcs-tls.yml --tags csr --check
ansible-playbook playbooks/papercut-adcs-tls.yml --tags import --check \
  --vault-id default@~/.ansible/vault-password.txt
```

## Security and behavior

- The key is created only when absent, is mode `0600`, and is never copied off
  the managed host.
- The CSR includes DNS and IPv4 SANs plus `digitalSignature`,
  `keyEncipherment`, and `serverAuth` usages.
- The import stage fails before deployment if files are missing, the PEM leaf or
  CA chain is malformed, the RSA modulus differs, or OpenSSL cannot validate
  the returned chain.
- Input and password stamps are read before a decision but are written only
  after a replacement PKCS#12 builds successfully and is atomically activated,
  so a failed attempt remains retryable.
- The PKCS#12 password is required from an Ansible Vault-compatible variable,
  is not committed, and is suppressed from task output with `no_log`.
- PaperCut is restarted only by a changed import handler; this repository task
  does not run against production during development.
