from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

import sync_google_admin_snipeit as syncer


class CoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.defaults = syncer.Defaults(category_id=10, status_id=20, company_id=30)
        self.models = {
            "Google Exact": {"id": 40, "name": "Snipe Exact", "category": {"id": 10}}
        }

    def test_model_mapping_is_exact_and_resolves_category(self) -> None:
        rows = [{"id": 40, "name": "Snipe Exact", "category": {"id": 10}}]
        resolved = syncer.resolve_models(rows, {"Google Exact": "Snipe Exact"}, 10)
        self.assertEqual(40, resolved["Google Exact"]["id"])
        with self.assertRaises(syncer.ConfigError):
            syncer.resolve_models(rows, {"google exact": "snipe exact"}, 10)
        with self.assertRaises(syncer.ConfigError):
            syncer.resolve_models(rows, {"Google Exact": "Snipe Exact"}, 999)

    def test_model_mapping_file_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mapping.json"
            path.write_text('{"Google Exact": "Snipe Exact"}\n', encoding="utf-8")
            self.assertEqual(
                {"Google Exact": "Snipe Exact"}, syncer.load_model_mapping(path)
            )
            path.write_text("{}\n", encoding="utf-8")
            with self.assertRaises(syncer.ConfigError):
                syncer.load_model_mapping(path)

    def test_payloads_are_allowlisted(self) -> None:
        device = syncer.GoogleDevice("g1", "SERIAL", "TAG", "Google Exact")
        self.assertEqual(
            {
                "asset_tag": "TAG",
                "serial": "SERIAL",
                "model_id": 40,
                "status_id": 20,
                "company_id": 30,
            },
            syncer.create_payload(device, 40, self.defaults),
        )
        existing = {
            "id": 1,
            "asset_tag": "OLD",
            "model": {"id": 99},
            "assigned_to": {"id": 777},
            "notes": "keep",
        }
        self.assertEqual(
            {"asset_tag": "TAG", "model_id": 40},
            syncer.update_payload(existing, "TAG", 40),
        )

    def test_dry_run_never_calls_writes_and_classifies(self) -> None:
        devices = [
            syncer.GoogleDevice("g1", "NEW", "NEW-TAG", "Google Exact"),
            syncer.GoogleDevice("g2", "UPDATE", "NEWER-TAG", "Google Exact"),
            syncer.GoogleDevice("g3", "SAME", "SAME-TAG", "Google Exact"),
            syncer.GoogleDevice("g4", "", "TAG", "Google Exact"),
            syncer.GoogleDevice("g5", "NO-TAG", "", "Google Exact"),
            syncer.GoogleDevice("g6", "UNKNOWN", "UNKNOWN-TAG", "Unknown"),
        ]
        assets = [
            {"id": 1, "serial": "UPDATE", "asset_tag": "OLD", "model": {"id": 99}},
            {"id": 2, "serial": "SAME", "asset_tag": "SAME-TAG", "model": {"id": 40}},
        ]
        snipe = Mock()
        results, summary = syncer.sync(
            devices, assets, self.models, self.defaults, False, snipe
        )
        self.assertEqual(
            [
                "would_create",
                "would_update",
                "unchanged",
                "missing_serial",
                "missing_asset_tag",
                "unmapped_model",
            ],
            [result.action for result in results],
        )
        self.assertEqual((6, 3, 1, 1, 1, 3, 1, 0), tuple(summary.__dict__.values()))
        snipe.create_asset.assert_not_called()
        snipe.update_asset.assert_not_called()

    def test_apply_updates_only_changed_fields_and_continues_after_error(self) -> None:
        devices = [
            syncer.GoogleDevice("g1", "A", "TAG-A", "Google Exact"),
            syncer.GoogleDevice("g2", "B", "TAG-B", "Google Exact"),
        ]
        assets = [
            {"id": 1, "serial": "A", "asset_tag": "OLD-A", "model": {"id": 40}},
            {"id": 2, "serial": "B", "asset_tag": "OLD-B", "model": {"id": 40}},
        ]
        snipe = Mock()
        snipe.update_asset.side_effect = [syncer.ApiError("rejected"), {"status": "success"}]
        results, summary = syncer.sync(
            devices, assets, self.models, self.defaults, True, snipe
        )
        self.assertEqual(["error", "updated"], [result.action for result in results])
        self.assertEqual(1, summary.errors)
        self.assertEqual(2, snipe.update_asset.call_count)
        self.assertEqual({"asset_tag": "TAG-A"}, snipe.update_asset.call_args_list[0].args[1])

    def test_serial_and_asset_tag_conflicts_are_blocked(self) -> None:
        devices = [
            syncer.GoogleDevice("g1", "DUP", "TAG-NEW", "Google Exact"),
            syncer.GoogleDevice("g2", "NEW", "TAKEN", "Google Exact"),
        ]
        assets = [
            {"id": 1, "serial": "DUP", "asset_tag": "ONE", "model": {"id": 40}},
            {"id": 2, "serial": "dup", "asset_tag": "TWO", "model": {"id": 40}},
            {"id": 3, "serial": "OTHER", "asset_tag": "TAKEN", "model": {"id": 40}},
        ]
        results, _ = syncer.sync(
            devices, assets, self.models, self.defaults, False, Mock()
        )
        self.assertEqual(
            ["duplicate_conflict", "duplicate_conflict"],
            [result.action for result in results],
        )

    def test_snipe_pagination(self) -> None:
        client = syncer.SnipeIT.__new__(syncer.SnipeIT)
        client.request = Mock(
            side_effect=[
                {"total": 3, "rows": [{"id": 1}, {"id": 2}]},
                {"total": 3, "rows": [{"id": 3}]},
            ]
        )
        self.assertEqual([1, 2, 3], [row["id"] for row in client.rows("/hardware")])
        self.assertEqual(0, client.request.call_args_list[0].kwargs["params"]["offset"])
        self.assertEqual(2, client.request.call_args_list[1].kwargs["params"]["offset"])


if __name__ == "__main__":
    unittest.main()
