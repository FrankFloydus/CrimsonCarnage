"""Current combat formulas and schema boundaries, independent of frozen gear reports."""
import copy
import unittest

import numpy as np

import simulator as sim


class SimulatorTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)

    def test_current_schema_has_no_healing_or_retired_power_rules(self):
        self.assertEqual(self.rules["schema_version"], 2)
        retired = {"base_health_regen", "critical_multiplier_base", "critical_multiplier_min",
                   "intellect_spell_power_per_point", "primary_attack_power_per_point",
                   "strength_capacity_per_point"}
        self.assertFalse(retired & self.rules.keys())

    def test_reference_defense_and_uncapped_raw_rating(self):
        self.assertAlmostEqual(float(sim.defense(500, self.rules)), 12 * 500 / 9500)
        self.assertEqual(float(sim.defense(10000, self.rules)), .75)
        self.assertEqual(float(sim.defense(0, self.rules)), 0)

    def test_current_resource_cost_has_no_efficiency_contribution(self):
        np.testing.assert_allclose(sim.resource_cost([-100, 0, .001, 20, 1e12]),
                                   [0, 0, .001, 20, 1e12])
        self.assertEqual(self.rules["resolve_max"], 40)
        self.assertNotIn("control_duration_reduction_max", self.rules)

    def test_strength_scales_only_its_physical_reference_linearly(self):
        values = np.array([-100, 0, 10, 50, 100, 138, 1_000_000], dtype=float)
        np.testing.assert_allclose(sim.strength_physical_multiplier(values, self.rules),
                                   [.9, .9, 1, 1.4, 1.9, 2.28, 10000.9])
        # Four times the base hit remains four times the result at every investment.
        ordinary = 25 * sim.strength_physical_multiplier(values, self.rules)
        heavy = 100 * sim.strength_physical_multiplier(values, self.rules)
        np.testing.assert_allclose(heavy / ordinary, 4)

    def test_critical_damage_is_bonus_points_above_150_percent(self):
        np.testing.assert_allclose(sim.critical_damage_multiplier(
            np.array([-100, 0, 50, 100, 1000, 1e8]), self.rules),
            [1.5, 1.5, 2, 2.5, 11.5, 1000001.5])

    def test_critical_guarantee_does_not_modify_noncritical_proc_chance(self):
        actual = sim.ailment_application_chance(np.array([0, 20, 50, 75, 100]), 20)
        np.testing.assert_allclose(actual, [.2, .36, .6, .8, 1])
        np.testing.assert_allclose(sim.ailment_application_chance(100, [-100, 0, 20, 100]), 1)
        np.testing.assert_allclose(sim.ailment_application_chance(0, [-100, 0, 20, 100, 200]),
                                   [0, 0, .2, 1, 1])

    def test_seeded_100000_hits_match_critical_or_ordinary_application_probability(self):
        rng = np.random.default_rng(9173)
        for crit in (0, 20, 75, 100):
            for ordinary in (0, 20, 100):
                critical_hits = rng.random(100_000) < crit / 100
                ordinary_rolls = rng.random(100_000) < ordinary / 100
                observed = np.mean(critical_hits | ordinary_rolls)
                predicted = float(sim.ailment_application_chance(crit, ordinary))
                self.assertLess(abs(observed - predicted), .006)

    def test_damage_ailments_have_their_own_base_rate_and_dot_scaling(self):
        for family, duration, expected in (("burn", 4, 100), ("bleed", 6, 100),
                                           ("poison", 6, 50)):
            base_rate = float(sim.ailment_damage_rate(100, family, 0, self.rules))
            self.assertAlmostEqual(base_rate * duration, expected)
            self.assertAlmostEqual(float(sim.ailment_damage_rate(100, family, 50, self.rules)),
                                   base_rate * 1.5)
            self.assertEqual(float(sim.ailment_damage_rate(100, family, -100, self.rules)), 0)
            self.assertEqual(float(sim.ailment_damage_rate(-100, family, 0, self.rules)), 0)

    def test_poison_lifetime_throughput_is_linear_in_necrotic_dps(self):
        # Equal Necrotic DPS delivered at different cadences yields equal expected
        # Poison lifetime damage per second, even though simultaneous counts differ.
        for interval in (.1, .5, 1, 2, 4):
            seed = 100 * interval
            per_stack_total = float(sim.ailment_damage_rate(seed, "poison", 0, self.rules)) * 6
            expected_dps = per_stack_total * .2 / interval
            self.assertAlmostEqual(expected_dps, 10)

    def test_utility_threshold_uses_level_and_relevant_damage_not_max_health(self):
        np.testing.assert_allclose(sim.ailment_potency([12, 35.2, 59.2], [1, 30, 60], self.rules), 1)
        self.assertAlmostEqual(float(sim.ailment_potency(30, 60, self.rules)), 30 / 59.2)
        self.assertEqual(float(sim.ailment_potency(0, 60, self.rules)), 0)
        self.assertEqual(float(sim.ailment_potency(1e12, 60, self.rules)), 1)
        self.assertAlmostEqual(float(sim.ailment_potency(12, -100, self.rules)), 1)

    def test_school_resistance_and_penetrated_armor_are_separate(self):
        self.assertEqual(float(sim.school_damage_reduction("physical", 1000, 80, 0, self.rules)), .75)
        self.assertEqual(float(sim.school_damage_reduction("physical", 1000, 80, 100, self.rules)), 0)
        for school in sim.MAGIC_SCHOOLS:
            self.assertEqual(float(sim.school_damage_reduction(school, 1e12, -100, 100, self.rules)), -1)
            self.assertEqual(float(sim.school_damage_reduction(school, 1e12, 999, 100, self.rules)), .8)

    def test_absorption_routes_all_schools_except_necrotic_and_bleed(self):
        for school in ("physical", "fire", "cold", "lightning", "void"):
            pool, health, absorbed = sim.absorption_damage(150, 100, school)
            self.assertEqual(float(pool), 0)
            self.assertEqual(float(health), 50)
            self.assertEqual(float(absorbed), 100)
        for school, bleed in (("necrotic", False), ("poison", False), ("physical", True)):
            pool, health, absorbed = sim.absorption_damage(150, 100, school, bleed)
            self.assertEqual(float(pool), 100)
            self.assertEqual(float(health), 150)
            self.assertEqual(float(absorbed), 0)

    def test_absorption_conserves_damage_for_100000_seeded_packets(self):
        rng = np.random.default_rng(12381)
        amounts, pools = rng.uniform(0, 5000, (2, 100_000))
        schools = rng.choice(("physical", "fire", "cold", "lightning", "void", "necrotic"),
                            100_000)
        bleed = (schools == "physical") & (rng.random(100_000) < .5)
        remaining, health, absorbed = sim.absorption_damage(amounts, pools, schools, bleed)
        np.testing.assert_allclose(health + absorbed, amounts, rtol=2e-15, atol=1e-12)
        np.testing.assert_allclose(remaining + absorbed, pools, rtol=2e-15, atol=1e-12)
        bypass = (schools == "necrotic") | bleed
        np.testing.assert_array_equal(absorbed[bypass], 0)
        self.assertTrue(np.all(remaining >= 0))
        self.assertTrue(np.all(health >= 0))

    def test_hollowed_reduces_absorption_recovery_without_an_absolute_cap(self):
        self.assertEqual(float(sim.absorption_regeneration(500, self.rules)), 50)
        self.assertEqual(float(sim.absorption_regeneration(500, self.rules, .3)), 35)
        self.assertEqual(float(sim.absorption_regeneration(1e12, self.rules)), 1e11)
        self.assertEqual(float(sim.absorption_regeneration(-100, self.rules)), 0)
        self.assertEqual(float(sim.absorption_regeneration(500, self.rules, 2)), 0)
        self.assertEqual(self.rules["hollowed_duration"], 6)
        self.assertEqual(self.rules["absorption_recovery_delay"], 3)

    def test_normalized_fast_actions_have_equal_continuous_stamina_demand(self):
        ordinary = float(sim.resource_cost(12)) / 1
        fast = float(sim.resource_cost(6)) / .5
        self.assertEqual(ordinary, fast)
        self.assertEqual(float(sim.resource_cost(20)), 20)

    def test_legacy_report_entry_points_reject_current_combat_schema(self):
        config = sim.read_json(sim.HERE / "scenarios.json")
        calls = (
            lambda: sim.require_legacy_report_schema(self.rules),
            lambda: sim.generate_builds(1, np.random.default_rng(1), 0, "initial", self.rules, config),
            lambda: sim.derive({}, self.rules, config),
            lambda: sim.payloads({}, {}, self.rules, config),
            lambda: sim.metrics({}, {}, {}, self.rules, config),
            lambda: sim.encounters({}, {}, {}, np.random.default_rng(1), self.rules, config),
            lambda: sim.parity_samples(self.rules),
        )
        for call in calls:
            with self.subTest(call=call), self.assertRaisesRegex(ValueError, "historical report"):
                call()

    def test_legacy_guard_accepts_frozen_schema_one_only(self):
        historical = copy.deepcopy(self.rules)
        historical["schema_version"] = 1
        self.assertIsNone(sim.require_legacy_report_schema(historical))

    def test_allocation_conserves_level_point_budget_for_100000_profiles(self):
        rng = np.random.default_rng(4471)
        weights = rng.gamma(.3, 1, (100_000, 4))
        for level in (1, 15, 30, 45, 60):
            points = 10 + 2 * (level - 1)
            allocation = sim.allocation(rng, weights, points)
            np.testing.assert_array_equal(allocation.sum(axis=1), points)
            self.assertTrue(np.all(allocation >= 0))

    def test_pareto_preserves_distinct_specialists(self):
        values = np.array([[10, 1, 1], [1, 10, 1], [1, 1, 10], [4, 4, 4], [3, 3, 3]])
        self.assertEqual(set(sim.nondominated(values)), {0, 1, 2, 3})

    def test_legacy_spelling_aliases_do_not_reintroduce_separate_schools(self):
        self.assertEqual(sim.canonical_school("frost"), "cold")
        self.assertEqual(sim.canonical_school("poison"), "necrotic")
        self.assertEqual(set(sim.MAGIC_SCHOOLS), {"fire", "cold", "lightning", "void", "necrotic"})


if __name__ == "__main__":
    unittest.main()
