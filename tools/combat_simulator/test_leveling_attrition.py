"""Persistent-chain expectations independent of aggregate campaign assumptions."""
import copy
import unittest
from unittest.mock import patch

import numpy as np

import leveling_attrition as chains
import leveling_study as study
import simulator as sim


class AttritionTests(unittest.TestCase):
    def setUp(self):
        self.rules = sim.read_json(sim.DEFAULT_RULES)
        self.config = chains.default_config()
        self.config.update(encounters=3, fight_horizon=8, builds_per_context=1)
        self.experiment = chains.experiment_config(self.config, 0)
        self.experiment["weapon_roll_range"] = [1, 1]

    def stats(self, count=1, school=0):
        values, _ = study.draw_profiles(
            count, 1, "none", "neutral", 19, self.rules, self.experiment
        )
        overrides = {
            "health": 1000., "absorption": 0., "armor": 0., "evasion": 0.,
            "block": 0., "hit_rating": 50., "critical_chance": 0.,
            "critical_damage": 0., "dot_damage": 0., "penetration": 0.,
            "control_reduction": 0., "cost": 0., "cooldown": 0.,
            "duration": 1., "base_duration": 1., "is_dot": False,
            "dot_duration": 0., "dot_period": 1., "dot_bleed": False,
            "kind_attack": True, "consumable_policy": 1,
            "stamina": 100., "mana": 100., "stamina_regen": 0., "mana_regen": 0.,
        }
        for key, amount in overrides.items():
            values[key][:] = amount
        values["level"][:] = 1
        values["resistance"][:] = 0
        values["ordinary_chances"][:] = 0
        values["raw_base_mean"][:] = 0
        values["raw_base_mean"][:, school] = 100
        values["raw_flat_magic"][:] = 0
        values["raw_mean"] = values["raw_base_mean"].copy()
        return values

    def run_fixture(self, player, enemy):
        with patch.object(study, "draw_enemy", side_effect=lambda *args: copy.deepcopy(enemy)):
            return chains.run_chain(player, self.rules, self.experiment, self.config, 81)

    def test_health_loss_persists_between_fights(self):
        player, enemy = self.stats(), self.stats()
        enemy["health"][:] = 1
        enemy["duration"][:] = .2
        enemy["raw_base_mean"][:, 0] = 10
        result = self.run_fixture(player, enemy)
        self.assertEqual(result["kills"][0], 3)
        self.assertTrue(result["completed"][0])
        self.assertLess(result["rows"][1]["mean_start_health_fraction"], 1)
        self.assertLess(result["rows"][2]["mean_start_health_fraction"], result["rows"][1]["mean_start_health_fraction"])
        self.assertEqual(result["health_restored"][0], 0)

    def test_paid_stamina_is_not_reset(self):
        player, enemy = self.stats(), self.stats()
        player["cost"][:] = 10
        enemy["health"][:] = 1
        enemy["raw_base_mean"][:] = 0
        result = self.run_fixture(player, enemy)
        self.assertEqual(result["kills"][0], 3)
        self.assertEqual(result["stamina"][0], 70)

    def test_consumable_charges_are_never_refilled(self):
        player, enemy = self.stats(), self.stats()
        player["health"][:] = 100
        enemy["health"][:] = 1
        enemy["duration"][:] = .2
        enemy["raw_base_mean"][:, 0] = 30
        self.experiment["consumables"]["charges"] = 1
        result = self.run_fixture(player, enemy)
        self.assertEqual(result["potions_used"][0], 1)
        self.assertEqual(result["charges"][0], 0)
        self.assertLess(result["kills"][0], 3)

    def test_lingering_poison_can_kill_after_enemy_dies(self):
        player, enemy = self.stats(), self.stats(school=5)
        player["health"][:] = 100
        enemy["health"][:] = 1
        enemy["duration"][:] = .2
        enemy["raw_base_mean"][:, 5] = 20
        enemy["critical_chance"][:] = 100
        result = self.run_fixture(player, enemy)
        self.assertEqual(result["kills"][0], 1)
        self.assertTrue(result["rest_deaths"][0])
        self.assertFalse(result["combat_deaths"][0])
        self.assertFalse(result["completed"][0])

    def test_early_winner_does_not_receive_other_rows_extra_rest(self):
        player, enemy = self.stats(2), self.stats(2)
        player["cost"][:] = 20
        player["stamina_regen"][:] = 1
        enemy["health"][:] = [1, 300]
        enemy["raw_base_mean"][:] = 0
        self.config["encounters"] = 1
        result = self.run_fixture(player, enemy)
        self.assertTrue(np.all(result["completed"]))
        self.assertAlmostEqual(result["stamina"][0], 90.6, places=8)
        self.assertLess(result["stamina"][0], 92)

    def test_timeout_is_not_a_kill_or_death(self):
        player, enemy = self.stats(), self.stats()
        player["raw_base_mean"][:] = 0
        enemy["raw_base_mean"][:] = 0
        result = self.run_fixture(player, enemy)
        self.assertTrue(result["timeouts"][0])
        self.assertEqual(result["kills"][0], 0)
        self.assertFalse(result["combat_deaths"][0])
        self.assertFalse(result["rest_deaths"][0])

    def test_short_rest_cannot_silently_discard_ailments(self):
        self.config["interfight_seconds"] = 2
        with self.assertRaisesRegex(ValueError, "longest retained effect"):
            chains.validate_config(self.config, self.rules, self.experiment)


if __name__ == "__main__":
    unittest.main()
