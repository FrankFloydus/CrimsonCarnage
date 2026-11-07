"""Independent expectations for the bounded leveling-study encounter clocks."""
import copy
import unittest

import numpy as np
import leveling_study as study
import simulator as sim


class LevelingStudyTests(unittest.TestCase):
    def setUp(self):
        self.rules=sim.read_json(sim.DEFAULT_RULES)
        self.config=study.default_config()
        self.config["weapon_roll_range"]=[1,1]
        self.config["horizon"]=10
        self.rng=np.random.default_rng(22)

    def stats(self,school=0):
        p,_=study.draw_profiles(1,1,"none","neutral",7,self.rules,self.config)
        for key,value in {"health":1000.,"absorption":0.,"armor":0.,"evasion":0.,"block":0.,
                          "hit_rating":50.,"critical_chance":0.,"critical_damage":0.,"dot_damage":0.,
                          "penetration":0.,"control_reduction":0.,"cost":0.,"cooldown":0.,"duration":1.,
                          "consumable_policy":0,"is_dot":False,"dot_bleed":False}.items():
            p[key][:]=value
        p["resistance"][:]=0;p["ordinary_chances"][:]=0
        p["raw_base_mean"][:]=0;p["raw_base_mean"][:,school]=100
        p["raw_flat_magic"][:]=0;p["raw_mean"]=p["raw_base_mean"].copy()
        return p

    def state(self,stats):
        return study.State(stats,self.rng,.1,self.rules,self.config)

    def deliver(self,source,target,t=0,step=0):
        study._deliver(source,target,np.ones(1,bool),self.rng,t,step,.1,self.rules,self.config)

    def advance(self,state,t,step=None,delta=.1):
        study._advance(state,t,int(round(t/.1)) if step is None else step,delta,self.rules,self.config)

    def test_lethal_dot_cannot_consume_or_revive(self):
        stats=self.stats();stats["consumable_policy"][:]=1
        target=self.state(stats);target.hp[:]=10
        study._apply_single(target,1,np.array([20.]),np.ones(1,bool),0,6,2)
        self.advance(target,2)
        self.assertEqual(target.hp[0],0)
        self.assertEqual(target.charges[0],3)
        self.assertEqual(target.potions_used[0],0)
        self.assertEqual(target.restored[0],0)

    def test_lethal_poison_cannot_revive(self):
        stats=self.stats();stats["consumable_policy"][:]=1
        target=self.state(stats);target.hp[:]=10;target.poison[10,0]=20
        self.advance(target,1)
        self.assertEqual(target.hp[0],0)
        self.assertEqual(target.potions_used[0],0)

    def test_health_does_not_passively_regenerate(self):
        target=self.state(self.stats());target.hp[:]=500
        self.advance(target,10,delta=10)
        self.assertEqual(target.hp[0],500)

    def test_absorption_protects_first_hit_lethal_indicator(self):
        source=self.state(self.stats());stats=self.stats();stats["absorption"][:]=500
        target=self.state(stats);target.hp[:]=50
        self.deliver(source,target)
        self.assertEqual(target.abs[0],400)
        self.assertEqual(target.hp[0],50)
        self.assertFalse(target.first_hit_lethal[0])
        self.assertEqual(target.first_hit_health_loss[0],0)

    def test_necrotic_first_hit_bypasses_and_kills(self):
        source=self.state(self.stats(5));stats=self.stats();stats["absorption"][:]=500
        target=self.state(stats);target.hp[:]=50
        self.deliver(source,target)
        self.assertEqual(target.abs[0],500)
        self.assertEqual(target.hp[0],0)
        self.assertTrue(target.first_hit_lethal[0])

    def test_critical_guarantees_bleed_but_not_critical_seed(self):
        s=self.stats();s["critical_chance"][:]=100
        source=self.state(s);target=self.state(self.stats())
        self.deliver(source,target)
        self.assertAlmostEqual(target.hp[0],850)
        self.assertAlmostEqual(target.dot_rate[0,1],100/6)
        for t in (2,4,6):self.advance(target,t)
        self.assertAlmostEqual(target.hp[0],750)

    def test_final_tick_precedes_expiration_and_family_clears(self):
        target=self.state(self.stats())
        study._apply_single(target,1,np.array([10.]),np.ones(1,bool),0,6,2)
        for t in (2,4,6):self.advance(target,t)
        self.assertAlmostEqual(target.hp[0],940)
        self.assertEqual(target.dot_rate[0,1],0)
        self.assertTrue(np.isinf(target.dot_next[0,1]))
        study._apply_single(target,1,np.array([10.]),np.ones(1,bool),6,6,2)
        self.assertEqual(target.dot_next[0,1],8)

    def test_stronger_replacement_preserves_tick_and_weaker_cannot_refresh(self):
        target=self.state(self.stats());yes=np.ones(1,bool)
        study._apply_single(target,0,np.array([10.]),yes,0,4,1)
        study._apply_single(target,0,np.array([20.]),yes,.5,4,1)
        self.assertEqual(target.dot_next[0,0],1)
        self.assertEqual(target.dot_end[0,0],4.5)
        study._apply_single(target,0,np.array([5.]),yes,1,4,1)
        self.assertEqual(target.dot_end[0,0],4.5)

    def test_equal_shorter_duration_does_not_truncate(self):
        target=self.state(self.stats());yes=np.ones(1,bool)
        study._apply_single(target,0,np.array([10.]),yes,0,10,1)
        study._apply_single(target,0,np.array([10.]),yes,1,4,1)
        self.assertEqual(target.dot_end[0,0],10)

    def test_absorbed_critical_still_burns(self):
        s=self.stats(1);s["critical_chance"][:]=100
        stats=self.stats();stats["absorption"][:]=500
        source=self.state(s);target=self.state(stats)
        self.deliver(source,target)
        self.assertEqual(target.hp[0],1000)
        self.assertEqual(target.abs[0],350)
        self.assertEqual(target.dot_rate[0,0],25)
        self.advance(target,1)
        self.assertEqual(target.abs[0],325)

    def test_unlimited_poison_queue_exceeds_old_stack_limits(self):
        s=self.stats(5);s["critical_chance"][:]=100
        stats=self.stats();stats["health"][:]=100000
        source=self.state(s);target=self.state(stats)
        for i in range(30):self.deliver(source,target,i*.1,i)
        self.assertAlmostEqual(target.poison.sum(),30*50)

    def test_environmental_period_is_owned_by_source_half_second(self):
        s=self.stats(1);s["is_dot"][:]=True;s["dot_duration"][:]=4;s["dot_period"][:]=.5
        s["raw_base_mean"][:]=0;s["raw_base_mean"][:,1]=10
        source=self.state(s);target=self.state(self.stats())
        self.deliver(source,target)
        self.advance(target,.5)
        self.assertEqual(target.hp[0],995)
        self.assertEqual(target.dot_next[0,2],1)
        for t in np.arange(1,4.01,.5):self.advance(target,float(t))
        self.assertEqual(target.hp[0],960)

    def test_environmental_period_two_seconds_preserves_lifetime_damage(self):
        s=self.stats(1);s["is_dot"][:]=True;s["dot_duration"][:]=10;s["dot_period"][:]=2
        s["raw_base_mean"][:]=0;s["raw_base_mean"][:,1]=10
        source=self.state(s);target=self.state(self.stats())
        self.deliver(source,target)
        self.advance(target,2)
        self.assertEqual(target.hp[0],980)
        self.assertEqual(target.dot_next[0,2],4)
        for t in (4,6,8,10):self.advance(target,t)
        self.assertEqual(target.hp[0],900)

    def test_flat_magic_power_is_not_randomized(self):
        self.config["weapon_roll_range"]=[.5,.5]
        stats=self.stats(1);stats["raw_flat_magic"][:,1]=40
        source=self.state(stats);target=self.state(self.stats())
        self.deliver(source,target)
        self.assertEqual(target.hp[0],910) # 100*.5 +40, not(100+40)*.5.

    def test_exact_absorption_delay_does_not_recover_early(self):
        stats=self.stats();stats["absorption"][:]=500
        target=self.state(stats);target.abs[:]=0;target.last_hit[:]=0
        self.advance(target,3,delta=.1)
        self.assertEqual(target.abs[0],0)
        self.advance(target,4,delta=1)
        self.assertEqual(target.abs[0],50)

    def test_hollowed_suppresses_only_overlap_with_recharge(self):
        stats=self.stats();stats["absorption"][:]=500
        target=self.state(stats);target.abs[:]=0;target.last_hit[:]=0
        target.hollow[:]=.3;target.hollow_end[:]=6
        self.advance(target,7,delta=7)
        self.assertAlmostEqual(target.abs[0],155) # 3s*.7*50 +1s*50.

    def test_hollowed_reduces_finite_consumable_health(self):
        stats=self.stats();stats["consumable_policy"][:]=1
        target=self.state(stats);target.hp[:]=300
        target.hollow[:]=.3;target.hollow_end[:]=6
        self.advance(target,1)
        self.assertEqual(target.hp[0],545)
        self.assertEqual(target.charges[0],2)

    def test_consumable_counterfactual_is_paired(self):
        config=copy.deepcopy(self.config);config["builds_per_context"]=4;config["repeats"]=1
        rows,_,_,checks=study.job((config,self.rules,1,"none","neutral",7))
        counts=[r["trajectories"] for r in rows if r["axis"]=="consumables"]
        self.assertEqual(counts,[4,4])
        self.assertEqual(checks["primary_budget_failures"],0)

    def test_budget_and_specialist_anchors(self):
        p,_=study.draw_profiles(64,60,"high","neutral",7,self.rules,self.config)
        budget=(12+.55*59)*1.65
        np.testing.assert_allclose(p["funding"].sum(axis=1),budget)
        np.testing.assert_allclose(p["primary"].sum(axis=1),128)
        joint=len(study.FUNDING)
        self.assertGreaterEqual(p["armor"][joint],1000)
        self.assertGreaterEqual(p["evasion"][joint],1000)
        self.assertEqual(p["block"][joint],.9)
        self.assertGreater(p["mana_regen"][study.FUNDING.index("mana_regen")],13.08)

    def test_primary_contributions_follow_shared_rules(self):
        rules=copy.deepcopy(self.rules)
        rules.update(dexterity_hit_rating_per_point=2,intellect_magic_power_per_point=3,
                     strength_stamina_per_point=4,intellect_mana_per_point=5,
                     base_mana=500,mana_per_level=3)
        p,_=study.draw_profiles(64,30,"none","neutral",7,rules,self.config)
        np.testing.assert_allclose(p["hit_rating"],p["primary"][:,1]*2)
        np.testing.assert_allclose(p["magic_power"],p["primary"][:,2]*3)
        np.testing.assert_allclose(p["stamina"],158+p["primary"][:,0]*4)
        np.testing.assert_allclose(p["mana"],587+p["primary"][:,2]*5)

    def test_action_overshoot_preserves_high_speed_cadence(self):
        self.config["horizon"]=30
        for rating,expected in ((0,30),(100,46),(500,72),(20000,99)):
            for dt in (.1,.05,.025):
                with self.subTest(rating=rating,dt=dt):
                    self.config["dt"]=dt
                    source=self.stats();target=self.stats()
                    source["duration"][:]=sim.rating_duration(1.,.3,rating,self.rules)
                    target["duration"][:]=1e9
                    source["raw_base_mean"][:]=0;target["raw_base_mean"][:]=0
                    result=study.simulate(source,target,self.rules,self.config,57)
                    self.assertEqual(result["hits"][0],expected)

    def test_weapon_minimums_preserve_equal_dps_speed_scaling(self):
        p,_=study.draw_profiles(64,60,"high","neutral",7,self.rules,self.config)
        np.testing.assert_allclose(p["minimum_duration"],.4*p["base_duration"])
        for rating in (0,100,500,20000,1e9):
            fast=50/sim.rating_duration(.5,.2,rating,self.rules)
            slow=200/sim.rating_duration(2.,.8,rating,self.rules)
            self.assertAlmostEqual(float(fast),float(slow),places=9)

    def test_resource_wait_discards_unused_completion_progress(self):
        source=self.state(self.stats());target=self.state(self.stats())
        source.progress[:]=1.4;source.st[:]=0;source.mp[:]=0;source.stats["cost"][:]=10
        study._actions(source,target,.1)
        self.assertEqual(source.progress[0],0)
        self.assertFalse(source.active[0])
        source.st[:]=100;source.mp[:]=100
        study._actions(source,target,.1)
        self.assertAlmostEqual(source.progress[0],.1)

    def test_cooldown_wait_discards_unused_completion_progress(self):
        source=self.state(self.stats());target=self.state(self.stats())
        source.progress[:]=1.4;source.cooldown[:]=.5
        study._actions(source,target,.1)
        self.assertEqual(source.progress[0],0)
        source.cooldown[:]=0
        study._actions(source,target,.1)
        self.assertAlmostEqual(source.progress[0],.1)

    def test_chill_slows_existing_action_without_resetting_progress(self):
        source=self.state(self.stats());target=self.state(self.stats())
        source.active[:]=True;source.progress[:]=.4;source.chill[:]=.2
        study._actions(source,target,.1)
        self.assertAlmostEqual(source.progress[0],.48)


if __name__=="__main__":unittest.main()
