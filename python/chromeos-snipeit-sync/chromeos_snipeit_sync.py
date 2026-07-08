#!/usr/bin/env python3
# ============================================================================
# chromeos_snipeit_sync.py — add-only sync of Google Admin ChromeOS devices
#                            into Snipe-IT
#
# Pulls ACTIVE ChromeOS devices from the Google Admin SDK Directory API and
# creates the ones that don't exist in Snipe-IT yet. It NEVER updates,
# overwrites, or changes the status of an existing Snipe-IT asset — there is
# no update/PATCH code path in this script at all.
#
# Field mapping:
#   Google serialNumber     -> Snipe-IT serial
#   Google annotatedAssetId -> Snipe-IT asset_tag (serial used when empty)
#   Google model            -> existing Snipe-IT model (case-insensitive
#                              exact name match, or the model-map file)
#
# A device is SKIPPED when its serial number OR asset tag already exists in
# Snipe-IT (or duplicates an earlier device in the same Google export).
# New assets are created with status "Ready to Deploy" and no financial
# fields. Re-running the script is idempotent.
#
# Unknown models are never guessed:
#   interactive run    -> prompt per model: create / map to existing / skip
#   --non-interactive  -> skip the devices and email the problems
#
# Requirements: python3 + `pip install -r requirements.txt`
#   (google-api-python-client, google-auth, google-auth-httplib2, requests)
#
# Configuration is environment variables only — see the env vars section
# below and chromeos-snipeit-sync.env.example. No secrets in code, ever.
#
# Required env vars:
#   GOOGLE_SA_KEY_FILE    path to the service-account JSON key
#   GOOGLE_ADMIN_SUBJECT  Workspace admin email the service account impersonates
#   SNIPEIT_URL           e.g. https://snipeit.nomma.lan
#   SNIPEIT_API_TOKEN     Snipe-IT API bearer token
# Required with --non-interactive (problem email):
#   SMTP_HOST, SMTP_USERNAME, SMTP_PASSWORD, SMTP_FROM, SMTP_TO
# Optional env vars:
#   GOOGLE_CUSTOMER_ID    default my_customer
#   SNIPEIT_STATUS_LABEL  default "Ready to Deploy"
#   SNIPEIT_VERIFY_TLS    default true (set false for self-signed certs)
#   SMTP_PORT             default 587 (STARTTLS)
#   SYNC_MODEL_MAP_FILE   default model-map.json next to this script
#   SYNC_REPORT_DIR       default reports/ next to this script
#
# Usage:
#   ./chromeos_snipeit_sync.py --dry-run          # no writes, report only
#   ./chromeos_snipeit_sync.py                    # interactive run
#   ./chromeos_snipeit_sync.py --non-interactive  # cron: skip + email problems
#
# Cron example (env file must be chmod 600, outside the repo):
#   17 6 * * * bash -c 'set -a; . /etc/nomma/chromeos-snipeit-sync.env; \
#     set +a; exec /opt/nomma/venv/bin/python \
#     /opt/nomma/chromeos_snipeit_sync.py --non-interactive' \
#     >> /var/log/chromeos-snipeit-sync.log 2>&1
#
# Exit codes: 0 = clean, 1 = fatal error, 2 = completed with problems
#             (unknown models or failed creates — see the CSV report)
# ============================================================================

import argparse
import csv
import json
import logging
import os
import random
import smtplib
import ssl
import sys
import time
import traceback
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path

try:
    import requests
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
except ImportError as exc:  # pragma: no cover
    sys.stderr.write(
        f"ERROR: missing dependency ({exc}).\n"
        "Install them with: pip install -r requirements.txt\n"
    )
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
GOOGLE_SCOPES = ["https://www.googleapis.com/auth/admin.directory.device.chromeos.readonly"]
SMTP_REQUIRED_VARS = ("SMTP_HOST", "SMTP_USERNAME", "SMTP_PASSWORD", "SMTP_FROM", "SMTP_TO")

log = logging.getLogger("chromeos-snipeit-sync")


class ConfigError(Exception):
    """Bad or missing configuration — abort before touching any API."""


class FatalError(Exception):
    """Unrecoverable runtime problem — abort the run (exit 1)."""


class SnipeITError(FatalError):
    """Snipe-IT API failure that retries could not resolve."""


def norm(value):
    """Normalize an identifier for comparison: trim + casefold. None-safe."""
    return (value or "").strip().casefold()


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@dataclass
class Config:
    google_sa_key_file: str
    google_admin_subject: str
    google_customer_id: str
    snipeit_url: str
    snipeit_api_token: str
    snipeit_status_label: str
    snipeit_verify_tls: bool
    smtp_host: str
    smtp_port: int
    smtp_username: str
    smtp_password: str
    smtp_from: str
    smtp_to: list
    model_map_file: Path
    report_dir: Path
    dry_run: bool
    non_interactive: bool
    limit: int

    @classmethod
    def from_env(cls, args):
        missing = []

        def required(name):
            value = os.environ.get(name, "").strip()
            if not value:
                missing.append(name)
            return value

        google_sa_key_file = required("GOOGLE_SA_KEY_FILE")
        google_admin_subject = required("GOOGLE_ADMIN_SUBJECT")
        snipeit_url = required("SNIPEIT_URL").rstrip("/")
        snipeit_api_token = required("SNIPEIT_API_TOKEN")

        # A cron job that can't report problems is a silent failure mode,
        # so SMTP config is mandatory for unattended runs (dry-run excepted).
        smtp = {name: os.environ.get(name, "").strip() for name in SMTP_REQUIRED_VARS}
        if args.non_interactive and not args.dry_run:
            missing.extend(name for name in SMTP_REQUIRED_VARS if not smtp[name])

        if missing:
            raise ConfigError(
                "missing required environment variables: " + ", ".join(sorted(set(missing)))
            )

        if not Path(google_sa_key_file).is_file():
            raise ConfigError(f"GOOGLE_SA_KEY_FILE not found: {google_sa_key_file}")

        verify_raw = os.environ.get("SNIPEIT_VERIFY_TLS", "true").strip().lower()
        if verify_raw not in ("true", "false", "1", "0", "yes", "no"):
            raise ConfigError(f"SNIPEIT_VERIFY_TLS must be true or false, got: {verify_raw}")

        try:
            smtp_port = int(os.environ.get("SMTP_PORT", "587").strip())
        except ValueError as exc:
            raise ConfigError(f"SMTP_PORT must be a number: {exc}") from exc

        if snipeit_url.lower().startswith("http://"):
            log.warning(
                "SNIPEIT_URL uses plain HTTP — the API token travels unencrypted; "
                "use HTTPS if possible"
            )

        return cls(
            google_sa_key_file=google_sa_key_file,
            google_admin_subject=google_admin_subject,
            google_customer_id=os.environ.get("GOOGLE_CUSTOMER_ID", "my_customer").strip(),
            snipeit_url=snipeit_url,
            snipeit_api_token=snipeit_api_token,
            snipeit_status_label=os.environ.get("SNIPEIT_STATUS_LABEL", "Ready to Deploy").strip(),
            snipeit_verify_tls=verify_raw in ("true", "1", "yes"),
            smtp_host=smtp["SMTP_HOST"],
            smtp_port=smtp_port,
            smtp_username=smtp["SMTP_USERNAME"],
            smtp_password=smtp["SMTP_PASSWORD"],
            smtp_from=smtp["SMTP_FROM"],
            smtp_to=[addr.strip() for addr in smtp["SMTP_TO"].split(",") if addr.strip()],
            model_map_file=Path(
                os.environ.get("SYNC_MODEL_MAP_FILE", "").strip()
                or SCRIPT_DIR / "model-map.json"
            ),
            report_dir=Path(
                os.environ.get("SYNC_REPORT_DIR", "").strip() or SCRIPT_DIR / "reports"
            ),
            dry_run=args.dry_run,
            non_interactive=args.non_interactive,
            limit=args.limit,
        )


def setup_logging():
    """INFO to stdout, WARNING+ to stderr, timestamped."""
    root = logging.getLogger()
    if root.handlers:  # already configured — don't stack duplicate handlers
        return
    root.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")

    out = logging.StreamHandler(sys.stdout)
    out.setFormatter(fmt)
    out.addFilter(lambda record: record.levelno < logging.WARNING)
    root.addHandler(out)

    err = logging.StreamHandler(sys.stderr)
    err.setFormatter(fmt)
    err.setLevel(logging.WARNING)
    root.addHandler(err)


# ---------------------------------------------------------------------------
# Google Admin
# ---------------------------------------------------------------------------

@dataclass
class GoogleDevice:
    device_id: str
    serial: str
    annotated_asset_id: str
    model: str
    org_unit: str


def build_google_service(cfg):
    creds = service_account.Credentials.from_service_account_file(
        cfg.google_sa_key_file, scopes=GOOGLE_SCOPES
    ).with_subject(cfg.google_admin_subject)
    return build("admin", "directory_v1", credentials=creds, cache_discovery=False)


def fetch_active_devices(service, cfg):
    """All ChromeOS devices with status ACTIVE, across every page.

    Status is filtered client-side against the exact API enum rather than via
    the Admin-console query language, whose terminology ("provisioned") maps
    to the enum only indirectly.
    """
    devices = []
    total_seen = 0
    page_token = None
    fields = (
        "nextPageToken,chromeosdevices("
        "deviceId,serialNumber,annotatedAssetId,model,status,orgUnitPath)"
    )
    while True:
        response = service.chromeosdevices().list(
            customerId=cfg.google_customer_id,
            projection="FULL",
            maxResults=300,
            pageToken=page_token,
            fields=fields,
        ).execute(num_retries=3)

        for item in response.get("chromeosdevices", []):
            total_seen += 1
            if item.get("status") != "ACTIVE":
                continue
            devices.append(GoogleDevice(
                device_id=item.get("deviceId", ""),
                serial=(item.get("serialNumber") or "").strip(),
                annotated_asset_id=(item.get("annotatedAssetId") or "").strip(),
                model=(item.get("model") or "").strip(),
                org_unit=item.get("orgUnitPath", ""),
            ))

        page_token = response.get("nextPageToken")
        if not page_token:
            break

    log.info("Google Admin: %d ChromeOS device(s), %d ACTIVE", total_seen, len(devices))
    return devices


# ---------------------------------------------------------------------------
# Snipe-IT client
# ---------------------------------------------------------------------------

class SnipeIT:
    """Minimal Snipe-IT REST client: throttled, retrying, add-only."""

    MAX_ATTEMPTS = 5
    MIN_INTERVAL = 0.55  # seconds between requests — under the 120 req/min throttle
    PAGE_SIZE = 500

    def __init__(self, base_url, token, verify_tls=True):
        self.base_url = base_url
        self.verify_tls = verify_tls
        self._session = requests.Session()
        self._session.headers.update({
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        })
        self._last_request = 0.0

    def _throttle(self):
        wait = self.MIN_INTERVAL - (time.monotonic() - self._last_request)
        if wait > 0:
            time.sleep(wait)
        self._last_request = time.monotonic()

    def _backoff(self, attempt, reason):
        delay = min(60, 2 ** attempt) + random.uniform(0, 1)
        log.warning("Snipe-IT %s — retrying in %.1fs (attempt %d/%d)",
                    reason, delay, attempt, self.MAX_ATTEMPTS)
        time.sleep(delay)

    def _request(self, method, path, params=None, json_body=None):
        """Returns the parsed JSON payload. Retries 429/5xx/network errors;
        raises SnipeITError on anything unrecoverable. NOTE: Snipe-IT can
        return HTTP 200 with {"status": "error"} for validation failures —
        callers must judge success on the payload, never the HTTP code."""
        url = f"{self.base_url}/api/v1{path}"
        for attempt in range(1, self.MAX_ATTEMPTS + 1):
            self._throttle()
            try:
                response = self._session.request(
                    method, url, params=params, json=json_body,
                    timeout=(10, 60), verify=self.verify_tls,
                )
            except (requests.ConnectionError, requests.Timeout) as exc:
                if attempt == self.MAX_ATTEMPTS:
                    raise SnipeITError(f"{method} {path}: {exc}") from exc
                self._backoff(attempt, f"connection problem ({exc.__class__.__name__})")
                continue

            if response.status_code == 429:
                if attempt == self.MAX_ATTEMPTS:
                    raise SnipeITError(f"{method} {path}: still rate-limited after retries")
                retry_after = response.headers.get("Retry-After", "")
                if retry_after.isdigit():
                    delay = min(120, int(retry_after)) + random.uniform(0, 1)
                    log.warning("Snipe-IT rate limit — honoring Retry-After: %ss", retry_after)
                    time.sleep(delay)
                else:
                    self._backoff(attempt, "rate limit (429)")
                continue

            if response.status_code >= 500:
                if attempt == self.MAX_ATTEMPTS:
                    raise SnipeITError(f"{method} {path}: HTTP {response.status_code}")
                self._backoff(attempt, f"server error (HTTP {response.status_code})")
                continue

            if response.status_code >= 400:
                # Auth/URL/permission problems — retrying is pointless.
                raise SnipeITError(
                    f"{method} {path}: HTTP {response.status_code}: {response.text[:300]}"
                )

            try:
                return response.json()
            except ValueError as exc:
                raise SnipeITError(f"{method} {path}: non-JSON response") from exc

        raise SnipeITError(f"{method} {path}: retries exhausted")  # unreachable

    def iter_rows(self, path, params=None):
        """Offset-paginate a Snipe-IT list endpoint, yielding every row.
        sort=id ascending keeps page boundaries stable across the pass."""
        offset = 0
        while True:
            page_params = {"limit": self.PAGE_SIZE, "offset": offset,
                           "sort": "id", "order": "asc"}
            if params:
                page_params.update(params)
            payload = self._request("GET", path, params=page_params)
            rows = payload.get("rows") or []
            yield from rows
            offset += len(rows)
            if not rows or offset >= int(payload.get("total") or 0):
                break

    def fetch_hardware_identifiers(self):
        """Every existing serial and asset tag, normalized — the sole
        duplicate-prevention authority for the whole run."""
        serials, tags = set(), set()
        count = 0
        for row in self.iter_rows("/hardware"):
            count += 1
            if norm(row.get("serial")):
                serials.add(norm(row.get("serial")))
            if norm(row.get("asset_tag")):
                tags.add(norm(row.get("asset_tag")))
        log.info("Snipe-IT: %d existing asset(s) (%d serials, %d tags)",
                 count, len(serials), len(tags))
        return serials, tags

    def fetch_models(self):
        """Case-insensitive model-name -> {id, name}. First name wins on a
        case collision (warned) so resolution order stays deterministic."""
        models = {}
        for row in self.iter_rows("/models"):
            name = (row.get("name") or "").strip()
            key = norm(name)
            if not key:
                continue
            if key in models:
                log.warning('Snipe-IT has case-colliding model names "%s" and "%s" — using the first',
                            models[key]["name"], name)
                continue
            models[key] = {"id": row["id"], "name": name}
        log.info("Snipe-IT: %d model(s)", len(models))
        return models

    def fetch_status_label_id(self, label_name):
        for row in self.iter_rows("/statuslabels"):
            if norm(row.get("name")) == norm(label_name):
                if norm(row.get("type")) != "deployable":
                    log.warning('status label "%s" is type "%s", not "deployable"',
                                row.get("name"), row.get("type"))
                return row["id"]
        return None

    def fetch_categories(self):
        return [
            {"id": row["id"], "name": row.get("name", "")}
            for row in self.iter_rows("/categories")
            if norm(row.get("category_type")) == "asset"
        ]

    def fetch_manufacturers(self):
        return [
            {"id": row["id"], "name": row.get("name", "")}
            for row in self.iter_rows("/manufacturers")
        ]

    def create_asset(self, asset_tag, serial, model_id, status_id, notes):
        """POST /hardware with exactly these fields — the allowlist payload
        structurally guarantees no financial or status fields can ever be
        sent for existing assets (there is no update path at all)."""
        payload = {
            "asset_tag": asset_tag,
            "serial": serial,
            "model_id": model_id,
            "status_id": status_id,
            "notes": notes,
        }
        response = self._request("POST", "/hardware", json_body=payload)
        if response.get("status") == "success":
            asset_id = (response.get("payload") or {}).get("id")
            return True, asset_id, ""
        return False, None, json.dumps(response.get("messages", response))

    def create_model(self, name, category_id, manufacturer_id=None):
        payload = {"name": name, "category_id": category_id}
        if manufacturer_id is not None:
            payload["manufacturer_id"] = manufacturer_id
        response = self._request("POST", "/models", json_body=payload)
        if response.get("status") == "success":
            model_id = (response.get("payload") or {}).get("id")
            return True, model_id, ""
        return False, None, json.dumps(response.get("messages", response))


# ---------------------------------------------------------------------------
# Model map (persisted interactive decisions)
# ---------------------------------------------------------------------------

def load_model_map(path, models):
    """{normalized google model: {"model_id": int, "model_name": str}}.
    Entries pointing at models deleted from Snipe-IT are dropped with a
    warning so the model goes back to the unknown-model flow."""
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        log.warning("could not read model map %s (%s) — treating as empty", path, exc)
        return {}

    valid_ids = {info["id"] for info in models.values()}
    mapping = {}
    for key, entry in data.items():
        if isinstance(entry, dict) and entry.get("model_id") in valid_ids:
            mapping[key] = entry
        else:
            log.warning('model-map entry "%s" points at a Snipe-IT model that no longer '
                        "exists — ignoring it", key)
    if mapping:
        log.info("model map: %d saved mapping(s) loaded from %s", len(mapping), path)
    return mapping


def save_model_map(path, mapping):
    path.write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Interactive unknown-model resolution
# ---------------------------------------------------------------------------

def prompt_choice(prompt, valid):
    while True:
        answer = input(prompt).strip().lower()
        if answer in valid:
            return answer
        print(f"  Please enter one of: {'/'.join(valid)}")


def pick_from_list(kind, items, default_index=None, allow_none=False):
    """Numbered picker. default_index is 1-based; 0 with allow_none means
    'none' is the default. Returns the chosen item dict, or None."""
    print(f"  {kind.capitalize()}s in Snipe-IT:")
    if allow_none:
        print("     0) (none)")
    for i, item in enumerate(items, 1):
        print(f"    {i:2d}) {item['name']}")
    if default_index is not None:
        default_label = "(none)" if default_index == 0 else items[default_index - 1]["name"]
        prompt = f"  Pick a {kind} [Enter = {default_label}]: "
    else:
        prompt = f"  Pick a {kind}: "
    while True:
        raw = input(prompt).strip()
        if not raw and default_index is not None:
            return None if default_index == 0 else items[default_index - 1]
        if raw.isdigit():
            n = int(raw)
            if allow_none and n == 0:
                return None
            if 1 <= n <= len(items):
                return items[n - 1]
        print("  Invalid choice.")


def prompt_map_to_model(display_name, models):
    """Substring search over existing Snipe-IT models -> picked model dict."""
    model_list = sorted(models.values(), key=lambda m: m["name"].casefold())
    while True:
        term = input('  Search Snipe-IT models (substring, Enter lists all): ').strip().casefold()
        matches = [m for m in model_list if term in m["name"].casefold()]
        if not matches:
            print("  No matches — try again.")
            continue
        shown = matches[:30]
        if len(matches) > len(shown):
            print(f"  Showing first {len(shown)} of {len(matches)} matches — refine the search.")
        print("     0) (search again)")
        for i, m in enumerate(shown, 1):
            print(f"    {i:2d}) {m['name']}")
        raw = input(f'  Map "{display_name}" to: ').strip()
        if raw.isdigit():
            n = int(raw)
            if n == 0:
                continue
            if 1 <= n <= len(shown):
                return shown[n - 1]
        print("  Invalid choice.")


def guess_manufacturer_index(model_name, manufacturers):
    """1-based index of the manufacturer matching the model's first word,
    or 0 (meaning 'none') when there is no match."""
    first_word = norm(model_name.split(" ", 1)[0] if model_name else "")
    for i, manufacturer in enumerate(manufacturers, 1):
        if norm(manufacturer["name"]) == first_word:
            return i
    return 0


def resolve_unknown_models(unknown, snipe, models, model_map, model_map_file):
    """Prompt once per unknown Google model: create / map / skip.
    Mutates `models` and `model_map` (persisting the map file after each
    decision). Returns the set of normalized model names the user skipped.
    Models are only ever created here, after explicit approval."""
    if not sys.stdin.isatty():
        raise FatalError(
            f"{len(unknown)} unknown model(s) need interactive resolution but stdin "
            "is not a TTY — re-run with --non-interactive for unattended use"
        )

    categories = snipe.fetch_categories()
    manufacturers = snipe.fetch_manufacturers()
    skipped = set()
    default_category_index = None  # remembered across creates — bulk onboarding

    print(f"\n{len(unknown)} Google model(s) have no matching Snipe-IT model.\n")
    for key in sorted(unknown):
        display = unknown[key]["display"]
        count = unknown[key]["count"]
        print(f'Unknown Google model: "{display}" ({count} device(s))')
        print("  [c] Create this model in Snipe-IT")
        print("  [m] Map it to an existing Snipe-IT model")
        print("  [s] Skip these devices for this run")
        choice = prompt_choice("Choice [c/m/s]: ", ("c", "m", "s"))

        if choice == "s":
            skipped.add(key)
            print()
            continue

        if choice == "m":
            picked = prompt_map_to_model(display, models)
            model_map[key] = {"model_id": picked["id"], "model_name": picked["name"]}
            save_model_map(model_map_file, model_map)
            log.info('mapped Google model "%s" -> Snipe-IT model "%s" (id %s)',
                     display, picked["name"], picked["id"])
            print()
            continue

        # Create
        if not categories:
            print("  No asset categories exist in Snipe-IT — create one there first.")
            print("  Skipping this model for now.\n")
            skipped.add(key)
            continue
        name = input(f"  Model name [{display}]: ").strip() or display
        category = pick_from_list("category", categories, default_index=default_category_index)
        default_category_index = categories.index(category) + 1
        manufacturer = pick_from_list(
            "manufacturer", manufacturers,
            default_index=guess_manufacturer_index(display, manufacturers),
            allow_none=True,
        )
        manufacturer_note = manufacturer["name"] if manufacturer else "(none)"
        confirm = prompt_choice(
            f'  Create model "{name}" (category: {category["name"]}, '
            f"manufacturer: {manufacturer_note})? [y/n]: ", ("y", "n"))
        if confirm != "y":
            skipped.add(key)
            print()
            continue

        ok, model_id, messages = snipe.create_model(
            name, category["id"], manufacturer["id"] if manufacturer else None)
        if not ok:
            log.error('failed to create model "%s": %s — skipping its devices', name, messages)
            skipped.add(key)
            print()
            continue

        models[norm(name)] = {"id": model_id, "name": name}
        # Persist even when the user kept the Google name — covers renames too.
        model_map[key] = {"model_id": model_id, "model_name": name}
        save_model_map(model_map_file, model_map)
        log.info('created Snipe-IT model "%s" (id %s)', name, model_id)
        print()

    return skipped


# ---------------------------------------------------------------------------
# Sync engine
# ---------------------------------------------------------------------------

def resolve_model(model_name, models, model_map):
    """Exact-name match first, then the persisted model map. Never guesses."""
    key = norm(model_name)
    if key in models:
        return models[key]
    if key in model_map:
        return {"id": model_map[key]["model_id"], "name": model_map[key]["model_name"]}
    return None


@dataclass
class ReportRow:
    serial: str = ""
    asset_tag: str = ""
    asset_tag_source: str = ""
    google_model: str = ""
    google_device_id: str = ""
    snipeit_model_id: str = ""
    snipeit_model_name: str = ""
    action: str = ""
    detail: str = ""
    snipeit_asset_id: str = ""


def sync_devices(devices, snipe, models, model_map, skipped_models,
                 snipe_serials, snipe_tags, status_id, cfg, run_ts):
    """The add-only decision loop. Skips anything whose serial or tag exists;
    creates everything else (or records would-create in dry-run)."""
    rows = []
    seen_serials, seen_tags = set(), set()  # everything from THIS Google export

    for device in devices:
        tag = device.annotated_asset_id or device.serial
        tag_source = "annotatedAssetId" if device.annotated_asset_id else "serial-fallback"
        n_serial, n_tag = norm(device.serial), norm(tag)
        row = ReportRow(
            serial=device.serial, asset_tag=tag, asset_tag_source=tag_source,
            google_model=device.model, google_device_id=device.device_id,
        )
        rows.append(row)

        if not n_serial:
            row.action = "failed"
            row.detail = "device has no serial number in Google Admin"
        elif n_serial in snipe_serials:
            row.action, row.detail = "skipped-exists", "serial already in Snipe-IT"
        elif n_tag in snipe_tags:
            row.action, row.detail = "skipped-exists", "asset tag already in Snipe-IT"
        elif n_serial in seen_serials or n_tag in seen_tags:
            row.action, row.detail = "skipped-exists", "duplicate within Google export"
        else:
            resolved = resolve_model(device.model, models, model_map)
            if not device.model:
                row.action = "skipped-unknown-model"
                row.detail = "device has no model string in Google Admin"
            elif norm(device.model) in skipped_models:
                row.action = "skipped-unknown-model"
                row.detail = f'model "{device.model}" skipped by user for this run'
            elif resolved is None:
                row.action = "skipped-unknown-model"
                row.detail = f'no Snipe-IT model matches "{device.model}"'
            else:
                row.snipeit_model_id = str(resolved["id"])
                row.snipeit_model_name = resolved["name"]
                if cfg.dry_run:
                    row.action, row.detail = "would-create", "dry run — nothing written"
                else:
                    notes = (f"Created by chromeos-snipeit-sync on {run_ts:%Y-%m-%d} "
                             f"from Google Admin (deviceId {device.device_id})")
                    ok, asset_id, messages = snipe.create_asset(
                        tag, device.serial, resolved["id"], status_id, notes)
                    if ok:
                        row.action = "created"
                        row.snipeit_asset_id = str(asset_id or "")
                        snipe_serials.add(n_serial)
                        snipe_tags.add(n_tag)
                    else:
                        row.action = "failed"
                        row.detail = f"Snipe-IT rejected create: {messages}"

        seen_serials.add(n_serial)
        seen_tags.add(n_tag)
        log.info("%-22s serial=%s tag=%s model=%s%s",
                 row.action, device.serial or "(none)", tag or "(none)",
                 device.model or "(none)", f" — {row.detail}" if row.detail else "")

    return rows


# ---------------------------------------------------------------------------
# Report + email
# ---------------------------------------------------------------------------

REPORT_COLUMNS = (
    "run_timestamp", "serial", "asset_tag", "asset_tag_source", "google_model",
    "google_device_id", "snipeit_model_id", "snipeit_model_name", "action",
    "detail", "snipeit_asset_id",
)


def write_report(rows, report_dir, run_ts):
    report_dir.mkdir(parents=True, exist_ok=True)
    path = report_dir / f"sync-report_{run_ts:%Y-%m-%d_%H%M%S}.csv"
    stamp = run_ts.isoformat(timespec="seconds")
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(REPORT_COLUMNS)
        for row in rows:
            writer.writerow([
                stamp, row.serial, row.asset_tag, row.asset_tag_source,
                row.google_model, row.google_device_id, row.snipeit_model_id,
                row.snipeit_model_name, row.action, row.detail, row.snipeit_asset_id,
            ])
    log.info("run report written: %s", path)
    return path


def collect_problems(rows):
    """Human-readable problem lines: unknown models (grouped) + failures."""
    problems = []
    unknown = Counter(
        row.google_model or "(no model string)"
        for row in rows if row.action == "skipped-unknown-model"
    )
    for model, count in sorted(unknown.items()):
        problems.append(
            f'unknown model "{model}" — {count} device(s) skipped; '
            "run the script interactively to create or map it"
        )
    for row in rows:
        if row.action == "failed":
            problems.append(
                f"failed: serial={row.serial or '(none)'} tag={row.asset_tag} — {row.detail}"
            )
    return problems


def build_email_body(problems, summary, run_ts):
    lines = [
        f"chromeos-snipeit-sync run {run_ts:%Y-%m-%d %H:%M} finished with "
        f"{len(problems)} problem(s).",
        "",
        "Summary: " + (", ".join(f"{action}={count}" for action, count
                                 in sorted(summary.items())) or "no devices processed"),
        "",
        "Problems:",
    ]
    lines.extend(f"  - {problem}" for problem in problems)
    lines += ["", "The full run report is attached.",
              "No existing Snipe-IT assets were modified (add-only sync)."]
    return "\n".join(lines)


def send_problem_email(cfg, subject, body, attachment_path=None):
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = cfg.smtp_from
    message["To"] = ", ".join(cfg.smtp_to)
    message.set_content(body)
    if attachment_path is not None:
        message.add_attachment(
            attachment_path.read_bytes(), maintype="text", subtype="csv",
            filename=attachment_path.name,
        )
    with smtplib.SMTP(cfg.smtp_host, cfg.smtp_port, timeout=30) as smtp:
        smtp.starttls(context=ssl.create_default_context())
        smtp.login(cfg.smtp_username, cfg.smtp_password)
        smtp.send_message(message)
    log.info("problem email sent to %s", ", ".join(cfg.smtp_to))


def email_fatal_error(cfg, error_text):
    """Best-effort: a cron run that dies should still reach the admin."""
    if cfg is None or not cfg.non_interactive or cfg.dry_run or not cfg.smtp_host:
        return
    try:
        send_problem_email(
            cfg,
            f"[chromeos-snipeit-sync] FATAL error — {datetime.now():%Y-%m-%d %H:%M}",
            "The sync aborted before completing:\n\n" + error_text +
            "\n\nNo existing Snipe-IT assets were modified (add-only sync).",
        )
    except Exception as exc:  # noqa: BLE001 — never mask the original fatal error
        log.error("could not send fatal-error email: %s", exc)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_sync(cfg):
    run_ts = datetime.now()
    log.info("starting %s run (%s)", "DRY-RUN" if cfg.dry_run else "sync",
             "non-interactive" if cfg.non_interactive else "interactive")

    service = build_google_service(cfg)
    devices = fetch_active_devices(service, cfg)
    if cfg.limit:
        devices = devices[:cfg.limit]
        log.info("--limit %d: processing first %d device(s)", cfg.limit, len(devices))

    snipe = SnipeIT(cfg.snipeit_url, cfg.snipeit_api_token, cfg.snipeit_verify_tls)
    snipe_serials, snipe_tags = snipe.fetch_hardware_identifiers()
    models = snipe.fetch_models()
    status_id = snipe.fetch_status_label_id(cfg.snipeit_status_label)
    if status_id is None:
        raise FatalError(
            f'status label "{cfg.snipeit_status_label}" not found in Snipe-IT — '
            "refusing to guess a status ID"
        )
    model_map = load_model_map(cfg.model_map_file, models)

    # Group unresolved Google models so each is handled once, not per device.
    unknown = {}
    for device in devices:
        key = norm(device.model)
        if not key or key in models or key in model_map:
            continue
        entry = unknown.setdefault(key, {"display": device.model, "count": 0})
        entry["count"] += 1

    skipped_models = set()
    if unknown:
        if cfg.dry_run:
            log.info("dry run: %d unknown model(s) would need resolution: %s",
                     len(unknown),
                     ", ".join(sorted(info["display"] for info in unknown.values())))
        elif cfg.non_interactive:
            log.warning("%d unknown model(s) — devices skipped, see problem email",
                        len(unknown))
        else:
            skipped_models = resolve_unknown_models(
                unknown, snipe, models, model_map, cfg.model_map_file)

    rows = sync_devices(devices, snipe, models, model_map, skipped_models,
                        snipe_serials, snipe_tags, status_id, cfg, run_ts)

    report_path = write_report(rows, cfg.report_dir, run_ts)
    summary = Counter(row.action for row in rows)
    log.info("done: %s", ", ".join(f"{action}={count}"
                                   for action, count in sorted(summary.items())) or "0 devices")

    problems = collect_problems(rows)
    if not problems:
        return 0

    body = build_email_body(problems, summary, run_ts)
    subject = f"[chromeos-snipeit-sync] {len(problems)} problem(s) — {run_ts:%Y-%m-%d %H:%M}"
    if cfg.dry_run:
        log.info("dry run: email that WOULD be sent on a non-interactive run:\n"
                 "Subject: %s\n%s", subject, body)
    elif cfg.non_interactive:
        try:
            send_problem_email(cfg, subject, body, report_path)
        except Exception as exc:  # noqa: BLE001 — report delivery must not crash the run
            log.error("could not send problem email: %s", exc)
    else:
        log.warning("%d problem(s) — see the report: %s", len(problems), report_path)
    return 2


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Add-only sync of ACTIVE Google Admin ChromeOS devices into "
                    "Snipe-IT. Never updates existing assets.",
    )
    parser.add_argument("--dry-run", action="store_true",
                        help="no writes, no prompts, no email — report what would happen")
    parser.add_argument("--non-interactive", action="store_true",
                        help="cron mode: never prompt; skip unknown models and email problems")
    parser.add_argument("--limit", type=int, default=0, metavar="N",
                        help="process only the first N devices (testing)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    setup_logging()

    try:
        cfg = Config.from_env(args)
    except ConfigError as exc:
        log.error("configuration: %s", exc)
        return 1

    try:
        return run_sync(cfg)
    except FatalError as exc:
        log.error("fatal: %s", exc)
        email_fatal_error(cfg, str(exc))
        return 1
    except KeyboardInterrupt:
        log.error("interrupted — no cleanup needed (add-only sync)")
        return 1
    except Exception:  # noqa: BLE001 — cron must get an email, not a silent stack trace
        error_text = traceback.format_exc()
        log.error("unhandled exception:\n%s", error_text)
        email_fatal_error(cfg, error_text)
        return 1


if __name__ == "__main__":
    sys.exit(main())
