#!/bin/sh
# install.sh — Set up dependencies for the Google → Snipe-IT user sync
set -eu

cd "$(dirname "$0")/.."

echo "==> Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq curl jq openssl

echo "==> Setting up config..."
[ ! -f .env ] && cp .env.example .env
[ ! -f config/grade-department-mapping.json ] && cp config/grade-department-mapping.example.json config/grade-department-mapping.json

chmod 600 .env

echo "==> Making scripts executable..."
chmod +x sync_google_users_to_snipeit.sh scripts/run-sync.sh

echo ""
echo "Installed."
echo "Next steps:"
echo "  1. Edit .env with your actual credentials"
echo "  2. Edit config/grade-department-mapping.json with your OU→department names"
echo "  3. Run: ./sync_google_users_to_snipeit.sh --validate-config"
echo "  4. Run: ./sync_google_users_to_snipeit.sh                   (dry-run)"
echo "  5. Run: ./sync_google_users_to_snipeit.sh --apply            (live)"
echo "  6. Or install systemd timer: sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/"