# Key Rotation Procedures

## Purpose

This document supports the NOMMA offline Root CA Ansible project.

## Key points

- The Root CA remains offline except during controlled signing, CRL, backup, or recovery operations.
- Root private keys must never leave `/opt/nomma-root-ca/private` except as encrypted offline backup media.
- Public certificates, certificate chains, CRLs, and CSRs may be distributed.
- Private keys and passphrases must not be stored in Git, tickets, email, or chat.

## Validation

Run these checks after deployment:

```bash
sudo openssl verify -CAfile /opt/nomma-root-ca/certs/nomma-root-ca.cert.pem /opt/nomma-root-ca/intermediate/certs/nomma-issuing-ca.cert.pem
sudo find /opt/nomma-root-ca -type f -name '*key*.pem' -exec ls -l {} \;
sudo ufw status verbose
sudo fail2ban-client status sshd
```

## Operational notes

- Use maintenance windows for Root CA operations.
- Record every signing event.
- Keep at least two encrypted offline backups stored separately.
- Test restore procedures before relying on backups.
