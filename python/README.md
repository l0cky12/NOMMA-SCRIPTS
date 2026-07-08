# Python Scripts

NOMMA IT automation scripts that need more than bash.

## chromeos-snipeit-sync/

Add-only sync of ACTIVE Google Admin ChromeOS devices into Snipe-IT.
Creates missing assets (serial, asset tag, model, status "Ready to Deploy")
and never touches existing ones. Interactive and cron modes, dry-run,
CSV run reports, problem emails.

```bash
cd chromeos-snipeit-sync/
python3 -m venv venv && venv/bin/pip install -r requirements.txt
venv/bin/python chromeos_snipeit_sync.py --dry-run
```

Requirements:

- Google service account with domain-wide delegation (ChromeOS read scope)
- Snipe-IT API token
- SMTP credentials for cron-mode problem emails

See [`chromeos-snipeit-sync/README.md`](chromeos-snipeit-sync/README.md) for
full setup and the test plan.
