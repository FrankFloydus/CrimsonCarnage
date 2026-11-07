"""Independent expectations for the current automatic-ailment/Absorption engine."""
from __future__ import annotations

import copy
import unittest

from tools.combat_simulator.lab import engine, model


def cell(school="physical", damage=100.0, level=1):
    session = model.default_session()
    ids = model.attribute_ids()
    source = {"id": "source", "name": "Source", "level": level,
              "allocations": {key: 0 for key in model.PRIMARY_KEYS},
              "base_values": {}, "modifiers": [], "tags": []}
    target = copy.deepcopy(source)
    target.update(id="target", name="Target")
    for actor in (source, target):
        actor["base_values"] = {str(ids["MAX_HEALTH"]): 10000.0,
                                str(ids["MAX_STAMINA"]): 1000.0,
                                str(ids["MAX_MANA"]): 1000.0,
                                str(ids["CRITICAL_CHANCE"]): 0.0,
                                str(ids["HIT_RATING"]): 50.0,
                                str(ids["ARMOR"]): 0.0, str(ids["EVASION"]): 0.0}
        for family in ("BURN", "CHILL", "ZAPPED", "BLEED", "POISON", "HOLLOWED"):
            actor["base_values"][str(ids[family + "_CHANCE"])] = 0.0
    ability = {"id": "test", "name": "Test", "kind": "melee", "tags": ["Ability.Attack"],
               "base_duration": 1.0, "minimum_duration": .1, "release_fraction": 0.0,
               "travel_time": 0.0, "cooldown": 1000.0, "cost_attribute": -1,
               "cost_amount": 0.0, "dodgeable": True, "blockable": True,
               "effects": [{"id": "impact", "name": "Impact", "base_damage": damage,
                            "damage_type": school, "power_coefficient": 0.0,
                            "scaling_attribute": -1, "critical": True,
                            "application_chance": 100.0, "periodic": False,
                            "scale_with_level": False}]}
    return {"index": 0, "player": source, "enemy": target, "ability": ability,
            "rules": copy.deepcopy(session["rules"]), "curves": copy.deepcopy(session["curves"]),
            "variants": {}}


def set_stat(case, side, key, value):
    case[side]["base_values"][str(model.attribute_ids()[key])] = value


def run(case, horizon=6.0, trials=1, seed=123, batch=4096):
    return engine.simulate_cell(case, trials, horizon, seed, batch_size=batch)


class CurrentCombatEngineTests(unittest.TestCase):
    def test_noncritical_zero_chance_does_not_apply_ailment(self):
        result = run(cell())
        self.assertEqual(result["damage_direct"], 100.0)
        self.assertEqual(result["damage_periodic"], 0.0)

    def test_critical_guarantees_bleed_without_inheriting_critical_damage(self):
        case = cell()
        set_stat(case, "player", "CRITICAL_CHANCE", 100.0)
        set_stat(case, "player", "CRITICAL_DAMAGE", 300.0)
        result = run(case)
        self.assertAlmostEqual(result["damage_direct"], 450.0)
        self.assertAlmostEqual(result["damage_periodic"], 100.0)

    def test_strength_contributes_once_to_direct_and_bleed(self):
        case = cell()
        set_stat(case, "player", "STRENGTH", 50.0)
        set_stat(case, "player", "BLEED_CHANCE", 100.0)
        result = run(case)
        self.assertAlmostEqual(result["damage_direct"], 140.0)
        self.assertAlmostEqual(result["damage_periodic"], 140.0)

    def test_dot_damage_does_not_change_direct_hit(self):
        case = cell("fire")
        set_stat(case, "player", "BURN_CHANCE", 100.0)
        set_stat(case, "player", "DOT_DAMAGE", 50.0)
        result = run(case, 4.0)
        self.assertAlmostEqual(result["damage_direct"], 100.0)
        self.assertAlmostEqual(result["damage_periodic"], 150.0)

    def test_fire_resistance_applies_once_to_burn(self):
        case = cell("fire")
        set_stat(case, "player", "BURN_CHANCE", 100.0)
        set_stat(case, "enemy", "FIRE_RESISTANCE", 50.0)
        result = run(case, 4.0)
        self.assertAlmostEqual(result["damage_direct"], 50.0)
        self.assertAlmostEqual(result["damage_periodic"], 50.0)

    def test_fully_absorbed_critical_still_applies_burn(self):
        case = cell("fire")
        set_stat(case, "player", "CRITICAL_CHANCE", 100.0)
        set_stat(case, "enemy", "MAX_ABSORPTION", 1000.0)
        result = run(case, 4.0)
        self.assertAlmostEqual(result["damage_direct"], 150.0)
        self.assertAlmostEqual(result["damage_periodic"], 100.0)
        self.assertAlmostEqual(result["damage_absorbed"], 250.0)
        self.assertAlmostEqual(result["enemy_health_remaining"], 10000.0)

    def test_bleed_bypasses_absorption_while_direct_physical_is_absorbed(self):
        case = cell()
        set_stat(case, "player", "BLEED_CHANCE", 100.0)
        set_stat(case, "enemy", "MAX_ABSORPTION", 500.0)
        result = run(case)
        self.assertAlmostEqual(result["damage_absorbed"], 100.0)
        self.assertAlmostEqual(result["enemy_health_remaining"], 9900.0)

    def test_necrotic_hit_and_poison_bypass_every_absorption_point(self):
        case = cell("necrotic")
        set_stat(case, "player", "POISON_CHANCE", 100.0)
        set_stat(case, "enemy", "MAX_ABSORPTION", 100000.0)
        result = run(case)
        self.assertAlmostEqual(result["damage_direct"], 100.0)
        self.assertAlmostEqual(result["damage_periodic"], 50.0)
        self.assertEqual(result["damage_absorbed"], 0.0)
        self.assertAlmostEqual(result["enemy_health_remaining"], 9850.0)

    def test_burn_ticks_drain_pool_without_restarting_recovery_delay(self):
        case = cell("fire")
        set_stat(case, "player", "BURN_CHANCE", 100.0)
        set_stat(case, "enemy", "MAX_ABSORPTION", 500.0)
        result = run(case, 5.0)
        self.assertAlmostEqual(result["enemy_absorption_remaining"], 400.0)

    def test_necrotic_direct_hits_interrupt_recovery_even_with_empty_pool(self):
        case = cell("necrotic", 10.0)
        case["ability"]["cooldown"] = 0.0
        set_stat(case, "enemy", "MAX_ABSORPTION", 500.0)
        set_stat(case, "enemy", "ABSORPTION", 0.0)
        result = run(case, 4.0)
        self.assertEqual(result["enemy_absorption_remaining"], 0.0)
        self.assertAlmostEqual(result["damage_direct"], 50.0)

    def test_hollowed_reduces_three_seconds_of_recharge_after_delay(self):
        case = cell("void", 12.0)
        set_stat(case, "player", "HOLLOWED_CHANCE", 100.0)
        set_stat(case, "enemy", "MAX_ABSORPTION", 500.0)
        set_stat(case, "enemy", "ABSORPTION", 0.0)
        result = run(case, 8.0)
        # 3..6 s: 35/s; 6..8 s:50/s, including an explicit six-second expiry.
        self.assertAlmostEqual(result["enemy_absorption_remaining"], 205.0)

    def test_resistance_reduces_hollowed_potency_without_actual_health_threshold(self):
        case = cell("void", 60.0, level=60)
        set_stat(case, "player", "HOLLOWED_CHANCE", 100.0)
        set_stat(case, "enemy", "VOID_RESISTANCE", 80.0)
        set_stat(case, "enemy", "MAX_ABSORPTION", 500.0)
        set_stat(case, "enemy", "ABSORPTION", 0.0)
        result = run(case, 8.0)
        expected = 50.0 * (1.0 - .3 * 12.0 / 59.2) * 3.0 + 50.0 * 2.0
        self.assertAlmostEqual(result["enemy_absorption_remaining"], expected)

    def test_equal_bleed_refresh_preserves_tick_phase(self):
        case = cell()
        case["ability"].update(cooldown=0.0, weapon_attacks_per_second=2.0)
        set_stat(case, "player", "BLEED_CHANCE", 100.0)
        result = run(case)
        self.assertEqual(result["mean_attempts"], 13.0)
        self.assertAlmostEqual(result["damage_periodic"], 100.0)

    def test_poison_has_more_than_five_independent_stacks(self):
        case = cell("necrotic", 12.0)
        case["ability"].update(cooldown=0.0, minimum_duration=.05, weapon_attacks_per_second=10.0)
        set_stat(case, "player", "POISON_CHANCE", 100.0)
        result = run(case, 1.6)
        self.assertEqual(result["mean_attempts"], 17.0)
        self.assertAlmostEqual(result["damage_periodic"], 7.0)

    def test_ailment_immunity_rejects_automatic_proc_even_on_critical(self):
        case = cell("fire")
        case["enemy"]["tags"] = ["Immunity.Burn.Special"]
        set_stat(case, "player", "CRITICAL_CHANCE", 100.0)
        result = run(case)
        self.assertEqual(result["damage_direct"], 150.0)
        self.assertEqual(result["damage_periodic"], 0.0)

    def test_extended_duration_does_not_reduce_damage_rate(self):
        case = cell("fire")
        case["rules"]["burn_duration"] = 8.0
        set_stat(case, "player", "BURN_CHANCE", 100.0)
        result = run(case, 8.0)
        self.assertAlmostEqual(result["damage_periodic"], 200.0)

    def test_zapped_changes_later_criticals_not_its_triggering_hit(self):
        case = cell("lightning", 20.0)
        case["ability"].update(cooldown=0.0)
        set_stat(case, "player", "ZAPPED_CHANCE", 100.0)
        result = run(case, 1.0, trials=20000)
        # First Hit never crits; second has5%. Two20-damage Hits average40.5.
        self.assertAlmostEqual(result["damage_direct"], 40.5, delta=.06)

    def test_school_scoped_critical_chance_qualifies_whole_hybrid_hit(self):
        case = cell("physical", 40.0)
        fire = copy.deepcopy(case["ability"]["effects"][0])
        fire.update(id="fire", damage_type="fire", base_damage=60.0)
        case["ability"]["effects"].append(fire)
        case["player"]["modifiers"] = [{"attribute": model.attribute_ids()["CRITICAL_CHANCE"],
            "operation": 0, "value": 100.0, "source": 0,
            "required_context_tags": ["Damage.Fire"], "excluded_context_tags": []}]
        result = run(case)
        self.assertAlmostEqual(result["damage_direct"], 150.0)
        # Guaranteed40-Physical Bleed and60-Fire Burn, despite zero ordinary chances.
        self.assertAlmostEqual(result["damage_periodic"], 100.0)

    def test_periodic_component_does_not_grant_direct_hit_scoped_critical_chance(self):
        case = cell("physical", 40.0)
        fire = copy.deepcopy(case["ability"]["effects"][0])
        fire.update(id="fire_dot", damage_type="fire", base_damage=10.0,
                    periodic=True, duration=2.0, period=1.0, critical=False)
        case["ability"]["effects"].append(fire)
        case["player"]["modifiers"] = [{"attribute": model.attribute_ids()["CRITICAL_CHANCE"],
            "operation": 0, "value": 100.0, "source": 0,
            "required_context_tags": ["Damage.Fire"], "excluded_context_tags": []}]
        result = run(case)
        self.assertAlmostEqual(result["damage_direct"], 40.0)
        self.assertAlmostEqual(result["damage_periodic"], 20.0)

    def test_noncritical_fire_component_can_qualify_shared_hit_critical_scope(self):
        case = cell("physical", 40.0)
        fire = copy.deepcopy(case["ability"]["effects"][0])
        fire.update(id="fire", damage_type="fire", base_damage=60.0, critical=False)
        case["ability"]["effects"].append(fire)
        case["player"]["modifiers"] = [{"attribute": model.attribute_ids()["CRITICAL_CHANCE"],
            "operation": 0, "value": 100.0, "source": 0,
            "required_context_tags": ["Damage.Fire"], "excluded_context_tags": []}]
        result = run(case)
        self.assertAlmostEqual(result["damage_direct"], 120.0)
        self.assertAlmostEqual(result["damage_periodic"], 100.0)

    def test_direct_physical_bleed_tag_does_not_bypass_absorption(self):
        case = cell()
        case["ability"]["effects"][0]["damage_tags"] = ["Damage.Bleed"]
        set_stat(case, "enemy", "MAX_ABSORPTION", 500.0)
        result = run(case, 1.0)
        self.assertAlmostEqual(result["damage_absorbed"], 100.0)
        self.assertAlmostEqual(result["enemy_health_remaining"], 10000.0)

    def test_fire_periodic_bleed_tag_does_not_bypass_absorption(self):
        case = cell("fire", 100.0)
        case["ability"]["effects"][0].update(periodic=True, duration=2.0, period=1.0,
                                              damage_tags=["Damage.Bleed"])
        set_stat(case, "enemy", "MAX_ABSORPTION", 500.0)
        result = run(case, 2.0)
        self.assertAlmostEqual(result["damage_absorbed"], 200.0)
        self.assertAlmostEqual(result["enemy_health_remaining"], 10000.0)

    def test_weapon_range_and_aps_are_reproducible_across_batch_sizes(self):
        case = cell()
        case["ability"].update(cooldown=0.0, weapon_attacks_per_second=2.0)
        case["ability"]["effects"][0].update(base_damage_min=80.0, base_damage_max=120.0)
        first = run(case, 2.0, trials=20000, batch=4096)
        second = run(case, 2.0, trials=20000, batch=631)
        self.assertEqual(first["mean_attempts"], 5.0)
        self.assertAlmostEqual(first["damage_direct"], 500.0, delta=.6)
        self.assertAlmostEqual(first["damage_direct"], second["damage_direct"], places=10)
        self.assertEqual(first["histogram"], second["histogram"])


if __name__ == "__main__":
    unittest.main()
