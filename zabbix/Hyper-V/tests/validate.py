#!/usr/bin/env python3
"""Static validation for the NOMMA Hyper-V Zabbix solution."""
from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys
import uuid

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
TEMPLATE = ROOT / "templates" / "template_hyperv_replica_7.0.yaml"
FIXTURES = ROOT / "tests" / "fixtures" / "scenarios.json"
errors: list[str] = []
checks = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        errors.append(message)


def all_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from all_nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_nodes(child)


data = yaml.safe_load(TEMPLATE.read_text(encoding="utf-8"))
export = data.get("zabbix_export", {})
check(export.get("version") == "7.0", "Template export version must be exactly 7.0.")
templates = export.get("templates", [])
check(len(templates) == 1, "Exactly one template is expected.")
template = templates[0]
check(template.get("template") == "NOMMA Hyper-V and Replica by Zabbix agent", "Unexpected template technical name.")

uuid_values: list[str] = []
for node in all_nodes(data):
    if "uuid" in node:
        value = str(node["uuid"])
        uuid_values.append(value)
        try:
            parsed = uuid.UUID(value)
            check(parsed.version == 4 and parsed.hex == value.lower(), f"UUID is not lowercase UUIDv4: {value}")
        except ValueError:
            check(False, f"Invalid UUID: {value}")
check(len(uuid_values) == len(set(uuid_values)), "Template UUIDs are not unique.")

items = template.get("items", [])
rules = template.get("discovery_rules", [])
item_prototypes = [item for rule in rules for item in rule.get("item_prototypes", [])]
keys = [item["key"] for item in items] + [rule["key"] for rule in rules] + [item["key"] for item in item_prototypes]
check(len(keys) == len(set(keys)), "Item, discovery-rule, or prototype keys are duplicated.")
key_set = set(keys)
for item in items + rules + item_prototypes:
    if item.get("type") == "DEPENDENT":
        master = item.get("master_item", {}).get("key")
        check(master in key_set, f"Dependent item {item['key']} references missing master item {master!r}.")

macro_names = {entry["macro"] for entry in template.get("macros", [])}
setup_text = (ROOT / "Setup.md").read_text(encoding="utf-8")
for macro in macro_names:
    check(macro in setup_text, f"Setup.md does not document required macro {macro}.")
for required_name in ["Get-ZabbixHyperVData.ps1", "Install-ZabbixHyperVMonitoring.ps1", "hyperv-monitoring.json", "hyperv.conf", "template_hyperv_replica_7.0.yaml"]:
    check(required_name in setup_text, f"Setup.md does not reference implemented file {required_name}.")
expressions: list[str] = []
for trigger in export.get("triggers", []):
    expressions.extend([trigger.get("expression", ""), trigger.get("recovery_expression", "")])
for item in template.get("items", []):
    for trigger in item.get("triggers", []):
        expressions.extend([trigger.get("expression", ""), trigger.get("recovery_expression", "")])
for item in item_prototypes:
    for trigger in item.get("trigger_prototypes", []):
        expressions.extend([trigger.get("expression", ""), trigger.get("recovery_expression", "")])
        if item.get("key", "").startswith("hyperv.replica."):
            check("hyperv.collector.ok" in trigger.get("expression", ""), f"Replica trigger {trigger.get('name')} lacks collector-failure gating.")
for expression in expressions:
    for macro in re.findall(r"\{\$[A-Z0-9_.]+(?:\:\"\{#[A-Z0-9_.]+\}\")?\}", expression):
        base = re.sub(r':"\{#[A-Z0-9_.]+\}"', "", macro)
        check(base in macro_names, f"Trigger expression references undefined user macro {base}.")
    for key in re.findall(r"hyperv\.[a-z0-9_.]+(?:\[\"[^\"]+\"\])?", expression):
        check(key in key_set, f"Trigger expression references missing item/prototype key {key}.")

fixture = json.loads(FIXTURES.read_text(encoding="utf-8"))
scenario_names = {entry["name"] for entry in fixture["scenarios"]}
required_scenarios = {
    "hyperv_operational", "hyperv_not_installed", "replication_disabled", "replication_healthy",
    "replication_warning", "replication_critical", "vm_powered_on", "vm_powered_off_intentionally",
    "standalone_host", "clustered_with_csv", "clustered_without_csv", "permission_denied",
    "inaccessible_or_deleted_vm", "empty_discovery", "powershell_or_cim_failure",
}
check(scenario_names == required_scenarios, "Fixture scenario coverage differs from the required 15 scenarios.")
healthy = next(entry["data"] for entry in fixture["scenarios"] if entry["name"] == "hyperv_operational")
for rule in rules:
    path = rule.get("preprocessing", [{}])[0].get("parameters", [""])[0]
    collection = path.removeprefix("$.")
    objects = healthy.get(collection, [])
    if not objects:
        continue
    consumed = set()
    for item in rule.get("item_prototypes", []):
        consumed.update(re.findall(r"\{#[A-Z0-9_.]+\}", json.dumps(item)))
    missing = consumed.difference(objects[0].keys())
    check(not missing, f"LLD rule {rule['key']} fixture lacks macros: {sorted(missing)}")

user_parameter = (ROOT / "userparameters" / "hyperv.conf").read_text(encoding="utf-8")
collector_text = (ROOT / "scripts" / "Get-ZabbixHyperVData.ps1").read_text(encoding="utf-8")
check("Measure-VMReplication" in collector_text, "Collector must use the supported Measure-VMReplication cmdlet.")
check("Get-VMReplicationStatistics" not in collector_text, "Collector uses nonexistent/unsupported Get-VMReplicationStatistics syntax.")
check("'Error' { return 5 }" in collector_text and "'UpdateError' { return 5 }" in collector_text, "Critical Replica error states are not mapped.")
check(user_parameter.count("UserParameter=hyperv.collect,") == 1, "Expected one hyperv.collect UserParameter.")
check(' -File "C:\\Program Files\\Zabbix Agent 2\\scripts\\Hyper-V\\Get-ZabbixHyperVData.ps1"' in user_parameter, "Collector path is not correctly quoted.")
check(' -ConfigPath "C:\\Program Files\\Zabbix Agent 2\\scripts\\Hyper-V\\hyperv-monitoring.json"' in user_parameter, "Configuration path is not correctly quoted.")

for ps1 in ROOT.rglob("*.ps1"):
    raw = ps1.read_bytes()
    check(all(byte < 128 for byte in raw), f"PowerShell file contains non-ASCII bytes unsafe for Windows PowerShell 5.1: {ps1.relative_to(ROOT)}")

status = subprocess.run(["git", "status", "--porcelain", "-uall"], cwd=REPO, text=True, capture_output=True, check=True).stdout.splitlines()
for line in status:
    path = line[3:].split(" -> ")[-1]
    check(path.startswith("zabbix/Hyper-V/"), f"Unrelated working-tree change detected: {path}")

sensitive = re.compile(r"(?i)(password|api[_-]?token|private[_-]?key)\s*[:=]\s*['\"][^<{$\s][^'\"]+['\"]")
for path in ROOT.rglob("*"):
    if path.is_file() and path.suffix.lower() in {".ps1", ".py", ".json", ".yaml", ".yml", ".conf", ".md"}:
        check(not sensitive.search(path.read_text(encoding="utf-8", errors="replace")), f"Possible hard-coded secret in {path.relative_to(ROOT)}")

if errors:
    print(f"FAIL: {len(errors)} of {checks} checks failed.")
    for error in errors:
        print(f" - {error}")
    sys.exit(1)
print(f"PASS: {checks} static template, LLD, key, UUID, path, and secret checks.")
