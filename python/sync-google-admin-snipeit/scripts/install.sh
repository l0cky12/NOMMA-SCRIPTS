#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements.txt
chmod 700 .venv
[ ! -f .env ] && cp .env.example .env
[ ! -f config/model-mapping.json ] && cp config/model-mapping.example.json config/model-mapping.json
chmod 600 .env
printf '%s\n' 'Installed. Edit .env and config/model-mapping.json, then run --validate-config and --dry-run.'
