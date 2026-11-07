from decimal import Decimal, localcontext
import itertools
import math
import unittest

import numpy as np

import simulator as sim


def decimal(value):
    return Decimal(str(value))



def reference_duration(base, minimum, rating):
    # Independent high-precision statement of the approved authored-duration rule.
    with localcontext() as context:
        context.prec = 80
        base, minimum = decimal(base), decimal(minimum)
        rating = max(Decimal(-50), decimal(rating))
        return minimum + (base - minimum) / (1 + rating / 100)



def reference_defense(rating):
    with localcontext() as context:
        context.prec = 80
        rating = max(Decimal(0), decimal(rating))
        return min(Decimal(".75"), 12 * rating / (3000 + 13 * rating))



def reference_level_gap(source, target):
    difference = source - target
    squared = Decimal(difference) ** 2
    advantage = 1 + 9 * squared / (64 + squared)
    return advantage if difference >= 0 else 1 / advantage



class CombatMathPropertyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = sim.read_json(sim.DEFAULT_RULES)

    def test_duration_grid_matches_independent_decimal_arithmetic(self):
        ratings = (-1e8, -50, -49.999, -1, 0, 1, 25, 100, 1000, 1e6, 1e12, 1e308)
        for base, fraction in itertools.product((.01, .1, .4, .8, 1, 4, 10), (.01, .4, .8, 1)):
            minimum = base * fraction
            actual = sim.rating_duration(base, minimum, np.array(ratings), self.rules)
            expected = [float(reference_duration(base, minimum, r)) for r in ratings]
            np.testing.assert_allclose(actual, expected, rtol=2e-15, atol=1e-15)
            self.assertTrue(np.all(np.diff(actual) <= 1e-14))
            self.assertTrue(np.all(actual >= minimum))
            self.assertEqual(actual[0], actual[1])
            self.assertAlmostEqual(actual[4], base)


    def test_invalid_authored_duration_relations_are_rejected(self):
        for base, minimum in ((0, 0), (-1, .1), (1, 0), (1, -.1), (.5, 1),
                              (math.inf, .1), (1, math.inf), (math.nan, .1), (1, math.nan)):
            with self.subTest(base=base, minimum=minimum), self.assertRaises(ValueError):
                sim.rating_duration(base, minimum, 100, self.rules)
        with self.assertRaises(ValueError):
            sim.rating_duration([1, .8], [.4, 0], [0, 0], self.rules)


    def test_playback_grid_keeps_attack_floor_and_cast_independence(self):
        for base, minimum, rating, encumbrance in itertools.product(
                (.25, .8, 1, 4), (.1, .2), (-1000, -50, 0, 25, 100, 1e12), (.5, .8, 1)):
            playback = float(decimal(base) / reference_duration(base, minimum, rating))
            attack = float(sim.action_speed_rate(base, minimum, rating, self.rules, encumbrance, True))
            cast = float(sim.action_speed_rate(base, minimum, rating, self.rules, encumbrance, False))
            self.assertAlmostEqual(attack, max(.5, playback * encumbrance), places=12)
            self.assertAlmostEqual(cast, playback, places=12)
        self.assertGreater(float(sim.action_speed_rate(4, .1, 1e12, self.rules, attack=True)), 39)


    def test_cooldown_reciprocal_grid_has_no_hidden_cap(self):
        for base in (-100, 0, .001, 1, 20, 1e6):
            actual = []
            for efficiency in (-1e12, -1, 0, 1, 25, 100, 1000, 1e12, 1e308):
                with localcontext() as context:
                    context.prec = 80
                    expected = float(max(Decimal(0), decimal(base)) /
                                     (1 + max(Decimal(0), decimal(efficiency)) / 100))
                value = float(sim.efficient_cost(base, efficiency))
                self.assertTrue(math.isfinite(value))
                self.assertTrue(math.isclose(value, expected, rel_tol=2e-15, abs_tol=1e-320))
                actual.append(value)
            self.assertTrue(np.all(np.diff(actual) <= 0))
            if base > 0:
                self.assertGreater(actual[-1], 0)
                self.assertLess(actual[-2], base / 1e9)


    def test_defense_extremes_and_penetration_match_decimal_arithmetic(self):
        ratings = (-1e308, -100, 0, 1e-300, 1e-12, .1, 1, 100, 250, 500,
                   999.999, 1000, 1000.001, 2000, 1e12, 1e308, np.finfo(float).max)
        expected = np.array([float(reference_defense(r)) for r in ratings])
        for evasion in (False, True):
            with np.errstate(all="raise"):
                actual = sim.defense(np.array(ratings), self.rules, evasion)
            np.testing.assert_allclose(actual, expected, rtol=3e-15, atol=0)
            self.assertTrue(np.all(np.isfinite(actual)))
            self.assertTrue(np.all(np.diff(actual) >= 0))
        for armor, penetration in itertools.product((0, 100, 500, 1000, 2000, 1e308), (0, 25, 50, 75, 100)):
            effective = decimal(armor) * (1 - decimal(penetration) / 100)
            result = float(sim.defense(armor * (1 - penetration / 100), self.rules))
            self.assertAlmostEqual(result, float(reference_defense(effective)), places=14)
        self.assertGreater(float(sim.defense(2000 * .75, self.rules)),
                           float(sim.defense(1000 * .75, self.rules)))


    def test_dot_percentage_pool_has_nonnegative_damage_without_upper_cap(self):
        for contributions in itertools.product((-200, -100, -50, 0, 25, 100, 1000), repeat=3):
            expected = float(max(Decimal(0), 1 + sum(map(decimal, contributions)) / 100))
            actual = float(sim.damage_multiplier(sum(contributions), self.rules))
            self.assertAlmostEqual(actual, expected, places=13)
            self.assertAlmostEqual(1 + float(sim.damage_bonus(sum(contributions), self.rules)), expected, places=13)
        self.assertEqual(float(sim.damage_multiplier(-200 + 200)), 1)
        self.assertEqual(float(sim.damage_multiplier(10000)), 101)


    def test_movement_zero_slowdown_cap_and_encumbrance_grid(self):
        for bonus, encumbrance in itertools.product((-1000, -100, -75, -1, 0, 25, 1000), (.5, .8, 1)):
            bounded = max(Decimal(-100), min(Decimal(25), decimal(bonus)))
            expected = float(max(Decimal(0), min(Decimal("1.25"),
                                                  (1 + bounded / 100) * decimal(encumbrance))))
            self.assertAlmostEqual(float(sim.movement_speed_rate(bonus, encumbrance, self.rules)), expected)
        self.assertEqual(float(sim.movement_speed_rate(-100, .5, self.rules)), 0)
        self.assertEqual(float(sim.movement_speed_rate(25, .5, self.rules)), .625)


    def test_retained_numeric_fixtures_match_current_reference_math(self):
        data = sim.read_json(sim.HERE / "parity_samples.json")
        for sample in data["armor"]:
            self.assertAlmostEqual(sample["expected"], float(reference_defense(sample["rating"])), places=14)
        for sample in data["penetration"]:
            penetration = min(Decimal(100), max(Decimal(0), decimal(sample["penetration"])))
            expected = reference_defense(decimal(sample["armor"]) * (1 - penetration / 100))
            self.assertAlmostEqual(sample["expected_reduction"], float(expected), places=14)
        for sample in data["rating_durations"]:
            expected = reference_duration(sample["base"], sample["minimum"], sample["rating"])
            self.assertAlmostEqual(sample["expected_duration"], float(expected), places=13)
            self.assertAlmostEqual(sample["expected_playback_rate"], float(decimal(sample["base"]) / expected), places=13)
        for sample in data["attack_playback"]:
            duration = reference_duration(sample["base"], sample["minimum"], sample["rating"])
            encumbrance = max(Decimal(".5"), min(Decimal(1), decimal(sample["capacity"]) /
                                                max(decimal(sample["capacity"]), decimal(sample["weight"]))))
            expected = max(Decimal(".5"), decimal(sample["base"]) / duration * encumbrance)
            self.assertAlmostEqual(sample["expected_playback_rate"], float(expected), places=13)
        for sample in data["movement_cases"]:
            bonus = max(Decimal(-100), min(Decimal(25), decimal(sample["bonus"])))
            encumbrance = max(Decimal(".5"), min(Decimal(1), decimal(sample["capacity"]) /
                                                max(decimal(sample["capacity"]), decimal(sample["weight"]))))
            self.assertAlmostEqual(sample["expected_multiplier"], float((1 + bonus / 100) * encumbrance))
        for sample in data["resource_costs"]:
            self.assertEqual(sample["expected_cost"], max(0, sample["base_cost"]))
        for section, base_key, rating_key, expected_key in (
                ("uncapped_cooldowns", "base", "recovery", "expected_duration"),):
            for sample in data[section]:
                expected = max(Decimal(0), decimal(sample[base_key])) / (1 + max(Decimal(0), decimal(sample[rating_key])) / 100)
                self.assertTrue(math.isclose(sample[expected_key], float(expected), rel_tol=2e-15, abs_tol=1e-300))
        for sample in data["uncapped_damage"]:
            expected = max(Decimal(0), 1 + sum(map(decimal, sample["contributions"])) / 100)
            self.assertAlmostEqual(sample["expected_multiplier"], float(expected))
        for sample in data["level_baselines"]:
            offset = sample["level"] - 1
            self.assertEqual(sample["health"], 120 + 8 * offset)
            self.assertEqual(sample["stamina"], 100 + 2 * offset)
            self.assertEqual(sample["mana"], 100 + 2 * offset)
        for sample in data["level_gaps"]:
            expected = reference_level_gap(sample["source_level"], sample["target_level"])
            self.assertAlmostEqual(sample["expected_multiplier"], float(expected), places=14)


    def test_resource_baselines_cover_every_legal_level(self):
        levels = np.arange(1, 61)
        baseline = sim.resource_baselines(levels, self.rules)
        np.testing.assert_array_equal(baseline["health"], 120 + 8 * (levels - 1))
        np.testing.assert_array_equal(baseline["stamina"], 100 + 2 * (levels - 1))
        np.testing.assert_array_equal(baseline["mana"], 100 + 2 * (levels - 1))

    def test_strength_and_critical_extremes_match_decimal_without_hidden_upper_cap(self):
        for value in (-1e6, -1, 0, 10, 100, 138, 1000, 1e12, 1e100):
            with localcontext() as context:
                context.prec = 100
                expected_strength = 1 + (max(Decimal(0), decimal(value)) - 10) / 100
                expected_critical = Decimal("1.5") + max(Decimal(0), decimal(value)) / 100
            self.assertTrue(math.isclose(float(sim.strength_physical_multiplier(value, self.rules)),
                                         float(expected_strength), rel_tol=2e-15))
            self.assertTrue(math.isclose(float(sim.critical_damage_multiplier(value, self.rules)),
                                         float(expected_critical), rel_tol=2e-15))

    def test_utility_threshold_is_monotonic_and_independent_of_actual_health(self):
        levels = np.arange(1, 61)
        previous = np.zeros(60)
        for damage in (0, .001, 1, 12, 30, 60, 1000):
            actual = sim.ailment_potency(damage, levels, self.rules)
            expected = [min(1, float(decimal(damage) / (12 + Decimal(".8") * int(level - 1))))
                        for level in levels]
            np.testing.assert_allclose(actual, expected, rtol=2e-15, atol=1e-15)
            self.assertTrue(np.all(actual >= previous))
            self.assertTrue(np.all(np.diff(actual) <= 1e-15))
            previous = actual

    def test_ailment_duration_extension_does_not_redistribute_existing_dps(self):
        for family in ("burn", "bleed", "poison"):
            before = sim.ailment_damage_rate(100, family, 50, self.rules)
            extended = dict(self.rules)
            extended[family + "_duration"] *= 3
            after = sim.ailment_damage_rate(100, family, 50, extended)
            self.assertEqual(float(before), float(after))
            self.assertAlmostEqual(float(after) * extended[family + "_duration"],
                                   float(before) * self.rules[family + "_duration"] * 3,
                                   places=11)


if __name__ == "__main__":
    unittest.main()
