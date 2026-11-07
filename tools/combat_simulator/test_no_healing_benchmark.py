"""Independent numerical expectations for directed no-restoration TTK trials."""
import copy
import unittest

import numpy as np
import no_healing_benchmark as benchmark
import leveling_study as study
import simulator as sim


class DirectedBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)
        self.config = benchmark.default_config()
        self.config.update(horizon=5., dt=.1, builds_per_context=8, repeats=1)
        self.config["weapon_roll_range"] = [1., 1.]

    def actor(self, health=1000., damage=100., school=0):
        actor, _ = study.draw_profiles(1, 1, "none", "neutral", 7, self.rules, self.config)
        for key, value in {
            "health": health, "absorption": 0., "armor": 0., "evasion": 0., "block": 0.,
            "hit_rating": 50., "critical_chance": 0., "critical_damage": 0., "dot_damage": 0.,
            "penetration": 0., "control_reduction": 0., "cost": 0., "cooldown": 0.,
            "duration": 1., "consumable_policy": 0, "is_dot": False,
            "dot_duration": 4., "dot_period": 1., "dot_bleed": False, "school": school,
            "stamina": 100., "mana": 100., "stamina_regen": 10., "mana_regen": 10.,
        }.items():
            actor[key][:] = value
        actor["resistance"][:] = 0.
        actor["ordinary_chances"][:] = 0.
        actor["raw_base_mean"][:] = 0.
        actor["raw_base_mean"][:, school] = damage
        actor["raw_flat_magic"][:] = 0.
        actor["raw_mean"] = actor["raw_base_mean"].copy()
        return actor

    def run_trial(self, source, target):
        return benchmark.simulate_direction(source, target, self.rules, self.config, 19)

    def test_known_direct_ttk_and_passive_target(self):
        result = self.run_trial(self.actor(), self.actor(health=250., damage=1e12))
        self.assertAlmostEqual(result["ttk"][0], 2.6)
        self.assertEqual(result["health_damage"][0], 250.)
        self.assertEqual(result["hits"][0], 3)
        self.assertEqual(result["passive_actions"][0], 0)
        self.assertEqual(result["restored"][0], 0)
        self.assertEqual(result["potions_used"][0], 0)

    def test_target_offense_cannot_change_directed_outcome(self):
        source, target = self.actor(), self.actor(health=250., damage=0.)
        before = self.run_trial(source, target)
        target["raw_base_mean"][:] = 1e20
        target["duration"][:] = .01
        target["critical_chance"][:] = 100.
        after = self.run_trial(source, target)
        for key in benchmark.METRICS:
            np.testing.assert_array_equal(before[key], after[key], err_msg=key)

    def test_reverse_direction_is_independent_of_player_offense(self):
        enemy, player = self.actor(damage=100.), self.actor(health=250., damage=0.)
        first = self.run_trial(enemy, player)
        player["raw_base_mean"][:] = 1e15
        second = self.run_trial(enemy, player)
        self.assertAlmostEqual(first["ttk"][0], 2.6)
        for key in benchmark.METRICS:
            np.testing.assert_array_equal(first[key], second[key])

    def test_timeout_is_censored_not_a_fake_kill(self):
        result = self.run_trial(self.actor(damage=0.), self.actor())
        self.assertTrue(np.isinf(result["ttk"][0]))
        self.assertEqual(result["observed_duration"][0], 5.)
        data = np.zeros(1, dtype=benchmark.RESULT_DTYPE)
        for key in benchmark.METRICS:
            data[key] = result[key]
        summary = benchmark.summarize(data)
        self.assertEqual(summary["kills"], 0)
        self.assertEqual(summary["censored"], 1)
        self.assertIsNone(summary["conditional_ttk_p50"])
        self.assertEqual(summary["restricted_mean_observed_duration"], 5.)

    def test_mixed_kills_and_censoring_use_independent_quantiles(self):
        data = np.zeros(4, dtype=benchmark.RESULT_DTYPE)
        data["ttk"] = [1., 3., np.inf, np.inf]
        data["observed_duration"] = [1., 3., 5., 5.]
        row = benchmark.summarize(data)
        self.assertEqual(row["kill_fraction"], .5)
        self.assertAlmostEqual(row["conditional_ttk_p10"], 1.2)
        self.assertAlmostEqual(row["conditional_ttk_p50"], 2.)
        self.assertAlmostEqual(row["conditional_ttk_p90"], 2.8)
        self.assertEqual(row["restricted_mean_observed_duration"], 3.5)

    def test_consumable_flags_cannot_restore_health_or_mutate_inputs(self):
        source, target = self.actor(), self.actor(health=250.)
        source["consumable_policy"][:] = 1
        target["consumable_policy"][:] = 1
        result = self.run_trial(source, target)
        self.assertEqual(result["restored"][0], 0.)
        self.assertEqual(result["potions_used"][0], 0.)
        self.assertEqual(source["consumable_policy"][0], 1)
        self.assertEqual(target["consumable_policy"][0], 1)
        self.config["consumables"]["charges"] = 3
        with self.assertRaisesRegex(ValueError, "restoration"):
            self.run_trial(source, target)

    def test_lethal_dot_records_death_without_restoration(self):
        source, target = self.actor(damage=20., school=1), self.actor(health=15.)
        source["is_dot"][:] = True
        result = self.run_trial(source, target)
        self.assertAlmostEqual(result["ttk"][0], 1.6)
        self.assertEqual(result["health_damage"][0], 15.)
        self.assertEqual(result["restored"][0], 0.)

    def test_necrotic_bypasses_absorption(self):
        target = self.actor(health=50.)
        target["absorption"][:] = 500.
        result = self.run_trial(self.actor(damage=100., school=5), target)
        self.assertAlmostEqual(result["ttk"][0], .6)
        self.assertEqual(result["absorbed_damage"][0], 0.)
        self.assertEqual(result["target_absorption"][0], 500.)

    def test_covered_dot_keeps_absorption_recovery(self):
        source, target = self.actor(damage=10., school=1), self.actor(health=100.)
        source["is_dot"][:] = True
        target["absorption"][:] = 100.
        result = self.run_trial(source, target)
        self.assertTrue(np.isinf(result["ttk"][0]))
        self.assertEqual(result["health_damage"][0], 0.)
        self.assertEqual(result["absorbed_damage"][0], 40.)
        self.assertGreater(result["target_absorption"][0], 90.)

    def test_stamina_regeneration_remains_continuous(self):
        source = self.actor(damage=0.)
        source["kind_attack"][:] = True
        source["cost"][:] = 60.
        result = self.run_trial(source, self.actor())
        self.assertEqual(result["actions"][0], 2.)
        self.assertAlmostEqual(result["source_stamina"][0], 30.)
        self.assertGreater(result["source_resource_wait"][0], 0.)

    def test_cohorts_are_disjoint_and_anchors_stay_separate(self):
        self.config["builds_per_context"] = 128
        data, hashes = benchmark.job((self.config, self.rules, 1, "none"))
        self.assertEqual(len(data), 256)
        self.assertEqual(len(hashes), 128*16)
        self.assertEqual(sum(np.count_nonzero(data["cohort"] == k) for k in range(3)), len(data))
        self.assertEqual(np.count_nonzero(data["cohort"] == 2), 2*(len(study.FUNDING)+6))
        self.assertEqual(data["restored"].sum(), 0.)
        self.assertEqual(data["passive_actions"].sum(), 0.)

    def test_configuration_rejects_healing_and_invalid_clocks(self):
        benchmark.validate_config(self.config, self.rules)
        for changes in ({"horizon": 5.05}, {"dt": .3}, {"levels": [1, 1]}, {"levels": [61]},
                        {"prices": {"neutral": {}, "invented": {}}}):
            config = copy.deepcopy(self.config)
            config.update(changes)
            with self.assertRaises(ValueError):
                benchmark.validate_config(config, self.rules)


if __name__ == "__main__":
    unittest.main()
