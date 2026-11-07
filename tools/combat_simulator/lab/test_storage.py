"""Experiment/results persistence without accessing desktop UI or modifying game data."""
from __future__ import annotations

import copy
import csv
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

try:
    from .test_helpers import PROJECT_ROOT, ids, session
except ImportError:
    from test_helpers import PROJECT_ROOT, ids, session

from tools.combat_simulator.lab import model, storage


class StorageTests(unittest.TestCase):
    def test_roundtrip_preserves_all_attributes_curves_modifiers_and_unicode(self):
        settings = session()
        settings["name"] = "Ãƒâ€°preuves / Ã§â€šÅ½"
        settings["curves"] = {"melee": [.8, .4, .2, .6], "spell": [.8, .4, .2, .6]}
        source = settings["players"][0]
        source["name"] = "GuerriÃƒÂ¨re Ãƒâ€ "
        source["base_values"] = {str(value): value + .125 for value in ids().values()}
        source["modifiers"] = [{"attribute": ids()["DOT_DAMAGE"], "operation": 0, "value": 12.5,
                                "source": 0, "required_context_tags": ["Damage.Periodic"],
                                "excluded_context_tags": ["Damage.Necrotic"]}]
        before = copy.deepcopy(settings)
        with tempfile.TemporaryDirectory(prefix="combat_lab_storage_") as temporary:
            path = Path(temporary) / "expÃƒÂ©rience.json"
            storage.save_experiment(path, settings)
            self.assertEqual(storage.load_experiment(path), before)
            self.assertEqual(settings, before)
            raw = path.read_text(encoding="utf-8")
            self.assertTrue(raw.endswith("\n"))
            self.assertNotIn("NaN", raw)

    def test_saved_run_restores_its_original_input_snapshot(self):
        settings = session()
        document = {"status": "cancelled", "cells": [], "scenario_snapshot": settings,
                    "completed_trials": 0, "requested_trials": settings["run"]["trials"]}
        with tempfile.TemporaryDirectory(prefix="combat_lab_run_") as temporary:
            path = Path(temporary) / "saved_run.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            restored = storage.load_experiment(path)
            self.assertEqual(restored, settings)
            restored["curves"]["melee"][0] = 0.01
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), document)
            document["scenario_snapshot"]["run"]["trials"] = 0
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaises(ValueError):
                storage.load_experiment(path)

    def test_utf8_bom_experiments_load_and_invalid_experiments_are_rejected(self):
        settings = session()
        with tempfile.TemporaryDirectory(prefix="combat_lab_storage_") as temporary:
            path = Path(temporary) / "input.json"
            path.write_text(json.dumps(settings), encoding="utf-8-sig")
            self.assertEqual(storage.load_experiment(path), settings)
            settings["run"]["trials"] = 0
            path.write_text(json.dumps(settings), encoding="utf-8")
            with self.assertRaises(ValueError):
                storage.load_experiment(path)
            output = Path(temporary) / "invalid_output.json"
            with self.assertRaises(ValueError):
                storage.save_experiment(output, settings)
            self.assertFalse(output.exists())

    def test_authored_game_paths_and_import_snapshot_are_protected_without_writing_them(self):
        protected = [PROJECT_ROOT / directory / "test_output.json"
                     for directory in ["combat", "player", "levels", "examples", "materials"]]
        protected += [PROJECT_ROOT / "combat" / "combat_rules.json",
                      Path(model.__file__).with_name("game_snapshot.json"),
                      PROJECT_ROOT / "tools" / "combat_simulator" / "lab" / ".." / ".." / ".." / "combat" / "combat_rules.json"]
        # ensure_output_path is pure. No attempted writes to actual authored files.
        for path in protected:
            with self.subTest(path=path), self.assertRaises(ValueError):
                storage.ensure_output_path(path, ".json")
        # Also verify the guard runs before writing, even if this test fails.
        with mock.patch.object(Path, "write_text", side_effect=AssertionError("Attempted protected write")):
            with self.assertRaises(ValueError):
                storage.save_experiment(PROJECT_ROOT / "combat" / "combat_rules.json", session())
        with mock.patch.object(Path, "open", side_effect=AssertionError("Attempted protected CSV open")):
            with self.assertRaises(ValueError):
                storage.export_csv(PROJECT_ROOT / "combat" / "test_output.csv", [])

    def test_output_suffixes_and_resolved_paths(self):
        with tempfile.TemporaryDirectory(prefix="combat_lab_storage_") as temporary:
            path = Path(temporary) / "relative" / ".." / "output.JSON"
            self.assertEqual(storage.ensure_output_path(path, ".json"), Path(temporary) / "output.JSON")
            for path, suffix in [(Path(temporary) / "wrong.csv", ".json"),
                                 (Path(temporary) / "wrong.json", ".csv"),
                                 (Path(temporary) / "no_extension", ".json")]:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    storage.ensure_output_path(path, suffix)
            with self.assertRaises(ValueError):
                storage.save_experiment(Path(temporary) / "wrong.csv", session())
            with self.assertRaises(ValueError):
                storage.export_csv(Path(temporary) / "wrong.json", [])

    def test_csv_preserves_unicode_timeouts_missing_ttk_and_nested_diagnostics(self):
        rows = [{"index": 0, "player_name": "GuerriÃƒÂ¨re Ãƒâ€ ", "enemy_name": "Ã§â€šÅ½, \"boss\"\nphase 2",
                 "ability_name": "BrÃƒÂ»lure", "trials": 100, "kills": 0, "timeouts": 100,
                 "kill_rate": 0, "ttk_mean": None, "ttk_p95": None,
                 "restricted_mean_time": 120, "variants": {"Armor": 100},
                 "analytic": {"assumptions": ["No movement", "Continuous regeneration"], "value": None},
                 "histogram": {"edges": [0, 1], "counts": [0]}},
                {"index": 1, "player_name": "Other", "trials": 1, "kills": 1, "timeouts": 0,
                 "ttk_mean": 0, "extra": ["x", 1, None]}]
        with tempfile.TemporaryDirectory(prefix="combat_lab_storage_") as temporary:
            path = Path(temporary) / "rÃƒÂ©sultats.csv"
            storage.export_csv(path, rows)
            with path.open(encoding="utf-8-sig", newline="") as stream:
                read = list(csv.DictReader(stream))
            self.assertEqual(len(read), 2)
            self.assertEqual(read[0]["enemy_name"], rows[0]["enemy_name"])
            self.assertEqual(read[0]["player_name"], "GuerriÃƒÂ¨re Ãƒâ€ ")
            self.assertEqual(read[0]["timeouts"], "100")
            self.assertEqual(read[0]["ttk_mean"], "")
            self.assertEqual(read[1]["ttk_mean"], "0")
            for field in ["variants", "analytic", "histogram"]:
                self.assertEqual(json.loads(read[0][field]), rows[0][field])
            self.assertEqual(json.loads(read[1]["extra"]), rows[1]["extra"])

    def test_empty_csv_still_has_measurement_headers(self):
        with tempfile.TemporaryDirectory(prefix="combat_lab_storage_") as temporary:
            path = Path(temporary) / "empty.csv"
            storage.export_csv(path, [])
            with path.open(encoding="utf-8-sig", newline="") as stream:
                reader = csv.DictReader(stream)
                self.assertIn("timeouts", reader.fieldnames)
                self.assertIn("ttk_mean", reader.fieldnames)
                self.assertEqual(list(reader), [])


class CommandLineSmokeTests(unittest.TestCase):
    def test_headless_cli_runs_default_matrix_and_saves_full_result_to_temporary_path(self):
        with tempfile.TemporaryDirectory(prefix="combat_lab_cli_") as temporary:
            output = Path(temporary) / "result.json"
            process = subprocess.run([
                sys.executable, str(PROJECT_ROOT / "tools" / "combat_simulator" / "combat_lab.py"),
                "--headless", "--trials", "100", "--horizon", "120", "--output", str(output),
            ], capture_output=True, text=True, timeout=30, cwd=PROJECT_ROOT)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["status"], "complete")
            self.assertTrue(result["cells"])
            self.assertEqual(result["completed_trials"], len(result["cells"]) * 100)
            self.assertEqual(result["scenario_snapshot"]["run"]["horizon"], 120)
            self.assertTrue(all(row["trials"] == 100 for row in result["cells"]))
            self.assertNotIn("Traceback", process.stderr)


if __name__ == "__main__":
    unittest.main()
