#!/usr/bin/env python3
# Event-time pressure investigation. Scenario prices and enemies are hypotheses.
from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import json
import math
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
import simulator as sim

TYPES = ("fire", "frost", "lightning", "poison")
HERE = Path(__file__).resolve().parent


def validate_pressure_config(config):
    if config["duration"] <= 0 or max(config["horizons"]) > config["duration"]:
        raise ValueError("Survival horizons must fit the positive scenario duration")
    for pattern in config["incoming_patterns"]:
        for channel in pattern["channels"]:
            if channel.get("interval", 1) <= 0:
                raise ValueError("Hit intervals must be positive")
            if channel.get("accuracy_kind", "attack") not in ("attack", "spell"):
                raise ValueError("Accuracy kind must explicitly select attack or spell")
            if "components" in channel and not math.isclose(sum(c.get("share", 1) for c in channel["components"]), 1):
                raise ValueError("Delivered-hit damage component shares must sum to one")
            if channel["kind"] == "dot" and (channel["period"] <= 0 or channel["duration"] < channel["period"]):
                raise ValueError("Periodic durations must contain at least one scheduled tick")
            if "on_hit_dot" in channel:
                dot = channel["on_hit_dot"]
                if dot.get("execute_on_application", False):
                    raise ValueError("Dependent immediate ticks are not supported by this envelope")
                if dot.get("policy", "refresh") not in ("refresh", "replace", "stack"):
                    raise ValueError("Unknown dependent reapplication policy")
    for pattern in config["outgoing_patterns"]:
        if pattern.get("accuracy_kind", "attack") not in ("attack", "spell"):
            raise ValueError("Accuracy kind must explicitly select attack or spell")
        if pattern["interval"] <= 0 or pattern["resource"] not in ("stamina", "mana"):
            raise ValueError("Outgoing profiles require a positive interval and resource")
        if pattern.get("execute_on_application", False) or pattern.get("on_hit_dot", {}).get("execute_on_application", False):
            raise ValueError("Immediate outgoing periodic ticks are outside this envelope")
        if pattern["power_source"] not in ("strength", "dexterity", "intellect"):
            raise ValueError("Unknown outgoing Power source")
        base_action = pattern.get("cast_time", pattern["interval"])
        minimum = pattern["minimum_action_duration"]
        if not math.isfinite(base_action) or not math.isfinite(minimum) or not 0 < minimum <= base_action:
            raise ValueError("Authored durations must be finite with 0 < minimum <= base")


def extended_config(base_config, pressure_config):
    config = copy.deepcopy(base_config)
    config["pressure_affix_split_range"] = pressure_config["affix_split_range"]
    for kind in TYPES:
        config["affixes"][kind + "_resistance"] = config["affixes"]["resistance"]
        for group in ("armor", "off_hand"):
            config["slot_groups"][group]["allowed"].append(kind + "_resistance")
    for model, prefix in (("initial", "initial"), ("defense_cost_review", "review")):
        config["cost_models"][model]["resistance"] = pressure_config[prefix + "_all_resistance_price"]
        for kind in TYPES:
            config["cost_models"][model][kind + "_resistance"] = pressure_config[prefix + "_single_resistance_price"]
    return config


def sample_builds(n, rng, gear_budget, model, rules, config, level=60, talent_budget=10):
    builds = sim.generate_builds(n, rng, gear_budget, model, rules, config, level, talent_budget)
    # Each item keeps exactly B/10; its two affixes vary independently of their types.
    splits = rng.uniform(*config["pressure_affix_split_range"], (n, config["affix_slots"] // 2))
    shares = np.empty((n, config["affix_slots"]))
    shares[:, ::2], shares[:, 1::2] = splits, 1 - splits
    funding = shares * gear_budget / (config["affix_slots"] / 2)
    stats = np.zeros_like(builds["stats"])
    units = np.array([config["affixes"][k] / config["cost_models"][model].get(k, 1) for k in builds["keys"]])
    rows = np.arange(n)
    for slot in range(config["affix_slots"]):
        chosen = builds["choices"][:, slot]
        np.add.at(stats, (rows, chosen), funding[:, slot] * units[chosen])
    builds["stats"], builds["affix_funding"] = stats, funding
    if not np.allclose(funding.sum(axis=1), gear_budget):
        raise ValueError("Gear funding is not conserved")
    return builds


def derive_stats(builds, rules, config, resistance_debuffs=None):
    d = sim.derive(builds, rules, config)
    for kind in TYPES:
        penalty = 0 if resistance_debuffs is None else resistance_debuffs.get(kind, 0)
        d[kind + "_resistance_fraction"] = np.clip(d["resistance"] + d[kind + "_resistance"] + penalty,
                                                      rules["resistance_min"], rules["resistance_max"]) / 100
    d["strength_power"] = np.maximum(0, builds["primary"][:, 0] * rules["primary_attack_power_per_point"] + d["attack_power"])
    d["dexterity_power"] = np.maximum(0, builds["primary"][:, 1] * rules["primary_attack_power_per_point"] + d["attack_power"])
    d["intellect_power"] = np.maximum(0, builds["primary"][:, 2] * rules["intellect_spell_power_per_point"] + d["spell_power"])
    return d


def sample_targets(n, rng, level, rules, pressure_config):
    sim.require_legacy_report_schema(rules)
    e = pressure_config["enemy"]
    target = {"enemy_level": np.clip(level + rng.choice(e["level_gaps"], n), 1, rules["max_level"]),
              "armor": rng.choice(e["armor_cases"], n), "penetration": rng.choice(e["penetration_cases"], n) / 100,
              "evasion_chance": rng.choice(e["evasion_cases"], n), "block_chance": rng.choice(e["block_cases"], n)}
    target["hit_rating"] = np.full(n, e.get("hit_rating", 0), dtype=float)
    target["spell_accuracy"] = np.full(n, e.get("spell_accuracy", 0), dtype=float)
    target["pressure_scale"] = rng.choice(e["pressure_scales"], n)
    for kind in TYPES:
        target[kind + "_resistance_fraction"] = rng.choice(e["resistance_cases"], n) / 100
    target["health_scale"] = rng.choice(e["health_scales"], n)
    target["health"] = target["health_scale"] * e["health_at_level60"] * (
        rules["base_health"] + rules["health_per_level"] * (target["enemy_level"] - 1)) / sim.resource_baselines(rules["max_level"], rules)["health"]
    return target


def _mitigation(channel, d, targets, rules, incoming):
    pieces = channel.get("components")
    if pieces is None:
        pieces = [{"damage_type": channel["damage_type"], "share": 1}]
    total = np.zeros_like(d["health"])
    for component in pieces:
        kind = component["damage_type"]
        if kind == "physical":
            armor = d["armor"] if incoming else targets["armor"]
            penetration = targets["penetration"] if incoming else d["penetration_fraction"]
            if channel.get("armor_ignore", False):
                penetration = 1
            reduction = sim.defense(armor * (1 - penetration), rules)
        else:
            reduction = (d if incoming else targets)[kind + "_resistance_fraction"]
        total += component.get("share", 1) * (1 - reduction)
    return total


def _attack_check(alive, entropy, last_attempt, t, evasion, block, rng, rules, channel):
    if channel.get("unavoidable", False):
        return alive.copy(), np.zeros_like(alive), np.zeros_like(alive)
    hit = alive.copy()
    evaded = np.zeros_like(alive)
    if channel.get("dodgeable", True):
        reset = alive & (t - last_attempt >= rules["entropy_reset_seconds"])
        entropy[reset] = rng.random(np.count_nonzero(reset))
        entropy[alive] += 1 - evasion[alive]
        hit &= entropy >= 1
        entropy[hit] -= 1
        last_attempt[alive] = np.broadcast_to(t, last_attempt.shape)[alive]
        evaded = alive & ~hit
    blocked = hit & (rng.random(len(hit)) < block) if channel.get("blockable", True) else np.zeros_like(hit)
    return hit & ~blocked, evaded, blocked


def _landed_delivery(connected, chance, rng, channel):
    # Environmental/prevalidated applications may opt out explicitly. Ordinary
    # standalone debuffs and DoTs still make exactly one hostile application check.
    if not channel.get("accuracy_check", True):
        return connected.copy()
    return sim.hit_mask(connected, chance, rng)


def _event_plan(pattern, end):
    events = []
    for index, channel in enumerate(pattern["channels"]):
        if channel["kind"] == "dot":
            duration, period = channel["duration"], channel["period"]
            times = [i * period for i in range(1, math.floor(duration / period + 1e-9) + 1)]
            if channel.get("execute_on_application", False):
                times.insert(0, 0)
            events.extend((round(t, 9), 0, index, "dot") for t in times if t <= end)
        else:
            interval = channel.get("interval", end + 1)
            start = interval if channel.get("first_event", "after_interval") == "after_interval" else channel["first_event"]
            stop = min(end, channel.get("duration", end))
            times = [start + i * interval for i in range(max(0, math.floor((stop - start) / interval + 1e-9) + 1))]
            events.extend((round(t, 9), 1, index, "hit") for t in times)
            if "on_hit_dot" in channel:
                dot = channel["on_hit_dot"]
                possible = {round(t + i * dot["period"], 9) for t in times for i in range(1, math.floor(dot["duration"] / dot["period"] + 1e-9) + 1) if t + i * dot["period"] <= end}
                events.extend((t, 0, index, "dependent") for t in possible)
    return sorted(events)


def simulate_incoming(builds, stats, pattern, rng, rules, pressure_config, targets=None):
    sim.require_legacy_report_schema(rules)
    n, end = len(builds["primary"]), pressure_config["duration"]
    if targets is None:
        targets = sample_targets(n, rng, builds["level"], rules, pressure_config)
    tier = (1 + rules["level_payload_per_level"] * (targets["enemy_level"] - 1)) / (1 + rules["level_payload_per_level"] * (rules["max_level"] - 1))
    gap = sim.level_gap_factor(targets["enemy_level"], builds["level"], rules)
    scale = tier * gap * targets.get("pressure_scale", 1)
    hp = stats["health"].copy()
    death = np.full(n, np.inf)
    entropy, last_attempt = rng.random(n), np.full(n, -np.inf)
    result = {k: np.zeros(n, dtype=np.int16) for k in ("events", "hits", "avoided", "blocked", "missed", "resisted")}
    quality_rng = sim.quality_random(rng)
    landed_chances = [sim.delivery_chance(targets["enemy_level"], builds["level"], targets,
                                         c.get("accuracy_kind", "attack"), rules) for c in pattern["channels"]]
    standalone = {}
    for i, channel in enumerate(pattern["channels"]):
        if channel["kind"] == "dot":
            standalone[i] = _landed_delivery(np.ones(n, dtype=bool), landed_chances[i], quality_rng, channel)
            result["resisted" if channel.get("accuracy_kind", "attack") == "spell" else "missed"] += ~standalone[i]
            result["hits"] += standalone[i]
    first_attempt_seen = False
    first_connected = np.zeros(n, dtype=bool)
    for key in ("first_hit_lethal", "first_packet_lethal_if_landed", "first_landed_hit_lethal"):
        result[key] = np.zeros(n, dtype=bool)
    mitigations = [_mitigation(c, stats, targets, rules, True) for c in pattern["channels"]]
    dependent = {}
    for i, c in enumerate(pattern["channels"]):
        if "on_hit_dot" in c:
            dot = c["on_hit_dot"]
            slots = dot.get("maximum_stacks", 1)
            dependent[i] = {"expiry": np.zeros((n, slots)), "next": np.full((n, slots), np.inf),
                            "damage": dot["total_damage"] / math.floor(dot["duration"] / dot["period"]) * scale * _mitigation(dot, stats, targets, rules, True)}
    previous = 0
    for t, _, index, kind in _event_plan(pattern, end):
        alive = np.isinf(death)
        if not np.any(alive):
            break
        hp[alive] = np.minimum(stats["health"][alive], hp[alive] + stats["health_regen"][alive] * (t - previous))
        previous = t
        channel = pattern["channels"][index]
        if kind == "dependent":
            state, dot = dependent[index], channel["on_hit_dot"]
            due = (state["next"] <= t + 1e-8) & (state["next"] <= state["expiry"] + 1e-8) & (state["expiry"] > 0) & alive[:, None]
            hp -= due.sum(axis=1) * state["damage"]
            state["next"][due] += dot["period"]
            result["events"] += due.sum(axis=1).astype(np.int16)
        elif kind == "dot":
            ticks = math.floor(channel["duration"] / channel["period"]) + int(channel.get("execute_on_application", False))
            applied = alive & standalone[index]
            hp -= np.where(applied, channel["total_damage"] / ticks * scale * mitigations[index], 0)
            result["events"] += applied
        else:
            damage = channel.get("damage", channel.get("dps", 0) * channel.get("interval", 1)) * scale * mitigations[index]
            chance = channel.get("critical_chance", 0)
            if chance:
                damage *= np.where(rng.random(n) < chance, channel.get("critical_multiplier", 1.5), 1)
            if not first_attempt_seen:
                result["first_packet_lethal_if_landed"] = damage >= stats["health"]
            connected, avoided, blocked = _attack_check(alive, entropy, last_attempt, t, stats["evasion_chance"], stats["block_chance"], rng, rules, channel)
            landed = _landed_delivery(connected, landed_chances[index], quality_rng, channel)
            hp -= np.where(landed, damage, 0)
            fatal = landed & (hp <= 0)
            if not first_attempt_seen:
                result["first_hit_lethal"] = fatal.copy()
                first_attempt_seen = True
            result["first_landed_hit_lethal"] |= fatal & ~first_connected
            first_connected |= landed
            result["events"] += alive
            result["hits"] += landed
            result["resisted" if channel.get("accuracy_kind", "attack") == "spell" else "missed"] += connected & ~landed
            result["avoided"] += avoided
            result["blocked"] += blocked
            if index in dependent:
                state, dot = dependent[index], channel["on_hit_dot"]
                state["expiry"][state["expiry"] <= t + 1e-8] = 0
                remaining = landed & (hp > 0)
                if dot.get("policy", "refresh") != "stack":
                    fresh = remaining & ((state["expiry"][:, 0] == 0) | (dot.get("policy") == "replace"))
                    state["next"][fresh, 0] = t + dot["period"]
                    state["expiry"][remaining, 0] = t + dot["duration"]
                else:
                    for slot in range(state["expiry"].shape[1]):
                        add = remaining & (state["expiry"][:, slot] == 0)
                        state["expiry"][add, slot] = t + dot["duration"]
                        state["next"][add, slot] = t + dot["period"]
                        remaining &= ~add
        died = alive & (hp <= 0)
        death[died] = t
    alive = np.isinf(death)
    hp[alive] = np.minimum(stats["health"][alive], hp[alive] + stats["health_regen"][alive] * (end - previous))
    return {**result, "death_time": death, "hp_end": hp}


def _outgoing_magnitude(builds, stats, pattern, rules, targets, periodic=False):
    source = pattern.get("power_source", "intellect")
    power = stats[source + "_power"]
    kind = pattern["damage_type"]
    bonus = stats["general"].copy()
    if kind in ("fire", "frost", "lightning"):
        bonus += stats["elemental_damage"]
    if periodic:
        bonus += stats["dot_damage"]
    level_scale = 1 + rules["level_payload_per_level"] * (builds["level"] - 1) if pattern.get("scale_with_level", False) else 1
    if periodic:
        if "base_tick" in pattern:
            raw = pattern["base_tick"] * level_scale + pattern.get("power_coefficient", 0) * power
        else:
            ticks = math.floor(pattern["duration"] / pattern["period"])
            raw = (pattern.get("base_total", 0) * level_scale + pattern.get("power_total_coefficient", 0) * power) / ticks
    else:
        raw = (pattern["base_dps"] * level_scale + pattern.get("power_per_second", 0) * power) * pattern["interval"]
    gap = sim.level_gap_factor(builds["level"], targets["enemy_level"], rules)
    return raw * (1 + sim.damage_bonus(bonus, rules)) * gap * _mitigation(pattern, stats, targets, rules, False)


def simulate_outgoing(builds, stats, pattern, rng, rules, pressure_config, targets=None):
    sim.require_legacy_report_schema(rules)
    n, end = len(builds["primary"]), pressure_config["duration"]
    if targets is None:
        targets = sample_targets(n, rng, builds["level"], rules, pressure_config)
    stamina = pattern["resource"] == "stamina"
    pool_max = stats["stamina"] if stamina else stats["mana"]
    regen = stats["stamina_regen"] if stamina else stats["mana_regen"]
    resource = pool_max.copy()
    base_action = pattern.get("cast_time", pattern["interval"])
    rating = stats["attack_speed_rating"] if stamina else stats["cast_speed_rating"]
    speed = sim.action_speed_rate(base_action, pattern["minimum_action_duration"], rating, rules,
                                  stats["encumbrance_multiplier"], stamina)
    interval = base_action / speed
    if pattern.get("cooldown", 0) > 0:
        interval = np.maximum(interval, sim.efficient_cost(pattern["cooldown"], stats["cooldown_recovery"]))
    cost = sim.efficient_cost(pattern["cost_per_second"] * pattern["interval"], stats["cost_efficiency"])
    first = pattern.get("first_event", "after_interval")
    next_action = interval.copy() if first == "after_interval" else np.full(n, first, dtype=float)
    next_action[cost > pool_max + 1e-9] = np.inf
    elapsed = np.zeros(n)
    hp = targets["health"].copy()
    kill = np.full(n, np.inf)
    entropy, last_attempt = np.zeros(n), np.full(n, -np.inf)
    quality_rng = sim.quality_random(rng)
    landed_chance = sim.delivery_chance(builds["level"], targets["enemy_level"], stats,
                                      pattern.get("accuracy_kind", "attack"), rules)
    potential, actual = np.zeros(n), np.zeros(n)
    actions, landed_count, evaded_count, blocked_count, starvation = [np.zeros(n, dtype=np.int16) for _ in range(5)]
    missed_count = np.zeros(n, dtype=np.int16)
    resisted_count = np.zeros(n, dtype=np.int16)
    is_dot = pattern["kind"] == "dot"
    dot = pattern if is_dot else pattern.get("on_hit_dot")
    if dot:
        dot = {"power_source": pattern["power_source"], **dot}
        dot_mag = _outgoing_magnitude(builds, stats, dot, rules, targets, True)
        slots = dot.get("maximum_stacks", 1)
        expiry = np.zeros((n, slots))
        next_tick = np.full((n, slots), np.inf)
    else:
        expiry = np.zeros((n, 1))
        next_tick = np.full((n, 1), np.inf)
    magnitude = np.zeros(n) if is_dot else _outgoing_magnitude(builds, stats, pattern, rules, targets)
    for _ in range(20000):
        tick_time = next_tick.min(axis=1)
        now = np.minimum(next_action, tick_time)
        active = now <= end + 1e-9
        if not np.any(active):
            break
        resource[active] = np.minimum(pool_max[active], resource[active] + regen[active] * (now[active] - elapsed[active]))
        elapsed[active] = now[active]
        damage = np.zeros(n)
        if dot:
            due = (next_tick <= now[:, None] + 1e-9) & (next_tick <= expiry + 1e-9) & (expiry > 0) & active[:, None]
            damage += due.sum(axis=1) * dot_mag
            next_tick[due] += dot["period"]
            ended = expiry <= now[:, None] + 1e-9
            expiry[ended] = 0
            next_tick[ended] = np.inf
        ready = active & (next_action <= now + 1e-9)
        paid = ready & (resource + 1e-9 >= cost)
        waiting = ready & ~paid
        starvation += waiting
        can_recover = waiting & (regen > 0) & (cost <= pool_max + 1e-9)
        next_action[waiting] = np.inf
        next_action[can_recover] = now[can_recover] + (cost[can_recover] - resource[can_recover]) / regen[can_recover]
        resource[paid] = np.maximum(0, resource[paid] - cost[paid])
        next_action[paid] = now[paid] + interval[paid]
        actions += paid
        application = paid.copy()
        if not is_dot:
            connected, avoided, blocked = _attack_check(paid, entropy, last_attempt, now, targets["evasion_chance"], targets["block_chance"], rng, rules, pattern)
            landed = _landed_delivery(connected, landed_chance, quality_rng, pattern)
            critical = rng.random(n) < stats["critical_chance_fraction"]
            hit_damage = magnitude * np.where(critical, stats["critical_multiplier_value"], 1)
            damage += np.where(landed, hit_damage, 0)
            application = landed
            landed_count += landed
            evaded_count += avoided
            blocked_count += blocked
            if pattern.get("accuracy_kind", "attack") == "spell":
                resisted_count += connected & ~landed
            else:
                missed_count += connected & ~landed
        else:
            application = _landed_delivery(paid, landed_chance, quality_rng, pattern)
            landed_count += application
            if pattern.get("accuracy_kind", "attack") == "spell":
                resisted_count += paid & ~application
            else:
                missed_count += paid & ~application
        if dot:
            if dot.get("policy", "refresh") in ("refresh", "replace"):
                fresh = application & ((expiry[:, 0] == 0) | (dot.get("policy") == "replace"))
                next_tick[fresh, 0] = now[fresh] + dot["period"]
                expiry[application, 0] = now[application] + dot["duration"]
            else:
                remaining = application.copy()
                for slot in range(expiry.shape[1]):
                    add = remaining & (expiry[:, slot] == 0)
                    expiry[add, slot] = now[add] + dot["duration"]
                    next_tick[add, slot] = now[add] + dot["period"]
                    remaining &= ~add
        actual += np.minimum(np.maximum(hp, 0), damage)
        potential += damage
        hp -= damage
        first_kill = np.isinf(kill) & (hp <= 0)
        kill[first_kill] = now[first_kill]
    else:
        raise RuntimeError("Outgoing event loop exceeded its safety bound")
    # Output after the first kill is counterfactual training-target continuation.
    return {"kill_time": kill, "potential_damage": potential, "actual_health_removed": actual,
            "actions": actions, "hits": landed_count, "avoided": evaded_count,
            "blocked": blocked_count, "missed": missed_count, "resisted": resisted_count,
            "resource_waits": starvation, "action_speed_rate": speed}
