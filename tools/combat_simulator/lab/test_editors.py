"""Editor parsing and serialization callbacks exercised with plain Python stubs, never Tk."""
from __future__ import annotations

import copy
import math
from types import SimpleNamespace
import unittest

try:
    from .test_helpers import ability, actor, session
except ImportError:
    from test_helpers import ability, actor, session

from tools.combat_simulator.lab import editors, model


class Value:
    def __init__(self, value):
        self.value = value

    def get(self):
        return self.value

    def set(self, value):
        self.value = value


class ListBox:
    def __init__(self, values=(), selected=()):
        self.values = list(values)
        self.selected = list(selected)

    def curselection(self):
        return tuple(self.selected)

    def delete(self, _first, _last):
        self.values.clear()
        self.selected.clear()

    def insert(self, _position, value):
        self.values.append(value)

    def selection_set(self, index):
        self.selected.append(index)


class EditorParsingTests(unittest.TestCase):
    def test_number_preserves_negative_fractional_values_and_supports_exact_integers(self):
        self.assertEqual(editors.number("-100.25", "Resistance"), -100.25)
        self.assertEqual(editors.number("1e3", "Trials", integer=True), 1000)
        self.assertIsInstance(editors.number("1.0", "Level", integer=True), int)
        for value, integer in [("NaN", False), ("inf", False), (-math.inf, False),
                               ("1.25", True), ("invalid", False), (None, False)]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                editors.number(value, "Relevant field", integer=integer)

    def test_comma_and_semicolon_lists_are_finite_ordered_and_deduplicated(self):
        self.assertEqual(editors.number_list("1, 2; 1, , -3.5,2", "Sweep"), [1, 2, -3.5])
        self.assertEqual(editors.number_list("1, 1.0, 2e0", "Levels", integer=True), [1, 2])
        self.assertEqual(editors.number_list(" , ; ", "Levels", integer=True), [])
        for text, integer in [("1,NaN", False), ("2;inf", False), ("1,2.5", True)]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                editors.number_list(text, "Sweep", integer=integer)

    def test_ability_kind_toggle_updates_delivery_and_accuracy_tags(self):
        for old_kind, new_kind, old_delivery, expected_delivery, original_tags, expected_tag in [
            ("melee", "spell", "melee_trace", "projectile", ["Ability.Attack.Melee", "Damage.Custom"], "Ability.Spell"),
            ("spell", "melee", "projectile", "melee_trace", ["Ability.Spell.Fire", "Damage.Custom"], "Ability.Attack"),
        ]:
            with self.subTest(kind=new_kind):
                original = ability(kind=old_kind, delivery=old_delivery, tags=original_tags)
                before = copy.deepcopy(original)
                stub = SimpleNamespace(
                    ability=original,
                    variables={"kind": (Value(new_kind), "choice"),
                               "tags": (Value(", ".join(original_tags)), "tags")},
                    resources={}, _save_effect=lambda: None,
                )
                result = editors.AbilityEditor.get_data(stub)
                self.assertEqual(result["delivery"], expected_delivery)
                self.assertIn(expected_tag, result["tags"])
                self.assertIn("Damage.Custom", result["tags"])
                self.assertEqual(original, before)
                self.assertIsNone(model.validate_session(session(attack=result)))

    def test_matrix_profile_refresh_preserves_unfinished_text_and_selections_by_identity(self):
        settings = session()
        settings["players"].append(actor("second_player", level=17))
        settings["enemies"].append(actor("second_enemy", level=23))
        old_ids = {"player_ids": ["player", "second_player"],
                   "enemy_ids": ["enemy", "second_enemy"], "ability_ids": ["attack"]}
        stub = SimpleNamespace(
            ids=copy.deepcopy(old_ids), loading=False,
            lists={key: ListBox(values, selected=[len(values) - 1]) for key, values in old_ids.items()},
            player_levels=Value("1, 5, unfinished"), enemy_levels=Value("3, 7"),
            sweeps=[(Value("player"), Value("Armor"), Value("0, 100, unfinished"))],
        )
        settings["players"].reverse()
        settings["enemies"].reverse()
        settings["players"][0]["name"] = "Renamed player"
        editors.MatrixEditor.refresh_profiles(stub, settings)
        self.assertEqual(stub.player_levels.get(), "1, 5, unfinished")
        self.assertEqual(stub.enemy_levels.get(), "3, 7")
        self.assertEqual(stub.sweeps[0][2].get(), "0, 100, unfinished")
        self.assertEqual(stub.ids["player_ids"], ["second_player", "player"])
        self.assertEqual(stub.lists["player_ids"].curselection(), (0,))
        self.assertEqual(stub.lists["enemy_ids"].curselection(), (0,))
        self.assertIn("Renamed player", stub.lists["player_ids"].values[0])
        self.assertFalse(stub.loading)


if __name__ == "__main__":
    unittest.main()
