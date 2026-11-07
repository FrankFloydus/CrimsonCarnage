from decimal import Decimal, localcontext
import math
import unittest

import numpy as np

import simulator as sim


class ConstantQuality:
    def __init__(self, value):
        self.value = value
        self.draws = 0

    def random(self, size):
        self.draws += int(np.prod(size))
        return np.full(size, self.value)


def reference_damage(source, target):
    # Independent rational form; both directions use one reciprocal advantage.
    with localcontext() as context:
        context.prec = 80
        gap_squared = Decimal((int(source) - int(target)) ** 2)
        advantage = (64 + 10 * gap_squared) / (64 + gap_squared)
        return advantage if source >= target else 1 / advantage


def reference_base_chance(source, target):
    with localcontext() as context:
        context.prec = 80
        difference = int(target) - int(source)
        if difference < 0:
            return min(Decimal(1), Decimal(".8") - Decimal(".04") * difference)
        approved = (".8", ".7835", ".7362", ".6635", ".5736", ".4757",
                    ".25", ".18", ".14", ".115", ".1")
        return Decimal(approved[min(difference, 10)])


def reference_required_rating(source, target):
    difference = int(target) - int(source)
    return Decimal(max(0, 50 + 10 * difference)) * Decimal(2) ** max(0, difference - 5)


def reference_hit_chance(source, target, rating):
    with localcontext() as context:
        context.prec = 80
        required = reference_required_rating(source, target)
        if required == 0:
            return Decimal(1)
        uncovered = max(Decimal(0), required - max(Decimal(0), Decimal(str(rating))))
        return 1 - (1 - reference_base_chance(source, target)) * uncovered / required


def reference_control(source, target):
    difference = max(0, int(target) - int(source))
    with localcontext() as context:
        context.prec = 80
        return max(Decimal(".25"), Decimal(10) / (10 + difference))



class LevelScalingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = sim.read_json(sim.DEFAULT_RULES)
        source, target = np.meshgrid(np.arange(1, 61), np.arange(1, 61), indexing="ij")
        cls.sources, cls.targets = source.ravel(), target.ravel()

    def test_damage_all_legal_level_pairs_match_decimal_reference(self):
        actual = sim.level_gap_factor(self.sources, self.targets, self.rules)
        expected = [float(reference_damage(s, t)) for s, t in zip(self.sources, self.targets)]
        np.testing.assert_allclose(actual, expected, rtol=2e-15, atol=2e-15)
        self.assertTrue(np.all(np.isfinite(actual)))
        self.assertTrue(np.all(actual > 0))
        self.assertTrue(np.all(actual < 10))


    def test_damage_is_reciprocal_and_monotonic_with_level_advantage(self):
        direct = sim.level_gap_factor(self.sources, self.targets, self.rules)
        reverse = sim.level_gap_factor(self.targets, self.sources, self.rules)
        np.testing.assert_allclose(direct * reverse, 1, rtol=2e-15)
        for source in (1, 15, 30, 45, 60):
            values = sim.level_gap_factor(source, np.arange(1, 61), self.rules)
            self.assertTrue(np.all(np.diff(values) < 0))
            self.assertEqual(float(values[source - 1]), 1)
        self.assertGreater(sim.level_gap_factor(60, 1, self.rules), 9.8)
        self.assertLess(sim.level_gap_factor(1, 60, self.rules), .102)


    def test_base_accuracy_and_rating_requirements_cover_every_level_pair(self):
        base = sim.base_hit_chance(self.sources, self.targets, self.rules)
        required = sim.required_hit_rating(self.sources, self.targets, self.rules)
        expected_base = [float(reference_base_chance(s, t)) for s, t in zip(self.sources, self.targets)]
        expected_rating = [float(reference_required_rating(s, t)) for s, t in zip(self.sources, self.targets)]
        np.testing.assert_allclose(base, expected_base, rtol=2e-15, atol=2e-15)
        np.testing.assert_array_equal(required, expected_rating)
        self.assertTrue(np.all(base >= .1))
        self.assertTrue(np.all(base <= 1))


    def test_natural_attack_and_spell_accuracy_follow_all_approved_gap_anchors(self):
        expected = (.8, .7835, .7362, .6635, .5736, .4757, .25, .18, .14, .115, .1)
        targets = np.arange(1, 12)
        for natural in (sim.base_hit_chance, sim.base_spell_success_chance):
            np.testing.assert_allclose(natural(1, targets, self.rules), expected,
                                       rtol=2e-15, atol=2e-15)
        for resolved in (sim.hit_chance, sim.spell_success_chance):
            np.testing.assert_allclose(resolved(1, targets, 0, self.rules), expected,
                                       rtol=2e-15, atol=2e-15)


    def test_attack_and_spell_floor_survives_every_extreme_gap_and_partial_investment(self):
        targets = np.arange(11, 61)
        for natural, required, resolved in (
                (sim.base_hit_chance, sim.required_hit_rating, sim.hit_chance),
                (sim.base_spell_success_chance, sim.required_spell_accuracy, sim.spell_success_chance)):
            np.testing.assert_array_equal(natural(1, targets, self.rules), .1)
            cap = required(1, targets, self.rules)
            for investment, expected in ((0, .1), (.25, .325), (.5, .55),
                                         (.75, .775), (1, 1), (2, 1)):
                np.testing.assert_allclose(resolved(1, targets, cap * investment, self.rules),
                                           expected, rtol=2e-15, atol=2e-15)
            self.assertTrue(np.all(resolved(1, targets, cap * .999999, self.rules) < 1))


    def test_attack_and_spell_success_have_the_approved_break_after_five_levels(self):
        sources = np.arange(1, 55)
        for natural, required, resolved in (
                (sim.base_hit_chance, sim.required_hit_rating, sim.hit_chance),
                (sim.base_spell_success_chance, sim.required_spell_accuracy, sim.spell_success_chance)):
            np.testing.assert_array_equal(natural(sources, sources + 5, self.rules), .4757)
            np.testing.assert_array_equal(natural(sources, sources + 6, self.rules), .25)
            np.testing.assert_array_equal(required(sources, sources + 5, self.rules), 100)
            np.testing.assert_array_equal(required(sources, sources + 6, self.rules), 220)
            np.testing.assert_array_equal(resolved(sources, sources + 5, 100, self.rules), 1)
            np.testing.assert_allclose(resolved(sources, sources + 6, 100, self.rules),
                                       float(Decimal(13) / 22), rtol=2e-15)
            np.testing.assert_array_equal(resolved(sources, sources + 6, 220, self.rules), 1)


    def test_accuracy_all_level_pairs_and_rating_budgets_match_decimal(self):
        previous = np.zeros_like(self.sources, dtype=float)
        for rating in (-100, 0, 1, 25, 50, 100, 150, 250, 640, 1000, 4800, 1e20, 1e308):
            actual = sim.hit_chance(self.sources, self.targets, rating, self.rules)
            expected = [float(reference_hit_chance(s, t, rating))
                        for s, t in zip(self.sources, self.targets)]
            np.testing.assert_allclose(actual, expected, rtol=2e-15, atol=2e-15)
            self.assertTrue(np.all(actual >= previous - 1e-15))
            self.assertTrue(np.all(actual <= 1))
            previous = actual


    def test_legacy_spell_math_alias_matches_unified_hit_formula(self):
        for rating in (0, 25, 50, 100, 4800, 1e20):
            actual = sim.spell_success_chance(self.sources, self.targets, rating, self.rules)
            expected = [float(reference_hit_chance(s, t, rating))
                        for s, t in zip(self.sources, self.targets)]
            np.testing.assert_allclose(actual, expected, rtol=2e-15, atol=2e-15)
        expected_base = [float(reference_base_chance(s, t)) for s, t in zip(self.sources, self.targets)]
        expected_required = [float(reference_required_rating(s, t)) for s, t in zip(self.sources, self.targets)]
        np.testing.assert_allclose(sim.base_spell_success_chance(self.sources, self.targets, self.rules),
                                   expected_base, rtol=2e-15, atol=2e-15)
        np.testing.assert_array_equal(sim.required_spell_accuracy(self.sources, self.targets, self.rules),
                                      expected_required)
        self.assertAlmostEqual(sim.hit_chance(30, 30, 0, self.rules), .8)
        self.assertEqual(sim.spell_success_chance(30, 30, 50, self.rules), 1)
        self.assertEqual(sim.hit_chance(30, 30, 50, self.rules), 1)
        self.assertAlmostEqual(sim.spell_success_chance(30, 30, 0, self.rules), .8)


    def test_caps_are_reachable_at_finite_rating_for_each_matchup(self):
        required = sim.required_hit_rating(self.sources, self.targets, self.rules)
        at_cap = sim.hit_chance(self.sources, self.targets, required, self.rules)
        over_cap = sim.hit_chance(self.sources, self.targets, required + 100, self.rules)
        np.testing.assert_array_equal(at_cap, 1)
        np.testing.assert_array_equal(over_cap, 1)
        positive = required > 0
        under_cap = sim.hit_chance(self.sources[positive], self.targets[positive],
                                       required[positive] * .999999, self.rules)
        self.assertTrue(np.all(under_cap < 1))


    def test_nonfinite_rating_fails_closed_and_large_finite_rating_still_caps(self):
        invalid = np.array((float("nan"), float("inf"), -float("inf")))
        np.testing.assert_allclose(sim.hit_chance(30, 30, invalid, self.rules), .8)
        np.testing.assert_array_equal(sim.hit_chance(60, 1, invalid, self.rules), 1)
        self.assertEqual(sim.hit_chance(1, 60, 1e308, self.rules), 1)
        self.assertAlmostEqual(sim.hit_chance(30, 30, -100, self.rules), .8)


    def test_scalar_array_and_broadcast_matchups_resolve_the_same_values(self):
        sources = np.array(((1,), (60,)))
        targets = np.array((1, 60))
        ratings = np.array((0, 1e20))
        actual = sim.hit_chance(sources, targets, ratings, self.rules)
        expected = np.array(((.8, 1), (1, 1)))
        np.testing.assert_allclose(actual, expected, rtol=2e-15)
        np.testing.assert_allclose(sim.level_gap_factor(sources, targets, self.rules),
                                   [[1, float(reference_damage(1, 60))],
                                    [float(reference_damage(60, 1)), 1]])


    def test_rating_covers_a_contiguous_higher_enemy_range(self):
        enemies = np.arange(1, 61)
        for source, rating, highest_full in ((10, 0, 5), (10, 50, 10),
                                             (10, 100, 15), (10, 150, 15), (10, 4800, 20), (60, 50, 60)):
            actual = sim.hit_chance(source, enemies, rating, self.rules)
            self.assertTrue(np.all(np.diff(actual) <= 1e-15))
            np.testing.assert_array_equal(actual[enemies <= highest_full], 1)
            self.assertTrue(np.all(actual[enemies > highest_full] < 1))
        self.assertAlmostEqual(sim.hit_chance(10, 20, 100, self.rules), .11875)
        self.assertAlmostEqual(sim.hit_chance(10, 30, 100, self.rules), float(reference_hit_chance(10, 30, 100)))
        self.assertAlmostEqual(sim.base_hit_chance(1, 11, self.rules), .1)
        self.assertAlmostEqual(sim.base_hit_chance(1, 60, self.rules), .1)
        self.assertEqual(sim.required_hit_rating(1, 11, self.rules), 4800)


    def test_overlevel_accuracy_reaches_natural_cap_without_rating(self):
        expected = (.8, .84, .88, .92, .96, 1, 1)
        for advantage, chance in enumerate(expected):
            self.assertAlmostEqual(sim.base_hit_chance(10, 10 - advantage, self.rules), chance)
            self.assertAlmostEqual(sim.hit_chance(10, 10 - advantage, 0, self.rules), chance)
        self.assertEqual(sim.hit_chance(60, 1, 0, self.rules), 1)
        self.assertAlmostEqual(sim.hit_chance(60, 60, 0, self.rules), .8)
        self.assertEqual(sim.hit_chance(60, 60, 50, self.rules), 1)


    def test_controls_shorten_only_against_higher_levels_and_retain_floor(self):
        actual = sim.control_level_duration_factor(self.sources, self.targets, self.rules)
        expected = [float(reference_control(s, t)) for s, t in zip(self.sources, self.targets)]
        np.testing.assert_allclose(actual, expected, rtol=2e-15, atol=2e-15)
        self.assertTrue(np.all(actual >= .25))
        self.assertTrue(np.all(actual <= 1))
        self.assertEqual(sim.control_level_duration_factor(60, 1, self.rules), 1)
        self.assertEqual(sim.control_level_duration_factor(1, 60, self.rules), .25)
        self.assertAlmostEqual(4 * sim.control_level_duration_factor(1, 60, self.rules) * .6, .6)


    def test_accuracy_investment_preserves_independent_damage_and_control_disadvantage(self):
        self.assertEqual(sim.hit_chance(1, 60, 1e20, self.rules), 1)
        self.assertLess(sim.level_gap_factor(1, 60, self.rules), .102)
        self.assertEqual(sim.control_level_duration_factor(1, 60, self.rules), .25)
        self.assertAlmostEqual(sim.hit_chance(30, 30, 0, self.rules), .8)
        self.assertEqual(sim.hit_chance(30, 30, 50, self.rules), 1)
        self.assertAlmostEqual(1 / .8 - 1, .25)


    def test_hit_sampling_consumes_randomness_only_for_uncertain_connected_deliveries(self):
        sampler = ConstantQuality(.5)
        connected = np.array((False, True, True, True, True))
        chance = np.array((.8, 0, 1, .4, .8))
        actual = sim.hit_mask(connected, chance, sampler)
        np.testing.assert_array_equal(actual, (False, False, True, False, True))
        self.assertEqual(sampler.draws, 2)
        sim.hit_mask(np.zeros(5, dtype=bool), chance, sampler)
        self.assertEqual(sampler.draws, 2)


    def test_retained_accuracy_fixtures_match_independent_reference(self):
        samples = sim.read_json(sim.HERE / "parity_samples.json")
        self.assertIn("hit_chances", samples.keys())
        self.assertIn("spell_success", samples.keys())
        self.assertIn("control_durations", samples.keys())
        self.assertGreater(len(samples["hit_chances"]), 10)
        self.assertGreater(len(samples["control_durations"]), 10)
        for row in samples["hit_chances"]:
            source, target, rating = row["source_level"], row["target_level"], row["rating"]
            self.assertTrue(math.isclose(row["expected_base_chance"],
                                         float(reference_base_chance(source, target)), abs_tol=2e-15))
            self.assertEqual(row["expected_required_rating"], float(reference_required_rating(source, target)))
            self.assertTrue(math.isclose(row["expected_chance"],
                                         float(reference_hit_chance(source, target, rating)), abs_tol=2e-15))
        for row in samples["spell_success"]:
            source, target, rating = row["source_level"], row["target_level"], row["rating"]
            self.assertTrue(math.isclose(row["expected_base_chance"],
                                         float(reference_base_chance(source, target)), abs_tol=2e-15))
            self.assertEqual(row["expected_required_rating"], float(reference_required_rating(source, target)))
            self.assertTrue(math.isclose(row["expected_chance"],
                                         float(reference_hit_chance(source, target, rating)), abs_tol=2e-15))
        for row in samples["control_durations"]:
            expected = float(reference_control(row["source_level"], row["target_level"]))
            self.assertTrue(math.isclose(row["expected_multiplier"], expected, abs_tol=2e-15))


    def test_attack_and_spell_delivery_read_only_unified_hit_rating(self):
        stats = {"hit_rating": np.array([0., 50., 1e20]),
                 "spell_accuracy": np.array([1e308, 0., 0.])}
        expected = np.array([.8, 1., 1.])
        for kind in ("attack", "spell"):
            np.testing.assert_allclose(sim.delivery_chance(30, 30, stats, kind, self.rules), expected)
        stats["hit_rating"][:] = 0
        np.testing.assert_allclose(sim.delivery_chance(30, 30, stats, "spell", self.rules), .8)

    def test_school_ailment_potency_respects_level_damage_without_health_scaling(self):
        ordinary_damage = 60 * float(sim.level_gap_factor(1, 11, self.rules))
        potency = float(sim.ailment_potency(ordinary_damage, 11, self.rules))
        self.assertAlmostEqual(ordinary_damage, 60 * 41 / 266)
        self.assertAlmostEqual(potency, ordinary_damage / 20)
        self.assertGreater(potency, 0)
        self.assertAlmostEqual(4 * float(sim.control_level_duration_factor(1, 11, self.rules)), 2)


if __name__ == "__main__":
    unittest.main()
