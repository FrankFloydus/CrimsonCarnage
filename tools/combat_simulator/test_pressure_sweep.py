"""Current pressure primitives and rejection of retired encounter schemas."""
import unittest

import numpy as np

import simulator as sim
import pressure_sweep as sweep


class PressureSweepTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)
        self.pressure = sim.read_json(sim.HERE / "pressure_scenarios.json")
        self.config = sweep.extended_config(sim.read_json(sim.HERE / "scenarios.json"), self.pressure)

    def test_retired_pressure_generators_reject_current_rules_before_sampling(self):
        calls = (
            lambda: sweep.sample_builds(1, np.random.default_rng(1), 0, "initial",
                                        self.rules, self.config, 1, 0),
            lambda: sweep.derive_stats({}, self.rules, self.config),
            lambda: sweep.sample_targets(1, np.random.default_rng(1), 1, self.rules, self.pressure),
            lambda: sweep.simulate_incoming({}, {}, {}, np.random.default_rng(1),
                                            self.rules, self.pressure),
            lambda: sweep.simulate_outgoing({}, {}, {}, np.random.default_rng(1),
                                            self.rules, self.pressure),
        )
        for call in calls:
            with self.subTest(call=call), self.assertRaisesRegex(ValueError, "historical report"):
                call()

    def test_periodic_event_planner_includes_final_tick_and_orders_before_same_time_hit(self):
        pattern = {"channels": [
            {"kind": "dot", "damage_type": "fire", "duration": 6, "period": 2},
            {"kind": "hit", "damage_type": "physical", "interval": 2,
             "first_event": "after_interval"},
        ]}
        events = sweep._event_plan(pattern, 6)
        self.assertEqual(events, [(2, 0, 0, "dot"), (2, 1, 1, "hit"),
                                  (4, 0, 0, "dot"), (4, 1, 1, "hit"),
                                  (6, 0, 0, "dot"), (6, 1, 1, "hit")])

    def test_event_horizon_does_not_execute_future_ticks(self):
        pattern = {"channels": [
            {"kind": "dot", "damage_type": "fire", "duration": 10, "period": 2},
        ]}
        self.assertEqual([row[0] for row in sweep._event_plan(pattern, 5)], [2, 4])

    def test_entropy_stream_preserves_per_trial_avoidance_counts(self):
        count = 100_000
        rng = np.random.default_rng(8012)
        entropy = rng.random(count)
        last = np.zeros(count)
        evades = np.zeros(count, dtype=np.int16)
        hits = np.zeros(count, dtype=np.int16)
        for index in range(100):
            landed, evaded, blocked = sweep._attack_check(
                np.ones(count, dtype=bool), entropy, last, index * .1,
                np.full(count, .75), np.zeros(count), rng, self.rules, {})
            evades += evaded
            hits += landed
            self.assertFalse(np.any(blocked))
        np.testing.assert_array_equal(evades, 75)
        np.testing.assert_array_equal(hits, 25)

    def test_block_is_independent_after_entropy_dodge(self):
        count = 100_000
        rng = np.random.default_rng(7041)
        entropy = rng.random(count)
        landed, evaded, blocked = sweep._attack_check(
            np.ones(count, dtype=bool), entropy, np.zeros(count), 0,
            np.full(count, .75), np.full(count, .9), rng, self.rules, {})
        self.assertLess(abs(np.mean(evaded) - .75), .006)
        self.assertLess(abs(np.mean(blocked) - .225), .006)
        self.assertLess(abs(np.mean(landed) - .025), .003)
        np.testing.assert_array_equal(landed.astype(int) + evaded + blocked, 1)

    def test_capped_hit_rating_does_not_bypass_avoidance(self):
        count = 100_000
        rng = np.random.default_rng(650)
        connected, evaded, blocked = sweep._attack_check(
            np.ones(count, dtype=bool), rng.random(count), np.zeros(count), 0,
            np.full(count, .75), np.full(count, .9), rng, self.rules, {})
        chance = sim.hit_chance(1, 60, np.full(count, 1e20), self.rules)
        landed = sim.hit_mask(connected, chance, sim.quality_random(rng))
        np.testing.assert_array_equal(landed, connected)
        self.assertGreater(np.mean(evaded | blocked), .97)

    def test_necrotic_and_bleed_pressure_reach_health_while_other_dots_use_absorption(self):
        school = np.array(["fire", "physical", "physical", "necrotic"])
        bleed = np.array([False, False, True, False])
        remaining, health, absorbed = sim.absorption_damage(100, 500, school, bleed)
        np.testing.assert_array_equal(remaining, [400, 400, 500, 500])
        np.testing.assert_array_equal(health, [0, 0, 100, 100])
        np.testing.assert_array_equal(absorbed, [100, 100, 0, 0])

    def test_hollowed_changes_sustain_threshold_for_a_covered_dot(self):
        ordinary = float(sim.absorption_regeneration(500, self.rules))
        hollowed = float(sim.absorption_regeneration(500, self.rules, .3))
        self.assertEqual(ordinary - 40, 10)
        self.assertEqual(hollowed - 40, -5)
        # No HP regeneration is added to conceal the bypass damage.
        self.assertNotIn("base_health_regen", self.rules)

    def test_independent_accuracy_stream_does_not_advance_defense_rng(self):
        rng = np.random.default_rng(200)
        state = repr(rng.bit_generator.state)
        independent = sim.quality_random(rng)
        sim.hit_mask(np.ones(1000, dtype=bool), .5, independent)
        self.assertEqual(repr(rng.bit_generator.state), state)

    def test_historical_pressure_config_validation_still_rejects_invalid_clocks(self):
        sweep.validate_pressure_config(self.pressure)
        import copy
        invalid = copy.deepcopy(self.pressure)
        invalid["outgoing_patterns"][0]["minimum_action_duration"] = 0
        with self.assertRaises(ValueError):
            sweep.validate_pressure_config(invalid)


if __name__ == "__main__":
    unittest.main()
