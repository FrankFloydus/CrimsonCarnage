#!/usr/bin/env python3
# Reproducible proposal audit. No Godot, desktop, network, or hidden item database.
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DEFAULT_RULES = HERE / "legacy_combat_rules_v1.json"
LIVE_RULES = HERE.parent.parent / "combat" / "combat_rules.json"
ARCHETYPES = ("strength_melee", "dexterity_melee", "fireball", "poison")
OBJECTIVES = ("damage_per_second", "physical_ehp", "elemental_ehp", "periodic_ehp", "resource_sustain")
STAT_NAME_ALIASES = {"attack_speed": "attack_speed_rating", "cast_speed": "cast_speed_rating", "cost_reduction": "cost_efficiency"}


def canonical_stat_name(name):
    # Name compatibility only: historical values use current formulas if replayed.
    return STAT_NAME_ALIASES.get(name, name)


def read_json(path):
    result = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if isinstance(result, dict) and "base_primary" in result and "defense_curve_numerator" in result:
        require_supported_rules(result)
    return result


def require_supported_rules(rules):
    """Keep the previous simulation model from silently evaluating Combat 2.0."""
    if int(rules.get("schema_version", 1)) > 2 or str(rules.get("combat_model", "")).startswith("2.0"):
        raise ValueError("Combat 2.0 is not supported by this legacy simulator. "
                         "Use legacy_combat_rules_v1.json for previous-model experiments; "
                         "these results do not validate the current Godot combat foundation.")


def defense(rating, rules, evasion=False):
    rating = np.maximum(0.0, rating)
    cap = rules["evasion_chance_max" if evasion else "armor_damage_reduction_max"]
    # Algebraically equivalent branches avoid inf/inf for uncapped finite ratings.
    small = np.minimum(rating, 1.0)
    numerator = rules["defense_curve_numerator"]
    base = rules["defense_curve_denominator_base"]
    per_rating = rules["defense_curve_denominator_per_rating"]
    ordinary = numerator * small / (base + per_rating * small)
    reciprocal = numerator / (base / np.maximum(1.0, rating) + per_rating)
    return np.minimum(cap, np.where(rating > 1.0, reciprocal, ordinary))


def damage_bonus(values, rules):
    # Fractional compatibility form; callers adding1 receive the new multiplier.
    return np.maximum(-1, np.asarray(values) / 100.0)


def damage_multiplier(values, rules=None):
    return np.maximum(0, 1 + np.asarray(values) / 100.0)


def level_gap_factor(source_level, target_level, rules):
    difference = np.asarray(source_level, dtype=float) - np.asarray(target_level, dtype=float)
    squared = np.square(difference)
    advantage = 1 + (rules["level_gap_advantage_max"] - 1) * squared / (
        rules["level_gap_width"] ** 2 + squared)
    return np.where(difference >= 0, advantage, 1 / advantage)


def required_hit_rating(source_level, target_level, rules):
    gap = np.asarray(target_level, dtype=float) - np.asarray(source_level, dtype=float)
    ordinary = np.maximum(0, rules["hit_rating_base_requirement"] + rules["hit_rating_requirement_per_level"] * gap)
    return ordinary * np.power(rules["accuracy_rating_growth_per_level"],
                               np.maximum(0, gap - rules["accuracy_rating_comfort_gap"]))


def base_hit_chance(source_level, target_level, rules):
    gap = np.asarray(target_level, dtype=float) - np.asarray(source_level, dtype=float)
    chances = np.asarray(rules["accuracy_chance_by_level_gap"], dtype=float)
    ordinary = chances[np.clip(gap, 0, len(chances) - 1).astype(np.intp)]
    lower = 1 - (1 - chances[0]) * np.clip(
        required_hit_rating(source_level, target_level, rules) / rules["hit_rating_base_requirement"], 0, 1)
    return np.where(gap < 0, lower, ordinary)


def hit_chance(source_level, target_level, rating, rules):
    base = base_hit_chance(source_level, target_level, rules)
    required = required_hit_rating(source_level, target_level, rules)
    finite_rating = np.where(np.isfinite(rating), rating, 0)
    progress = np.divide(np.maximum(0, finite_rating), required,
                         out=np.ones(np.broadcast_shapes(np.shape(rating), required.shape)), where=required > 0)
    return base + (1 - base) * np.minimum(1, progress)


def base_spell_success_chance(source_level, target_level, rules):
    return base_hit_chance(source_level, target_level, rules)


def required_spell_accuracy(source_level, target_level, rules):
    return required_hit_rating(source_level, target_level, rules)


def spell_success_chance(source_level, target_level, spell_accuracy, rules):
    return hit_chance(source_level, target_level, spell_accuracy, rules)


def delivery_chance(source_level, target_level, stats, accuracy_kind, rules):
    # Delivery category changes presentation, never the accuracy attribute.
    return hit_chance(source_level, target_level, stats.get("hit_rating", 0), rules)



MAGIC_SCHOOLS = ("fire", "cold", "lightning", "void", "necrotic")
AILMENTS = {"physical": "bleed", "fire": "burn", "cold": "chill",
            "lightning": "zapped", "void": "hollowed", "necrotic": "poison"}


def canonical_school(school):
    """Legacy spelling migration; new authored damage uses Cold and Necrotic."""
    return {"frost": "cold", "poison": "necrotic"}.get(str(school).lower(), str(school).lower())


def strength_physical_multiplier(strength, rules):
    """Apply Strength once to the Physical component, including its DoT seed."""
    return np.maximum(0.0, 1.0 + (np.maximum(0.0, np.asarray(strength))
                      - rules["base_primary"]) * rules["strength_physical_damage_per_point"])


def critical_damage_multiplier(bonus_percent, rules):
    """Critical Damage is bonus percentage points above 150% base damage."""
    return rules["critical_base_multiplier"] + np.maximum(0.0, bonus_percent) / 100.0


def ailment_application_chance(critical_chance_percent, ordinary_proc_percent):
    """Overall probability among landed Hits; noncritical proc chance is unchanged."""
    critical = np.clip(np.asarray(critical_chance_percent) / 100.0, 0.0, 1.0)
    ordinary = np.clip(np.asarray(ordinary_proc_percent) / 100.0, 0.0, 1.0)
    return critical + (1.0 - critical) * ordinary


def ailment_potency(school_damage, target_level, rules):
    """Utility strength uses damage after level/resistance, before crit/Absorption."""
    threshold = (rules["utility_threshold_base"]
                 + rules["utility_threshold_per_level"]
                 * (np.clip(target_level, 1, rules["max_level"]) - 1))
    return np.clip(np.maximum(0.0, school_damage) / threshold, 0.0, 1.0)


def absorption_damage(amount, available, school, bleed=False):
    """Route already-mitigated damage; returns pool, Health damage, amount absorbed."""
    amount = np.maximum(0.0, np.asarray(amount, dtype=float))
    available = np.maximum(0.0, np.asarray(available, dtype=float))
    bypass = np.asarray(bleed) | (np.asarray(school) == "necrotic") | (np.asarray(school) == "poison")
    absorbed = np.where(bypass, 0.0, np.minimum(amount, available))
    return available - absorbed, amount - absorbed, absorbed


def absorption_regeneration(maximum, rules, hollowed=0.0):
    """Rate while recharge is eligible; Hollowed is a fractional recovery penalty."""
    return (np.maximum(0.0, maximum) * rules["absorption_recovery_fraction"]
            * (1.0 - np.clip(hollowed, 0.0, 1.0)))


def ailment_damage_rate(school_seed, family, dot_damage, rules):
    """Ordinary precrit raw component produces a fixed rate before its own mitigation."""
    return np.maximum(0.0, school_seed) * rules[family + "_damage_per_second_fraction"] * damage_multiplier(dot_damage)


def school_damage_reduction(school, armor, resistance, penetration, rules):
    """Physical uses penetrated Armor, all magic schools use their own resistance."""
    if canonical_school(school) == "physical":
        return defense(np.maximum(0.0, armor) * (1.0 - np.clip(penetration, 0.0, 100.0) / 100.0), rules)
    return np.clip(resistance, rules["resistance_min"], rules["resistance_max"]) / 100.0


def control_level_duration_factor(source_level, target_level, rules):
    gap = np.maximum(0, np.asarray(target_level, dtype=float) - np.asarray(source_level, dtype=float))
    return np.maximum(rules["control_level_duration_min"], 1 / (1 + gap / rules["control_level_duration_width"]))


def quality_random(rng):
    # Independent miss stream: accuracy rolls must not perturb dodge/block.
    seed = int.from_bytes(hashlib.sha256(("hit:" + repr(rng.bit_generator.state)).encode("utf-8")).digest()[:8], "little")
    return np.random.default_rng(seed)


def hit_mask(connected, chance, rng):
    connected = np.asarray(connected, dtype=bool)
    chance = np.broadcast_to(chance, connected.shape)
    full = connected & (chance >= 1)
    pending = connected & (chance > 0) & (chance < 1)
    count = np.count_nonzero(pending)
    if count:
        full[pending] = rng.random(count) < chance[pending]
    return full


def rating_duration(base, minimum, rating, rules):
    base, minimum = np.asarray(base), np.asarray(minimum)
    if (np.any(~np.isfinite(base)) or np.any(~np.isfinite(minimum))
            or np.any(base <= 0) or np.any(minimum <= 0) or np.any(minimum > base)):
        raise ValueError("Action durations require finite 0 < minimum <= positive base")
    bounded = np.maximum(rules["speed_rating_min"], rating)
    return minimum + (base - minimum) / (1 + bounded / rules["speed_rating_scale"])


def action_speed_rate(base, minimum, rating, rules, encumbrance=1, attack=False):
    rate = np.asarray(base) / rating_duration(base, minimum, rating, rules)
    if attack:
        return np.maximum(rules["final_attack_speed_rate_min"], rate * encumbrance)
    return rate


def movement_speed_rate(bonus, encumbrance, rules):
    bounded = np.clip(bonus, rules["movement_speed_bonus_min"], rules["movement_speed_bonus_max"])
    return np.clip((1 + bounded / 100.0) * encumbrance,
                   rules["final_movement_speed_rate_min"], rules["final_movement_speed_rate_max"])


def efficient_cost(base, efficiency):
    """Reciprocal used by Cooldown Recovery and guarded historical reports."""
    return np.maximum(0, base) / (1 + np.maximum(0, efficiency) / 100)


def resource_cost(base):
    """Current authored action cost; Mana/Stamina Efficiency is retired."""
    return np.maximum(0, np.asarray(base, dtype=float))


def resource_baselines(level, rules):
    return {"health": rules["base_health"] + rules["health_per_level"] * (level - 1),
            "stamina": rules["base_stamina"] + rules["stamina_per_level"] * (level - 1),
            "mana": rules["base_mana"] + rules["mana_per_level"] * (level - 1)}


def allocation(rng, weights, points):
    scaled = weights / weights.sum(axis=1, keepdims=True) * points
    result = np.floor(scaled).astype(np.int16)
    order = np.argsort(-(scaled - result), axis=1)
    remainder = points - result.sum(axis=1)
    for i in range(result.shape[1]):
        rows = np.flatnonzero(remainder > i)
        result[rows, order[rows, i]] += 1
    return result



def require_legacy_report_schema(rules):
    """Historical funded-item generators cannot represent the current combat model."""
    if int(rules.get("schema_version", 1)) >= 2:
        raise ValueError("This historical report generator requires combat schema 1 and retired "
                         "itemization assumptions. Current schema 2 experiments must use "
                         "combat_lab.py --headless or leveling_study.py. Frozen reports remain historical.")

def generate_builds(n, rng, budget, model, rules, config, level=60, talent_budget=10):
    require_legacy_report_schema(rules)
    keys = list(config["affixes"])
    index = {key: i for i, key in enumerate(keys)}
    archetype = rng.integers(0, len(ARCHETYPES), n)
    shield = rng.random(n) < 0.5
    primary = allocation(rng, rng.gamma(0.3, 1, (n, 4)),
                         rules["creation_points"] + rules["points_per_level"] * (level - 1))
    talents = allocation(rng, rng.gamma(0.3, 1, (n, 3)), talent_budget)
    preference = rng.gamma(config["preference_concentration"], 1, (n, len(keys)))
    stats = np.zeros((n, len(keys)), dtype=np.float64)
    choices = np.zeros((n, config["affix_slots"]), dtype=np.int16)
    unit_values = np.array([config["affixes"][k] / config["cost_models"][model].get(k, 1) for k in keys])
    unit_budget = budget / config["affix_slots"]
    rows = np.arange(n)
    slot = 0
    for group, group_config in config["slot_groups"].items():
        allowed = np.array([index[k] for k in group_config["allowed"]])
        for _ in range(group_config["count"]):
            weights = preference[:, allowed].copy()
            if group == "off_hand":
                weights[~shield, np.flatnonzero(allowed == index["block"])] = 0
            cdf = np.cumsum(weights, axis=1)
            selected = allowed[np.sum(rng.random(n)[:, None] * cdf[:, -1:] >= cdf, axis=1)]
            choices[:, slot] = selected
            np.add.at(stats, (rows, selected), unit_budget * unit_values[selected])
            slot += 1
    assert slot == config["affix_slots"]
    assert np.all(primary.sum(axis=1) == rules["creation_points"] + rules["points_per_level"] * (level - 1))
    assert np.all(talents.sum(axis=1) == talent_budget)
    assert np.all(stats[~shield, index["block"]] == 0)
    return {"stats": stats, "primary": primary, "talents": talents, "archetype": archetype,
            "shield": shield, "choices": choices, "budget": budget, "model": model, "keys": keys,
            "level": level, "talent_budget": talent_budget}


def derive(builds, rules, config):
    require_legacy_report_schema(rules)
    s = {k: builds["stats"][:, i] for i, k in enumerate(builds["keys"])}
    strength, dexterity, intellect, vitality = builds["primary"].T
    level = builds["level"]
    base = resource_baselines(level, rules)
    shield = builds["shield"]
    talents = builds["talents"]
    health = np.maximum(rules["minimum_capacity"], base["health"] * (1 + rules["vitality_health_per_point"] * vitality) + s["health"] + talents[:, 2] * config["talent_health_per_point"])
    stamina = np.maximum(rules["minimum_capacity"], base["stamina"] + rules["strength_stamina_per_point"] * strength + s["stamina"])
    mana = np.maximum(rules["minimum_capacity"], base["mana"] + rules["intellect_mana_per_point"] * intellect + s["mana"])
    capacity = np.maximum(rules["minimum_capacity"], rules["base_carry_capacity"] + rules["strength_capacity_per_point"] * strength)
    load = np.where(shield, config["loadouts"]["shield"]["weight"], config["loadouts"]["two_hand"]["weight"])
    encumbrance = np.clip(capacity / np.maximum(capacity, load), rules["encumbrance_multiplier_min"], 1)
    s["attack_speed_rating"] = np.maximum(rules["speed_rating_min"], s["attack_speed_rating"])
    s["cast_speed_rating"] = np.maximum(rules["speed_rating_min"], s["cast_speed_rating"])
    s["cost_efficiency"] = np.maximum(0, s["cost_efficiency"])
    s["cooldown_recovery"] = np.maximum(0, s["cooldown_recovery"])
    s["health_regen"] = np.maximum(0, rules["base_health_regen"] + s["health_regen"])
    mana_base_regen = rules["mana_regen_base"] + rules["mana_regen_per_level"] * (level - 1)
    stamina_base_regen = rules["stamina_regen_base"] + rules["stamina_regen_per_level"] * (level - 1)
    mana_regen = np.maximum(0, mana_base_regen * (1 + s["mana_regen_percent"] / 100))
    stamina_regen = np.maximum(0, stamina_base_regen * (1 + s["stamina_regen_percent"] / 100))
    enemy_penetration = np.clip(config["encounter"]["enemy_penetration"], 0, rules["armor_penetration_max"]) / 100
    armor_reduction = defense(s["armor"] * (1 - enemy_penetration), rules)
    evasion = defense(dexterity * rules["dexterity_evasion_per_point"] + s["evasion"], rules, True)
    resistance = np.clip(s["resistance"], rules["resistance_min"], rules["resistance_max"]) / 100
    shield_base = np.where(shield, config["loadouts"]["shield"]["base_block"], 0)
    block = np.clip(shield_base + s["block"] + talents[:, 0] * config["talent_block_per_point"], 0, rules["block_chance_max"]) / 100
    critical = np.clip(rules["critical_chance_base"] + s["critical_chance"], 0, rules["critical_chance_max"]) / 100
    critical_multiplier = np.maximum(rules["critical_multiplier_min"], rules["critical_multiplier_base"] + s["critical_multiplier"])
    primary_power = np.where((builds["archetype"] == 1) | (builds["archetype"] == 3), dexterity, strength)
    attack_power = np.maximum(0, primary_power * rules["primary_attack_power_per_point"] + s["attack_power"])
    spell_power = np.maximum(0, intellect * rules["intellect_spell_power_per_point"] + s["spell_power"])
    penetration = np.clip(s["penetration"], 0, rules["armor_penetration_max"]) / 100
    general = s["general_damage"] + talents[:, 1] * config["talent_damage_per_point"]
    # Hit has no invented affix price: callers may explicitly supply funded/authored rating.
    hit_rating = np.maximum(0, np.broadcast_to(np.asarray(s.get("hit_rating", 0), dtype=float), health.shape)
                            + np.broadcast_to(np.asarray(builds.get("hit_rating", 0), dtype=float), health.shape))
    spell_accuracy = np.maximum(0, np.broadcast_to(np.asarray(s.get("spell_accuracy", 0), dtype=float), health.shape)
                               + np.broadcast_to(np.asarray(builds.get("spell_accuracy", 0), dtype=float), health.shape))
    enemy_accuracy = {"hit_rating": config["encounter"].get("enemy_hit_rating", 0),
                      "spell_accuracy": config["encounter"].get("enemy_spell_accuracy", 0)}
    physical_chance = delivery_chance(level, level, enemy_accuracy, config["encounter"].get("physical_accuracy_kind", "attack"), rules)
    elemental_chance = delivery_chance(level, level, enemy_accuracy, config["encounter"].get("elemental_accuracy_kind", "spell"), rules)
    physical_taken = (1 - armor_reduction) * (1 - evasion) * (1 - block) * physical_chance
    elemental_taken = (1 - resistance) * (1 - evasion) * (1 - block) * elemental_chance
    periodic_taken = 1 - resistance
    return {**s, "health": health, "stamina": stamina, "mana": mana, "capacity": capacity, "encumbrance_multiplier": encumbrance,
            "mana_regen": mana_regen, "stamina_regen": stamina_regen, "armor_reduction": armor_reduction,
            "evasion_chance": evasion, "resistance_fraction": resistance, "block_chance": block, "critical_chance_fraction": critical,
            "critical_multiplier_value": critical_multiplier, "attack_power_value": attack_power, "spell_power_value": spell_power,
            "penetration_fraction": penetration, "general": general, "physical_taken": physical_taken, "elemental_taken": elemental_taken,
            "periodic_taken": periodic_taken, "hit_rating": hit_rating, "spell_accuracy": spell_accuracy}


def payloads(builds, d, rules, config, target_armor=None, target_resistance=None):
    require_legacy_report_schema(rules)
    abilities = config["reference_abilities"]
    encounter = config["encounter"]
    level_scale = 1 + rules["level_payload_per_level"] * (builds["level"] - 1)
    melee = abilities["melee"]
    fire = abilities["fireball"]
    poison = abilities["poison"]
    armor_rating = encounter["target_armor"] if target_armor is None else target_armor
    resistance_value = encounter["target_resistance"] if target_resistance is None else target_resistance
    armor = defense(armor_rating * (1 - d["penetration_fraction"]), rules)
    resistance = np.clip(resistance_value, rules["resistance_min"], rules["resistance_max"]) / 100
    direct_melee = (melee["base_damage"] + melee["power_coefficient"] * d["attack_power_value"]) * (1 + damage_bonus(d["general"], rules)) * (1 - armor)
    bleed = (melee["bleed_base_tick"] + melee["bleed_power_coefficient"] * d["attack_power_value"]) * (1 + damage_bonus(d["general"] + d["dot_damage"], rules)) * (1 - armor)
    direct_fire = (fire["impact_base"] * level_scale + fire["impact_power_coefficient"] * d["spell_power_value"]) * (1 + damage_bonus(d["general"] + d["elemental_damage"], rules)) * (1 - resistance)
    burn = (fire["burn_base_tick"] * level_scale + fire["burn_power_coefficient"] * d["spell_power_value"]) * (1 + damage_bonus(d["general"] + d["elemental_damage"] + d["dot_damage"], rules)) * (1 - resistance)
    direct_poison = (poison["impact_base"] + poison["impact_power_coefficient"] * d["attack_power_value"]) * (1 + damage_bonus(d["general"], rules)) * (1 - armor)
    poison_tick = (poison["base_tick"] + poison["power_coefficient"] * d["attack_power_value"]) * (1 + damage_bonus(d["general"] + d["dot_damage"], rules)) * (1 - resistance)
    a = builds["archetype"]
    direct = np.where(a < 2, direct_melee, np.where(a == 2, direct_fire, direct_poison))
    tick = np.where(a < 2, bleed, np.where(a == 2, burn, poison_tick))
    stamina_action = (a < 2) | (a == 3)
    stamina_interval = np.where(a == 3, poison["interval"], melee["interval"])
    stamina_cost = np.where(a == 3, poison["stamina_cost"], melee["stamina_cost"])
    stamina_minimum = np.where(a == 3, poison["minimum_action_duration"], melee["minimum_action_duration"])
    attack_rate = action_speed_rate(stamina_interval, stamina_minimum, d["attack_speed_rating"], rules, d["encumbrance_multiplier"], True)
    cast_duration = rating_duration(fire["cast_seconds"], fire["minimum_action_duration"], d["cast_speed_rating"], rules)
    interval = np.where(stamina_action, stamina_interval / attack_rate,
                        np.maximum(cast_duration, efficient_cost(fire["cooldown"], d["cooldown_recovery"])))
    cost = efficient_cost(np.where(stamina_action, stamina_cost, fire["mana_cost"]), d["cost_efficiency"])
    period = np.where(a < 2, melee["period"], np.where(a == 3, poison["period"], fire["period"]))
    duration = np.where(a < 2, melee["bleed_duration"], np.where(a == 3, poison["duration"], fire["burn_duration"]))
    accuracy_kind = np.where(a < 2, melee.get("accuracy_kind", "attack"),
                             np.where(a == 2, fire.get("accuracy_kind", "spell"), poison.get("accuracy_kind", "attack")))
    return {"direct": direct, "tick": tick, "interval": interval, "cost": cost, "accuracy_kind": accuracy_kind,
            "period": period, "duration": duration}


def metrics(builds, d, p, rules, config):
    require_legacy_report_schema(rules)
    a = builds["archetype"]
    seconds = config["encounter"]["seconds"]
    stamina_action = (a < 2) | (a == 3)
    pool = np.where(stamina_action, d["stamina"], d["mana"])
    regen = np.where(stamina_action, d["stamina_regen"], d["mana_regen"])
    funded_rate = np.divide(pool / seconds + regen, p["cost"],
                            out=np.full_like(p["cost"], np.inf), where=p["cost"] > 0)
    affordable = p["cost"] <= pool + 1e-9
    rate = np.where(affordable, np.minimum(1 / p["interval"], funded_rate), 0)
    crit = 1 + d["critical_chance_fraction"] * (d["critical_multiplier_value"] - 1)
    landed = np.where(p.get("accuracy_kind", "attack") == "spell",
                      spell_success_chance(builds["level"], builds["level"], d["spell_accuracy"], rules),
                      hit_chance(builds["level"], builds["level"], d["hit_rating"], rules))
    # Ranking remains an approximation: it weights dependent periodic output by
    # landed-hit availability instead of promising uninterrupted Refresh uptime.
    dot_stacks = np.where(a == 3, np.minimum(config["reference_abilities"]["poison"]["maximum_stacks"], rate * landed * config["reference_abilities"]["poison"]["duration"]), landed)
    output = p["direct"] * crit * rate * landed + np.where(rate > 0, p["tick"] / p["period"] * dot_stacks, 0)
    # Regeneration is reported separately; EHP axes deliberately remain finite and directly comparable.
    resource_sustain = np.where(affordable, funded_rate * p["interval"], 0)
    return np.column_stack((output, d["health"] / d["physical_taken"], d["health"] / d["elemental_taken"],
                            d["health"] / d["periodic_taken"], np.minimum(resource_sustain, 2)))


def encounters(builds, d, p, rng, rules, config):
    require_legacy_report_schema(rules)
    n = len(builds["archetype"])
    e = config["encounter"]
    dt = e["step_seconds"]
    pressures = rng.integers(0, len(e["pressures"]), n)
    gap_index = rng.integers(0, len(e["level_gaps"]), n)
    enemy_level = np.clip(builds["level"] + np.array(e["level_gaps"])[gap_index], 1, rules["max_level"])
    gap = enemy_level - builds["level"]
    armor_index = rng.integers(0, len(e["target_armor_cases"]), n)
    resistance_index = rng.integers(0, len(e["target_resistance_cases"]), n)
    penetration_index = rng.integers(0, len(e["enemy_penetration_cases"]), n)
    target_armor = np.array(e["target_armor_cases"])[armor_index]
    target_resistance = np.array(e["target_resistance_cases"])[resistance_index]
    enemy_penetration = np.array(e["enemy_penetration_cases"])[penetration_index] / 100
    p = payloads(builds, d, rules, config, target_armor, target_resistance)
    incoming_armor_reduction = defense(d["armor"] * (1 - enemy_penetration), rules)
    enemy_tier = (1 + rules["level_payload_per_level"] * (enemy_level - 1)) / (
        1 + rules["level_payload_per_level"] * (rules["max_level"] - 1))
    incoming_level = level_gap_factor(enemy_level, builds["level"], rules)
    outgoing_level = level_gap_factor(builds["level"], enemy_level, rules)
    quality_rng = quality_random(rng)
    enemy_accuracy = {"hit_rating": e.get("enemy_hit_rating", 0), "spell_accuracy": e.get("enemy_spell_accuracy", 0)}
    physical_chance = delivery_chance(enemy_level, builds["level"], enemy_accuracy, e.get("physical_accuracy_kind", "attack"), rules)
    elemental_chance = delivery_chance(enemy_level, builds["level"], enemy_accuracy, e.get("elemental_accuracy_kind", "spell"), rules)
    spell_actions = p["accuracy_kind"] == "spell"
    outgoing_chance = np.where(spell_actions, spell_success_chance(builds["level"], enemy_level, d["spell_accuracy"], rules),
                               hit_chance(builds["level"], enemy_level, d["hit_rating"], rules))
    physical_share = np.array([v["physical_share"] for v in e["pressures"]])[pressures]
    hazard_dps = np.array([v["unavoidable_poison_dps"] for v in e["pressures"]])[pressures]
    hp = d["health"].copy()
    enemy_health_baseline = rules["base_health"] + rules["health_per_level"] * (enemy_level - 1)
    target_hp = e["target_health"] * enemy_health_baseline / resource_baselines(rules["max_level"], rules)["health"]
    mana, stamina = d["mana"].copy(), d["stamina"].copy()
    next_action = np.full(n, dt)
    entropy = rng.random(n)
    last_attempt = np.full(n, -math.inf)
    poison_stacks = config["reference_abilities"]["poison"]["maximum_stacks"]
    expiry = np.zeros((n, poison_stacks))
    next_tick = np.zeros_like(expiry)
    enemy_burn_expiry = np.zeros(n)
    enemy_burn_next_tick = np.zeros(n)
    resolved = np.zeros(n, dtype=bool)
    won = np.zeros(n, dtype=bool)
    elapsed = np.full(n, e["seconds"])
    player_actions = np.zeros(n, dtype=np.int16)
    enemy_attempts = np.zeros(n, dtype=np.int16)
    avoided = np.zeros(n, dtype=np.int16)
    blocked = np.zeros(n, dtype=np.int16)
    enemy_hits = np.zeros(n, dtype=np.int16)
    missed = np.zeros(n, dtype=np.int16)
    resisted = np.zeros(n, dtype=np.int16)
    missed_actions = np.zeros(n, dtype=np.int16)
    resisted_actions = np.zeros(n, dtype=np.int16)
    outgoing_damage = np.zeros(n)
    a = builds["archetype"]
    stamina_action = (a < 2) | (a == 3)
    health_regen = d["health_regen"]
    for step in range(1, int(round(e["seconds"] / dt)) + 1):
        t = step * dt
        active = ~resolved
        if not np.any(active):
            break
        hp[active] = np.minimum(d["health"][active], hp[active] + health_regen[active] * dt)
        mana[active] = np.minimum(d["mana"][active], mana[active] + d["mana_regen"][active] * dt)
        stamina[active] = np.minimum(d["stamina"][active], stamina[active] + d["stamina_regen"][active] * dt)
        ticked = (expiry > 0) & (next_tick <= t + 1e-9) & (next_tick <= expiry + 1e-9) & active[:, None]
        damage = p["tick"] * ticked.sum(axis=1) * outgoing_level
        next_tick += ticked * p["period"][:, None]
        expiry[expiry <= t + 1e-9] = 0
        ready = active & (next_action <= t + 1e-9)
        resources = np.where(stamina_action, stamina, mana)
        action = ready & (resources + 1e-9 >= p["cost"])
        critical = rng.random(n) < d["critical_chance_fraction"]
        hit_action = hit_mask(action, outgoing_chance, quality_rng)
        missed_actions += action & ~hit_action & ~spell_actions
        resisted_actions += action & ~hit_action & spell_actions
        damage += np.where(hit_action, p["direct"] * outgoing_level * np.where(critical, d["critical_multiplier_value"], 1), 0)
        mana[action & ~stamina_action] -= p["cost"][action & ~stamina_action]
        stamina[action & stamina_action] -= p["cost"][action & stamina_action]
        next_action[action] += p["interval"][action]
        next_action[ready & ~action] = t + dt
        player_actions += action
        action = hit_action
        # Burn/bleed Refresh preserve the next tick. Poison Stack adds independent finite instances.
        for slot in range(poison_stacks):
            install = action & (expiry[:, slot] == 0) & ((a == 3) | (slot == 0))
            expiry[install, slot] = t + p["duration"][install]
            next_tick[install, slot] = t + p["period"][install]
            action = action & ~install
        refresh = action & (a != 3)
        expiry[refresh, 0] = t + p["duration"][refresh]
        target_hp -= damage
        outgoing_damage += damage
        # Direct hits are scheduled explicitly; DoT below never consumes entropy or block rolls.
        if abs(t / e["enemy_hit_interval"] - round(t / e["enemy_hit_interval"])) < 1e-8:
            attempt = active & (target_hp > 0)
            reset = attempt & ((t - last_attempt) >= rules["entropy_reset_seconds"])
            entropy[reset] = rng.random(np.count_nonzero(reset))
            entropy[attempt] += 1 - d["evasion_chance"][attempt]
            hit = attempt & (entropy >= 1)
            entropy[hit] -= 1
            last_attempt[attempt] = t
            block = hit & (rng.random(n) < d["block_chance"])
            landed = hit & ~block
            connected = landed
            physical = rng.random(n) < physical_share
            spell_delivery = np.where(physical, e.get("physical_accuracy_kind", "attack") == "spell",
                                      e.get("elemental_accuracy_kind", "spell") == "spell")
            landed = hit_mask(connected, np.where(physical, physical_chance, elemental_chance), quality_rng)
            enemy_hits += landed
            missed += connected & ~landed & ~spell_delivery
            resisted += connected & ~landed & spell_delivery
            taken = np.where(physical, 1 - incoming_armor_reduction, 1 - d["resistance_fraction"])
            hp -= np.where(landed, e["enemy_hit_damage"] * enemy_tier * incoming_level * taken, 0)
            apply_burn = landed & (rng.random(n) < e["on_hit_burn_chance"])
            new_burn = apply_burn & (enemy_burn_expiry == 0)
            enemy_burn_next_tick[new_burn] = t + e["on_hit_burn_period"]
            enemy_burn_expiry[apply_burn] = t + e["on_hit_burn_duration"]
            enemy_attempts += attempt
            avoided += attempt & ~hit
            blocked += block
        enemy_tick = active & (enemy_burn_expiry > 0) & (enemy_burn_next_tick <= t + 1e-9) & (enemy_burn_next_tick <= enemy_burn_expiry + 1e-9)
        hp -= np.where(enemy_tick, e["on_hit_burn_tick"] * enemy_tier * incoming_level * (1 - d["resistance_fraction"]), 0)
        enemy_burn_next_tick[enemy_tick] += e["on_hit_burn_period"]
        enemy_burn_expiry[enemy_burn_expiry <= t + 1e-9] = 0
        hp -= np.where(active, hazard_dps * dt * enemy_tier * incoming_level * (1 - d["resistance_fraction"]), 0)
        finished = active & ((hp <= 0) | (target_hp <= 0))
        won[finished] = (target_hp[finished] <= 0) & (hp[finished] > 0)
        elapsed[finished] = t
        resolved |= finished
    return {"won": won, "survived": hp > 0, "timeout": ~resolved, "elapsed": elapsed,
            "damage": outgoing_damage, "pressure": pressures, "gap_index": gap_index, "actual_gap": gap,
            "armor_index": armor_index, "resistance_index": resistance_index, "penetration_index": penetration_index,
            "enemy_level": enemy_level,
            "attempts": enemy_attempts, "avoided": avoided, "blocked": blocked, "hits": enemy_hits,
            "missed": missed, "resisted": resisted, "actions": player_actions,
            "missed_actions": missed_actions, "resisted_actions": resisted_actions}


def nondominated(points):
    keep = np.ones(len(points), dtype=bool)
    for i in range(len(points)):
        if not keep[i]:
            continue
        dominates = np.all(points >= points[i], axis=1) & np.any(points > points[i], axis=1)
        if np.any(dominates):
            keep[i] = False
    return np.flatnonzero(keep)


def candidate_archive(values, rng):
    count = min(16, len(values))
    normalized = values / np.maximum(np.median(values, axis=0), 1e-9)
    scores = [values[:, i] for i in range(values.shape[1])]
    scores += [np.exp(np.mean(np.log(np.maximum(normalized, 1e-9)), axis=1)), np.min(normalized, axis=1)]
    selected = [np.argpartition(score, -count)[-count:] for score in scores]
    selected.append(rng.choice(len(values), min(64, len(values)), replace=False))
    return np.unique(np.concatenate(selected))


def profile(builds, d, objectives, row):
    axis_maxima = np.maximum(objectives.max(axis=0), 1e-9)
    return {"archetype": ARCHETYPES[int(builds["archetype"][row])], "shield": bool(builds["shield"][row]),
            "gear_budget": builds["budget"], "cost_model": builds["model"], "level": builds["level"], "talent_budget": builds["talent_budget"],
            "primary_points": dict(zip(("strength", "dexterity", "intellect", "vitality"), map(int, builds["primary"][row]))),
            "talent_points": dict(zip(("block", "damage", "health"), map(int, builds["talents"][row]))),
            "gear_affixes": [builds["keys"][i] for i in builds["choices"][row]],
            "gear_stats": {k: round(float(builds["stats"][row, j]), 6) for j, k in enumerate(builds["keys"]) if builds["stats"][row, j]},
            "derived": {k: round(float(d[k][row]), 6) for k in ("health", "stamina", "mana", "armor_reduction", "evasion_chance", "block_chance", "health_regen", "critical_chance_fraction", "critical_multiplier_value")},
            "objectives": dict(zip(OBJECTIVES, map(float, objectives[row]))),
            "fraction_of_individual_axis_best": dict(zip(OBJECTIVES, map(float, objectives[row] / axis_maxima)))}


def unique_profile_count(builds):
    n = len(builds["archetype"])
    counts = np.zeros((n, len(builds["keys"])), dtype=np.int16)
    if builds["budget"] > 0:
        for slot in range(builds["choices"].shape[1]):
            np.add.at(counts, (np.arange(n), builds["choices"][:, slot]), 1)
    identity = np.column_stack((builds["primary"], builds["talents"], builds["archetype"], builds["shield"], counts))
    # Affix order is irrelevant, and zero-budget cosmetic choices do not invent new builds.
    return len(np.unique(identity.astype(np.int16), axis=0))


def expand_budget_profiles(spec):
    return [{"level": level, "gear_budget": pair["gear_budget"], "talent_budget": talent}
            for level in spec["levels"] for pair in spec["gear_talent_pairs"] for talent in pair["talent_budgets"]]


def parity_samples(rules):
    require_legacy_report_schema(rules)
    accuracy_matchups = ([(1, target) for target in range(1, 12)]
                         + [(1, 21), (1, 60), (60, 60), (60, 59), (60, 56), (60, 55), (60, 1)])
    return {"description": "Current Python reference outputs for Godot parity checks; percentages, raw Ratings, resource costs, and seconds are named explicitly. Historical report fixtures are separate.",
            "uncapped_damage": [{"contributions": values, "expected_multiplier": float(damage_multiplier(sum(values), rules))}
                                 for values in ([20, 25, 15], [50, 75, 50], [-90], [-100], [-150], [-200, 200], [1000, -50])],
            "rating_durations": [{"base": base, "minimum": minimum, "rating": rating,
                                   "expected_duration": float(rating_duration(base, minimum, rating, rules)),
                                   "expected_playback_rate": float(action_speed_rate(base, minimum, rating, rules))}
                                  for base, minimum in ((1, .4), (.8, .4), (.25, .1))
                                  for rating in (-1e8, -50, -49.999, 0, 25, 100, 1000, 1e12)],
            "attack_playback": [{"base": base, "minimum": minimum, "rating": rating,
                                  "capacity": 100, "weight": weight,
                                  "expected_playback_rate": float(action_speed_rate(base, minimum, rating, rules,
                                      max(rules["encumbrance_multiplier_min"], min(1, 100 / max(100, weight))), True))}
                                 for base, minimum in ((1, .4), (.8, .4), (.25, .1))
                                 for rating in (-50, 0, 25, 100, 1e12) for weight in (0, 125, 300)],
            "movement_cases": [{"bonus": bonus, "capacity": 100, "weight": weight,
                                 "expected_multiplier": float(movement_speed_rate(bonus,
                                     max(rules["encumbrance_multiplier_min"], min(1, 100 / max(100, weight))), rules))}
                                for bonus in (-1000, -100, -75, 0, 25, 100) for weight in (0, 125, 300)],
            "efficiency_costs": [{"base_cost": base, "efficiency": efficiency,
                                   "expected_cost": float(efficient_cost(base, efficiency))}
                                  for base in (-10, 0, .001, 20, 1e6) for efficiency in (-100, 0, 25, 100, 1000, 1e12)],
            "uncapped_cooldowns": [{"base": base, "recovery": recovery, "expected_duration": float(efficient_cost(base, recovery))}
                                   for base in (-2, 0, .001, 1.5) for recovery in (-100, 0, 25, 100, 1000, 1e12)],
            "effect_payloads": [
                {"name": "fire_impact", "damage_type": "Fire", "periodic": False, "level": 60, "scale_with_level": True, "base": 60, "power": 200, "power_coefficient": .5, "general": 20, "elemental": 25, "dot": 15, "armor": 500, "resistance": 40, "penetration": 0, "expected": 200.796},
                {"name": "fire_burn", "damage_type": "Fire", "periodic": True, "level": 60, "scale_with_level": True, "base": 8, "power": 200, "power_coefficient": .05, "general": 20, "elemental": 25, "dot": 15, "armor": 500, "resistance": 40, "penetration": 0, "expected": 26.3424},
                {"name": "poison_strike_impact_dexterity", "damage_type": "Physical", "periodic": False, "level": 60, "scale_with_level": False, "base": 50, "power": 200, "power_coefficient": .3, "general": 20, "elemental": 25, "dot": 15, "armor": 500, "resistance": 40, "penetration": 0, "expected": 48.63157894736842},
                {"name": "poison_tick_dexterity", "damage_type": "Poison", "periodic": True, "level": 60, "scale_with_level": False, "base": 4, "power": 200, "power_coefficient": .04, "general": 20, "elemental": 25, "dot": 15, "armor": 500, "resistance": 40, "penetration": 0, "expected": 9.72},
                {"name": "bleed_tick_penetration", "damage_type": "Physical", "periodic": True, "level": 60, "scale_with_level": False, "base": 12, "power": 200, "power_coefficient": .12, "general": 20, "elemental": 25, "dot": 15, "armor": 500, "resistance": 40, "penetration": 50, "expected": 25.272}
            ],
            "armor": [{"rating": a, "expected": float(defense(a, rules))}
                      for a in (-1e308, -100, 0, 1e-12, .1, 1, 100, 250, 500, 999.999, 1000, 1000.001, 2000, 1e12, 1e308)],
            "penetration": [{"armor": a, "penetration": p, "expected_reduction": float(defense(a * (1 - min(100, max(0, p)) / 100), rules))}
                            for a in (0, 100, 500, 999, 1000, 2000, 1e308) for p in (-50, 0, 25, 50, 75, 100, 125)],
            "level_baselines": [{"level": level, **resource_baselines(level, rules)} for level in range(1, 61)],
            "level_gaps": [{"source_level": source, "target_level": target,
                             "expected_multiplier": float(level_gap_factor(source, target, rules))}
                            for source in (1, 2, 15, 30, 45, 59, 60) for target in (1, 2, 15, 30, 45, 59, 60)],
            "hit_chances": [{"source_level": source, "target_level": target, "rating": rating,
                           "expected_base_chance": float(base_hit_chance(source, target, rules)),
                           "expected_required_rating": float(required_hit_rating(source, target, rules)),
                           "expected_chance": float(hit_chance(source, target, rating, rules))}
                          for source, target in accuracy_matchups
                          for rating in (-100, 0, 25, 50, 100, 150, 640, 4800, 1e20, 1e308)],
            "spell_success": [{"source_level": source, "target_level": target, "rating": rating,
                               "expected_base_chance": float(base_spell_success_chance(source, target, rules)),
                               "expected_required_rating": float(required_spell_accuracy(source, target, rules)),
                               "expected_chance": float(spell_success_chance(source, target, rating, rules))}
                              for source, target in accuracy_matchups
                              for rating in (-100, 0, 25, 50, 100, 150, 640, 4800, 1e20, 1e308)],
            "accuracy_independence": [{"source_level": source, "target_level": target,
                                       "hit_rating": hit, "spell_accuracy": spell,
                                       "expected_hit_chance": float(hit_chance(source, target, hit, rules)),
                                       "expected_spell_chance": float(spell_success_chance(source, target, spell, rules))}
                                      for source, target in ((1, 1), (1, 6), (1, 11), (1, 60), (60, 1))
                                      for hit, spell in ((0, 0), (50, 0), (0, 50), (4800, 0), (0, 4800), (1e20, 1e20))],
            "control_durations": [{"source_level": source, "target_level": target,
                                   "expected_multiplier": float(control_level_duration_factor(source, target, rules))}
                                  for source in (1, 5, 15, 30, 60) for target in (1, 5, 15, 30, 60)],
            "encumbrance": [{"capacity": capacity, "weight": weight,
                             "expected": max(rules["encumbrance_multiplier_min"], min(1, capacity / max(capacity, weight)))}
                            for capacity in (1, 100, 1000) for weight in (0, capacity, capacity + 1, capacity * 1.25, capacity * 2, capacity * 4)],
            "damage_bonus": [{"contributions": values, "expected": float(damage_bonus(sum(values), rules))} for values in ([20, 25, 15], [50, 75, 50], [-60, -20], [0])],
            "block_source": [{"shield": 20, "talent": 15, "general": 100, "expected": 35}, {"shield": 0, "talent": 0, "general": 100, "expected": 0}, {"shield": 80, "talent": 40, "general": 0, "expected": rules["block_chance_max"]}]}


def run(args):
    started = time.monotonic()
    source_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    rules, config = read_json(args.rules), read_json(args.config)
    budget_spec = read_json(args.profiles)
    budget_profiles = expand_budget_profiles(budget_spec)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "parity_samples.json").write_text(json.dumps(parity_samples(rules), indent=2) + "\n", encoding="utf-8")
    groups = [(model, budget, seed) for model in config["cost_models"] for budget in budget_profiles for seed in config["seeds"]]
    per_group = math.ceil(args.builds / len(groups))
    summaries, top_profiles, csv_rows = [], [], []
    total_fights = total_builds = 0
    for group_index, (model, budget, seed) in enumerate(groups):
        level, gear, talents = budget["level"], budget["gear_budget"], budget["talent_budget"]
        cell_seed = seed + level * 100003 + int(gear) * 1009 + talents * 9176
        rng = np.random.default_rng(cell_seed)
        pieces, derived, objective_pieces, encounter_pieces = [], [], [], []
        for offset in range(0, per_group, args.batch_size):
            count = min(args.batch_size, per_group - offset)
            builds = generate_builds(count, rng, gear, model, rules, config, level, talents)
            d = derive(builds, rules, config)
            p = payloads(builds, d, rules, config)
            # Identical reference enemy for all candidates in this budget context.
            values = metrics(builds, d, p, rules, config)
            fight_rng = np.random.default_rng(cell_seed + offset + 900000001)
            fights = encounters(builds, d, p, fight_rng, rules, config)
            pieces.append(builds)
            derived.append(d)
            objective_pieces.append(values)
            encounter_pieces.append(fights)
        builds = {key: np.concatenate([v[key] for v in pieces]) if isinstance(pieces[0][key], np.ndarray) else pieces[0][key] for key in pieces[0]}
        d = {key: np.concatenate([v[key] for v in derived]) for key in derived[0]}
        values = np.concatenate(objective_pieces)
        fights = {key: np.concatenate([v[key] for v in encounter_pieces]) for key in encounter_pieces[0]}
        archive = candidate_archive(values, np.random.default_rng(cell_seed))
        archive = archive[nondominated(values[archive])]
        verified = []
        for row in archive:
            if not np.any(np.all(values >= values[row], axis=1) & np.any(values > values[row], axis=1)):
                verified.append(int(row))
        med = np.median(values, axis=0)
        p90 = np.quantile(values[:, :4], .90, axis=0)
        maxima = np.max(values[:, :4], axis=0)
        high_axes = values[:, :4] >= p90
        near_best_axes = values[:, :4] >= .8 * maxima
        generalist = np.exp(np.mean(np.log(np.maximum(values / np.maximum(med, 1e-9), 1e-9)), axis=1))
        selected = sorted(set(sorted(verified, key=lambda row: generalist[row], reverse=True)[:5] +
                              [max(verified, key=lambda row: values[row, i]) for i in range(values.shape[1])])) if verified else []
        selected_unique = set()
        for row in selected:
            identity = (tuple(builds["primary"][row]), tuple(builds["talents"][row]), int(builds["archetype"][row]),
                        bool(builds["shield"][row]), tuple(builds["stats"][row]))
            if identity in selected_unique:
                continue
            selected_unique.add(identity)
            record = profile(builds, d, values, row)
            record["seed"] = seed
            record["sample_row"] = row
            record["selection_roles"] = [OBJECTIVES[i] + "_specialist" for i in range(values.shape[1])
                                         if values[row, i] == max(values[v, i] for v in verified)]
            if row in sorted(verified, key=lambda v: generalist[v], reverse=True)[:5]:
                record["selection_roles"].append("balanced_candidate")
            top_profiles.append(record)
        cap_matrix = np.column_stack((d["armor_reduction"] >= rules["armor_damage_reduction_max"] - 1e-9,
                                      d["evasion_chance"] >= rules["evasion_chance_max"] - 1e-9,
                                      d["block_chance"] >= rules["block_chance_max"] / 100 - 1e-9,
                                      d["resistance_fraction"] >= rules["resistance_max"] / 100 - 1e-9))
        tier_factor = (1 + rules["level_payload_per_level"] * (level - 1)) / (1 + rules["level_payload_per_level"] * (rules["max_level"] - 1))
        raw_physical_dps = config["encounter"]["enemy_hit_damage"] * tier_factor / config["encounter"]["enemy_hit_interval"]
        zero_pressure = d["health_regen"] >= raw_physical_dps * d["physical_taken"]
        near_best = np.all(near_best_axes, axis=1)
        summary = {"model": model, "level": level, "budget": gear, "talent_budget": talents, "seed": seed,
                   "build_evaluations": per_group, "encounter_trials": per_group,
                   "unique_build_profiles_in_cell": unique_profile_count(builds),
                   "wins": int(fights["won"].sum()), "survivors": int(fights["survived"].sum()), "timeouts": int(fights["timeout"].sum()),
                   "win_fraction": float(fights["won"].mean()), "survival_fraction": float(fights["survived"].mean()),
                   "median_objectives": dict(zip(OBJECTIVES, map(float, med))),
                   "p99_objectives": dict(zip(OBJECTIVES, map(float, np.quantile(values, .99, axis=0)))),
                   "axis_maxima": dict(zip(OBJECTIVES[:4], map(float, maxima))),
                   "top_decile_all_four_axes_count": int(np.count_nonzero(np.all(high_axes, axis=1))),
                   "top_decile_at_least_three_axes_count": int(np.count_nonzero(high_axes.sum(axis=1) >= 3)),
                   "within_80_percent_of_all_four_axis_bests_count": int(near_best.sum()),
                   "near_best_generalist_encounter_win_fraction": float(fights["won"][near_best].mean()) if np.any(near_best) else None,
                   "defensive_cap_counts": dict(zip(("armor", "evasion", "block", "all_resistances"), map(int, cap_matrix.sum(axis=0)))),
                   "at_least_three_defensive_caps_count": int(np.count_nonzero(cap_matrix.sum(axis=1) >= 3)),
                   "candidate_archive_size": len(archive), "verified_nondominated_candidates": len(verified),
                   "steady_physical_pressure_outhealed_fraction": float(zero_pressure.mean()),
                   "minimum_primary_budget": int(builds["primary"].sum(axis=1).min()),
                   "maximum_primary_budget": int(builds["primary"].sum(axis=1).max()),
                   "minimum_talent_budget": int(builds["talents"].sum(axis=1).min()),
                   "maximum_talent_budget": int(builds["talents"].sum(axis=1).max()),
                   "invalid_nonshield_block_affixes": int(np.count_nonzero(builds["stats"][~builds["shield"], builds["keys"].index("block")])),
                   "minimum_enemy_level": int(fights["enemy_level"].min()), "maximum_enemy_level": int(fights["enemy_level"].max())}
        summaries.append(summary)
        # Marginal conditional cells avoid a mostly empty full Cartesian table.
        axes = {
            "pressure": (fights["pressure"], [v["name"] for v in config["encounter"]["pressures"]]),
            "target_armor": (fights["armor_index"], config["encounter"]["target_armor_cases"]),
            "target_resistance": (fights["resistance_index"], config["encounter"]["target_resistance_cases"]),
            "enemy_penetration": (fights["penetration_index"], config["encounter"]["enemy_penetration_cases"]),
            "enemy_level": (fights["enemy_level"], None)}
        for axis, (indices, labels) in axes.items():
            for value in np.unique(indices):
                for archetype in range(len(ARCHETYPES)):
                    mask = (indices == value) & (builds["archetype"] == archetype)
                    count = int(mask.sum())
                    if count:
                        csv_rows.append({"model": model, "level": level, "gear_budget": gear, "talent_budget": talents, "seed": seed,
                                         "condition": axis, "value": str(labels[int(value)] if labels is not None else int(value)),
                                         "archetype": ARCHETYPES[archetype], "trials": count, "wins": int(fights["won"][mask].sum()),
                                         "survivors": int(fights["survived"][mask].sum()), "timeouts": int(fights["timeout"][mask].sum()),
                                         "mean_elapsed_seconds": float(fights["elapsed"][mask].mean())})
        total_builds += per_group
        total_fights += per_group
        if (group_index + 1) % 6 == 0 or group_index == 0:
            print(f"{group_index+1}/{len(groups)} cells: {total_builds:,} builds + fights; {model} L{level} gear={gear} talent={talents}; {time.monotonic()-started:.1f}s", flush=True)
    report = {"schema_version": 2, "rules_path": str(Path(args.rules).resolve()),
              "simulator_sha256": source_hash, "batch_size": args.batch_size,
              "requested_build_evaluations": args.builds,
              "rules_sha256": hashlib.sha256(Path(args.rules).read_bytes()).hexdigest(),
              "scenario_sha256": hashlib.sha256(Path(args.config).read_bytes()).hexdigest(),
              "budget_profiles_sha256": hashlib.sha256(Path(args.profiles).read_bytes()).hexdigest(),
              "build_evaluations": total_builds, "stochastic_encounter_trials": total_fights,
              "sampling": "With replacement. Per-cell unique profile counts collapse affix order and ignore zero-budget affix choices. They must not be summed and claimed as globally unique profiles.",
              "independent_budget_contexts": len(budget_profiles), "comparison_cells": len(groups),
              "elapsed_seconds": time.monotonic() - started, "config": config, "budget_profiles": budget_spec, "groups": summaries,
              "limitations": [
                  "Gear, talent, loadout and enemy prices/profiles are provisional assumptions, not implemented content budgets.",
                  "Low-level/high-gear combinations are affordability stress tests, not normal loot progression.",
                  "Pareto and generalist objectives use the same fixed reference Armor500/resistance40/penetration0 at each level; randomized encounters never alter objective rankings.",
                  "Enemy levels are clamped to1..60. Enemy Health uses its level Health baseline; hit and periodic payloads use the shared tier curve, then the level-gap factor once.",
                  "One encounter per sampled build supports aggregate inference, not a reliable win probability for each individual build.",
                  "Per-cell unique profile counts are exact, but profiles can recur across seeds or price-model contexts.",
                  "Candidate fronts are checked against every sampled equal-budget/level/talent/seed build; discovery is not an exhaustive full Pareto enumeration.",
                  "Top-decile thresholds include ties; near-all-axis best at zero budgets can mean uniformly weak profiles with little specialization headroom.",
                  "Fixed-position fights omit aiming, navigation and player skill. Target defense extremes are deliberate stress profiles.",
                  "Saved example payloads and costs are matched; contact/cast animation delays are approximated.",
                  "All-resistance grants all four types; the reviewed price explicitly charges a premium rather than treating four resistances as one.",
                  "Encounter time steps are0.5s; separate profile trials quantify0.1s timing sensitivity.",
                  "Uncapped regeneration can outheal finite pressure. A sampled study cannot prove absence of exploits."]}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (output / "top_builds.json").write_text(json.dumps(top_profiles, indent=2) + "\n", encoding="utf-8")
    with (output / "encounters.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(csv_rows[0]))
        writer.writeheader()
        writer.writerows(csv_rows)
    lines = ["# Broad combat budget experiment", "", f"**{total_builds:,} sampled build evaluations and {total_fights:,} stochastic encounter trajectories.**",
             "", f"{len(budget_profiles)} independent level/gear/talent contexts; {len(groups)} model/seed cells. Samples are drawn with replacement; these are not claimed to be ten million unique builds.",
             "", "## Fairness and coverage", "",
             "- Levels1/15/30/45/60, gear budgets0/10/20/40/60/100, talent budgets0/5/10/20.",
             "- Each build exactly spends its legal level's primary points, funded gear slots and selected talent budget.",
             "- Every encounter samples target Armor0/250/500/1000/2000, resistance-20/0/40/80, enemy penetration0/50/100 and one of four pressure mixes.",
             "- Enemy level differences are legal within1..60. Enemy baseline Health and payloads scale by level before the gap factor.",
             "- All build-ranking objectives use one common reference opponent per level, independently of those randomized encounters.",
             "- Cost-model differences reprice provisional gear only; agreed gameplay formulas and caps are unchanged.",
             "- Detailed marginal opponent/archetype outcome cells are in encounters.csv. Some conditions overlap; do not sum different condition dimensions as additional trials.",
             "", "## Equal-budget broad-build diagnostics", "",
             "| Model | Level | Gear | Talents | Seed | Evaluations | Unique profiles within cell | Win rate | All4 axes top decile | All4 axes>=80% of independent best | >=3 defense caps |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for s in summaries:
        lines.append(f"| {s['model']} | {s['level']} | {s['budget']} | {s['talent_budget']} | {s['seed']} | {s['build_evaluations']:,} | {s['unique_build_profiles_in_cell']:,} | {s['win_fraction']:.2%} | {s['top_decile_all_four_axes_count']} | {s['within_80_percent_of_all_four_axis_bests_count']} | {s['at_least_three_defensive_caps_count']} |")
    lines += ["", "## Interpretation", "",
              "Generalist axes are damage, Physical hit EHP, elemental hit EHP and periodic EHP; resource sustain is an additional Pareto axis. A relative high score at a weak zero-budget baseline is not evidence of an overpowered character.",
              "The candidate archive combines individual-objective specialists, geometric-mean and weakest-axis generalists, and random candidates. Retained candidates are checked against all sampled builds in their own comparison cell.",
              "Initial and reviewed prices share seeds and underlying build choices. Reviewed prices charge more for regeneration, broad resistances, blocking and selected defensive/offensive affixes.",
              "", "## Limits", ""] + ["- " + item for item in report["limitations"]]
    (output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description="Equal-budget combat audit; evaluation count is neither hit count nor unique-build count.")
    parser.add_argument("--builds", type=int, default=10_000_000)
    parser.add_argument("--batch-size", type=int, default=25_000)
    parser.add_argument("--rules", type=Path, default=DEFAULT_RULES)
    parser.add_argument("--config", type=Path, default=HERE / "scenarios.json")
    parser.add_argument("--profiles", type=Path, default=HERE / "budget_profiles.json")
    parser.add_argument("--output", type=Path, default=HERE / "results")
    args = parser.parse_args()
    if args.builds < 240 or args.batch_size < 1:
        parser.error("Use at least240 evaluations and a positive batch size.")
    run(args)


if __name__ == "__main__":
    main()
