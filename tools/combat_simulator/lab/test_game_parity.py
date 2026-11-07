"""Pre-2.0 Godot attribute parity; skipped when the live game uses the new model."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

try:
    from .test_helpers import PROJECT_ROOT, actor, ids
    from .test_model import modifier
except ImportError:
    from test_helpers import PROJECT_ROOT, actor, ids
    from test_model import modifier

from tools.combat_simulator.lab import model


GODOT_PROFILE_SCRIPT = r'''
extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var profiles: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var results: Array = []
	for data: Dictionary in profiles:
		var source: Dictionary = data.actor
		var attributes := ActorAttributes.new()
		attributes.level = int(source.level)
		attributes.automatic_regeneration = false
		for primary: String in ["strength", "dexterity", "intellect", "vitality"]:
			attributes.set("allocated_" + primary, int(source.allocations.get(primary, 0)))
		var authored: Array[AttributeModifier] = []
		for entry: Dictionary in source.modifiers:
			var value := AttributeModifier.new()
			value.attribute = int(entry.attribute)
			value.operation = int(entry.operation)
			value.value = float(entry.value)
			value.source = int(entry.source)
			value.required_context_tags = PackedStringArray(entry.get("required_context_tags", []))
			value.excluded_context_tags = PackedStringArray(entry.get("excluded_context_tags", []))
			authored.append(value)
		attributes.initial_modifiers = authored
		attributes.initialize()
		var owned: Array[AttributeModifier] = []
		for key: String in source.base_values:
			var id := int(key)
			if CombatAttributes.is_current_resource(id):
				continue
			var value := AttributeModifier.new()
			value.attribute = id
			value.operation = AttributeModifier.Operation.SET_BASE
			value.value = float(source.base_values[key])
			if id == CombatAttributes.Id.BLOCK_CHANCE:
				value.source = AttributeModifier.Source.SHIELD
			owned.append(value)
		attributes.set_modifiers(&"lab_parity_test", owned)
		# An experiment starts fresh at its configured capacities, then explicit pool edits apply.
		attributes.restore_resources()
		for key: String in source.base_values:
			var id := int(key)
			if CombatAttributes.is_current_resource(id):
				attributes.modify_current(id, float(source.base_values[key]) - attributes.get_value(id))
		var snapshots: Array = []
		for context: Array in data.contexts:
			var values := {}
			for id: int in CombatAttributes.all_ids():
				values[str(id)] = attributes.get_value(id, PackedStringArray(context))
			snapshots.append(values)
		results.append({"id": source.id, "snapshots": snapshots})
		attributes.free()
	var file := FileAccess.open(args[1], FileAccess.WRITE)
	file.store_string(JSON.stringify(results))
	file.close()
	print("LAB_ATTRIBUTE_PARITY_OK")
	quit(0)
'''


class GodotAttributeParityTests(unittest.TestCase):
    def test_actual_saved_and_custom_actor_attributes_match_all_query_contexts(self):
        if model._read_json(model.LIVE_RULES_PATH).get("schema_version") != 2:
            self.skipTest("Live Godot uses Combat 2.0; the lab intentionally retains the pre-2.0 model.")
        try:
            executable = model._godot_executable(None)
        except ValueError as exc:
            self.skipTest(str(exc))
        contexts = [[], ["Ability.Attack.Melee", "Damage.Physical", "Damage.Direct"],
                    ["Ability.Attack.Melee", "Scaling.Dexterity", "Damage.Physical", "Damage.Direct"],
                    ["Ability.Spell.Fire", "Damage.Fire", "Damage.Elemental", "Damage.Direct"],
                    ["Ability.Spell.Fire", "Damage.Fire", "Damage.Elemental", "Damage.Periodic"]]
        with tempfile.TemporaryDirectory(prefix="combat_lab_parity_") as temporary:
            directory = Path(temporary)
            snapshot_path = directory / "game_snapshot.json"
            export = subprocess.run([
                str(executable), "--headless", "--path", str(PROJECT_ROOT), "--script",
                "res://tools/combat_simulator/lab/export_game.gd", "--", "--output", str(snapshot_path),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(export.returncode, 0, export.stdout + export.stderr)
            self.assertNotIn("SCRIPT ERROR", export.stdout + export.stderr)
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8-sig"))
            self.assertEqual({entry["id"] for entry in snapshot["catalogue"]},
                             {entry["id"] for entry in model.attribute_catalogue()})
            profiles = copy.deepcopy(snapshot["players"] + snapshot["enemies"])
            primary = actor("primaries")
            primary["allocations"] = {"strength": 20, "dexterity": 7, "intellect": 30, "vitality": 4}
            profiles.append(primary)
            scoped = actor("scoped", MAX_HEALTH=1000, HEALTH=250, MAX_STAMINA=200, STAMINA=80,
                           MAX_MANA=300, MANA=120, BLOCK_CHANCE=100, ARMOR_PENETRATION=150)
            scoped["allocations"] = {"strength": 15, "dexterity": 12, "intellect": 6, "vitality": 3}
            scoped["modifiers"] = [
                modifier("STRENGTH", 5, required=["Ability.Attack"], excluded=["Damage.Periodic"]),
                modifier("DEXTERITY", 12, required=["Scaling.Dexterity"]),
                modifier("INTELLECT", 8, required=["Ability.Spell"]),
                modifier("VITALITY", 20, required=["Ability.Spell"]),
                modifier("DOT_DAMAGE", 30, required=["Damage.Periodic"]),
                modifier("HIT_RATING", 50, required=["Ability.Spell"]),
                modifier("BLOCK_CHANCE", 100, source=0),
                modifier("ARMOR", 50, operation=2),
                modifier("ARMOR", 20), modifier("ARMOR", 10, operation=1),
            ]
            scoped["base_values"][str(ids()["ARMOR"])] = 100
            profiles.append(scoped)
            profiles.append(actor("uncapped", level=60, MAX_HEALTH=1000000, MAX_STAMINA=500000,
                                  MAX_MANA=800000, CRITICAL_DAMAGE=1000, STAMINA_REGEN=40000, MANA_REGEN=30000, DOT_DAMAGE=5000,
                                  COOLDOWN_RECOVERY=5000, MOVEMENT_SPEED=-200, FIRE_RESISTANCE=-200,
                                  NECROTIC_RESISTANCE=500, HIT_RATING=1e10, ))
            for profile in profiles:
                profile.setdefault("base_values", {})
            inputs = [{"actor": profile, "contexts": contexts} for profile in profiles]
            input_path = directory / "profiles.json"
            output_path = directory / "values.json"
            script_path = directory / "attribute_parity.gd"
            input_path.write_text(json.dumps(inputs, allow_nan=False), encoding="utf-8")
            script_path.write_text(GODOT_PROFILE_SCRIPT, encoding="utf-8")
            result = subprocess.run([
                str(executable), "--headless", "--path", str(PROJECT_ROOT), "--script", str(script_path),
                "--", str(input_path), str(output_path),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("SCRIPT ERROR", result.stdout + result.stderr)
            actual_profiles = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(len(actual_profiles), len(profiles))
            for profile, actual_profile in zip(profiles, actual_profiles):
                self.assertEqual(actual_profile["id"], profile["id"])
                for context, actual in zip(contexts, actual_profile["snapshots"]):
                    expected = model.resolve_actor(profile, snapshot["rules"], context)
                    self.assertEqual(set(expected), {int(key) for key in actual})
                    for attribute, value in expected.items():
                        with self.subTest(profile=profile["id"], context=context, attribute=attribute):
                            self.assertAlmostEqual(value, actual[str(attribute)],
                                                   delta=max(1, abs(value)) * 1e-10)


if __name__ == "__main__":
    unittest.main()
