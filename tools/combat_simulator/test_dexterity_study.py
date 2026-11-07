"""Independent expectations for the offline Dexterity proposal experiment."""
import copy
import unittest

import numpy as np

import dexterity_study as study
import simulator as sim


class DexterityStudyTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)
        self.config = study.default_config()
        self.config.update(windows=[1., 3., 5.], damage_roll_range=[1., 1.],
                           critical_chance=0., ordinary_ailment_chance=0., target_health=250.)

    def profile(self, family=None):
        profile = study.make_profile(1, "power_only", "magic_direct", 50., "free", self.config, self.rules)
        profile.update(duration=1., base_packet=100., flat_magic=0., hit_chance=1.,
                       resource_max=100., resource_regen=0., cost=0., family=family)
        return profile

    def run_profile(self, profile, trials=4):
        return study.simulate(profile, self.config, self.rules, trials, 33)

    def test_exact_direct_damage_clocks_and_ttk(self):
        result = self.run_profile(self.profile())
        np.testing.assert_allclose(result["ttk"], 2.6)
        for row, expected in zip(result["windows"], (100., 300., 500.)):
            np.testing.assert_allclose(row["damage"], expected)
        self.assertFalse(result["health_restoration_enabled"])

    def test_target_health_is_only_a_measurement_threshold(self):
        first = self.run_profile(self.profile())
        self.config["target_health"] = 10000.
        second = self.run_profile(self.profile())
        self.assertTrue(np.isinf(second["ttk"]).all())
        for a, b in zip(first["windows"], second["windows"]):
            np.testing.assert_array_equal(a["damage"], b["damage"])

    def test_no_hit_means_no_damage_or_ailment(self):
        p = self.profile("poison")
        p["hit_chance"] = 0.
        self.config.update(critical_chance=100., ordinary_ailment_chance=100.)
        result = self.run_profile(p)
        np.testing.assert_array_equal(result["windows"][-1]["damage"], 0.)
        self.assertTrue(np.isinf(result["ttk"]).all())

    def test_continuous_regen_exact_wait_schedule(self):
        starts, releases, waits = study.action_schedule(1., 10., 2., 6., 10.)
        np.testing.assert_allclose(starts, [0., 1., 4., 7., 10.])
        np.testing.assert_allclose(releases, [.6, 1.6, 4.6, 7.6])
        self.assertEqual(waits, [(2., 4.), (5., 7.), (8., 10.)])
        self.assertAlmostEqual(study.resource_at(5., starts, 10., 2., 6.), 2.)

    def test_cost_above_capacity_never_starts(self):
        starts, releases, waits = study.action_schedule(1., 10., 2., 11., 10.)
        self.assertEqual(len(starts), 0)
        self.assertEqual(len(releases), 0)
        self.assertEqual(waits, [(0., 10.)])

    def test_no_regen_pool_exhaustion_stops_actions(self):
        starts, releases, waits = study.action_schedule(1., 10., 0., 6., 5.)
        np.testing.assert_allclose(starts, [0.])
        np.testing.assert_allclose(releases, [.6])
        self.assertEqual(waits, [(1., 5.)])

    def test_critical_guarantees_burn_without_critical_seed(self):
        self.config["critical_chance"] = 100.
        result = self.run_profile(self.profile("burn"))
        final = result["windows"][-1]
        np.testing.assert_allclose(final["direct_damage"], 750.)
        np.testing.assert_allclose(final["periodic_damage"], 100.)
        self.config["critical_damage"] = 100.
        stronger = self.run_profile(self.profile("burn"))["windows"][-1]
        np.testing.assert_allclose(stronger["direct_damage"], 1250.)
        np.testing.assert_allclose(stronger["periodic_damage"], 100.)

    def test_poison_independent_lifetime_and_lethal_tick(self):
        self.config.update(windows=[7.], ordinary_ailment_chance=100., target_health=140.)
        p = self.profile("poison")
        p.update(resource_max=1., cost=1.)
        result = self.run_profile(p)
        np.testing.assert_allclose(result["windows"][0]["damage"], 150.)
        np.testing.assert_allclose(result["windows"][0]["periodic_damage"], 50.)
        np.testing.assert_allclose(result["ttk"], 5.6)

    def test_poison_multiple_applications_add_linearly(self):
        self.config["ordinary_ailment_chance"] = 100.
        result = self.run_profile(self.profile("poison"))["windows"][-1]
        np.testing.assert_allclose(result["periodic_damage"], 100./12*(1+2+3+4))

    def test_final_burn_and_bleed_tick_before_expiry(self):
        self.config.update(windows=[7.], ordinary_ailment_chance=100.)
        for family in ("burn", "bleed"):
            p = self.profile(family)
            p.update(resource_max=1., cost=1.)
            result = self.run_profile(p)["windows"][0]
            np.testing.assert_allclose(result["periodic_damage"], 100.)
            np.testing.assert_allclose(result["damage"], 200.)

    def test_family_strength_retained_between_final_tick_and_expiry(self):
        state = {"rate": np.zeros(1), "end": np.zeros(1), "next": np.full(1, np.inf)}
        yes = np.ones(1, bool)
        study._single_application(np.array([100.]), yes, 0., 4., 1., state)
        study._single_application(np.array([200.]), yes, .5, 4., 1., state)
        for t in (1., 2., 3., 4.):
            np.testing.assert_allclose(study._single_due(t, 1., state), 200.)
        self.assertEqual(state["rate"][0], 200.)
        self.assertEqual(state["end"][0], 4.5)
        self.assertEqual(state["next"][0], 5.)
        study._single_application(np.array([50.]), yes, 4.2, 4., 1., state)
        self.assertEqual(state["rate"][0], 200.)
        self.assertEqual(state["end"][0], 4.5)
        study._single_due(4.5, 1., state)
        study._single_application(np.array([50.]), yes, 4.6, 4., 1., state)
        self.assertAlmostEqual(state["next"][0], 5.6)

    def test_tail_refresh_reactivates_preserved_next_tick(self):
        for refreshed_rate in (200., 300.):
            state = {"rate": np.zeros(1), "end": np.zeros(1), "next": np.full(1, np.inf)}
            yes = np.ones(1, bool)
            study._single_application(np.array([100.]), yes, 0., 4., 1., state)
            study._single_application(np.array([200.]), yes, .5, 4., 1., state)
            for t in (1., 2., 3., 4.):
                study._single_due(t, 1., state)
            study._single_application(np.array([refreshed_rate]), yes, 4.2, 4., 1., state)
            self.assertAlmostEqual(state["end"][0], 8.2)
            self.assertEqual(state["next"][0], 5.)
            np.testing.assert_allclose(study._single_due(5., 1., state), refreshed_rate)

    def test_flat_magic_is_not_randomized(self):
        self.config["damage_roll_range"] = [.5, .5]
        p = self.profile()
        p["flat_magic"] = 40.
        result = self.run_profile(p)["windows"][0]
        np.testing.assert_allclose(result["damage"], 90.)

    def test_allocations_conserve_points_and_resource_capacity(self):
        for level, expected in ((1, 10), (10, 28), (30, 68), (60, 128)):
            for allocation in study.ALLOCATIONS:
                physical = study.make_profile(level, allocation, "physical_fast", 0., "heavy", self.config, self.rules)
                magical = study.make_profile(level, allocation, "magic_direct", 0., "heavy", self.config, self.rules)
                self.assertEqual(physical["power_points"]+physical["dexterity_points"], expected)
                self.assertEqual(magical["resource_max"], physical["resource_max"])
                neutral = 100.+2*(level-1)
                self.assertEqual(physical["resource_max"], neutral+physical["power_points"])
                self.assertAlmostEqual(physical["duration"]/physical["base_duration"], magical["duration"]/magical["base_duration"])

    def test_parity_magic_and_physical_source_means(self):
        for allocation in study.ALLOCATIONS:
            p = study.make_profile(60, allocation, "physical_fast", 50., "free", self.config, self.rules)
            m = study.make_profile(60, allocation, "magic_direct", 50., "free", self.config, self.rules)
            self.assertAlmostEqual(p["base_packet"]/p["base_duration"],
                                   (m["base_packet"]+m["flat_magic"])/m["base_duration"])

    def test_dexterity_and_other_speed_share_one_rating_curve(self):
        # Level 21 supplies exactly 50 allocatable points. With all in DEX,
        # the proposed contribution adds 50 to the same pool as 100 other rating.
        for style in ("physical_fast", "magic_direct"):
            profile = study.make_profile(21, "dexterity_only", style, 0., "free",
                                         self.config, self.rules, other_speed=100.)
            self.assertEqual(profile["dexterity_points"], 50)
            self.assertAlmostEqual(profile["duration"]/profile["base_duration"], .64)
            self.assertNotAlmostEqual(profile["duration"]/profile["base_duration"], .8*.7)

    def test_speed_source_split_does_not_change_execution_duration(self):
        for style in ("physical_fast", "magic_direct"):
            dexterity = study.make_profile(21, "dexterity_only", style, 0., "free",
                                           self.config, self.rules, other_speed=100.)
            direct = study.make_profile(21, "power_only", style, 0., "free",
                                        self.config, self.rules, other_speed=150.)
            self.assertAlmostEqual(dexterity["duration"], direct["duration"])

    def test_reproducibility_and_input_immutability(self):
        self.config["damage_roll_range"] = [.8, 1.2]
        profile = self.profile("bleed")
        original = copy.deepcopy(profile)
        first, second = self.run_profile(profile), self.run_profile(profile)
        self.assertEqual(original, profile)
        for a, b in zip(first["windows"], second["windows"]):
            np.testing.assert_array_equal(a["damage"], b["damage"])

    def test_cost_policies_share_exact_outcomes_before_depletion(self):
        self.config["damage_roll_range"] = [.8, 1.2]
        free = self.profile("burn")
        charged = copy.deepcopy(free)
        charged.update(cost_policy="heavy", cost=10.)
        _, free_row = study.job((0, "main", free, 8, self.config, self.rules))
        _, charged_row = study.job((1, "main", charged, 8, self.config, self.rules))
        for key in ("damage_1s", "damage_3s", "damage_5s", "direct_damage_5s", "periodic_damage_5s", "conditional_ttk_median"):
            self.assertEqual(free_row[key], charged_row[key])
        self.assertLess(charged_row["resource_remaining_5s"], free_row["resource_remaining_5s"])

    def test_invalid_inputs_reject(self):
        self.config["windows"] = [5., 1.]
        with self.assertRaises(ValueError):
            study.validate_config(self.config, self.rules)


if __name__ == "__main__":
    unittest.main()
