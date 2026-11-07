"""Independent checks of cooldown and execution throughput gates."""
import unittest

import offense_cooldown_probe as probe
import simulator as sim


class OffenseCooldownProbeTests(unittest.TestCase):
    def setUp(self):
        self.config = probe.default_config()
        self.rules = sim.read_json(sim.DEFAULT_RULES)

    def test_separate_gates_and_speed_recovery_complementarity(self):
        # Fixed 50 DEX -> 0.8-second action; CDR shifts a 2-second cooldown
        # through 2 -> 1 -> 2/3 seconds. The cycle stops at the action gate.
        for rating, expected_cd, expected_cycle in ((0., 2., 2.), (100., 1., 1.), (200., 2/3, .8)):
            row = probe.evaluate(0., 50., (0., 0., rating), 2., 1., 50., 60, self.config, self.rules)
            self.assertAlmostEqual(row["execution_duration"], .8)
            self.assertAlmostEqual(row["recovered_cooldown"], expected_cd)
            self.assertAlmostEqual(row["cycle"], expected_cycle)
            self.assertAlmostEqual(row["expected_direct_dps"], 100/expected_cycle)
        slow = probe.evaluate(0., 0., (0., 0., 0.), 2., 1., 50., 60, self.config, self.rules)
        fast = probe.evaluate(0., 50., (0., 0., 0.), 2., 1., 50., 60, self.config, self.rules)
        self.assertEqual(slow["expected_direct_dps"], fast["expected_direct_dps"])

    def test_grid_conservation_and_zero_cooldown_never_needs_recovery(self):
        grid = list(probe.allocations(75., 5.))
        self.assertEqual(len(grid), 136)
        self.assertTrue(all(sum(row) == 75. for row in grid))
        config = dict(self.config, levels=[60], primary_power_fractions=[.8],
                      other_hit_ratings=[50.], base_cooldowns=[0.],
                      cooldown_recovery_per_credit=[2.])
        rows, count = probe.run(config, self.rules)
        self.assertEqual(count, 136)
        result = rows[0]
        self.assertEqual(result["best_grid_allocation"]["cooldown_credits"], 0.)
        self.assertAlmostEqual(result["gain_over_no_recovery"], 0.)
        self.assertEqual(result["primary_power"]+result["primary_dexterity"], 128)


if __name__ == "__main__":
    unittest.main()
