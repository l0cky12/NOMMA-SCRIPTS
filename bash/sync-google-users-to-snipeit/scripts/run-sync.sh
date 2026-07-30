#!/bin/sh
# run-sync.sh — Wrapper for cron/systemd
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "--apply" ]; then
    exec ./sync_google_users_to_snipeit.sh "$@"
fi
exec ./sync_google_users_to_snipeit.sh --apply