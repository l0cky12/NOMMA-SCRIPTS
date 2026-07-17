#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
    set -- --dry-run
fi
exec .venv/bin/python sync_google_admin_snipeit.py "$@"
