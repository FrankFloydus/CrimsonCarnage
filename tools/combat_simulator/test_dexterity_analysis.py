"""Independent expectations for the proposed-Dexterity allocation analysis."""
import copy
import unittest

import dexterity_analysis as analysis
import simulator as sim


class DexterityAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)
        self.config = analysis.default_config()
        self.case = {
            "case_id": 0, "family": "strength", "level": 60, "target_level": 60,
            "level_gap": 0, "point_budget": 128, "power_damage_ratio": .01,
            "minimum_duration_fraction": .4, "other_speed_rating": 0.,
            "other_hit_rating": 0., "dexterity_speed_per_point": 1.,
        }

    def curve(self, **changes):
        case = {**self.case, **changes}
        return case, analysis.evaluate_curve(case, self.rules, self.config)

    def test_budget_is_exact_for_every_allocation(self):
        case, curve = self.curve()
        self.assertEqual(len(curve), 129)
        self.assertTrue(all(row["power_points"]+row["dexterity_points"] == 128 for row in curve))
        self.assertEqual(curve[0]["power_attribute"], 138)
        self.assertEqual(curve[-1]["dexterity_attribute"], 138)

    def test_independent_pure_power_and_pure_dexterity_damage(self):
        _, curve = self.curve()
        self.assertAlmostEqual(curve[0]["expected_direct_dps"], 100*2.28*.8)
        self.assertAlmostEqual(curve[-1]["action_duration"], .4+.6/2.28)
        self.assertAlmostEqual(curve[-1]["expected_direct_dps"], 100/(.4+.6/2.28))

    def test_same_level_no_other_hit_optimum_and_near_band(self):
        case, curve = self.curve()
        result = analysis.summarize_curve(case, curve, self.config)
        self.assertEqual(result["best_dexterity_points"], [50])
        self.assertAlmostEqual(result["best_expected_direct_dps"], 100*1.78*1.25)
        self.assertIn(50, result["near_best_dexterity_points"])
        self.assertTrue(all(curve[index]["expected_direct_dps"] >= .99*222.5-1e-10
                            for index in result["near_best_dexterity_points"]))
        self.assertLess(result["near_best_dexterity_min"], 50)
        self.assertGreater(result["near_best_dexterity_max"], 50)

    def test_existing_hit_changes_optimum(self):
        case, curve = self.curve(other_hit_rating=50.)
        result = analysis.summarize_curve(case, curve, self.config)
        self.assertEqual(result["best_dexterity_points"], [18])
        self.assertTrue(all(row["hit_chance"] == 1 for row in curve))

    def test_higher_level_damage_factor_is_included_once(self):
        case, curve = self.curve(level=10, target_level=13, level_gap=3, point_budget=28)
        # Advantage=1+9*3^2/(8^2+3^2)=154/73; disadvantage is reciprocal.
        self.assertAlmostEqual(curve[0]["level_damage_factor"], 73/154)
        self.assertAlmostEqual(curve[0]["expected_direct_dps"], 100*1.28*.6635*73/154)
        self.assertAlmostEqual(curve[0]["relative_to_unallocated"], 1.28)

    def test_existing_speed_can_make_pure_power_optimal(self):
        case, curve = self.curve(other_hit_rating=50., other_speed_rating=100.)
        self.assertEqual(analysis.summarize_curve(case, curve, self.config)["best_dexterity_points"], [0])

    def test_calibrated_intellect_matches_strength_only_in_controlled_reference(self):
        _, physical = self.curve()
        _, magical = self.curve(family="intellect", power_damage_ratio=.01)
        self.assertEqual(physical, magical)
        _, weaker = self.curve(family="intellect", power_damage_ratio=.005)
        self.assertAlmostEqual(weaker[0]["expected_direct_dps"], 100*1.64*.8)

    def test_same_context_external_hit_does_not_spend_primary_budget(self):
        _, curve = self.curve(point_budget=10, other_hit_rating=50.)
        self.assertEqual(curve[0]["power_points"], 10)
        self.assertEqual(curve[0]["hit_chance"], 1.)
        self.assertAlmostEqual(curve[0]["expected_direct_dps"], 110.)

    def test_impossible_target_levels_are_skipped_not_clipped(self):
        cases, skipped = analysis.generate_cases(self.config, self.rules)
        self.assertTrue(all(case["target_level"] <= 60 for case in cases))
        self.assertFalse(any(case["level"] == 60 and case["level_gap"] > 0 for case in cases))
        self.assertEqual({(row["level"], row["gap"]) for row in skipped}, {(60, 3), (60, 5)})
        self.assertEqual({case["point_budget"] for case in cases}, {10, 28, 68, 128})

    def test_heavy_named_allocations_report_actual_integer_spending(self):
        case, curve = self.curve(point_budget=28)
        selected = analysis.summarize_curve(case, curve, self.config)["selected_allocations"]
        self.assertEqual(selected["power_heavy_80_20"]["power_points"], 22)
        self.assertEqual(selected["power_heavy_80_20"]["dexterity_points"], 6)
        self.assertEqual(selected["mixed_50_50"]["dexterity_points"], 14)
        self.assertEqual(selected["dexterity_heavy_20_80"]["dexterity_points"], 22)

    def test_invalid_configs_reject_nonphysical_timings_and_counts(self):
        for key, value in (("levels", [61]), ("levels", [1, 1]),
                           ("minimum_duration_fractions", [0]),
                           ("other_speed_ratings", [float("nan")]),
                           ("base_action_duration", 0)):
            config = copy.deepcopy(self.config)
            config[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                analysis.validate_config(config, self.rules)


if __name__ == "__main__":
    unittest.main()
