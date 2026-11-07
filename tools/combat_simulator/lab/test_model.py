"""Attribute catalogue, owned modifiers, Cartesian matrices, and input validation."""
from __future__ import annotations

import copy
import itertools
import math
import unittest

try:
    from .test_helpers import actor, ability, effect, ids, session
except ImportError:
    from test_helpers import actor, ability, effect, ids, session

from tools.combat_simulator.lab import model


def modifier(attribute, value, operation=0, source=0, required=(), excluded=()):
    return {"attribute": ids()[attribute], "value": value, "operation": operation,
            "source": source, "required_context_tags": list(required),
            "excluded_context_tags": list(excluded)}


class AttributeModelTests(unittest.TestCase):
    def resolve(self, profile, context=()):
        return model.resolve_actor(profile, model.default_session()["rules"], context)

    def test_catalogue_contains_every_stable_active_attribute_without_retired_slots(self):
        catalogue = model.attribute_catalogue()
        self.assertEqual(len(catalogue), 41)
        self.assertEqual({entry["id"] for entry in catalogue}, set(range(53)) - {10, 13, 16, 17, 23, 28, 29, 31, 32, 35, 36, 41})
        self.assertEqual(len({entry["key"] for entry in catalogue}), 41)
        self.assertEqual(ids()["ARMOR_PENETRATION"], 34)
        self.assertEqual(ids()["HIT_RATING"], 40)
        self.assertNotIn("SPELL_ACCURACY", ids())
        self.assertEqual(ids()["RESOLVE"], 24)
        self.assertNotIn("CONTROL_DURATION_REDUCTION", ids())
        self.assertNotIn("STAMINA_COST_EFFICIENCY", ids())
        self.assertNotIn("MANA_COST_EFFICIENCY", ids())
        for entry in catalogue:
            self.assertTrue(entry["name"])
            self.assertIn("minimum", entry)
            self.assertIn("maximum", entry)
        current = {entry["key"] for entry in catalogue if entry["current"]}
        self.assertEqual(current, {"HEALTH", "STAMINA", "MANA", "ABSORPTION"})

    def test_neutral_and_level_sixty_baselines(self):
        names = ids()
        for level, expected in [(1, {"MAX_HEALTH": 120, "MAX_STAMINA": 100, "MAX_MANA": 100,
                                    "STAMINA_REGEN": 15, "MANA_REGEN": 6}),
                                (60, {"MAX_HEALTH": 592, "MAX_STAMINA": 218, "MAX_MANA": 218,
                                     "STAMINA_REGEN": 32.7, "MANA_REGEN": 13.08})]:
            with self.subTest(level=level):
                values = self.resolve(actor(level=level))
                for key, value in expected.items():
                    self.assertAlmostEqual(values[names[key]], value, msg=key)
                for key in ["STRENGTH", "DEXTERITY", "INTELLECT", "VITALITY"]:
                    self.assertEqual(values[names[key]], 10)
                self.assertEqual(values[names["HEALTH"]], values[names["MAX_HEALTH"]])
                self.assertEqual(values[names["STAMINA"]], values[names["MAX_STAMINA"]])
                self.assertEqual(values[names["MANA"]], values[names["MAX_MANA"]])
                self.assertEqual(values[names["CRITICAL_CHANCE"]], 5)
                self.assertEqual(values[names["CRITICAL_DAMAGE"]], 0)

    def test_primary_contributions_and_dexterity_scaling_context(self):
        profile = actor()
        profile["allocations"] = {"strength": 20, "dexterity": 7, "intellect": 30, "vitality": 4}
        values = self.resolve(profile)
        names = ids()
        expected = {"STRENGTH": 30, "DEXTERITY": 17, "INTELLECT": 40, "VITALITY": 14,
                    "MAX_HEALTH": 122.4, "MAX_STAMINA": 120, "MAX_MANA": 130,
                    "CARRY_CAPACITY": 104, "EVASION": 7, "HIT_RATING": 7, "MAGIC_POWER": 30}
        for key, value in expected.items():
            self.assertAlmostEqual(values[names[key]], value, msg=key)
        dexterity = self.resolve(profile, ["Ability.Attack.Melee", "Scaling.Dexterity"])
        self.assertEqual(dexterity[names["HIT_RATING"]], 7)
        self.assertNotIn("HEALING_POWER", names)

    def test_owned_set_base_add_and_percentage_follow_godot_order(self):
        profile = actor(ARMOR=100)
        profile["modifiers"] = [modifier("ARMOR", 20), modifier("ARMOR", 50, operation=1),
                                modifier("ARMOR", 40, operation=2)]
        values = self.resolve(profile)
        # Authored Set Base 40, then GUI-owned Set Base 100; +50% and +20 remain.
        self.assertEqual(values[ids()["ARMOR"]], 170)
        self.assertEqual(model.resolve_actor_bases(profile, model.default_session()["rules"])[ids()["ARMOR"]], 100)

    def test_context_tags_are_hierarchical_and_exclusions_override_required_tags(self):
        profile = actor()
        profile["modifiers"] = [modifier("STRENGTH", 5, required=["Ability.Attack"],
                                         excluded=["Damage.Periodic"])]
        names = ids()
        plain = self.resolve(profile)
        attack = self.resolve(profile, ["Ability.Attack.Melee", "Damage.Direct"])
        excluded = self.resolve(profile, ["Ability.Attack.Melee", "Damage.Periodic.Bleed"])
        self.assertEqual(plain[names["STRENGTH"]], 10)
        self.assertEqual(attack[names["STRENGTH"]], 15)
        self.assertEqual(attack[names["STRENGTH"]], 15)
        self.assertEqual(excluded[names["STRENGTH"]], 10)
        self.assertEqual(excluded[names["STRENGTH"]], 10)
        # Capacity contributions query unscoped Strength, as ActorAttributes does.
        self.assertEqual(attack[names["MAX_STAMINA"]], 100)
        self.assertEqual(attack[names["CARRY_CAPACITY"]], 100)

    def test_only_shield_and_talent_modifiers_grant_block(self):
        profile = actor()
        profile["modifiers"] = [modifier("BLOCK_CHANCE", 100, source=0),
                                modifier("BLOCK_CHANCE", 30, source=1),
                                modifier("BLOCK_CHANCE", 40, source=2)]
        self.assertEqual(self.resolve(profile)[ids()["BLOCK_CHANCE"]], 70)
        profile["base_values"][str(ids()["BLOCK_CHANCE"])] = 100
        self.assertEqual(self.resolve(profile)[ids()["BLOCK_CHANCE"]], 90)

    def test_current_pools_clamp_to_capacity_and_unbounded_capacities_remain_unbounded(self):
        names = ids()
        profile = actor(MAX_HEALTH=1000000, HEALTH=2000000, MAX_STAMINA=500000,
                        STAMINA=-1, MAX_MANA=800000, MANA=123,
                        CRITICAL_DAMAGE=1000, STAMINA_REGEN=50000,
                        MANA_REGEN=50000, ARMOR_PENETRATION=200,
                        MOVEMENT_SPEED=-200, FIRE_RESISTANCE=-200)
        values = self.resolve(profile)
        for key, expected in {"HEALTH": 1000000, "STAMINA": 0, "MANA": 123,
                              "CRITICAL_DAMAGE": 1000,
                              "STAMINA_REGEN": 50000, "MANA_REGEN": 50000,
                              "ARMOR_PENETRATION": 100, "MOVEMENT_SPEED": -100,
                              "FIRE_RESISTANCE": -100}.items():
            self.assertEqual(values[names[key]], expected, key)

    def test_resolve_renames_the_stable_control_stat_without_changing_its_bounds(self):
        entry = next(entry for entry in model.attribute_catalogue() if entry["key"] == "RESOLVE")
        self.assertEqual((entry["id"], entry["name"], entry["maximum_rule"]),
                         (24, "Resolve", "resolve_max"))
        for value, expected in ((-100, 0), (0, 0), (25, 25), (40, 40), (1000, 40)):
            with self.subTest(value=value):
                self.assertEqual(self.resolve(actor(RESOLVE=value))[ids()["RESOLVE"]], expected)


class MatrixTests(unittest.TestCase):
    def settings(self):
        settings = session()
        settings["players"].append(actor("second_player"))
        settings["enemies"].append(actor("second_enemy"))
        settings["abilities"].append(ability(id="second_ability", name="Second ability"))
        settings["matrix"].update(player_levels=[1, 10], enemy_levels=[5, 20], sweeps=[
            {"side": "player", "attribute": ids()["ARMOR"], "values": [0, 100]},
            {"side": "enemy", "attribute": ids()["FIRE_RESISTANCE"], "values": [-20, 0, 80]},
        ])
        return settings

    def test_cartesian_expansion_includes_every_selected_dimension(self):
        settings = self.settings()
        before = copy.deepcopy(settings)
        self.assertEqual(model.estimate_matrix_size(settings), 192)
        cells = model.build_matrix(settings)
        self.assertEqual(len(cells), 192)
        observed = {
            (cell["player"]["id"], cell["enemy"]["id"], cell["ability"]["id"],
             cell["player"]["level"], cell["enemy"]["level"],
             cell["player"]["base_values"][str(ids()["ARMOR"] )],
             cell["enemy"]["base_values"][str(ids()["FIRE_RESISTANCE"] )])
            for cell in cells
        }
        expected = set(itertools.product(["player", "second_player"], ["enemy", "second_enemy"],
                                         ["attack", "second_ability"], [1, 10], [5, 20],
                                         [0, 100], [-20, 0, 80]))
        self.assertEqual(observed, expected)
        self.assertEqual(settings, before)

    def test_giant_matrix_can_be_consumed_lazily_without_materializing_its_full_cartesian_product(self):
        settings = session()
        attributes = [attribute for attribute in ids().values() if attribute not in (0, 2, 4, 45)]
        settings["matrix"]["sweeps"] = [
            {"side": "player", "attribute": attribute, "values": list(range(10))}
            for attribute in attributes
        ]
        self.assertEqual(model.estimate_matrix_size(settings), 10 ** 37)
        before = copy.deepcopy(settings)
        first_three = list(itertools.islice(model.iter_matrix(settings), 3))
        self.assertEqual([cell["index"] for cell in first_three], [0, 1, 2])
        self.assertEqual([cell["player"]["base_values"][str(attributes[-1])]
                          for cell in first_three], [0, 1, 2])
        self.assertEqual(settings, before)

    def test_selected_profiles_and_empty_level_lists_preserve_authored_levels(self):
        settings = self.settings()
        settings["players"][1]["level"] = 17
        settings["enemies"][1]["level"] = 23
        settings["matrix"].update(player_ids=["second_player"], enemy_ids=["second_enemy"],
                                  ability_ids=["attack"], player_levels=[], enemy_levels=[], sweeps=[])
        cells = model.build_matrix(settings)
        self.assertEqual(len(cells), 1)
        self.assertEqual(cells[0]["player"]["level"], 17)
        self.assertEqual(cells[0]["enemy"]["level"], 23)

    def test_sweep_profiles_are_independent_without_mutating_authored_profiles(self):
        settings = self.settings()
        cells = model.build_matrix(settings)
        cells[0]["player"]["base_values"][str(ids()["ARMOR"])] = 999
        self.assertNotEqual(cells[1]["player"]["base_values"][str(ids()["ARMOR"] )], 999)
        self.assertNotIn(str(ids()["ARMOR"]), settings["players"][0]["base_values"])


class SessionValidationTests(unittest.TestCase):
    def invalid(self, mutate, text=None):
        settings = session()
        mutate(settings)
        with self.assertRaises(ValueError) as context:
            model.validate_session(settings)
        if text:
            self.assertIn(text.lower(), str(context.exception).lower())

    def test_valid_fixture_and_nonmonotonic_experimental_curve(self):
        settings = session()
        self.assertIsNone(model.validate_session(settings))
        settings["curves"] = {"melee": [.2, .9, .3], "spell": [.2, .9, .3]}
        self.assertIsNone(model.validate_session(settings))

    def test_nonfinite_numbers_rejected_with_useful_context(self):
        for value in [math.nan, math.inf, -math.inf]:
            with self.subTest(value=value):
                self.invalid(lambda data: data["players"][0]["base_values"].update({str(ids()["ARMOR"]): value}))
                self.invalid(lambda data: data["abilities"][0].update(cost_amount=value))
                self.invalid(lambda data: data["curves"]["spell"].__setitem__(0, value))

    def test_invalid_cost_duration_period_and_stack_limits(self):
        self.invalid(lambda data: data["abilities"][0].update(cost_amount=-1), "cost")
        self.invalid(lambda data: data["abilities"][0].update(base_duration=0), "duration")
        self.invalid(lambda data: data["abilities"][0].update(minimum_duration=2), "duration")
        for changes in [{"period": 0}, {"duration": 0}, {"period": -1}, {"maximum_stacks": -1}]:
            with self.subTest(changes=changes):
                self.invalid(lambda data: data["abilities"][0].update(effects=[effect(
                    periodic=True, duration=4, period=2, **{key: value for key, value in changes.items()
                                                       if key not in ("duration", "period")}) | changes]))

    def test_invalid_identity_selection_and_attribute_ids(self):
        self.invalid(lambda data: data["players"].append(copy.deepcopy(data["players"][0])), "id")
        self.invalid(lambda data: data["matrix"].update(player_ids=["not_defined"]))
        for attribute in [17, 23, 28, 29, 36, 999]:
            with self.subTest(attribute=attribute):
                self.invalid(lambda data: data["players"][0]["base_values"].update({str(attribute): 1}))

    def test_unsupported_accuracy_kind_tag_disagreements_are_rejected_explicitly(self):
        self.invalid(lambda data: data["abilities"][0].update(kind="spell", tags=["Ability.Attack.Melee"]))
        self.invalid(lambda data: data["abilities"][0].update(kind="melee", tags=["Ability.Spell.Fire"]))
        settings = session(attack=ability(kind="spell", tags=["Ability.Spell.Physical"],
                                         effects=[effect(damage_type="physical")]))
        self.assertIsNone(model.validate_session(settings))
        settings = session(attack=ability(kind="melee", tags=["Ability.Attack.Fire"],
                                         effects=[effect(damage_type="fire")]))
        self.assertIsNone(model.validate_session(settings))

    def test_dynamic_effect_tag_dependencies_are_rejected_instead_of_silently_approximated(self):
        burn = effect(id="burn", base_damage=3, periodic=True, duration=4, period=2,
                      granted_tags=["Status.Burning.Heavy"])
        for field in ["required_target_tags", "blocked_target_tags"]:
            with self.subTest(field=field):
                settings = session(attack=ability(effects=[burn, effect(**{field: ["Status.Burning"]})]))
                with self.assertRaises(ValueError):
                    model.validate_session(settings)
        # Tags used only for visuals, and requirements based on unrelated static tags, are valid.
        settings = session(attack=ability(effects=[burn, effect(required_target_tags=["Creature.Beast"])]))
        self.assertIsNone(model.validate_session(settings))

    def test_duplicate_periodic_identity_is_rejected_while_instant_duplicate_ids_are_valid(self):
        dot = effect(id="shared", periodic=True, duration=4, period=2)
        settings = session(attack=ability(effects=[dot, copy.deepcopy(dot)]))
        with self.assertRaisesRegex(ValueError, "duplicate periodic effect ID"):
            model.validate_session(settings)
        settings = session(attack=ability(effects=[effect(id="shared"), effect(id="shared")]))
        self.assertIsNone(model.validate_session(settings))
        settings = session(attack=ability(effects=[effect(id="shared"), dot]))
        self.assertIsNone(model.validate_session(settings))

    def test_invalid_run_and_level_bounds(self):
        for changes in [{"trials": 0}, {"trials": 1.5}, {"horizon": 0}, {"horizon": math.nan},
                        {"batch_size": 0}, {"workers": 0}]:
            with self.subTest(changes=changes):
                self.invalid(lambda data: data["run"].update(changes))
        for level in [0, 61, 1.5]:
            with self.subTest(level=level):
                self.invalid(lambda data: data["players"][0].update(level=level))
        self.invalid(lambda data: data["curves"].update(spell=[]))
        self.invalid(lambda data: data["curves"].update(melee=[1.01]))

    def test_cartesian_explosion_is_estimated_exactly_without_allocating_cells(self):
        settings = session()
        settings["matrix"]["sweeps"] = [
            {"side": "player", "attribute": attribute, "values": list(range(10))}
            for attribute in ids().values() if attribute not in (0, 2, 4, 45)
        ]
        self.assertIsNone(model.validate_session(settings))
        self.assertEqual(model.estimate_matrix_size(settings), 10 ** 37)


if __name__ == "__main__":
    unittest.main()
