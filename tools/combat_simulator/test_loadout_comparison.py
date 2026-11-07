"""Keep historical loadouts isolated; retain paired statistics and current scaling checks."""
import unittest
import numpy as np

import simulator as sim
import loadout_comparison as loadout


class LoadoutTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)
        self.base = sim.read_json(sim.HERE / "scenarios.json")
        self.pressure = sim.read_json(sim.HERE / "pressure_scenarios.json")
        self.settings = sim.read_json(sim.HERE / "loadout_scenarios.json")

    def test_retired_loadout_builder_rejects_current_rules(self):
        with self.assertRaisesRegex(ValueError, "historical report"):
            loadout.make_common(100, 33, "mage", 150, 60, "initial",
                                {"chance": 20, "points": 7}, self.rules,
                                self.base, self.pressure, self.settings)

    def test_retired_package_application_rejects_current_rules_before_mutation(self):
        common = {"armor": np.array([100.]), "health": np.array([500.])}
        original = {key: value.copy() for key, value in common.items()}
        with self.assertRaisesRegex(ValueError, "historical report"):
            loadout.apply_package(common, {}, {}, self.settings, self.rules)
        for key in common:
            np.testing.assert_array_equal(common[key], original[key])

    def test_paired_interval_uses_actor_scores_not_pattern_pseudoreplication(self):
        a, b = np.array([1, 1, 0, 0]), np.array([0, 1, 1, 0])
        result = loadout.paired_difference(a, b)
        self.assertEqual(result["mean_difference"], 0)
        self.assertEqual(result["profiles"], 4)
        self.assertEqual(result["a_better"], 1)
        self.assertEqual(result["b_better"], 1)

    def test_paired_difference_is_symmetric_when_order_is_reversed(self):
        a = np.array([10, 4, 3, 10, 1.])
        b = np.array([2, 5, 3, 1, 5.])
        direct, reverse = loadout.paired_difference(a, b), loadout.paired_difference(b, a)
        self.assertEqual(direct["mean_difference"], -reverse["mean_difference"])
        self.assertEqual(direct["a_better"], reverse["b_better"])
        self.assertEqual(direct["b_better"], reverse["a_better"])

    def test_current_strength_scaling_preserves_intrinsic_weapon_damage_ratios(self):
        strengths = np.array([0., 10., 50., 138., 1000., 1e8])
        multiplier = sim.strength_physical_multiplier(strengths, self.rules)
        for ratio in (1.2, 1.4, 1.6):
            np.testing.assert_allclose((100 * ratio * multiplier) / (100 * multiplier), ratio)

    def test_current_magic_school_list_has_one_shared_power_domain(self):
        self.assertEqual(len(sim.MAGIC_SCHOOLS), 5)
        self.assertIn("void", sim.MAGIC_SCHOOLS)
        self.assertIn("necrotic", sim.MAGIC_SCHOOLS)
        self.assertNotIn("poison", sim.MAGIC_SCHOOLS)
        self.assertNotIn("physical", sim.MAGIC_SCHOOLS)


if __name__ == "__main__":
    unittest.main()
