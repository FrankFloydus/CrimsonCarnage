"""Independent encounter-clock and damage expectations for the offline combat lab."""
from __future__ import annotations

import copy
import math
import threading
import unittest

try:
    from .test_helpers import actor, ability, effect, first_cell, ids, session
except ImportError:
    from test_helpers import actor, ability, effect, first_cell, ids, session

from tools.combat_simulator.lab import engine, model


class EncounterTestCase(unittest.TestCase):
    def simulate(self, settings):
        run = settings["run"]
        return engine.simulate_cell(first_cell(settings), run["trials"], run["horizon"],
                                    run["seed"], batch_size=run["batch_size"])

    def assert_kill(self, settings, expected_ttk, *, attempts=None, direct=None, periodic=None):
        row = self.simulate(settings)
        self.assertEqual(row["kills"], settings["run"]["trials"])
        self.assertEqual(row["timeouts"], 0)
        for key in ("ttk_mean", "ttk_p10", "ttk_median", "ttk_p90", "ttk_p95", "ttk_max"):
            self.assertAlmostEqual(row[key], expected_ttk, places=8, msg=key)
        if attempts is not None:
            self.assertAlmostEqual(row["mean_attempts"], attempts, places=8)
        if direct is not None:
            self.assertAlmostEqual(row["damage_direct"], direct, places=8)
        if periodic is not None:
            self.assertAlmostEqual(row["damage_periodic"], periodic, places=8)
        return row


class EncounterMathTests(EncounterTestCase):
    def test_direct_hits_and_actual_overkill(self):
        # Three ten-damage releases at .25, 1.25, 2.25 remove only 25 Health.
        self.assert_kill(session(), 2.25, attempts=3, direct=25, periodic=0)

    def test_first_release_and_projectile_travel_are_not_full_cast_duration(self):
        attack = ability(kind="spell", tags=["Ability.Spell.Test"],
                         release_fraction=0.2, travel_time=0.4)
        self.assert_kill(session(enemy=actor("enemy", MAX_HEALTH=10), attack=attack),
                         0.6, attempts=1)

    def test_zero_and_guaranteed_critical_chance(self):
        attack = ability(effects=[effect(critical=True)])
        for chance, ttk, attempts in [(0, 2.25, 3), (100, 1.25, 2)]:
            with self.subTest(chance=chance):
                source = actor(HIT_RATING=50, CRITICAL_CHANCE=chance, CRITICAL_DAMAGE=50)
                row = self.assert_kill(session(player=source, attack=attack), ttk,
                                       attempts=attempts, direct=25)
                self.assertAlmostEqual(row["crit_rate"], chance / 100)

    def test_armor_penetrates_raw_rating_before_curve(self):
        # Armor 1000 reduces 75%; Armor 500 reduces 12/19; full penetration ignores armor.
        for penetration, ttk, attempts in [(0, 9.25, 10), (50, 6.25, 7), (100, 2.25, 3)]:
            with self.subTest(penetration=penetration):
                source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, ARMOR_PENETRATION=penetration)
                target = actor("enemy", MAX_HEALTH=25, ARMOR=1000)
                self.assert_kill(session(player=source, enemy=target), ttk, attempts=attempts)

    def test_elemental_and_poison_resistances_use_matching_school(self):
        for damage_type, resistance in [("fire", "FIRE_RESISTANCE"),
                                        ("cold", "COLD_RESISTANCE"),
                                        ("lightning", "LIGHTNING_RESISTANCE"),
                                        ("necrotic", "NECROTIC_RESISTANCE")]:
            for value, ttk in [(-100, 1.25), (0, 2.25), (80, 12.25)]:
                with self.subTest(damage_type=damage_type, resistance=value):
                    target = actor("enemy", MAX_HEALTH=25, **{resistance: value})
                    attack = ability(effects=[effect(damage_type=damage_type)])
                    self.assert_kill(session(enemy=target, attack=attack), ttk)

    def test_magic_power_scales_all_five_magic_schools(self):
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAGIC_POWER=100)
        for school in ["fire", "cold", "lightning", "void", "necrotic"]:
            with self.subTest(school=school):
                self.assert_kill(session(player=source, enemy=actor("enemy", MAX_HEALTH=80),
                    attack=ability(effects=[effect(damage_type=school,
                        scaling_attribute=ids()["MAGIC_POWER"], power_coefficient=.1)])), 3.25)

    def test_selected_power_contributes_once_with_its_coefficient(self):
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAGIC_POWER=20, STRENGTH=20)
        for school, coefficient, ttk in [("fire", .5, 3.25), ("physical", 1, 7.25)]:
            with self.subTest(school=school):
                self.assert_kill(session(player=source, enemy=actor("enemy", MAX_HEALTH=80),
                    attack=ability(effects=[effect(damage_type=school,
                        scaling_attribute=ids()["MAGIC_POWER"], power_coefficient=coefficient)])), ttk)

    def test_level_damage_factor_is_separate_from_accuracy_cap(self):
        # Level 1 versus 6: each base-100 hit deals 100*(89/314); three hits remove 80 HP.
        source = actor(level=1, HIT_RATING=100, CRITICAL_CHANCE=0)
        target = actor("enemy", level=6, MAX_HEALTH=80)
        self.assert_kill(session(player=source, enemy=target,
                                 attack=ability(effects=[effect(base_damage=100)])),
                         2.25, attempts=3)

    def test_shared_hit_rating_and_curve_control_attack_and_spell_success(self):
        for kind, failed_rate in [("melee", "miss_rate"), ("spell", "resist_rate")]:
            with self.subTest(kind=kind):
                source = actor(CRITICAL_CHANCE=0, HIT_RATING=0)
                attack = ability(kind=kind, tags=["Ability.Spell.Test" if kind == "spell" else "Ability.Attack.Test"])
                settings = session(player=source, enemy=actor("enemy", MAX_HEALTH=1),
                    attack=attack, trials=4096, horizon=.5)
                settings["curves"] = {"melee": [.25] * 11, "spell": [.25] * 11}
                row = self.simulate(settings)
                self.assertAlmostEqual(row["hit_rate"], .25, delta=.025)
                self.assertAlmostEqual(row[failed_rate], .75, delta=.025)
                self.assertAlmostEqual(row["kill_rate"], row["hit_rate"])
                self.assertEqual(row["miss_rate" if kind == "spell" else "resist_rate"], 0)
                source["base_values"][str(ids()["HIT_RATING"])] = 50
                self.assert_kill(settings, .25, attempts=1)

    def test_zero_delivery_curve_cannot_attach_dot(self):
        attack = ability(effects=[effect(base_damage=0, periodic=True, duration=4, period=2)])
        attack["effects"][0]["base_damage"] = 10
        settings = session(player=actor(HIT_RATING=0, CRITICAL_CHANCE=0),
                           enemy=actor("enemy", MAX_HEALTH=1), attack=attack, trials=16, horizon=5)
        settings["curves"] = {"melee": [0] * 11, "spell": [0] * 11}
        row = self.simulate(settings)
        self.assertEqual(row["kills"], 0)
        self.assertEqual(row["timeouts"], 16)
        self.assertEqual(row["damage_periodic"], 0)
        self.assertEqual(row["miss_rate"], 1)

    def test_automatic_block_and_dodge_remain_separate_from_accuracy(self):
        for attributes, field, expected in [({"BLOCK_CHANCE": 90}, "block_rate", .9),
                                             ({"EVASION": 1000}, "dodge_rate", .75)]:
            with self.subTest(layer=field):
                settings = session(enemy=actor("enemy", MAX_HEALTH=1, **attributes),
                                   trials=4096, horizon=.5)
                row = self.simulate(settings)
                self.assertAlmostEqual(row[field], expected, delta=.025)
                self.assertAlmostEqual(row["hit_rate"] + row[field], 1, places=8)
                self.assertEqual(row["miss_rate"], 0)

    def test_physical_uses_strength_and_magical_coefficients_use_intellect_power(self):
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0)
        source["allocations"] = {"strength": 20, "dexterity": 5, "intellect": 20, "vitality": 0}
        self.assert_kill(session(player=source, enemy=actor("enemy", MAX_HEALTH=65),
            attack=ability(effects=[effect(damage_type="physical")])), 5.25)
        self.assert_kill(session(player=source, enemy=actor("enemy", MAX_HEALTH=65),
            attack=ability(effects=[effect(damage_type="fire", scaling_attribute=ids()["MAGIC_POWER"],
                power_coefficient=1)])), 2.25)

    def test_effect_application_chance_is_separate_from_successful_delivery(self):
        settings = session(enemy=actor("enemy", MAX_HEALTH=1),
                           attack=ability(cooldown=100, effects=[effect(application_chance=25)]),
                           trials=4096, horizon=.5)
        row = self.simulate(settings)
        self.assertEqual(row["hit_rate"], 1)
        self.assertEqual(row["miss_rate"], 0)
        self.assertAlmostEqual(row["kill_rate"], .25, delta=.025)
        self.assertAlmostEqual(row["damage_direct"], row["kill_rate"])

    def test_periodic_scoped_bonus_does_not_leak_into_impact_or_cost(self):
        names = ids()
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, DOT_DAMAGE=50)
        source["modifiers"] = [{"attribute": names["DOT_DAMAGE"], "operation": 0,
                                "value": 100, "source": 0,
                                "required_context_tags": ["Damage.Periodic"], "excluded_context_tags": []}]
        attack = ability(cooldown=100, effects=[effect(), effect(
            id="burn", base_damage=5, periodic=True, duration=4, period=2)])
        self.assert_kill(session(player=source, enemy=actor("enemy", MAX_HEALTH=35), attack=attack),
                         4.25, direct=10, periodic=25)
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAX_MANA=5, MANA=5, MANA_REGEN=0)
        source["modifiers"] = [{"attribute": names["DOT_DAMAGE"], "operation": 0,
                                "value": 100, "source": 0,
                                "required_context_tags": ["Damage.Periodic"], "excluded_context_tags": []}]
        row = self.simulate(session(player=source, attack=ability(cost_attribute=names["MANA"],
                                                                 cost_amount=10), horizon=5))
        self.assertEqual(row["mean_attempts"], 0)
        self.assertEqual(row["resource_depleted_trials"], 1)

    def test_entropic_dodge_preserves_one_landed_hit_per_four_fast_attempts(self):
        settings = session(enemy=actor("enemy", MAX_HEALTH=10000, EVASION=1000),
                           trials=256, horizon=3.25)
        row = self.simulate(settings)
        self.assertEqual(row["mean_attempts"], 4)
        self.assertEqual(row["dodge_rate"], .75)
        self.assertEqual(row["hit_rate"], .25)
        self.assertEqual(row["damage_direct"], 10)

    def test_scoped_dot_damage_does_not_amplify_direct_magic_hit(self):
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, DOT_DAMAGE=50, MAGIC_POWER=100)
        self.assert_kill(session(player=source, enemy=actor("enemy", MAX_HEALTH=55),
            attack=ability(effects=[effect(damage_type="fire", scaling_attribute=ids()["MAGIC_POWER"],
                power_coefficient=.15)])), 2.25, attempts=3)


class EncounterClockTests(EncounterTestCase):
    def test_continuous_resource_regeneration_waits_for_affordability(self):
        names = ids()
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAX_STAMINA=10,
                       STAMINA=10, STAMINA_REGEN=2)
        attack = ability(cost_attribute=names["STAMINA"], cost_amount=10)
        # Spend at 0 and regenerate continuously; starts at 0/5/10 release at .25/5.25/10.25.
        self.assert_kill(session(player=source, attack=attack), 10.25, attempts=3)

    def test_authored_resource_cost_is_independent_of_cooldown_recovery(self):
        names = ids()
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAX_MANA=10, MANA=10,
                       MANA_REGEN=1, COOLDOWN_RECOVERY=100)
        attack = ability(kind="spell", tags=["Ability.Spell.Test"], cost_attribute=names["MANA"],
                         cost_amount=10, cooldown=4)
        source["base_values"][str(names["HIT_RATING"])] = 50
        # Recovery halves the cooldown to 2s; each cast still spends the authored
        # 10 Mana, so affordability determines starts at 0/10/20.
        self.assert_kill(session(player=source, attack=attack, horizon=25), 20.25, attempts=3)

    def test_retired_efficiency_modifiers_are_rejected_instead_of_discounting_cost(self):
        for retired_id in (28, 29):
            with self.subTest(attribute=retired_id):
                source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAX_MANA=10, MANA=10)
                source["modifiers"] = [{"attribute": retired_id, "operation": 0,
                                        "value": 1000, "source": 0,
                                        "required_context_tags": [], "excluded_context_tags": []}]
                with self.assertRaisesRegex(ValueError, "retired"):
                    self.simulate(session(player=source))

    def test_cooldown_and_animation_are_independent_start_gates(self):
        self.assert_kill(session(attack=ability(cooldown=3)), 6.25, attempts=3)
        self.assert_kill(session(attack=ability(cooldown=.1)), 2.25, attempts=3)

    def test_haste_captures_duration_and_release_fraction(self):
        # B=2, M=.5, rating=100 gives T=1.25; releases at .3125, 1.5625, 2.8125.
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, ATTACK_SPEED_RATING=100)
        attack = ability(base_duration=2, minimum_duration=.5)
        self.assert_kill(session(player=source, attack=attack), 2.8125, attempts=3)

    def test_encumbrance_slows_attacks_but_not_casts(self):
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0,
                       CARRY_CAPACITY=100, CARRIED_WEIGHT=200)
        self.assert_kill(session(player=source), 4.5, attempts=3)
        self.assert_kill(session(player=source, attack=ability(kind="spell", tags=["Ability.Spell.Test"])),
                         2.25, attempts=3)

    def test_regeneration_flags_and_stamina_pause_are_respected(self):
        names = ids()
        for flag in ["automatic_regeneration", "pause_stamina_regeneration"]:
            with self.subTest(flag=flag):
                source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAX_STAMINA=10,
                               STAMINA=0, STAMINA_REGEN=10)
                source[flag] = False if flag == "automatic_regeneration" else True
                row = self.simulate(session(player=source, attack=ability(
                    cost_attribute=names["STAMINA"], cost_amount=10), horizon=5))
                self.assertEqual(row["kills"], 0)
                self.assertEqual(row["resource_depleted_trials"], 1)
                self.assertEqual(row["damage_direct"], 0)
        target = actor("enemy", MAX_HEALTH=25, )
        target["automatic_regeneration"] = False
        self.assert_kill(session(enemy=target), 2.25, attempts=3)

    def test_health_cost_that_spends_last_health_cancels_before_release(self):
        names = ids()
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAX_HEALTH=10,
                       HEALTH=10, )
        row = self.simulate(session(player=source, attack=ability(
            cost_attribute=names["HEALTH"], cost_amount=10), horizon=5))
        self.assertEqual(row["damage_direct"], 0)
        self.assertEqual(row["mean_attempts"], 0)
        self.assertEqual(row["resource_depleted_trials"], 1)

    def test_required_and_blocked_source_tags_prevent_activation(self):
        for source, attack in [
            (actor(HIT_RATING=50), ability(required_tags=["State.Empowered"])),
            (actor(HIT_RATING=50) | {"tags": ["State.Stunned.Heavy"]}, ability()),
        ]:
            with self.subTest(tags=source["tags"]):
                row = self.simulate(session(player=source, attack=attack, horizon=5))
                self.assertEqual(row["mean_attempts"], 0)
                self.assertEqual(row["damage_direct"], 0)
                self.assertEqual(row["timeouts"], 1)

    def test_horizon_includes_due_deliveries_but_does_not_invent_late_hits(self):
        self.assert_kill(session(horizon=2.25), 2.25, attempts=3)
        row = self.simulate(session(horizon=2.249))
        self.assertEqual(row["kills"], 0)
        self.assertEqual(row["timeouts"], 1)
        self.assertEqual(row["damage_direct"], 20)
        self.assertEqual(row["restricted_mean_time"], 2.249)

    def test_periodic_final_due_tick_precedes_expiration(self):
        dot = effect(base_damage=5, periodic=True, duration=4, period=2)
        attack = ability(cooldown=100, effects=[dot])
        self.assert_kill(session(enemy=actor("enemy", MAX_HEALTH=10), attack=attack),
                         4.25, attempts=1, direct=0, periodic=10)

    def test_nondivisible_duration_does_not_create_an_extra_expiration_tick(self):
        dot = effect(base_damage=5, periodic=True, duration=5, period=2)
        row = self.simulate(session(enemy=actor("enemy", MAX_HEALTH=20),
                                    attack=ability(cooldown=100, effects=[dot]), horizon=10))
        self.assertEqual(row["kills"], 0)
        self.assertEqual(row["damage_periodic"], 10)
        self.assertEqual(row["timeouts"], 1)

    def test_refresh_does_not_repeat_execute_on_application_ticks(self):
        dot = effect(base_damage=5, periodic=True, duration=4, period=2,
                     execute_on_application=True)
        # One immediate tick at .25, then 2.25/4.25/6.25; Refresh adds no immediate ticks.
        self.assert_kill(session(enemy=actor("enemy", MAX_HEALTH=20),
                                 attack=ability(effects=[dot])), 6.25, periodic=20, direct=0)

    def test_existing_periodic_ticks_do_not_reroll_dodge_or_block(self):
        dot = effect(base_damage=5, periodic=True, duration=4, period=2)
        settings = session(enemy=actor("enemy", MAX_HEALTH=10, EVASION=1000, BLOCK_CHANCE=90),
                           attack=ability(cooldown=100, effects=[dot]), trials=4096, horizon=5)
        row = self.simulate(settings)
        self.assertGreater(row["hit_rate"], 0)
        self.assertEqual(row["kill_rate"], row["hit_rate"])
        self.assertAlmostEqual(row["ttk_mean"], 4.25)
        self.assertAlmostEqual(row["damage_periodic"], row["hit_rate"] * 10)

    def test_refresh_preserves_tick_phase_while_replace_restarts_it(self):
        for policy, kills, ttk in [("refresh", 1, 4.25), ("replace", 0, None)]:
            with self.subTest(policy=policy):
                dot = effect(base_damage=5, periodic=True, duration=4, period=2, reapplication=policy)
                settings = session(enemy=actor("enemy", MAX_HEALTH=10),
                                   attack=ability(effects=[dot]), horizon=6)
                row = self.simulate(settings)
                self.assertEqual(row["kills"], kills)
                self.assertEqual(row["ttk_mean"], ttk)
                if not kills:
                    self.assertEqual(row["damage_periodic"], 0)

    def test_stack_limit_is_finite_and_rejections_do_not_reset_existing_ticks(self):
        dot = effect(base_damage=5, periodic=True, duration=4, period=2,
                     reapplication="stack", maximum_stacks=2)
        self.assert_kill(session(enemy=actor("enemy", MAX_HEALTH=10),
                                 attack=ability(effects=[dot])),
                         3.25, direct=0, periodic=10)

    def test_periodic_damage_does_not_inherit_critical_rolls(self):
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=50, CRITICAL_DAMAGE=50)
        dot = effect(base_damage=5, critical=True, periodic=True, duration=4, period=2)
        settings = session(player=source, enemy=actor("enemy", MAX_HEALTH=15),
                           attack=ability(cooldown=100, effects=[dot]), trials=4096, horizon=5)
        row = self.simulate(settings)
        # Snapshots let approximately 50% of applications kill; rerolling each tick gives 75%.
        self.assertEqual(row["kill_rate"], 0)
        self.assertIsNone(row["ttk_mean"])
        self.assertEqual(row["crit_rate"], 0)
        self.assertAlmostEqual(row["damage_periodic"], 10)
        self.assertEqual(row["kills"] + row["timeouts"], 4096)

    def test_no_kill_censoring_is_explicit(self):
        settings = session(enemy=actor("enemy", MAX_HEALTH=100), horizon=4)
        row = self.simulate(settings)
        self.assertEqual(row["kills"], 0)
        self.assertEqual(row["timeouts"], 1)
        self.assertEqual(row["kill_rate"], 0)
        for key in ("ttk_mean", "ttk_p10", "ttk_median", "ttk_p90", "ttk_p95", "ttk_max"):
            self.assertIsNone(row[key], key)
        self.assertEqual(row["restricted_mean_time"], 4)

    def test_dead_at_zero_first_release_has_zero_ttk(self):
        self.assert_kill(session(enemy=actor("enemy", MAX_HEALTH=1),
                                 attack=ability(release_fraction=0)), 0, attempts=1)

    def test_resource_depletion_is_reported_instead_of_a_kill(self):
        names = ids()
        source = actor(HIT_RATING=50, CRITICAL_CHANCE=0, MAX_MANA=5, MANA=5, MANA_REGEN=0)
        settings = session(player=source, attack=ability(cost_attribute=names["MANA"], cost_amount=10),
                           horizon=5)
        row = self.simulate(settings)
        self.assertEqual(row["kills"], 0)
        self.assertEqual(row["resource_depleted_trials"], 1)
        self.assertEqual(row["timeouts"], 1)
        self.assertEqual(row["damage_direct"], 0)


class EngineCoordinationTests(unittest.TestCase):
    def normalized(self, result):
        rows = []
        for row in result["cells"]:
            row = copy.deepcopy(row)
            row.pop("elapsed_seconds", None)
            row.pop("index", None)
            rows.append(row)
        return sorted(rows, key=lambda row: (row["player_name"], row["enemy_name"],
                                              row["ability_name"], row["player_level"], row["enemy_level"]))

    def assert_nested_equal(self, first, second):
        if isinstance(first, dict):
            self.assertEqual(first.keys(), second.keys())
            for key in first:
                self.assert_nested_equal(first[key], second[key])
        elif isinstance(first, list):
            self.assertEqual(len(first), len(second))
            for one, two in zip(first, second):
                self.assert_nested_equal(one, two)
        elif isinstance(first, float):
            self.assertAlmostEqual(first, second, places=10)
        else:
            self.assertEqual(first, second)

    def test_seeded_results_reproduce_across_workers_selection_order_and_batches(self):
        settings = session(player=actor(HIT_RATING=0, CRITICAL_CHANCE=50), trials=256, horizon=8)
        settings["enemies"].append(actor("second_enemy", MAX_HEALTH=40, BLOCK_CHANCE=20))
        first = engine.run_matrix(settings)
        reordered = copy.deepcopy(settings)
        reordered["run"]["workers"] = 2
        reordered["run"]["batch_size"] = 37
        reordered["matrix"]["enemy_ids"] = ["second_enemy", "enemy"]
        second = engine.run_matrix(reordered)
        self.assertEqual(first["status"], "complete")
        self.assertEqual(first["completed_trials"], 512)
        self.assert_nested_equal(self.normalized(first), self.normalized(second))

    def test_cancellation_mid_encounter_excludes_unfinished_trials_instead_of_censoring_them(self):
        settings = session(player=actor(HIT_RATING=50, CRITICAL_CHANCE=50, CRITICAL_DAMAGE=50),
                           enemy=actor("enemy", MAX_HEALTH=15),
                           attack=ability(effects=[effect(critical=True)]), trials=128)
        prepared = engine._prepare(first_cell(settings), settings["run"]["horizon"], None)
        calls = 0

        def cancel_after_first_delivery():
            nonlocal calls
            calls += 1
            return calls >= 2

        batch = engine._simulate_batch(prepared, 128, 0, 1928,
                                       settings["run"]["horizon"], cancel_after_first_delivery)
        self.assertTrue(batch["cancelled"])
        self.assertGreater(batch["count"], 0)
        self.assertLess(batch["count"], 128)
        self.assertEqual(batch["count"], len(batch["kill_times"]))
        self.assertTrue(all(time == .25 for time in batch["kill_times"]))
        self.assertEqual(batch["metrics"]["damage_direct"], batch["count"] * 15)
        self.assertEqual(batch["exposure"], batch["count"] * .25)

    def test_precancelled_work_does_not_fabricate_timeouts(self):
        cancel = threading.Event()
        cancel.set()
        result = engine.run_matrix(session(trials=100), cancel=cancel)
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["completed_trials"], 0)
        self.assertEqual(sum(row["trials"] for row in result["cells"]), 0)

    def test_progress_can_cancel_without_mutating_experiment(self):
        settings = session(trials=2048, horizon=5)
        settings["run"]["batch_size"] = 64
        before = copy.deepcopy(settings)
        cancel = threading.Event()
        progress = []

        def observe(message):
            progress.append(message)
            if message.get("type") == "progress" and message.get("completed_trials", 0) > 0:
                cancel.set()

        result = engine.run_matrix(settings, progress=observe, cancel=cancel)
        self.assertEqual(result["status"], "cancelled")
        self.assertGreater(result["completed_trials"], 0)
        self.assertLess(result["completed_trials"], 2048)
        self.assertEqual(result["completed_trials"], sum(row["trials"] for row in result["cells"]))
        self.assertEqual(settings, before)
        self.assertTrue(progress)


if __name__ == "__main__":
    unittest.main()
