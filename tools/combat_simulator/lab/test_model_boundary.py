"""The legacy lab must not reinterpret Combat 2.0 or overwrite its frozen inputs."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tools.combat_simulator import simulator
from tools.combat_simulator.lab import model, storage


class CombatModelBoundaryTests(unittest.TestCase):
    def test_default_rules_are_frozen_and_match_the_bundled_legacy_snapshot(self):
        rules = simulator.read_json(simulator.DEFAULT_RULES)
        self.assertEqual(simulator.DEFAULT_RULES.resolve(), model.RULES_PATH.resolve())
        self.assertNotEqual(model.RULES_PATH.resolve(), model.LIVE_RULES_PATH.resolve())
        self.assertEqual(rules["schema_version"], 2)
        exported_rules = model._snapshot()["rules"]
        self.assertEqual(set(rules), set(exported_rules))
        for key, value in rules.items():
            with self.subTest(key=key):
                if isinstance(value, (int, float)):
                    self.assertAlmostEqual(value, exported_rules[key])
                else:
                    self.assertEqual(value, exported_rules[key])

    def test_default_session_identifies_its_legacy_model(self):
        session = model.default_session()
        self.assertEqual(session["rules"]["schema_version"], 2)
        self.assertIn("pre-2.0", session["name"])
        self.assertIn(model.LEGACY_NOTICE, session["import_notes"])
        names = model.attribute_ids()
        actor = session["players"][0]
        values = model.resolve_actor(actor, session["rules"])
        self.assertIn(names["MAX_HEALTH"], values)
        self.assertNotIn("PHYSICAL_POWER", names)

    def test_rule_reader_rejects_live_2_0_rules_with_actionable_error(self):
        rules = copy.deepcopy(simulator.read_json(simulator.DEFAULT_RULES))
        rules.update(schema_version=3, combat_model="2.0-foundation")
        with tempfile.TemporaryDirectory(prefix="combat_model_boundary_") as temporary:
            path = Path(temporary) / "combat_rules.json"
            path.write_text(json.dumps(rules), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Combat 2.0.*legacy simulator"):
                simulator.read_json(path)
        with self.assertRaisesRegex(ValueError, "Combat 2.0"):
            model.require_legacy_rules(rules)

    def test_session_validation_rejects_2_0_before_evaluating_legacy_attributes(self):
        session = model.default_session()
        session["rules"]["schema_version"] = 3
        session["rules"]["combat_model"] = "2.0-foundation"
        with self.assertRaisesRegex(ValueError, "Combat 2.0 is not supported"):
            model.validate_session(session)
        for evaluate in (model.resolve_actor, model.resolve_actor_bases):
            with self.subTest(evaluate=evaluate.__name__), \
                    self.assertRaisesRegex(ValueError, "Combat 2.0 is not supported"):
                evaluate(session["players"][0], session["rules"])

    def test_import_guard_runs_before_godot_or_snapshot_mutation(self):
        live = {"schema_version": 3, "combat_model": "2.0-foundation"}
        with mock.patch.object(model, "_read_json", return_value=live), \
                mock.patch.object(model, "_godot_executable") as executable, \
                mock.patch.object(model.subprocess, "run") as process, \
                mock.patch.object(Path, "write_text") as write:
            with self.assertRaisesRegex(ValueError, "Combat 2.0 is not supported"):
                model.import_game("unused-godot")
        executable.assert_not_called()
        process.assert_not_called()
        write.assert_not_called()

    def test_experiment_cannot_overwrite_frozen_numeric_rules(self):
        with mock.patch.object(Path, "write_text") as write:
            with self.assertRaises(ValueError):
                storage.save_experiment(model.RULES_PATH, model.default_session())
        write.assert_not_called()


if __name__ == "__main__":
    unittest.main()
