#!/usr/bin/env python3
"""One-way ChromeOS inventory sync: Google Admin -> Snipe-IT."""

from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import random
import sys
import time
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass, field
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any, Iterator, Mapping, Protocol

import requests
from dotenv import load_dotenv
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

ROOT = Path(__file__).resolve().parent
GOOGLE_SCOPE = "https://www.googleapis.com/auth/admin.directory.device.chromeos.readonly"
LOG = logging.getLogger("google-admin-snipeit-sync")

EXIT_OK = 0
EXIT_CONFIG = 2
EXIT_LOCKED = 3
EXIT_API = 4
EXIT_PARTIAL = 5


class ConfigError(Exception):
    """Invalid local configuration."""


class ApiError(Exception):
    """Fatal remote API error."""


class AlreadyRunning(Exception):
    """Another process owns the lock."""


def clean(value: Any) -> str:
    return str(value or "").strip()


def key(value: Any) -> str:
    return clean(value).casefold()


def secret_safe(text: str, secrets: tuple[str, ...]) -> str:
    result = text
    for secret in secrets:
        if secret:
            result = result.replace(secret, "[REDACTED]")
    return result


@dataclass(frozen=True)
class Config:
    snipeit_url: str
    snipeit_api_token: str
    google_service_account_file: Path
    google_delegated_admin: str
    google_customer_id: str
    model_mapping_file: Path
    log_level: str = "INFO"
    log_file: Path = ROOT / "logs/sync.log"
    lock_file: Path = ROOT / "logs/sync.lock"
    category_name: str = "Chromebook"
    status_name: str = "Ready to Depoly"
    company_name: str = "New Orleans Military & Maritime Academy"
    verify_tls: bool = True

    @classmethod
    def from_env(cls, env_file: Path | None = None) -> Config:
        load_dotenv(env_file or ROOT / ".env", override=False)
        required = (
            "SNIPEIT_URL",
            "SNIPEIT_API_TOKEN",
            "GOOGLE_SERVICE_ACCOUNT_FILE",
            "GOOGLE_DELEGATED_ADMIN",
            "GOOGLE_CUSTOMER_ID",
            "MODEL_MAPPING_FILE",
        )
        missing = [name for name in required if not clean(os.getenv(name))]
        if missing:
            raise ConfigError("missing environment variables: " + ", ".join(missing))

        verify_raw = clean(os.getenv("SNIPEIT_VERIFY_TLS", "true")).lower()
        if verify_raw not in {"true", "false", "1", "0", "yes", "no"}:
            raise ConfigError("SNIPEIT_VERIFY_TLS must be true or false")
        level = clean(os.getenv("LOG_LEVEL", "INFO")).upper()
        if level not in logging.getLevelNamesMapping():
            raise ConfigError(f"invalid LOG_LEVEL: {level}")

        def path_from(name: str, default: str | Path | None = None) -> Path:
            raw = clean(os.getenv(name)) or str(default or "")
            path = Path(raw).expanduser()
            return path if path.is_absolute() else ROOT / path

        url = clean(os.environ["SNIPEIT_URL"]).rstrip("/")
        if not url.startswith("https://"):
            raise ConfigError("SNIPEIT_URL must use HTTPS")
        return cls(
            snipeit_url=url,
            snipeit_api_token=clean(os.environ["SNIPEIT_API_TOKEN"]),
            google_service_account_file=path_from("GOOGLE_SERVICE_ACCOUNT_FILE"),
            google_delegated_admin=clean(os.environ["GOOGLE_DELEGATED_ADMIN"]),
            google_customer_id=clean(os.environ["GOOGLE_CUSTOMER_ID"]),
            model_mapping_file=path_from("MODEL_MAPPING_FILE"),
            log_level=level,
            log_file=path_from("LOG_FILE", ROOT / "logs/sync.log"),
            lock_file=path_from("LOCK_FILE", ROOT / "logs/sync.lock"),
            category_name=clean(os.getenv("SNIPEIT_CATEGORY_NAME", "Chromebook")),
            status_name=clean(os.getenv("SNIPEIT_STATUS_NAME", "Ready to Depoly")),
            company_name=clean(
                os.getenv(
                    "SNIPEIT_COMPANY_NAME",
                    "New Orleans Military & Maritime Academy",
                )
            ),
            verify_tls=verify_raw in {"true", "1", "yes"},
        )

    @property
    def secrets(self) -> tuple[str, ...]:
        return (self.snipeit_api_token,)

    def validate_local(self, require_credentials: bool = True) -> dict[str, str]:
        problems: list[str] = []
        if require_credentials and not self.google_service_account_file.is_file():
            problems.append(
                f"GOOGLE_SERVICE_ACCOUNT_FILE not found: {self.google_service_account_file}"
            )
        if not self.model_mapping_file.is_file():
            problems.append(f"MODEL_MAPPING_FILE not found: {self.model_mapping_file}")
        if self.google_delegated_admin.count("@") != 1:
            problems.append("GOOGLE_DELEGATED_ADMIN must be an email address")
        if not all((self.category_name, self.status_name, self.company_name)):
            problems.append("Snipe-IT default names cannot be blank")
        if problems:
            raise ConfigError("; ".join(problems))
        mappings = load_model_mapping(self.model_mapping_file)
        return {
            "snipeit_url": self.snipeit_url,
            "google_delegated_admin": self.google_delegated_admin,
            "google_customer_id": self.google_customer_id,
            "model_mapping_file": str(self.model_mapping_file),
            "model_mappings": str(len(mappings)),
            "category": self.category_name,
            "status": self.status_name,
            "company": self.company_name,
        }


def setup_logging(cfg: Config) -> None:
    cfg.log_file.parent.mkdir(parents=True, exist_ok=True)
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s", "%Y-%m-%dT%H:%M:%S%z"
    )
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(cfg.log_level)
    console = logging.StreamHandler()
    console.setFormatter(formatter)
    rotating = RotatingFileHandler(
        cfg.log_file, maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8"
    )
    rotating.setFormatter(formatter)
    root.addHandler(console)
    root.addHandler(rotating)


@contextmanager
def single_run_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise AlreadyRunning(f"another run owns lock {path}") from exc
        handle.seek(0)
        handle.truncate()
        handle.write(str(os.getpid()))
        handle.flush()
        yield


@dataclass(frozen=True)
class GoogleDevice:
    device_id: str
    serial: str
    asset_tag: str
    hardware_model: str

    @classmethod
    def from_api(cls, row: Mapping[str, Any]) -> GoogleDevice:
        return cls(
            device_id=clean(row.get("deviceId")),
            serial=clean(row.get("serialNumber")),
            asset_tag=clean(row.get("annotatedAssetId")),
            hardware_model=clean(row.get("model")),
        )


class GoogleInventory:
    def __init__(self, cfg: Config):
        credentials = service_account.Credentials.from_service_account_file(
            str(cfg.google_service_account_file), scopes=[GOOGLE_SCOPE]
        ).with_subject(cfg.google_delegated_admin)
        self.service = build(
            "admin", "directory_v1", credentials=credentials, cache_discovery=False
        )
        self.customer_id = cfg.google_customer_id

    def devices(self) -> list[GoogleDevice]:
        found: list[GoogleDevice] = []
        token: str | None = None
        try:
            while True:
                response = (
                    self.service.chromeosdevices()
                    .list(
                        customerId=self.customer_id,
                        projection="FULL",
                        maxResults=300,
                        pageToken=token,
                        fields=(
                            "nextPageToken,chromeosdevices("
                            "deviceId,serialNumber,annotatedAssetId,model)"
                        ),
                    )
                    .execute(num_retries=5)
                )
                found.extend(
                    GoogleDevice.from_api(row)
                    for row in response.get("chromeosdevices", [])
                )
                token = response.get("nextPageToken")
                if not token:
                    return found
        except HttpError as exc:
            status = getattr(exc.resp, "status", "unknown")
            raise ApiError(f"Google Admin API HTTP {status}: {exc.reason}") from exc
        except Exception as exc:
            raise ApiError(f"Google authentication/device retrieval failed: {exc}") from exc


class InventoryBackend(Protocol):
    def devices(self) -> list[GoogleDevice]: ...


class SnipeIT:
    PAGE_SIZE = 500
    MAX_ATTEMPTS = 5

    def __init__(self, cfg: Config):
        self.base_url = cfg.snipeit_url
        self.verify_tls = cfg.verify_tls
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {cfg.snipeit_api_token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            }
        )

    def request(
        self,
        method: str,
        path: str,
        *,
        params: Mapping[str, Any] | None = None,
        body: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = f"{self.base_url}/api/v1{path}"
        for attempt in range(1, self.MAX_ATTEMPTS + 1):
            try:
                response = self.session.request(
                    method,
                    url,
                    params=params,
                    json=body,
                    timeout=(10, 60),
                    verify=self.verify_tls,
                )
            except (requests.ConnectionError, requests.Timeout) as exc:
                if attempt == self.MAX_ATTEMPTS:
                    raise ApiError(f"Snipe-IT {method} {path}: {exc}") from exc
                self._backoff(attempt, "network failure")
                continue

            if response.status_code == 429 or response.status_code >= 500:
                if attempt == self.MAX_ATTEMPTS:
                    raise ApiError(
                        f"Snipe-IT {method} {path}: HTTP {response.status_code} after retries"
                    )
                retry_after = response.headers.get("Retry-After", "")
                if retry_after.isdigit():
                    time.sleep(min(int(retry_after), 60))
                else:
                    self._backoff(attempt, f"HTTP {response.status_code}")
                continue
            if response.status_code >= 400:
                raise ApiError(
                    f"Snipe-IT {method} {path}: HTTP {response.status_code}: "
                    f"{response.text[:300]}"
                )
            try:
                payload = response.json()
            except ValueError as exc:
                raise ApiError(f"Snipe-IT {method} {path}: non-JSON response") from exc
            return payload
        raise ApiError("unreachable retry failure")

    @staticmethod
    def _backoff(attempt: int, reason: str) -> None:
        delay = min(2 ** (attempt - 1) + random.random(), 30)
        LOG.warning("Snipe-IT %s; retrying in %.1fs", reason, delay)
        time.sleep(delay)

    def rows(
        self, path: str, params: Mapping[str, Any] | None = None
    ) -> Iterator[dict[str, Any]]:
        offset = 0
        while True:
            page_params = {"limit": self.PAGE_SIZE, "offset": offset}
            page_params.update(params or {})
            payload = self.request("GET", path, params=page_params)
            page = payload.get("rows") or []
            if not isinstance(page, list):
                raise ApiError(f"Snipe-IT {path}: invalid rows response")
            yield from page
            offset += len(page)
            if not page or offset >= int(payload.get("total", offset)):
                return

    def assets(self) -> list[dict[str, Any]]:
        return list(self.rows("/hardware", {"sort": "id", "order": "asc"}))

    def models(self) -> list[dict[str, Any]]:
        return list(self.rows("/models", {"sort": "name", "order": "asc"}))

    def named_rows(self, path: str, name: str) -> list[dict[str, Any]]:
        return [row for row in self.rows(path) if clean(row.get("name")) == name]

    def create_asset(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        return self._write("POST", "/hardware", payload)

    def update_asset(self, asset_id: int, payload: Mapping[str, Any]) -> dict[str, Any]:
        return self._write("PATCH", f"/hardware/{asset_id}", payload)

    def _write(
        self, method: str, path: str, payload: Mapping[str, Any]
    ) -> dict[str, Any]:
        response = self.request(method, path, body=payload)
        if response.get("status") != "success":
            messages = response.get("messages", response)
            raise ApiError(f"Snipe-IT rejected {method} {path}: {messages}")
        return response


@dataclass(frozen=True)
class Defaults:
    category_id: int
    status_id: int
    company_id: int


def exact_one(rows: list[dict[str, Any]], kind: str, name: str) -> dict[str, Any]:
    if not rows:
        raise ConfigError(f'Snipe-IT {kind} named "{name}" does not exist')
    if len(rows) > 1:
        raise ConfigError(f'Snipe-IT has multiple {kind} records named "{name}"')
    return rows[0]


def resolve_defaults(snipe: SnipeIT, cfg: Config) -> Defaults:
    category = exact_one(
        snipe.named_rows("/categories", cfg.category_name), "category", cfg.category_name
    )
    status = exact_one(
        snipe.named_rows("/statuslabels", cfg.status_name),
        "status label",
        cfg.status_name,
    )
    company = exact_one(
        snipe.named_rows("/companies", cfg.company_name), "company", cfg.company_name
    )
    category_type = key(category.get("category_type"))
    if category_type and category_type != "asset":
        raise ConfigError(
            f'category "{cfg.category_name}" is type "{category.get("category_type")}", not asset'
        )
    status_type = key(status.get("type"))
    if status_type and status_type != "deployable":
        raise ConfigError(
            f'status label "{cfg.status_name}" is type "{status.get("type")}", not deployable'
        )
    configured_status = clean(status.get("name"))
    if configured_status != cfg.status_name:
        raise ConfigError(
            f'status spelling mismatch: configured "{cfg.status_name}", '
            f'Snipe-IT returned "{configured_status}"'
        )
    LOG.info(
        'resolved defaults: category="%s" id=%s; status="%s" id=%s; company="%s" id=%s',
        cfg.category_name,
        category["id"],
        cfg.status_name,
        status["id"],
        cfg.company_name,
        company["id"],
    )
    return Defaults(int(category["id"]), int(status["id"]), int(company["id"]))


def load_model_mapping(path: Path) -> dict[str, str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"cannot read model mapping {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"invalid JSON in model mapping {path}: {exc}") from exc
    if not isinstance(payload, dict) or not payload:
        raise ConfigError("model mapping must be a non-empty JSON object")
    mapping: dict[str, str] = {}
    for google_name, snipe_name in payload.items():
        if not isinstance(google_name, str) or not google_name.strip():
            raise ConfigError("model mapping keys must be non-empty strings")
        if not isinstance(snipe_name, str) or not snipe_name.strip():
            raise ConfigError(f'mapping for "{google_name}" must be a model name')
        if google_name != google_name.strip() or snipe_name != snipe_name.strip():
            raise ConfigError("model mapping names may not have surrounding whitespace")
        mapping[google_name] = snipe_name
    return mapping


def nested_id(value: Any) -> int | None:
    if isinstance(value, Mapping) and value.get("id") is not None:
        return int(value["id"])
    if isinstance(value, int):
        return value
    return None


def resolve_models(
    rows: list[dict[str, Any]], mapping: Mapping[str, str], category_id: int
) -> dict[str, dict[str, Any]]:
    by_name: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        by_name.setdefault(clean(row.get("name")), []).append(row)
    resolved: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    for google_name, snipe_name in mapping.items():
        matches = by_name.get(snipe_name, [])
        if len(matches) != 1:
            reason = "missing" if not matches else "duplicated"
            errors.append(f'"{snipe_name}" ({reason})')
            continue
        model = matches[0]
        model_category = nested_id(model.get("category")) or nested_id(
            model.get("category_id")
        )
        if model_category != category_id:
            errors.append(
                f'"{snipe_name}" is not in configured Chromebook category id {category_id}'
            )
            continue
        resolved[google_name] = model
    if errors:
        raise ConfigError("invalid mapped Snipe-IT models: " + "; ".join(errors))
    return resolved


@dataclass
class Result:
    action: str
    serial: str
    asset_tag: str
    google_model: str
    detail: str = ""
    changed_fields: dict[str, Any] = field(default_factory=dict)


@dataclass
class Summary:
    google_devices_read: int = 0
    eligible_devices: int = 0
    created: int = 0
    updated: int = 0
    unchanged: int = 0
    skipped: int = 0
    unmapped_models: int = 0
    errors: int = 0

    def count(self, result: Result) -> None:
        if result.action in {"created", "would_create"}:
            self.created += 1
        elif result.action in {"updated", "would_update"}:
            self.updated += 1
        elif result.action == "unchanged":
            self.unchanged += 1
        elif result.action == "unmapped_model":
            self.unmapped_models += 1
            self.skipped += 1
        elif result.action == "error":
            self.errors += 1
            self.skipped += 1
        else:
            self.skipped += 1


def asset_model_id(asset: Mapping[str, Any]) -> int | None:
    return nested_id(asset.get("model")) or nested_id(asset.get("model_id"))


def update_payload(
    asset: Mapping[str, Any], desired_tag: str, desired_model_id: int
) -> dict[str, Any]:
    payload: dict[str, Any] = {}
    if clean(asset.get("asset_tag")) != desired_tag:
        payload["asset_tag"] = desired_tag
    if asset_model_id(asset) != desired_model_id:
        payload["model_id"] = desired_model_id
    return payload


def create_payload(
    device: GoogleDevice, model_id: int, defaults: Defaults
) -> dict[str, Any]:
    return {
        "asset_tag": device.asset_tag,
        "serial": device.serial,
        "model_id": model_id,
        "status_id": defaults.status_id,
        "company_id": defaults.company_id,
    }


def build_indexes(
    assets: list[dict[str, Any]],
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, list[dict[str, Any]]]]:
    serials: dict[str, list[dict[str, Any]]] = {}
    tags: dict[str, list[dict[str, Any]]] = {}
    for asset in assets:
        if key(asset.get("serial")):
            serials.setdefault(key(asset.get("serial")), []).append(asset)
        if key(asset.get("asset_tag")):
            tags.setdefault(key(asset.get("asset_tag")), []).append(asset)
    return serials, tags


def evaluate_device(
    device: GoogleDevice,
    serial_index: dict[str, list[dict[str, Any]]],
    tag_index: dict[str, list[dict[str, Any]]],
    models: Mapping[str, dict[str, Any]],
    defaults: Defaults,
    apply: bool,
    snipe: Any,
) -> Result:
    def result(action: str, **kwargs: Any) -> Result:
        return Result(
            action=action,
            serial=device.serial,
            asset_tag=device.asset_tag,
            google_model=device.hardware_model,
            **kwargs,
        )

    if not device.serial:
        return result("missing_serial", detail="Google device has no serial number")
    if not device.asset_tag:
        return result("missing_asset_tag", detail="Google device has no asset ID")
    if device.hardware_model not in models:
        return result(
            "unmapped_model",
            detail=f'no exact mapping for "{device.hardware_model or "(blank)"}"',
        )

    serial_matches = serial_index.get(key(device.serial), [])
    if len(serial_matches) > 1:
        return result(
            "duplicate_conflict",
            detail=f"{len(serial_matches)} Snipe-IT assets have this serial",
        )
    model_id = int(models[device.hardware_model]["id"])
    if serial_matches:
        asset = serial_matches[0]
        tag_conflicts = [
            row
            for row in tag_index.get(key(device.asset_tag), [])
            if int(row["id"]) != int(asset["id"])
        ]
        if tag_conflicts:
            return result(
                "duplicate_conflict",
                detail="desired asset tag belongs to another Snipe-IT asset",
            )
        changes = update_payload(asset, device.asset_tag, model_id)
        if not changes:
            return result("unchanged", detail="asset tag and model already match")
        if not apply:
            return result("would_update", changed_fields=changes)
        try:
            snipe.update_asset(int(asset["id"]), changes)
            return result("updated", changed_fields=changes)
        except ApiError as exc:
            return result("error", detail=str(exc), changed_fields=changes)

    if tag_index.get(key(device.asset_tag)):
        return result(
            "duplicate_conflict",
            detail="asset tag belongs to a different Snipe-IT serial",
        )
    payload = create_payload(device, model_id, defaults)
    if not apply:
        return result("would_create", changed_fields=payload)
    try:
        response = snipe.create_asset(payload)
        created = (response.get("payload") or {}) if isinstance(response, Mapping) else {}
        synthetic = {
            "id": created.get("id", -1),
            "asset_tag": device.asset_tag,
            "serial": device.serial,
            "model": {"id": model_id},
        }
        serial_index.setdefault(key(device.serial), []).append(synthetic)
        tag_index.setdefault(key(device.asset_tag), []).append(synthetic)
        return result("created", changed_fields=payload)
    except ApiError as exc:
        return result("error", detail=str(exc), changed_fields=payload)


def sync(
    devices: list[GoogleDevice],
    assets: list[dict[str, Any]],
    models: Mapping[str, dict[str, Any]],
    defaults: Defaults,
    apply: bool,
    snipe: Any,
) -> tuple[list[Result], Summary]:
    serial_index, tag_index = build_indexes(assets)
    google_serials = Counter(key(device.serial) for device in devices if device.serial)
    results: list[Result] = []
    summary = Summary(google_devices_read=len(devices))
    for device in devices:
        if device.serial and google_serials[key(device.serial)] > 1:
            result = Result(
                "duplicate_conflict",
                device.serial,
                device.asset_tag,
                device.hardware_model,
                "duplicate serial in Google inventory",
            )
        else:
            result = evaluate_device(
                device, serial_index, tag_index, models, defaults, apply, snipe
            )
        if result.action not in {
            "missing_serial",
            "missing_asset_tag",
            "unmapped_model",
            "duplicate_conflict",
            "error",
        }:
            summary.eligible_devices += 1
        summary.count(result)
        results.append(result)
        LOG.info(
            "action=%s serial=%s asset_tag=%s google_model=%s changed=%s detail=%s",
            result.action,
            result.serial or "(missing)",
            result.asset_tag or "(missing)",
            result.google_model or "(missing)",
            json.dumps(result.changed_fields, sort_keys=True),
            result.detail,
        )
    return results, summary


class FixtureSnipe:
    """Read-only local verifier. Writes raise if a dry-run guard regresses."""

    def create_asset(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        raise AssertionError("fixture dry-run attempted create")

    def update_asset(self, asset_id: int, payload: Mapping[str, Any]) -> dict[str, Any]:
        raise AssertionError("fixture dry-run attempted update")


def read_fixture(path: Path) -> tuple[list[GoogleDevice], list[dict[str, Any]], list[dict[str, Any]], Defaults]:
    data = json.loads(path.read_text(encoding="utf-8"))
    devices = [GoogleDevice.from_api(row) for row in data["google_devices"]]
    defaults = Defaults(**data["defaults"])
    return devices, data["snipe_assets"], data["snipe_models"], defaults


def print_summary(summary: Summary) -> None:
    print("\nRun summary")
    for name in (
        "google_devices_read",
        "eligible_devices",
        "created",
        "updated",
        "unchanged",
        "skipped",
        "unmapped_models",
        "errors",
    ):
        print(f"  {name}: {getattr(summary, name)}")


def list_unmapped(devices: list[GoogleDevice], mapping: Mapping[str, str]) -> list[str]:
    return sorted(
        {device.hardware_model or "(blank)" for device in devices}
        - set(mapping),
        key=str.casefold,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="One-way Google Admin ChromeOS -> Snipe-IT inventory sync. Default mode is dry-run."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="evaluate only; never write (default)")
    mode.add_argument("--apply", action="store_true", help="create/update Snipe-IT assets")
    mode.add_argument("--validate-config", action="store_true", help="validate local configuration only")
    mode.add_argument(
        "--list-unmapped-models",
        action="store_true",
        help="read Google inventory and print hardware models absent from the mapping",
    )
    parser.add_argument("--env-file", type=Path, help="environment file (default: .env beside script)")
    parser.add_argument(
        "--fixture-file",
        type=Path,
        help="local fixture for offline dry-run verification; incompatible with --apply",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    cfg: Config | None = None
    if args.fixture_file and args.apply:
        print("ERROR: --fixture-file cannot be used with --apply", file=sys.stderr)
        return EXIT_CONFIG
    try:
        cfg = Config.from_env(args.env_file)
        setup_logging(cfg)
        cfg.validate_local(require_credentials=not bool(args.fixture_file))
        mapping = load_model_mapping(cfg.model_mapping_file)
        if args.validate_config:
            for setting, value in cfg.validate_local(
                require_credentials=not bool(args.fixture_file)
            ).items():
                print(f"{setting}: {value}")
            print("configuration valid (local checks only; no API calls made)")
            return EXIT_OK

        with single_run_lock(cfg.lock_file):
            if args.fixture_file:
                devices, assets, model_rows, defaults = read_fixture(args.fixture_file)
                resolved_models = resolve_models(
                    model_rows, mapping, defaults.category_id
                )
                snipe: Any = FixtureSnipe()
            else:
                google = GoogleInventory(cfg)
                devices = google.devices()
                if args.list_unmapped_models:
                    missing = list_unmapped(devices, mapping)
                    print("\n".join(missing) if missing else "No unmapped Google models.")
                    return EXIT_PARTIAL if missing else EXIT_OK
                snipe = SnipeIT(cfg)
                defaults = resolve_defaults(snipe, cfg)
                model_rows = snipe.models()
                resolved_models = resolve_models(
                    model_rows, mapping, defaults.category_id
                )
                assets = snipe.assets()

            if args.list_unmapped_models:
                missing = list_unmapped(devices, mapping)
                print("\n".join(missing) if missing else "No unmapped Google models.")
                return EXIT_PARTIAL if missing else EXIT_OK

            apply = bool(args.apply)
            LOG.info("starting mode=%s", "apply" if apply else "dry-run")
            _, summary = sync(devices, assets, resolved_models, defaults, apply, snipe)
            print_summary(summary)
            return EXIT_PARTIAL if summary.errors or summary.unmapped_models else EXIT_OK
    except ConfigError as exc:
        message = secret_safe(str(exc), cfg.secrets if cfg is not None else ())
        print(f"CONFIG ERROR: {message}", file=sys.stderr)
        return EXIT_CONFIG
    except AlreadyRunning as exc:
        print(f"LOCK ERROR: {exc}", file=sys.stderr)
        return EXIT_LOCKED
    except (ApiError, OSError, ValueError, KeyError) as exc:
        message = secret_safe(str(exc), cfg.secrets if cfg is not None else ())
        LOG.error("fatal error: %s", message) if logging.getLogger().handlers else print(
            f"API ERROR: {message}", file=sys.stderr
        )
        return EXIT_API
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
