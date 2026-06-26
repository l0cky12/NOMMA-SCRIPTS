#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook is not installed. Install ansible-core before validation." >&2
  exit 1
fi

if [ -f requirements.yml ]; then
  printf 'Installing required Ansible collections...\n'
  ansible-galaxy collection install -r requirements.yml
fi

printf 'Checking Ansible syntax...\n'
if [ -f group_vars/vault.yml ]; then
  ansible-playbook -i inventory/hosts.yml playbooks/site.yml --syntax-check --ask-vault-pass
else
  tmp_vault="$(mktemp)"
  trap 'rm -f "$tmp_vault"' EXIT
  cat > "$tmp_vault" <<'EOF'
vault_admin_password_hash: "$6$placeholder$placeholderplaceholderplaceholderplaceholderplaceholderplaceholderplaceholderplaceholderplaceholderplaceholder"
vault_root_ca_key_passphrase: "placeholder-root-ca-passphrase-for-syntax-only"
vault_intermediate_ca_key_passphrase: "placeholder-intermediate-ca-passphrase-for-syntax-only"
EOF
  ansible-playbook -i inventory/hosts.yml playbooks/site.yml --syntax-check -e "@$tmp_vault"
fi

if command -v yamllint >/dev/null 2>&1; then
  printf 'Running yamllint...\n'
  yamllint .
else
  printf 'yamllint not installed; skipping.\n'
fi

if command -v ansible-lint >/dev/null 2>&1; then
  printf 'Running ansible-lint...\n'
  ansible-lint
else
  printf 'ansible-lint not installed; skipping.\n'
fi
