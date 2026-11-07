"""Independent expectations for matched offensive investment experiments."""
import copy
import unittest

import numpy as np

import offense_study as study
import simulator as sim


class OffensiveStudyTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)
        self.config = study.default_config()
        self.config.update(windows=[1., 3., 7.], target_health=[100., 250., 1000.],
                           physical_armor=[0.], magic_resistance=[0.], target_absorption=[0., 100.],
                           damage_roll_range=[1., 1.])

    def profile(self, style="physical_fast"):
        profile = study.make_profile(1, .5, style, "mixed", 0, 0., "reference", "free", 50., self.config, self.rules)
        profile.update(base_packet=100., flat_magic=0., duration=1., hit_chance=1.,
                       resource_max=100., resource_regen=0., cost=0., critical_chance=0.,
                       ordinary_chance=0., dot_damage=0.)
        return profile

    def run_profile(self, profile):
        return study.simulate(profile, self.config, self.rules, 4, 7)

    def test_primary_and_secondary_budgets_are_separate_and_conserved(self):
        for level in (1, 10, 30, 60):
            for focus in study.STRATEGIES:
                p = study.make_profile(level, .8, "physical_fast", focus, 2, 75., "reference", "free", 0., self.config, self.rules)
                self.assertEqual(p["primary_power"]+p["primary_dex"], study.dex.point_budget(level, self.rules))
                self.assertAlmostEqual(sum(p["spending"].values()), 75.)
                self.assertLessEqual(p["critical_chance"], 100.+1e-8)
                self.assertLessEqual(p["ordinary_chance"], 100.+1e-8)

    def test_no_budget_cap_waste_refunds_to_power(self):
        units = self.config["units_per_credit"]
        weights = np.zeros(len(study.STATS))
        weights[study.STATS.index("ailment_chance")] = 1
        spend = study.fund_stats(weights, 75., 0., 0., units, self.config)
        self.assertEqual(spend["ailment_chance"], 40.)
        self.assertEqual(spend["power"], 35.)
        weights[:] = 0; weights[study.STATS.index("hit")] = 1
        spend = study.fund_stats(weights, 75., 60., 0., units, self.config)
        self.assertEqual(spend["hit"], 0.)
        self.assertEqual(spend["power"], 75.)

    def test_hit_focused_still_has_automatic_ailments(self):
        p = study.make_profile(1, .8, "fire_spell", "hit_focused", 1, 25., "reference", "free", 0., self.config, self.rules)
        self.assertEqual(p["family"], "burn")
        self.assertEqual(p["ordinary_chance"], 20.)
        self.assertEqual(p["dot_damage"], 0.)

    def test_exact_damage_and_multiple_ttk_thresholds(self):
        result = self.run_profile(self.profile())
        np.testing.assert_allclose(result["ttk"][0, 0], .6)
        np.testing.assert_allclose(result["ttk"][1, 0], 2.6)
        self.assertTrue(np.isinf(result["ttk"][2]).all())
        np.testing.assert_allclose(result["snapshots"][-1]["direct"][0], 700.)

    def test_absorption_stops_covered_damage_but_necrotic_bypasses(self):
        p = self.profile("magic_direct")
        covered = self.run_profile(p)
        np.testing.assert_allclose(covered["snapshots"][0]["absorbed"][1], 100.)
        np.testing.assert_allclose(covered["snapshots"][0]["health"][1], 0.)
        p = self.profile("necrotic_spell")
        bypass = self.run_profile(p)
        np.testing.assert_allclose(bypass["snapshots"][0]["absorbed"][1], 0.)
        np.testing.assert_allclose(bypass["snapshots"][0]["health"][1], 100.)

    def test_mitigation_applies_once_to_hit_and_bleed(self):
        self.config.update(physical_armor=[1000.], target_absorption=[0.], windows=[7.])
        p = self.profile(); p.update(cost=1., resource_max=1., ordinary_chance=100.)
        result = self.run_profile(p)["snapshots"][0]
        np.testing.assert_allclose(result["direct"], 25.)
        np.testing.assert_allclose(result["periodic"], 25.)

    def test_bleed_bypasses_absorption_and_crit_seed_is_noncritical(self):
        p = self.profile(); p.update(cost=1., resource_max=1., critical_chance=100.)
        result = self.run_profile(p)["snapshots"][-1]
        np.testing.assert_allclose(result["direct"][0], 150.)
        np.testing.assert_allclose(result["periodic"][0], 100.)
        np.testing.assert_allclose(result["health"][1], 150.)

    def test_poison_linear_independent_applications(self):
        p = self.profile("necrotic_spell"); p["ordinary_chance"] = 100.
        result = self.run_profile(p)["snapshots"][-1]
        np.testing.assert_allclose(result["periodic"][0], 100/12*(1+2+3+4+5+6))

    def test_target_health_never_changes_damage(self):
        p = self.profile("fire_spell"); p["ordinary_chance"] = 100.
        first = self.run_profile(p)
        self.config["target_health"] = [1., 1e8]
        second = self.run_profile(p)
        for a, b in zip(first["snapshots"], second["snapshots"]):
            np.testing.assert_array_equal(a["direct"], b["direct"])
            np.testing.assert_array_equal(a["periodic"], b["periodic"])

    def test_single_family_refresh_phase_reused(self):
        state = {"rate": np.zeros((2, 2)), "end": np.zeros((2, 2)), "next": np.full((2, 2), np.inf)}
        proc = np.ones((2, 2), bool)
        study.dex._single_application(np.full((2, 2), 100.), proc, 0, 4, 1, state)
        study.dex._single_application(np.full((2, 2), 200.), proc, .5, 4, 1, state)
        for t in (1, 2, 3, 4): study.dex._single_due(t, 1, state)
        study.dex._single_application(np.full((2, 2), 200.), proc, 4.2, 4, 1, state)
        np.testing.assert_allclose(state["next"], 5.)
        np.testing.assert_allclose(study.dex._single_due(5, 1, state), 200.)

    def test_speed_contributions_sum_once(self):
        fixture = study.speed_fixture(self.rules)
        row = next(r for r in fixture["arithmetic"] if r["dexterity_speed_rating"] == 50 and r["other_speed_rating"] == 100)
        self.assertAlmostEqual(row["correct_duration"], .64)
        self.assertAlmostEqual(row["incorrect_multiplied_duration"], .56)

    def test_five_on_five_off_preserves_ticks_and_resource_regeneration(self):
        starts, releases, _ = study.windowed_action_schedule(2., 10., 1., 6., 15.)
        np.testing.assert_allclose(starts, [0., 2., 10.])
        np.testing.assert_allclose(releases, [1.2, 3.2, 11.2])
        self.config["windows"] = [5., 9., 15.]
        p = self.profile("necrotic_spell")
        p.update(availability="five_on_five_off", ordinary_chance=100.)
        result = self.run_profile(p)["snapshots"]
        self.assertGreater(result[1]["periodic"][0].mean(), result[0]["periodic"][0].mean())
        np.testing.assert_allclose(result[1]["direct"], result[0]["direct"])

    def test_paired_reproducibility_and_immutability(self):
        self.config["damage_roll_range"] = [.8, 1.2]
        p = self.profile("fire_spell"); p["ordinary_chance"] = 100.
        before = copy.deepcopy(p)
        a, b = self.run_profile(p), self.run_profile(p)
        self.assertEqual(before, p)
        np.testing.assert_array_equal(a["snapshots"][-1]["health"], b["snapshots"][-1]["health"])


if __name__ == "__main__":
    unittest.main()
