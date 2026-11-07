#!/usr/bin/env python3
"""Reproducible fixed-contact leveling pressure experiment; no desktop access.

Raw-stat funding, weapon envelopes, enemy content and consumables are explicit
experimental inputs, not approved itemization. A bounded time grid models two
combatants, automatic ailments, finite resources and finite Health consumables.
Shared combat formulae come from simulator.py and the game's current rules.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
import numpy as np
import simulator as sim

HERE = Path(__file__).resolve().parent
SCHOOLS = ("physical", "fire", "cold", "lightning", "void", "necrotic")
STYLES = ("physical_fast", "physical_slow", "fire", "cold", "lightning", "void", "necrotic", "hybrid")
FUNDING = ("health", "absorption", "armor", "evasion", "block", "hit_rating", "magic_power",
           "strength", "dexterity", "intellect", "vitality", "critical_chance", "critical_damage",
           "dot_damage", "speed_rating", "cooldown_recovery", "armor_penetration",
           "fire_resistance", "cold_resistance", "lightning_resistance", "void_resistance",
           "necrotic_resistance", "ailment_chance", "max_stamina", "max_mana", "resolve",
           "stamina_regen", "mana_regen")


def default_config():
    return {
        "description": "Experimental raw-stat budget study, not itemization or AI/movement balance.",
        "seed": 20261106, "levels": list(range(1, 61)), "builds_per_context": 2048,
        "repeats": 2, "dt": .1, "horizon": 45.0,
        "coherent_fraction": .5,
        "gear_tiers": {"none": 0.0, "low": .45, "standard": 1.0, "high": 1.65},
        "funding_budget": {"base": 12.0, "per_level": .55},
        "prices": {
            "neutral": {},
            "defense_expensive": {k: 1.6 for k in ("health", "absorption", "armor", "evasion", "block", *[s+"_resistance" for s in SCHOOLS[1:]])},
            "offense_expensive": {k: 1.6 for k in ("magic_power", "strength", "intellect", "critical_chance", "critical_damage", "dot_damage", "speed_rating", "ailment_chance")},
            "absorption_expensive": {"absorption": 2.0},
        },
        "unit_values": {
            "health": [8, .30], "absorption": [8, .30], "armor": [15, 1], "evasion": [15, 1],
            "block": [2, 0], "hit_rating": [3, .10], "magic_power": [2, .05],
            "strength": [1, .03], "dexterity": [1, .03], "intellect": [1, .03], "vitality": [1, .03],
            "critical_chance": [1.5, 0], "critical_damage": [5, 0], "dot_damage": [8, 0],
            "speed_rating": [8, 0], "cooldown_recovery": [8, 0],
            "armor_penetration": [3, 0], **{s+"_resistance": [3, 0] for s in SCHOOLS[1:]},
            "ailment_chance": [4, 0], "max_stamina": [5, .12], "max_mana": [5, .12],
            "resolve": [2, 0],
            "stamina_regen": [1.5, .03], "mana_regen": [1, .02],
        },
        "level_gap_cases": [-5, -3, -1, 0, 0, 0, 1, 2, 3, 5, 6, 10],
        "weapon_intrinsic_dps_scales": [.7, 1.0, 1.3],
        "player_base_dps_fraction_of_level_health": .15,
        "weapon_roll_range": [.7, 1.3], "magic_power_coefficient_per_base_second": .7,
        "minimum_duration_fraction": .4,
        "basic_stamina_cost_policies": {"free": 0.0, "low": 1.0},
        "low_basic_stamina_cost": [6.0, .05],
        "spell_mana_cost_fraction_per_base_second": .07,
        "spell_cost_scales": [.75, 1., 1.5, 2.],
        "consumables": {"charges": 3, "restore_fraction": .35, "threshold": .35, "cooldown": 8.0},
        "enemy_patterns": [
            {"id": "physical_fast", "family": "fast_physical", "school": 0, "interval": .6, "pressure": .12},
            {"id": "physical_medium", "family": "medium_physical", "school": 0, "interval": 1.2, "pressure": .12},
            {"id": "physical_big", "family": "big_slow_hit", "school": 0, "interval": 3.0, "pressure": .16},
            {"id": "fire_fast", "family": "small_spell_hits", "school": 1, "interval": .5, "pressure": .12},
            {"id": "fire_big", "family": "big_spell_hit", "school": 1, "interval": 3.0, "pressure": .16},
            {"id": "cold", "family": "cold_control", "school": 2, "interval": 1.0, "pressure": .12},
            {"id": "lightning", "family": "lightning_crit", "school": 3, "interval": 1.2, "pressure": .12},
            {"id": "void", "family": "void_recovery", "school": 4, "interval": 1.2, "pressure": .12},
            {"id": "necrotic", "family": "necrotic_poison", "school": 5, "interval": .8, "pressure": .12},
            {"id": "hybrid", "family": "hybrid", "school": -1, "interval": 1.0, "pressure": .14},
            {"id": "fire_dot_fast", "family": "short_fast_dot", "school": 1, "interval": 4., "pressure": .12, "dot": True, "duration": 4., "period": .5},
            {"id": "fire_dot_slow", "family": "long_slow_dot", "school": 1, "interval": 10., "pressure": .12, "dot": True, "duration": 10., "period": 2.},
            {"id": "necro_dot_fast", "family": "bypass_short_dot", "school": 5, "interval": 4., "pressure": .12, "dot": True, "duration": 4., "period": .5},
            {"id": "bleed_dot_huge", "family": "bypass_huge_dot", "school": 0, "interval": 8., "pressure": .24, "dot": True, "duration": 4., "period": 1., "bleed": True},
            {"id": "physical_dot_long", "family": "covered_physical_dot", "school": 0, "interval": 10., "pressure": .12, "dot": True, "duration": 10., "period": 2.},
        ],
        "enemy_health_multipliers": [.8, 1.2, 2.0],
        "enemy_armor_ratings_at60": [0, 150, 400, 1000],
        "enemy_school_resistances": [-20, 0, 20, 40, 80],
        "enemy_evasion_at60": [0, 100, 300], "enemy_block_chances": [0, 0, 20, 40],
        "enemy_absorption_health_fractions": [0, 0, .3, .8],
        "enemy_hit_ratings": [0, 25, 50], "enemy_critical_chances": [5, 10, 20],
        "enemy_armor_penetration": [0, 0, 25, 100],
        "resolve_cases": [0, 0, 20, 40],
        "player_encumbrance_cases": [0, 0, .75, 1.0, 1.25],
        "ordinary_envelope": {"health_multiplier_max":1.2,"armor_at60_max":150,
                              "evasion_at60_max":100,"block_max":20,"resistance_max":40,
                              "absorption_fraction_max":.3,"penetration_max":25,
                              "excluded_patterns":["physical_big","fire_big","bleed_dot_huge"]},
    }


def _allocate(weights, points):
    raw = weights / weights.sum(axis=1, keepdims=True) * points
    result = np.floor(raw)
    remainder = (points-result.sum(axis=1)).astype(int)
    order = np.argsort(-(raw-result), axis=1)
    for j in range(4):
        rows = np.flatnonzero(remainder > j)
        result[rows, order[rows, j]] += 1
    return result


def _base_health(level, rules):
    return rules["base_health"] + rules["health_per_level"] * (np.asarray(level)-1)


def draw_profiles(n, level, tier, price, seed, rules, config):
    """Generate conserved funding draws; price variants share underlying draws."""
    if "efficiency" in config.get("unit_values", {}) or "resolve" not in config.get("unit_values", {}) \
            or "resolve_cases" not in config:
        raise ValueError("This funding configuration predates Resolve and retired Mana/Stamina Efficiency. "
                         "Use current defaults; preserve old reports with their source snapshots.")
    rng = np.random.default_rng(np.random.SeedSequence([seed, level, list(config["gear_tiers"]).index(tier)]))
    style = rng.integers(0, len(STYLES), n)
    coherent=np.arange(n)>=int(n*(1-config["coherent_fraction"]))
    primary_weights=rng.gamma(.3,1,(n,4))
    aligned_shapes=np.where((style<2)[:,None],np.array([2.,.6,.05,.8]),np.array([.05,.6,2.,.8]))
    aligned_shapes[style==7]=[1.,.6,1.,.8]
    primary_weights[coherent]=rng.gamma(aligned_shapes[coherent],1)
    primary = _allocate(primary_weights, int(rules["creation_points"]+rules["points_per_level"]*(level-1)))
    budget = (config["funding_budget"]["base"]+config["funding_budget"]["per_level"]*(level-1))*config["gear_tiers"][tier]
    weights = rng.gamma(.35, 1, (n, len(FUNDING)))
    physical=(style<2); magic=~physical; attack=physical|(style==7)
    relevant={"magic_power":magic,"intellect":magic,"strength":physical|(style==7),
              "armor_penetration":physical|(style==7),"cooldown_recovery":~attack,
              "max_stamina":attack,"stamina_regen":attack,"max_mana":~attack,"mana_regen":~attack}
    for key,mask in relevant.items():weights[coherent&~mask,FUNDING.index(key)]=0
    # Deliberate single-stat and joint-defense probes supplement random draws.
    # They conserve the exact same funding budget as every other profile.
    anchors=min(n,len(FUNDING))
    weights[:anchors]=np.eye(len(FUNDING))[:anchors]
    extra_anchors=[{"armor":1000/(config["unit_values"]["armor"][0]+config["unit_values"]["armor"][1]*level),
                    "evasion":1000/(config["unit_values"]["evasion"][0]+config["unit_values"]["evasion"][1]*level),
                    "block":90/config["unit_values"]["block"][0]},
                   {"absorption":.4,"evasion":.25,"block":.35},
                   {s+"_resistance":1 for s in SCHOOLS[1:]},
                   {"critical_chance":.4,"critical_damage":.3,"magic_power":.3},
                   {"dot_damage":.5,"ailment_chance":.2,"magic_power":.3},
                   {"stamina_regen":1/3,"mana_regen":1/3,"speed_rating":1/3}]
    for j,entry in enumerate(extra_anchors,len(FUNDING)):
        if j>=n:break
        weights[j]=0
        for key,value in entry.items():weights[j,FUNDING.index(key)]=value
    anchor=np.arange(n)<len(FUNDING)+len(extra_anchors)
    coherent[anchor]=False
    funding = weights / weights.sum(axis=1, keepdims=True) * budget
    units = np.array([config["unit_values"][k][0]+config["unit_values"][k][1]*level for k in FUNDING])
    prices = np.array([config["prices"][price].get(k, 1) for k in FUNDING])
    values = funding * units / prices
    gear = dict(zip(FUNDING, values.T))
    primary_final = primary + np.column_stack([gear[k] for k in ("strength", "dexterity", "intellect", "vitality")])
    hp_base = float(_base_health(level, rules))
    stamina_base = rules["base_stamina"]+rules["stamina_per_level"]*(level-1)
    mana_base = rules["base_mana"]+rules["mana_per_level"]*(level-1)
    p = {
        "level": np.full(n, level), "style": style, "cohort":coherent.astype(int), "anchor":anchor,
        "primary": primary, "funding": funding,
        "health": hp_base*(1+rules["vitality_health_per_point"]*primary_final[:, 3])+gear["health"],
        "absorption": gear["absorption"], "stamina": stamina_base+primary_final[:, 0]*rules["strength_stamina_per_point"]+gear["max_stamina"],
        "mana": mana_base+primary_final[:, 2]*rules["intellect_mana_per_point"]+gear["max_mana"],
        "stamina_regen": rules["stamina_regen_base"]+rules["stamina_regen_per_level"]*(level-1)+gear["stamina_regen"],
        "mana_regen": rules["mana_regen_base"]+rules["mana_regen_per_level"]*(level-1)+gear["mana_regen"],
        "armor": gear["armor"], "evasion": gear["evasion"]+primary_final[:, 1]*rules["dexterity_evasion_per_point"],
        "block": np.clip(gear["block"], 0, rules["block_chance_max"])/100,
        "hit_rating": gear["hit_rating"]+primary_final[:, 1]*rules["dexterity_hit_rating_per_point"],
        "magic_power": gear["magic_power"]+primary_final[:, 2]*rules["intellect_magic_power_per_point"],
        "critical_chance": np.clip(rules["critical_chance_base"]+gear["critical_chance"], 0, 100),
        "critical_damage": gear["critical_damage"], "dot_damage": gear["dot_damage"],
        "penetration": np.clip(gear["armor_penetration"], 0, 100),
        "control_reduction": np.clip(gear["resolve"],0,rules["resolve_max"])/100,
        "is_dot": np.zeros(n, bool), "dot_duration": np.zeros(n), "dot_period": np.ones(n), "dot_bleed": np.zeros(n, bool),
        "school": np.full(n, -1),
    }
    p["resistance"] = np.column_stack([np.zeros(n)]+[np.clip(gear[s+"_resistance"], rules["resistance_min"], rules["resistance_max"])/100 for s in SCHOOLS[1:]])
    p["ordinary_chances"] = np.full((n, 6), float(rules.get("ailment_chance_base",20)))
    school = np.where(style < 2, 0, np.minimum(style-1, 5))
    school[style == 7] = 0
    p["ordinary_chances"][np.arange(n), school] += gear["ailment_chance"]
    p["ordinary_chances"] = np.clip(p["ordinary_chances"], 0, 100)
    p["base_duration"] = np.choose(style, [.5, 2., 1.25, 1.25, 1.25, 1.25, 1.25, 1.])
    p["kind_attack"] = (style < 2) | (style == 7)
    minimum = p["base_duration"]*config["minimum_duration_fraction"]
    p["minimum_duration"]=minimum
    carry = rules["base_carry_capacity"] + primary_final[:, 3]*rules["vitality_capacity_per_point"]
    p["carried_weight"] = rng.choice(config["player_encumbrance_cases"], n)*rules["base_carry_capacity"]
    enc = np.clip(carry/np.maximum(carry, p["carried_weight"]), rules["encumbrance_multiplier_min"], 1)
    p["duration"] = p["base_duration"]/sim.action_speed_rate(p["base_duration"], minimum, gear["speed_rating"], rules, enc, attack=True)
    cast = ~p["kind_attack"]
    p["duration"][cast] = sim.rating_duration(p["base_duration"][cast], minimum[cast], gear["speed_rating"][cast], rules)
    p["cooldown"] = np.where(p["kind_attack"], 0, sim.efficient_cost(.8*p["base_duration"], gear["cooldown_recovery"]))
    p["stamina_policy"] = rng.integers(0, 2, n)
    low = config["low_basic_stamina_cost"][0]+config["low_basic_stamina_cost"][1]*level
    costs = np.where(p["kind_attack"], low*p["stamina_policy"], config["spell_mana_cost_fraction_per_base_second"]*mana_base*p["base_duration"])
    p["spell_cost_scale"]=rng.choice(config["spell_cost_scales"],n)
    costs*=np.where(p["kind_attack"],1,p["spell_cost_scale"])
    p["cost"] = sim.resource_cost(costs)
    shares = np.zeros((n, 6))
    shares[np.arange(n), school] = 1
    shares[style == 7] = [.55,.15,.15,.1,0,.05]
    intrinsic = rng.choice(config["weapon_intrinsic_dps_scales"], n)
    mean = config["player_base_dps_fraction_of_level_health"]*hp_base*p["base_duration"]*intrinsic
    p["raw_base_mean"] = shares*mean[:, None]
    p["raw_base_mean"][:, 0] *= sim.strength_physical_multiplier(rules["base_primary"]+primary_final[:, 0], rules)
    p["raw_flat_magic"] = np.zeros((n,6))
    p["raw_flat_magic"][:, 1:] = shares[:, 1:] * (config["magic_power_coefficient_per_base_second"]*p["base_duration"]*p["magic_power"])[:, None]
    p["raw_mean"] = p["raw_base_mean"]+p["raw_flat_magic"]
    p["weapon_min"] = mean*shares[:,0]*config["weapon_roll_range"][0]
    p["weapon_max"] = mean*shares[:,0]*config["weapon_roll_range"][1]
    p["weapon_aps"] = 1/p["base_duration"]
    p["intrinsic_scale"] = intrinsic
    p["consumable_policy"] = rng.integers(0, 2, n)
    # Exact fingerprint of generated stats and intrinsic weapon configuration;
    # environment and random outcome seed are deliberately excluded.
    fingerprint_values = np.column_stack([p[k] for k in sorted(p) if k not in ("funding","primary","consumable_policy","cohort","anchor")])
    fingerprints = b"".join(hashlib.blake2b(row.tobytes(), digest_size=16).digest() for row in np.round(fingerprint_values, 9))
    return p, fingerprints


def draw_enemy(player, seed, rules, config):
    n = len(player["health"])
    rng = np.random.default_rng(seed)
    level = np.clip(player["level"]+rng.choice(config["level_gap_cases"], n),1,rules["max_level"])
    base = _base_health(level,rules)
    pattern = rng.integers(0,len(config["enemy_patterns"]), n)
    patterns = config["enemy_patterns"]
    get = lambda key, default: np.array([patterns[i].get(key,default) for i in pattern])
    interval = get("interval",1.)
    school = get("school",0).astype(int)
    e = {"level":level,"pattern":pattern,"style":pattern,
         "health":base*rng.choice(config["enemy_health_multipliers"],n),
         "absorption":base*rng.choice(config["enemy_absorption_health_fractions"],n),
         "stamina":np.full(n,1.),"mana":np.full(n,1.),"stamina_regen":np.zeros(n),"mana_regen":np.zeros(n),
         "armor":rng.choice(config["enemy_armor_ratings_at60"],n)*(.25+.75*level/60),
         "evasion":rng.choice(config["enemy_evasion_at60"],n)*(.25+.75*level/60),
         "block":rng.choice(config["enemy_block_chances"],n)/100,
         "hit_rating":rng.choice(config["enemy_hit_ratings"],n),
         "critical_chance":rng.choice(config["enemy_critical_chances"],n),"critical_damage":np.zeros(n),"dot_damage":np.zeros(n),
         "penetration":rng.choice(config["enemy_armor_penetration"],n),
         "control_reduction":rng.choice(config["resolve_cases"],n)/100,
         "ordinary_chances":np.full((n,6),float(rules.get("ailment_chance_base",20))),
         "base_duration":interval,"duration":interval,"cooldown":np.zeros(n),"cost":np.zeros(n),
         "kind_attack":school==0,"is_dot":get("dot",False).astype(bool),
         "dot_duration":get("duration",0.),"dot_period":get("period",1.),"dot_bleed":get("bleed",False).astype(bool),
         "school":school,"consumable_policy":np.zeros(n,int)}
    e["resistance"] = np.column_stack([np.zeros(n)]+[rng.choice(config["enemy_school_resistances"],n)/100 for _ in range(5)])
    shares = np.zeros((n,6)); single = school>=0
    shares[np.flatnonzero(single),school[single]] = 1
    shares[~single] = [.4,.2,.15,.15,.1,0]
    # DoT raw_mean is DPS; direct raw_mean is the implicit packet mean.
    e["raw_mean"] = shares*(get("pressure",.12)*base*np.where(e["is_dot"],1,interval))[:,None]
    e["raw_base_mean"]=e["raw_mean"].copy();e["raw_flat_magic"]=np.zeros((n,6))
    return e


def ordinary_enemy_mask(player,enemy,rules,config):
    """Explicit content subset; never infer 'normal' from the best outcomes."""
    c=config["ordinary_envelope"];base=_base_health(enemy["level"],rules)
    scale=.25+.75*enemy["level"]/rules["max_level"]
    excluded=[i for i,p in enumerate(config["enemy_patterns"]) if p["id"] in c["excluded_patterns"]]
    return ((enemy["level"]==player["level"])
            &(enemy["health"]<=base*c["health_multiplier_max"]+1e-8)
            &(enemy["armor"]<=scale*c["armor_at60_max"]+1e-8)
            &(enemy["evasion"]<=scale*c["evasion_at60_max"]+1e-8)
            &(enemy["block"]<=c["block_max"]/100+1e-8)
            &(enemy["resistance"][:,1:].max(axis=1)<=c["resistance_max"]/100+1e-8)
            &(enemy["absorption"]<=base*c["absorption_fraction_max"]+1e-8)
            &(enemy["penetration"]<=c["penetration_max"]+1e-8)
            &~np.isin(enemy["pattern"],excluded))


class State:
    def __init__(self, stats, rng, dt, rules, config):
        self.stats=stats; n=len(stats["health"])
        self.hp=stats["health"].copy(); self.abs=stats["absorption"].copy()
        self.st=stats["stamina"].copy(); self.mp=stats["mana"].copy()
        self.progress=np.zeros(n); self.active=np.zeros(n,bool); self.released=np.zeros(n,bool)
        self.cooldown=np.zeros(n); self.last_hit=np.full(n,-1e9)
        self.entropy=rng.random(n); self.last_attempt=np.full(n,-1e9)
        self.chill=np.zeros(n);self.chill_end=np.zeros(n)
        self.zap=np.zeros(n);self.zap_end=np.zeros(n)
        self.hollow=np.zeros(n);self.hollow_end=np.zeros(n)
        self.dot_rate=np.zeros((n,3)); self.dot_next=np.full((n,3),np.inf); self.dot_end=np.zeros((n,3))
        self.environment_bypass=np.zeros(n,bool)
        self.environment_period=np.ones(n)
        self.poison=np.zeros((int(math.ceil(rules.get("poison_duration",6)/dt))+2,n))
        self.charges=np.where(stats["consumable_policy"]>0,config["consumables"]["charges"],0)
        self.potion_cd=np.zeros(n); self.potions_used=np.zeros(n,int); self.restored=np.zeros(n)
        self.damage_hp=np.zeros(n);self.damage_abs=np.zeros(n);self.hits=np.zeros(n,int);self.crits=np.zeros(n,int)
        self.actions=np.zeros(n,int)
        self.misses=np.zeros(n,int);self.dodges=np.zeros(n,int);self.blocks=np.zeros(n,int)
        self.resource_wait=np.zeros(n);self.death=np.full(n,np.inf);self.first_hit_damage=np.full(n,np.nan)
        self.first_hit_lethal=np.zeros(n,bool);self.first_hit_health_loss=np.full(n,np.nan)
        self.first_covered=np.full(n,np.nan);self.first_bypass=np.full(n,np.nan)
        self.finished=np.zeros(n,bool)


def _route(state, amount, bypass, direct, t):
    alive=(state.hp>0)&~state.finished
    amount=np.where(alive,np.maximum(0,amount),0)
    absorbed=np.where(bypass,0,np.minimum(state.abs,amount))
    health=np.minimum(state.hp,amount-absorbed)
    state.abs-=absorbed;state.hp-=health
    state.damage_hp+=health;state.damage_abs+=absorbed
    if direct:
        state.last_hit[amount>0]=t
    died=(state.hp<=0)&np.isinf(state.death)
    state.death[died]=t


def _qualify(source, target, due, rng, t, rules):
    s,d=source.stats,target.stats
    direct=due&~s["is_dot"]
    reset=direct&(t-target.last_attempt>=rules["entropy_reset_seconds"])
    target.entropy[reset]=rng.random(np.count_nonzero(reset))
    target.entropy[direct]+=1-sim.defense(d["evasion"][direct],rules,True)
    dodge=direct&(target.entropy<1)
    connected=direct&~dodge
    target.entropy[connected]-=1
    target.last_attempt[direct]=t
    blocked=connected&(rng.random(len(due))<d["block"])
    pending=(connected&~blocked)|(due&s["is_dot"])
    chance=sim.hit_chance(s["level"],d["level"],s["hit_rating"],rules)
    miss=pending&(rng.random(len(due))>=chance)
    landed=pending&~miss
    source.hits+=landed;source.misses+=miss;source.dodges+=dodge;source.blocks+=blocked
    return landed


def _apply_single(target,index,rate,proc,t,duration,period):
    active=(target.dot_rate[:,index]>0)&(target.dot_end[:,index]>t+1e-8)
    stronger=proc&(~active|(rate>target.dot_rate[:,index]+1e-9))
    equal=proc&active&np.isclose(rate,target.dot_rate[:,index],rtol=1e-9,atol=1e-9)
    new=stronger&~active
    target.dot_rate[stronger,index]=rate[stronger]
    expiry=t+np.broadcast_to(duration,rate.shape)
    target.dot_end[stronger,index]=expiry[stronger]
    target.dot_end[equal,index]=np.maximum(target.dot_end[equal,index],expiry[equal])
    target.dot_next[new,index]=t+np.broadcast_to(period,rate.shape)[new]
    return stronger


def _utility(target,name,magnitude,proc,t,duration):
    value=getattr(target,name);end=getattr(target,name+"_end")
    strong=proc&((end<=t)|(magnitude>value+1e-9))
    equal=proc&(end>t)&np.isclose(magnitude,value,rtol=1e-9,atol=1e-9)
    value[strong]=magnitude[strong]
    expiry=t+np.broadcast_to(duration,value.shape)
    end[strong]=expiry[strong]
    end[equal]=np.maximum(end[equal],expiry[equal])


def _deliver(source,target,due,rng,t,step,dt,rules,config):
    if not np.any(due):return
    s,d=source.stats,target.stats;n=len(due)
    landed=_qualify(source,target,due,rng,t,rules)
    if not np.any(landed):return
    roll=rng.uniform(*config["weapon_roll_range"],(n,6))
    raw=s["raw_base_mean"]*roll+s["raw_flat_magic"]
    reduction=d["resistance"].copy()
    reduction[:,0]=sim.defense(d["armor"]*(1-s["penetration"]/100),rules)
    ordinary=raw*sim.level_gap_factor(s["level"],d["level"],rules)[:,None]*(1-reduction)
    authored=landed&s["is_dot"]
    if np.any(authored):
        rate=ordinary.sum(axis=1)
        accepted=_apply_single(target,2,rate,authored,t,s["dot_duration"],s["dot_period"])
        target.environment_bypass[accepted]=(s["dot_bleed"]|(s["school"]==5))[accepted]
        target.environment_period[accepted]=s["dot_period"][accepted]
    direct=landed&~s["is_dot"]
    crit=direct&(rng.random(n)<np.clip(s["critical_chance"]/100+target.zap,0,1))
    source.crits+=crit
    damage=ordinary*np.where(crit,sim.critical_damage_multiplier(s["critical_damage"],rules),1)[:,None]
    damage*=direct[:,None]
    first=np.isnan(target.first_hit_damage)&(damage.sum(axis=1)>0)
    target.first_hit_damage[first]=damage.sum(axis=1)[first]
    target.first_covered[first]=damage[:,:5].sum(axis=1)[first]
    target.first_bypass[first]=damage[:,5][first]
    health_before=target.hp.copy()
    _route(target,damage[:,:5].sum(axis=1),False,True,t)
    _route(target,damage[:,5],True,True,t)
    target.first_hit_health_loss[first]=(health_before-target.hp)[first]
    target.first_hit_lethal[first]=target.hp[first]<=0
    procs=(direct&(target.hp>0))[:,None]&(raw>0)&(crit[:,None]|(rng.random((n,6))<s["ordinary_chances"]/100))
    # Damage magnitudes use ordinary component, never the critical packet.
    burn=sim.ailment_damage_rate(ordinary[:,1],"burn",s["dot_damage"],rules)
    bleed=sim.ailment_damage_rate(ordinary[:,0],"bleed",s["dot_damage"],rules)
    _apply_single(target,0,burn,procs[:,1],t,rules.get("burn_duration",4),rules.get("burn_period",1))
    _apply_single(target,1,bleed,procs[:,0],t,rules.get("bleed_duration",6),rules.get("bleed_period",2))
    poison_tick=sim.ailment_damage_rate(ordinary[:,5],"poison",s["dot_damage"],rules)*rules["poison_period"]
    poison_tick*=procs[:,5]
    for tick in np.arange(rules.get("poison_period",1),rules.get("poison_duration",6)+1e-8,rules.get("poison_period",1)):
        target.poison[(step+int(round(tick/dt)))%len(target.poison)]+=poison_tick
    potency=sim.ailment_potency(ordinary,d["level"][:,None],rules)
    chill_duration=rules.get("chill_duration",4)*(1-d["control_reduction"])*sim.control_level_duration_factor(s["level"],d["level"],rules)
    _utility(target,"chill",potency[:,2]*rules["chill_slow_max"],procs[:,2],t,chill_duration)
    _utility(target,"zap",potency[:,3]*rules["zapped_critical_bonus"]/100,procs[:,3],t,rules["zapped_duration"])
    _utility(target,"hollow",potency[:,4]*rules["hollowed_recovery_reduction_max"],procs[:,4],t,rules["hollowed_duration"])


def _advance(state,t,step,dt,rules,config):
    s=state.stats;alive=(state.hp>0)&~state.finished
    hollow=state.hollow.copy()
    eligible_start=np.maximum(t-dt,state.last_hit+rules["absorption_recovery_delay"])
    recovery_seconds=np.clip(t-eligible_start,0,dt)*alive
    hollow_seconds=np.clip(np.minimum(t,state.hollow_end)-eligible_start,0,recovery_seconds)
    for name in ("chill","zap","hollow"):
        getattr(state,name)[getattr(state,name+"_end")<=t]=0
    state.st=np.minimum(s["stamina"],state.st+dt*s["stamina_regen"]*alive)
    state.mp=np.minimum(s["mana"],state.mp+dt*s["mana_regen"]*alive)
    recovery=s["absorption"]*rules["absorption_recovery_fraction"]*(recovery_seconds-hollow*hollow_seconds)
    state.abs=np.minimum(s["absorption"],state.abs+recovery)
    periods=(np.full(len(alive),rules.get("burn_period",1)),np.full(len(alive),rules.get("bleed_period",2)),state.environment_period)
    for family in range(3):
        due=alive&(state.dot_next[:,family]<=t+1e-8)&(state.dot_next[:,family]<=state.dot_end[:,family]+1e-8)
        amount=state.dot_rate[:,family]*periods[family]*due
        bypass=True if family==1 else state.environment_bypass if family==2 else False
        _route(state,amount,bypass,False,t)
        state.dot_next[due,family]+=periods[family][due]
        expired=state.dot_end[:,family]<=t+1e-8
        state.dot_rate[expired,family]=0;state.dot_next[expired,family]=np.inf
    slot=step%len(state.poison)
    _route(state,state.poison[slot],True,False,t)
    state.poison[slot]=0
    state.cooldown=np.maximum(0,state.cooldown-dt)
    state.potion_cd=np.maximum(0,state.potion_cd-dt)
    c=config["consumables"]
    alive=(state.hp>0)&~state.finished
    drink=alive&(state.hp<=s["health"]*c["threshold"])&(state.charges>0)&(state.potion_cd<=0)
    restored=np.minimum(s["health"]-state.hp,s["health"]*c["restore_fraction"]*(1-state.hollow))*drink
    state.hp+=restored;state.restored+=restored
    state.charges-=drink;state.potions_used+=drink;state.potion_cd[drink]=c["cooldown"]


def _actions(state,opponent,dt):
    s=state.stats;alive=(state.hp>0)&(opponent.hp>0)
    resource=np.where(s["kind_attack"],state.st,state.mp)
    ready=alive&~state.active&(state.cooldown<=0)
    start=ready&(resource+1e-9>=s["cost"])
    state.resource_wait+=dt*(ready&~start)
    state.st-=s["cost"]*start*s["kind_attack"]
    state.mp-=s["cost"]*start*~s["kind_attack"]
    # Preserve work beyond the previous completion for an immediately repeatable
    # action. Throwing it away rounds every fast action up to a whole time step.
    # Actual cooldown/resource waiting instead discards that unused work.
    carried=np.maximum(0,state.progress-1)
    state.progress[~state.active&~start]=0
    state.active[start]=True;state.released[start]=False;state.progress[start]=carried[start]
    state.actions+=start
    state.cooldown[start]=s["cooldown"][start]
    state.progress+=dt*(1-state.chill)/s["duration"]*state.active*alive
    release=alive&state.active&~state.released&(state.progress>=.6)
    state.released[release]=True
    state.active[state.progress>=1-1e-9]=False
    return release


def simulate(player,enemy,rules,config,seed):
    rng=np.random.default_rng(seed);dt=float(config["dt"]);n=len(player["health"])
    p,e=State(player,rng,dt,rules,config),State(enemy,rng,dt,rules,config)
    for step in range(int(round(config["horizon"]/dt))+1):
        t=round(step*dt,9)
        delta=0. if step==0 else dt
        _advance(p,t,step,delta,rules,config);_advance(e,t,step,delta,rules,config)
        pmask=_actions(p,e,delta);emask=_actions(e,p,delta)
        _deliver(p,e,pmask,rng,t,step,dt,rules,config)
        _deliver(e,p,emask,rng,t,step,dt,rules,config)
        finished=(p.hp<=0)|(e.hp<=0)
        p.finished|=finished;e.finished|=finished
        if np.all((p.hp<=0)|(e.hp<=0)):break
    kill=e.death;death=p.death
    total=p.first_covered+p.first_bypass
    spare=np.minimum(np.divide(p.hp,p.first_bypass,out=np.full(n,np.inf),where=p.first_bypass>0),
                     np.divide(p.hp+p.abs,total,out=np.full(n,np.nan),where=total>0))
    return {"kill":kill,"death":death,"win":np.isfinite(kill)&(kill<death),
            "loss":np.isfinite(death)&(death<=kill),"timeout":np.isinf(kill)&np.isinf(death),
            "health_end":p.hp/player["health"],"absorption_end":np.divide(p.abs,player["absorption"],out=np.zeros(n),where=player["absorption"]>0),
            "potions_used":p.potions_used,"potions_empty":(p.charges==0)&(player["consumable_policy"]>0),
            "restored":p.restored,"resource_wait":p.resource_wait,"hits":p.hits,"crits":p.crits,
            "actions":p.actions,
            "misses":p.misses,"dodges":p.dodges,"blocks":p.blocks,"taken_hits":e.hits,
            "first_hit_fraction":p.first_hit_damage/player["health"],
            "first_hit_lethal":p.first_hit_lethal,
            "first_hit_health_fraction":p.first_hit_health_loss/player["health"],
            "spare_first_packets":spare,
            "health_damage":p.damage_hp,"absorption_damage":p.damage_abs}


def _quantiles(values):
    values=np.asarray(values);values=values[np.isfinite(values)]
    return [float(v) for v in np.quantile(values,[.1,.5,.9])] if len(values) else [None]*3


def summarize(result,mask):
    kills=result["kill"][mask];deaths=result["death"][mask]
    out={"trajectories":int(mask.sum()),"wins":int(result["win"][mask].sum()),"losses":int(result["loss"][mask].sum()),"timeouts":int(result["timeout"][mask].sum()),
         "kills":int(np.isfinite(kills).sum()),"deaths":int(np.isfinite(deaths).sum()),
         "kill_time_sum":float(kills[np.isfinite(kills)].sum()),"death_time_sum":float(deaths[np.isfinite(deaths)].sum())}
    for prefix,values in (("kill",kills),("death",deaths)):
        for q,value in zip(("p10","p50","p90"),_quantiles(values)):out[prefix+"_"+q]=value
    for key in ("health_end","absorption_end","potions_used","potions_empty","restored","resource_wait","actions","hits","crits","misses","dodges","blocks","taken_hits","health_damage","absorption_damage"):
        out[key+"_sum"]=float(result[key][mask].sum())
    values=result["first_hit_fraction"][mask];values=values[np.isfinite(values)]
    out["first_hit_samples"]=len(values);out["first_hit_fraction_sum"]=float(values.sum())
    out["first_hit_one_shot_count"]=int(result["first_hit_lethal"][mask].sum())
    health_values=result["first_hit_health_fraction"][mask]
    out["first_hit_health_fraction_sum"]=float(np.nansum(health_values))
    won=mask&result["win"]
    out["winning_health_fraction_sum"]=float(result["health_end"][won].sum())
    out["winning_potions_used_sum"]=float(result["potions_used"][won].sum())
    spare=result["spare_first_packets"][won];spare=spare[np.isfinite(spare)]
    out["winning_spare_packet_samples"]=len(spare);out["winning_spare_packet_sum"]=float(spare.sum())
    return out


def _profile_snapshot(player,enemy,result,i,context):
    get=lambda k:float(player[k][i])
    return {**context,"index":int(i),"style":STYLES[int(player["style"][i])],"enemy_pattern":int(enemy["pattern"][i]),
            "enemy_level":int(enemy["level"][i]),"primary_allocation":player["primary"][i].tolist(),
            "funding":dict(zip(FUNDING,map(float,player["funding"][i]))),
            "stats":{k:get(k) for k in ("health","absorption","armor","evasion","block","hit_rating","magic_power","critical_chance","critical_damage","dot_damage","penetration","duration","cost","weapon_min","weapon_max","weapon_aps")},
            "resistances":dict(zip(SCHOOLS[1:],map(float,player["resistance"][i,1:]))),
            "outcome":{k:None if not np.isfinite(result[k][i]) else float(result[k][i]) for k in ("kill","death","health_end","potions_used","resource_wait")}}


def job(spec):
    config,rules,level,tier,price,seed=spec
    n=config["builds_per_context"]
    player,fingerprints=draw_profiles(n,level,tier,price,seed,rules,config)
    env_seed=np.random.SeedSequence([seed,level,list(config["gear_tiers"]).index(tier),701])
    enemy=draw_enemy(player,env_seed,rules,config)
    ordinary=ordinary_enemy_mask(player,enemy,rules,config)
    context={"level":level,"gear":tier,"price":price}
    rows=[];samples=[]
    for repeat in range(config["repeats"]*2):
        # Each funded profile is replayed under both finite-consumable policies.
        # Policy pairs begin with the same outcome stream.
        player["consumable_policy"][:]=repeat%2
        outcome_seed=np.random.SeedSequence([seed,level,list(config["gear_tiers"]).index(tier),repeat//2,901])
        result=simulate(player,enemy,rules,config,outcome_seed)
        groups=[("all","all",np.ones(n,bool))]
        groups += [("cohort","broad",player["cohort"]==0),("cohort","coherent",player["cohort"]==1),
                   ("ordinary_coherent","all",ordinary&(player["cohort"]==1))]
        for policy in (0,1):groups.append(("consumables",str(policy),player["consumable_policy"]==policy))
        for k,name in enumerate(STYLES):groups.append(("style",name,player["style"]==k))
        for k,pattern in enumerate(config["enemy_patterns"]):groups.append(("incoming",pattern["id"],enemy["pattern"]==k))
        gap=enemy["level"]-player["level"]
        for value in np.unique(gap):groups.append(("level_gap",str(int(value)),gap==value))
        for policy in (0,1):groups.append(("basic_stamina",str(policy),player["kind_attack"]&(player["stamina_policy"]==policy)))
        for axis,value,mask in groups:
            if np.any(mask):rows.append({**context,"repeat":repeat,"axis":axis,"value":value,**summarize(result,mask)})
        if repeat<2:
            for mask,label in ((result["win"],"fastest_win"),(result["loss"],"earliest_death")):
                indices=np.flatnonzero(mask)
                if len(indices):
                    key="kill" if label=="fastest_win" else "death"
                    i=indices[np.argmin(result[key][indices])]
                    samples.append({"selection":label,"consumable_policy":repeat%2,**_profile_snapshot(player,enemy,result,i,context)})
    # Funding and primary allocations must remain conserved independent of prices.
    expected=config["creation_points"] if "creation_points" in config else rules["creation_points"]+rules["points_per_level"]*(level-1)
    checks={"primary_budget_failures":int(np.count_nonzero(player["primary"].sum(axis=1)!=expected)),
            "nonfinite_profiles":int(sum(np.count_nonzero(~np.isfinite(player[k])) for k in ("health","absorption","armor","evasion","hit_rating","duration","cost"))),
            "negative_health_recovery_sources":0}
    return rows,samples,fingerprints,checks


def _write_csv(path,rows):
    if not rows:return
    with path.open("w",newline="",encoding="utf-8") as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)


def _combined(rows):
    n=sum(r["trajectories"] for r in rows)
    if not n:return {"n":0}
    return {"n":n,"win":sum(r["wins"] for r in rows)/n,"loss":sum(r["losses"] for r in rows)/n,
            "timeout":sum(r["timeouts"] for r in rows)/n,"potion_mean":sum(r["potions_used_sum"] for r in rows)/n,
            "resource_wait":sum(r["resource_wait_sum"] for r in rows)/n,
            "first_hit":sum(r["first_hit_fraction_sum"] for r in rows)/max(1,sum(r["first_hit_samples"] for r in rows)),
            "first_health":sum(r["first_hit_health_fraction_sum"] for r in rows)/max(1,sum(r["first_hit_samples"] for r in rows)),
            "one_shot":sum(r["first_hit_one_shot_count"] for r in rows)/max(1,sum(r["first_hit_samples"] for r in rows)),
            "ttk":sum(r["kill_time_sum"] for r in rows)/max(1,sum(r["kills"] for r in rows)),
            "winning_health":sum(r["winning_health_fraction_sum"] for r in rows)/max(1,sum(r["wins"] for r in rows)),
            "spare_packets":sum(r["winning_spare_packet_sum"] for r in rows)/max(1,sum(r["winning_spare_packet_samples"] for r in rows))}


def write_report(folder,rows,manifest,config):
    lines=["# Current combat leveling experiment","", "This is a fixed-contact numerical experiment, not approved enemy content, itemization, AI or player skill.","",
           f"Executed **{manifest['trajectories']:,} trajectories** using **{manifest['distinct_generated_stat_profiles']:,} distinct generated stat/weapon profiles** across levels {min(config['levels'])}â€“{max(config['levels'])}.","",
           "Health has no passive regeneration or healing-power contribution. Health restoration comes only from the explicitly finite experimental consumable policy.","",
           "## Ordinary-content leveling reference","", "Style-coherent builds, neutral prices, same-level enemies inside the declared ordinary-content envelope, and the three-charge consumable policy. This is not the full adversarial population or a selection of winning builds. Lower levels are intended to be less forgiving.","",
           "| Level band | Gear | Trajectories | Win | Death | Timeout | Mean TTK among kills (s) | Health left among wins | Spare first-Hit packets among sampled wins |", "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    bands=[(1,9),(10,19),(20,29),(30,39),(40,49),(50,60)]
    for low,high in bands:
        for gear in config["gear_tiers"]:
            selected=[r for r in rows if low<=r["level"]<=high and r["gear"]==gear and r["price"]=="neutral" and r["axis"]=="ordinary_coherent" and r["repeat"]%2==1]
            m=_combined(selected)
            if m["n"]:lines.append(f"| {low}â€“{high} | {gear} | {m['n']:,} | {m['win']:.1%} | {m['loss']:.1%} | {m['timeout']:.1%} | {m['ttk']:.2f} | {m['winning_health']:.1%} | {m['spare_packets']:.2f} |")
    lines += ["", "## Same-level broad-stress reference", "", "This includes inefficient allocations and extreme enemy defenses; its failures are not an expected campaign death rate.","", "| Level band | Gear | Trajectories | Win | Death | Timeout | Conditional mean TTK (s) | First packet / Health |", "|---|---|---:|---:|---:|---:|---:|---:|"]
    for low,high in bands:
        for gear in config["gear_tiers"]:
            selected=[r for r in rows if low<=r["level"]<=high and r["gear"]==gear and r["price"]=="neutral" and r["axis"]=="level_gap" and r["value"]=="0"]
            m=_combined(selected)
            if m["n"]:lines.append(f"| {low}â€“{high} | {gear} | {m['n']:,} | {m['win']:.1%} | {m['loss']:.1%} | {m['timeout']:.1%} | {m['ttk']:.2f} | {m['first_hit']:.1%} |")
    lines += ["", "## Price sensitivity", "", "Same underlying funding and weapon draws are paired across these hypothetical prices. No price is an approved item stat valuation.","", "| Price model | Trajectories | Win | Death | Timeout | Resource waiting (s/trial) |", "|---|---:|---:|---:|---:|---:|"]
    for price in config["prices"]:
        m=_combined([r for r in rows if r["axis"]=="all" and r["price"]==price])
        lines.append(f"| {price} | {m['n']:,} | {m['win']:.1%} | {m['loss']:.1%} | {m['timeout']:.1%} | {m['resource_wait']:.2f} |")
    lines += ["", "## Incoming pressure families", "", "| Pattern | Trajectories | Win | Death | Timeout | Mean first landed Hit / Health |", "|---|---:|---:|---:|---:|---:|"]
    for pattern in config["enemy_patterns"]:
        m=_combined([r for r in rows if r["axis"]=="incoming" and r["value"]==pattern["id"]])
        if m["n"]:lines.append(f"| {pattern['id']} | {m['n']:,} | {m['win']:.1%} | {m['loss']:.1%} | {m['timeout']:.1%} | {m['first_hit']:.1%} |")
    lines += ["", "## Consumables and basic-attack costs", "", "| Axis | Policy | Trajectories | Win | Death | Mean consumables | Resource waiting (s/trial) |", "|---|---|---:|---:|---:|---:|---:|"]
    for axis in ("consumables","basic_stamina"):
        for policy in ("0","1"):
            m=_combined([r for r in rows if r["axis"]==axis and r["value"]==policy])
            if m["n"]:lines.append(f"| {axis} | {policy} | {m['n']:,} | {m['win']:.1%} | {m['loss']:.1%} | {m['potion_mean']:.2f} | {m['resource_wait']:.2f} |")
    lines += ["", "## Meaning and limitations", "", "- Every trajectory is a two-combatant fixed-contact timing model. Movement, manual aiming, active avoidance, animation physics, inventory travel, progression rewards and player skill are not simulated.",
              "- The time grid is explicit in the manifest. Release is modeled at 60% of the action; final due DoT ticks execute before expiry. Numerical timing is an approximation, not frame-perfect Godot replay.",
              "- Gear funding, prices, enemy Health/damage/defenses, weapon quality and consumables are experimental inputs. A leveling difficulty target cannot be certified without approved content budgets.",
              "- Basic melee damage uses implicit weapon min/max Physical damage and base attacks per second. Fast/light and slow/heavy variants share a base-DPS envelope; intrinsic weapon-DPS scale is a separate sensitivity input. There is no added Physical ability damage.",
              "- Block funding represents a legal Talent source; it is not a free shield package. No weapon-versus-shield itemization conclusion follows.",
              "- Health never regenerates. Policy 0 has no consumables; policy 1 has three finite charges restoring 35% Max Health at a 35% threshold with eight-second cooldown. Hollowed reduces restoration. These are study assumptions, not implemented item values.",
              "- Poison has no stack cap: linear delayed tick queues aggregate independently snapshotted applications without truncating the stack count.",
              "- Kill-time and death-time percentiles in summaries.csv are conditional on the event occurring. Timeouts remain explicit. No horizon is substituted for an unobserved kill.",
              "- Half of draws are broad stress profiles; half use style-coherent primary/funding choices, with varied offense/defense allocations. Purposeful specialists and joint-cap probes receive no extra funding.",
              "- Each profile is paired across no-consumable and finite-consumable policies, then repeated for independent outcomes. Distinct profiles use all rounded actual actor/weapon inputs; cohort labels, environment and outcome seed do not create new builds.",
              "- First-packet fraction is post-mitigation damage before Absorption and is only a burst indicator. Actual one-shot counts separately include Absorption and Necrotic bypass.",
              "- Spare-packet budget expresses remaining Health/Absorption as repetitions of the first incoming packet, without future recovery/ailments. It is conditional on winning and receiving a direct Hit; DoT-only fights have no sample.",
              "- Duels freeze at their first combatant death. Persistent wounds and finite consumables across ten encounters are evaluated separately by leveling_attrition.py."]
    (folder/"report.md").write_text("\n".join(lines)+"\n",encoding="utf-8")


def check_game_parity(path,rules):
    fixtures=json.loads(Path(path).read_text(encoding="utf-8-sig"));comparisons=0;maximum_error=0.
    for case in fixtures["cases"]:
        source,target=case["source_level"],case["target_level"]
        rating=case["rating_input"]
        expected={"armor":sim.defense(rating,rules),"level_factor":sim.level_gap_factor(source,target,rules),
                  "hit_chance":sim.hit_chance(source,target,rating,rules),
                  "strength_multiplier":sim.strength_physical_multiplier(case["strength_input"],rules),
                  "critical_multiplier":sim.critical_damage_multiplier(rating,rules),
                  "ailment_chance":sim.ailment_application_chance(75.,20.),
                  "potency":sim.ailment_potency(30.,target,rules),
                  "duration":sim.rating_duration(1.2,.3,rating,rules)}
        for key,value in expected.items():
            error=abs(float(value)-case[key]);maximum_error=max(maximum_error,error);comparisons+=1
            if not math.isclose(float(value),case[key],rel_tol=1e-9,abs_tol=1e-9):
                raise AssertionError(f"Godot/Python mismatch {key}: {value} versus {case[key]}")
    expected_resources={"after_delay_absorption":400.,"after_second_absorption":450.,
                        "hollowed_recovery":35.,"consumable_restored":245.,
                        "health_after_consumable":445.,"health_after_wait":445.}
    for key,value in expected_resources.items():
        comparisons+=1;error=abs(value-fixtures["resources"][key]);maximum_error=max(maximum_error,error)
        if error>1e-8:raise AssertionError(f"Godot resource fixture {key} differs: {fixtures['resources'][key]}")
    return {"cases":len(fixtures["cases"]),"comparisons":comparisons,"maximum_absolute_error":maximum_error,"passed":True}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config",type=Path);parser.add_argument("--output",type=Path,default=HERE/"leveling_results")
    parser.add_argument("--builds",type=int);parser.add_argument("--repeats",type=int)
    parser.add_argument("--workers",type=int,default=min(8,os.cpu_count() or 1));parser.add_argument("--levels",type=int,nargs="+")
    parser.add_argument("--dt",type=float);parser.add_argument("--horizon",type=float)
    parser.add_argument("--check-parity",type=Path,help="Verify a saved headless Godot parity probe and exit.")
    args=parser.parse_args();config=default_config()
    if args.check_parity:
        print(json.dumps(check_game_parity(args.check_parity,sim.read_json(sim.DEFAULT_RULES)),indent=2));return
    if args.config:config=json.loads(args.config.read_text(encoding="utf-8-sig"))
    for option,key in ((args.builds,"builds_per_context"),(args.repeats,"repeats"),(args.levels,"levels"),(args.dt,"dt"),(args.horizon,"horizon")):
        if option is not None:config[key]=option
    if config["dt"]<=0 or not math.isclose(round(1/config["dt"])*config["dt"],1):raise ValueError("dt must divide a second")
    if config["builds_per_context"]<1 or config["repeats"]<1:raise ValueError("Positive build/repeat counts required")
    rules=sim.read_json(sim.DEFAULT_RULES);folder=args.output.resolve();folder.mkdir(parents=True,exist_ok=True)
    periods=[rules[k+"_period"] for k in ("burn","bleed","poison")]+[p.get("period",1.) for p in config["enemy_patterns"]]
    if any(not math.isclose(round(period/config["dt"])*config["dt"],period) for period in periods):
        raise ValueError("dt must divide every authored and automatic DoT period")
    source_paths=tuple([Path(__file__),HERE/"simulator.py",sim.DEFAULT_RULES]
                       +sorted((HERE.parent.parent/"combat").rglob("*.gd")))
    source_bytes={str(p.relative_to(HERE.parent.parent)):p.read_bytes() for p in source_paths}
    source_start={key:hashlib.sha256(value).hexdigest() for key,value in source_bytes.items()}
    snapshot_dir=folder/"source_snapshot";snapshot_dir.mkdir(exist_ok=True)
    for key,value in source_bytes.items():(snapshot_dir/(Path(key).name+".txt")).write_bytes(value)
    (folder/"rules_snapshot.json").write_text(json.dumps(rules,indent=2)+"\n",encoding="utf-8")
    (folder/"experiment.json").write_text(json.dumps(config,indent=2)+"\n",encoding="utf-8")
    specs=[(config,rules,level,tier,price,config["seed"]) for level in config["levels"] for tier in config["gear_tiers"] for price in config["prices"]]
    started=time.perf_counter();rows=[];samples=[];checks={};fingerprint_path=folder/"profile_fingerprints.bin"
    with fingerprint_path.open("wb") as fingerprints:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            futures={pool.submit(job,spec):spec for spec in specs}
            for done,future in enumerate(as_completed(futures),1):
                result,selected,hashes,validation=future.result()
                rows.extend(result);samples.extend(selected);fingerprints.write(hashes)
                for key,value in validation.items():checks[key]=checks.get(key,0)+value
                if done%max(1,len(specs)//40)==0 or done==len(specs):
                    print(json.dumps({"contexts_complete":done,"contexts_total":len(specs),"elapsed_seconds":round(time.perf_counter()-started,1)}),flush=True)
    rows.sort(key=lambda r:(r["level"],r["gear"],r["price"],r["repeat"],r["axis"],r["value"]))
    fingerprints=np.fromfile(fingerprint_path,dtype="V16")
    distinct=len(np.unique(fingerprints));fingerprint_count=len(fingerprints)
    source_end={str(p.relative_to(HERE.parent.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}
    manifest={"schema_version":1,"seed":config["seed"],"levels":config["levels"],"contexts":len(specs),
              "build_draws":fingerprint_count,"distinct_generated_stat_profiles":distinct,
              "trajectories":fingerprint_count*config["repeats"]*2,"outcome_repeats":config["repeats"],"consumable_policies":2,
              "dt":config["dt"],"horizon":config["horizon"],"workers":args.workers,
              "elapsed_seconds":time.perf_counter()-started,"validation":checks,
              "source_sha256":source_start,"source_sha256_after_run":source_end,
              "source_changed_during_run":source_start!=source_end}
    _write_csv(folder/"summaries.csv",rows)
    (folder/"selected_profiles.json").write_text(json.dumps(samples,indent=2)+"\n",encoding="utf-8")
    (folder/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
    write_report(folder,rows,manifest,config)
    print(json.dumps(manifest,indent=2),flush=True)


if __name__=="__main__":main()
