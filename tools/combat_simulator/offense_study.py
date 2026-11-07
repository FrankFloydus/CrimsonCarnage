#!/usr/bin/env python3
"""Matched offensive investment experiments; proposals, not game item values.

Level primary points remain primary points. A separate, conserved experimental
secondary budget buys existing offensive attributes. Every investment strategy
retains its direct Hits and automatic ailments. A shared event stream measures
multiple passive target defenses and finite TTK thresholds without fake Health.
"""
from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import math
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

import dexterity_study as dex
import simulator as sim

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
EPS = 1e-8
STATS = ("power", "dexterity", "dot_damage", "critical_chance", "critical_damage",
         "speed", "hit", "ailment_chance", "penetration", "regeneration")
STRATEGIES = ("hit_focused", "dot_focused", "mixed")


def default_config():
    return {
        "description": "Matched primary and secondary offensive funding; no game item prices.",
        "seed": 20261106, "levels": [1, 10, 30, 60], "primary_power_fractions": [.8, .5, .2],
        "secondary_budgets": [0., 25., 75.], "candidates_per_strategy": 4,
        "dot_price_variants": {"dot_expensive": .5, "reference": 1., "dot_cheap": 2.},
        "units_per_credit": {"power": 1., "dexterity": 1., "dot_damage": 5.,
                             "critical_chance": 1., "critical_damage": 3., "speed": 2.,
                             "hit": 2., "ailment_chance": 2., "penetration": 1.5,
                             "regeneration": .015},
        "main_costs": ["free", "base_sustainable"], "main_other_hit": 0.,
        "trials": 128, "windows": [5., 30., 120.], "target_health": [500., 2000., 10000.],
        "target_absorption": [0., 1000.], "physical_armor": [0., 500., 1000.],
        "magic_resistance": [0., 40., 80.], "base_dps": 100., "minimum_fraction": .4,
        "critical_chance_base": 5., "critical_damage_base": 0., "ordinary_chance_base": 20.,
        "dexterity_hit_per_point": 1., "dexterity_speed_per_point": 1.,
        "magic_coefficient_scale": 1., "damage_roll_range": [.8, 1.2],
        "sensitivity_level": 60, "sensitivity_budget": 75.,
    }


def validate_config(config, rules):
    if not config["levels"] or any(not isinstance(x, int) or not 1 <= x <= rules["max_level"] for x in config["levels"]):
        raise ValueError("Levels must be valid integer game levels")
    if len(set(config["levels"])) != len(config["levels"]):
        raise ValueError("Duplicate levels duplicate evidence")
    if config["trials"] < 2 or config["candidates_per_strategy"] < 1:
        raise ValueError("At least two trials and one candidate required")
    if config["windows"] != sorted(set(config["windows"])) or any(x <= 0 for x in config["windows"]):
        raise ValueError("Positive increasing windows required")
    if any(not math.isfinite(x) or x < 0 for x in config["secondary_budgets"]):
        raise ValueError("Finite nonnegative funding required")
    if any(not math.isfinite(x) or x <= 0 for x in config["units_per_credit"].values()):
        raise ValueError("Finite positive unit conversions required")
    if len(config["physical_armor"]) != len(config["magic_resistance"]):
        raise ValueError("Matched mitigation cases required")


def funding_weights(strategy, candidate, style, seed):
    """Deliberately different investment focuses, never different damage rules."""
    shapes = {
        "hit_focused": [1.5, .6, 0., 1., 1., 1., .5, 0., .5, .4],
        "dot_focused": [1., .5, 2., .8, 0., .5, .5, 1.5, .5, .4],
        "mixed": [1., .6, 1., .8, .6, .8, .5, .6, .4, .4],
    }[strategy]
    shapes = np.array(shapes, float)
    if not dex.STYLES[style]["attack"]:
        shapes[STATS.index("penetration")] = 0.
    if dex.STYLES[style]["family"] is None:
        shapes[STATS.index("dot_damage")] = 0.
        shapes[STATS.index("ailment_chance")] = 0.
    if candidate == 0:
        return shapes
    anchors = {
        "hit_focused": ({"power": 1.}, {"critical_chance": 1., "critical_damage": 1.}),
        "dot_focused": ({"power": 1., "dot_damage": 1.}, {"dot_damage": 1., "ailment_chance": 1.},
                        {"dot_damage": 1., "critical_chance": 1.}),
        "mixed": ({"power": 1., "speed": 1.}, {"power": 1., "dot_damage": 1., "critical_chance": 1.}),
    }[strategy]
    if candidate <= len(anchors):
        weights = np.array([anchors[candidate-1].get(key, 0.) for key in STATS])
        if dex.STYLES[style]["family"] is None:
            weights[STATS.index("dot_damage")] = 0.
            weights[STATS.index("ailment_chance")] = 0.
        return weights
    rng = np.random.default_rng(np.random.SeedSequence([seed, candidate, STRATEGIES.index(strategy), 1201]))
    return np.where(shapes > 0, rng.gamma(np.maximum(.15, shapes), 1.), 0.)


def fund_stats(weights, budget, primary_dex, other_hit, units, config, hit_requirement=50.):
    """Conserve spending; capped points are reinvested into uncapped power."""
    spend = np.asarray(weights, float)/np.sum(weights)*budget
    index = {key: i for i, key in enumerate(STATS)}
    for key, allowance in (("critical_chance", 100-config["critical_chance_base"]),
                           ("ailment_chance", 100-config["ordinary_chance_base"]),
                           ("penetration", 100.)):
        maximum = allowance/units[key]
        excess = max(0., spend[index[key]]-maximum)
        spend[index[key]] -= excess
        spend[index["power"]] += excess
    dex_total = primary_dex+spend[index["dexterity"]]*units["dexterity"]
    hit_allowance = max(0., hit_requirement-other_hit-dex_total*config["dexterity_hit_per_point"])
    maximum = hit_allowance/units["hit"]
    excess = max(0., spend[index["hit"]]-maximum)
    spend[index["hit"]] -= excess
    spend[index["power"]] += excess
    if not math.isclose(float(spend.sum()), budget, abs_tol=1e-8):
        raise AssertionError("Secondary funding not conserved")
    return dict(zip(STATS, map(float, spend)))


def make_profile(level, power_fraction, style, strategy, candidate, budget, price, cost,
                 other_hit, config, rules, magic_scale=None):
    primary = dex.point_budget(level, rules)
    primary_power = int(math.floor(primary*power_fraction+.5))
    primary_dex = primary-primary_power
    units = dict(config["units_per_credit"])
    units["dot_damage"] *= config["dot_price_variants"][price]
    spending = fund_stats(funding_weights(strategy, candidate, style, config["seed"]),
                         budget, primary_dex, other_hit, units, config,
                         float(sim.required_hit_rating(level, level, rules)))
    purchased = {key: spending[key]*units[key] for key in STATS}
    power = primary_power+purchased["power"]
    dexterity = primary_dex+purchased["dexterity"]
    action = dex.STYLES[style]
    resource = "stamina" if action["attack"] else "mana"
    base_regen = rules[resource+"_regen_base"]+rules[resource+"_regen_per_level"]*(level-1)
    regen = base_regen*(1+purchased["regeneration"])
    base = action["base_duration"]
    scale = config["magic_coefficient_scale"] if magic_scale is None else magic_scale
    packet = config["base_dps"]*base
    flat = 0.
    if action["attack"]:
        packet *= float(sim.strength_physical_multiplier(rules["base_primary"]+power, rules))
    else:
        flat = power*rules["intellect_magic_power_per_point"]*base*config["base_dps"]/100*scale
    rating = dexterity*config["dexterity_speed_per_point"]+purchased["speed"]
    result = {
        "level": level, "style": style, "strategy": strategy, "candidate": candidate,
        "primary_budget": primary, "primary_power": primary_power, "primary_dex": primary_dex,
        "power_points": power, "dexterity_points": dexterity, "secondary_budget": budget,
        "price": price, "spending": spending, "cost_policy": cost, "other_hit": other_hit,
        "magic_scale": scale, "base_duration": base, "duration": float(sim.rating_duration(
            base, base*config["minimum_fraction"], rating, rules)),
        "resource_max": rules["base_"+resource]+rules[resource+"_per_level"]*(level-1)
            +power*rules["strength_stamina_per_point" if action["attack"] else "intellect_mana_per_point"],
        "resource_regen": regen, "cost": {"free": 0., "base_sustainable": 1., "heavy": 2.}[cost]*base_regen*base,
        "hit_chance": float(sim.hit_chance(level, level,
            other_hit+dexterity*config["dexterity_hit_per_point"]+purchased["hit"], rules)),
        "base_packet": packet, "flat_magic": flat, "family": action["family"],
        "critical_chance": config["critical_chance_base"]+purchased["critical_chance"],
        "critical_damage": config["critical_damage_base"]+purchased["critical_damage"],
        "ordinary_chance": config["ordinary_chance_base"]+purchased["ailment_chance"],
        "dot_damage": purchased["dot_damage"], "penetration": purchased["penetration"],
        "speed_rating": rating,
        "availability": "continuous",
    }
    return result


def windowed_action_schedule(duration, capacity, regen, cost, horizon, on=5., off=5.):
    """Actions must fit inside active windows; resources recover through pauses."""
    if min(duration, capacity, on, off) <= 0 or min(regen, cost) < 0:
        raise ValueError("Invalid action availability/resource values")
    if duration > on+EPS or cost > capacity+EPS:
        return np.array([]), np.array([]), []
    period, ready, resource_time, available = on+off, 0., 0., capacity
    starts, releases, waits = [], [], []
    while ready <= horizon+EPS:
        phase = ready % period
        if phase+duration > on+EPS:
            ready = (math.floor(ready/period)+1)*period
        if ready > horizon+EPS:
            break
        available = min(capacity, available+(ready-resource_time)*regen)
        resource_time = ready
        if available+EPS < cost:
            if regen <= 0:
                waits.append((ready, horizon)); break
            delay = (cost-available)/regen
            waits.append((ready, min(ready+delay, horizon)))
            ready += delay
            continue
        available -= cost
        starts.append(ready)
        if ready+.6*duration <= horizon+EPS:
            releases.append(ready+.6*duration)
        ready += duration
    return np.array(starts), np.array(releases), waits


def targets_for(profile, config, rules):
    result = []
    for mitigation in range(len(config["physical_armor"])):
        if dex.STYLES[profile["style"]]["attack"]:
            armor = config["physical_armor"][mitigation]
            reduction = float(sim.defense(armor*(1-profile["penetration"]/100), rules))
            defense = armor
        else:
            defense = config["magic_resistance"][mitigation]
            reduction = defense/100
        for absorption in config["target_absorption"]:
            result.append({"mitigation_case": mitigation, "defense_value": defense,
                           "reduction": reduction, "absorption": absorption})
    return result


def simulate(profile, config, rules, trials, seed):
    """One source schedule, a matrix of passive damage-measurement targets."""
    rng = np.random.default_rng(seed)
    horizon = max(config["windows"])
    scheduler = windowed_action_schedule if profile["availability"] == "five_on_five_off" else dex.action_schedule
    starts, releases, waits = scheduler(profile["duration"], profile["resource_max"],
        profile["resource_regen"], profile["cost"], horizon)
    targets = targets_for(profile, config, rules)
    shape = (len(targets), trials)
    reduction = np.array([t["reduction"] for t in targets])[:, None]
    maximum_abs = np.array([t["absorption"] for t in targets])[:, None]
    absorption = np.broadcast_to(maximum_abs, shape).copy()
    direct, periodic, health, absorbed = (np.zeros(shape) for _ in range(4))
    last_hit = np.full(shape, -1e9)
    hollow = np.zeros(shape)
    hollow_end = np.zeros(shape)
    thresholds = np.array(config["target_health"])[:, None, None]
    ttk = np.full((len(thresholds), *shape), np.inf)
    retained = {"rate": np.zeros(shape), "end": np.zeros(shape), "next": np.full(shape, np.inf)}
    queue, sequence, release_index, window_index, previous = [], 0, 0, 0, 0.
    snapshots = []
    family = profile["family"]

    def route(amount, is_periodic, bypass, now):
        nonlocal absorption
        if np.any(amount < -EPS) or np.any(~np.isfinite(amount)):
            raise AssertionError("Invalid damage event")
        prevented = np.zeros_like(amount) if bypass else np.minimum(absorption, amount)
        absorption -= prevented
        absorbed[:] += prevented
        health[:] += amount-prevented
        (periodic if is_periodic else direct)[:] += amount
        if not is_periodic:
            last_hit[amount > 0] = now
        crossed = np.isinf(ttk) & (health[None, :, :]+EPS >= thresholds)
        ttk[crossed] = now

    while window_index < len(config["windows"]):
        next_release = releases[release_index] if release_index < len(releases) else np.inf
        eligible = np.where(retained["next"] <= retained["end"]+EPS, retained["next"], np.inf)
        next_tick = min(float(eligible.min()), queue[0][0] if queue else np.inf)
        expiry = float(np.where(retained["rate"] > 0, retained["end"], np.inf).min())
        now = min(next_release, next_tick, expiry, config["windows"][window_index])
        eligible_start = np.maximum(previous, last_hit+rules["absorption_recovery_delay"])
        seconds = np.maximum(0., now-eligible_start)
        overlap = np.clip(np.minimum(now, hollow_end)-eligible_start, 0., seconds)
        recovery = maximum_abs*rules["absorption_recovery_fraction"]*(seconds-hollow*overlap)
        absorption = np.minimum(maximum_abs, absorption+recovery)
        hollow[hollow_end <= now+EPS] = 0.
        if family in ("burn", "bleed"):
            route(dex._single_due(now, rules[family+"_period"], retained), True, family == "bleed", now)
        while queue and queue[0][0] <= now+EPS:
            _, _, amount = heapq.heappop(queue)
            route(amount, True, True, now)
        if next_release <= now+EPS:
            raw = profile["base_packet"]*rng.uniform(*config["damage_roll_range"], trials)+profile["flat_magic"]
            ordinary = raw[None, :]*(1-reduction)
            landed = rng.random(trials) < profile["hit_chance"]
            critical = landed & (rng.random(trials) < profile["critical_chance"]/100)
            packet = ordinary*landed[None, :]*np.where(critical,
                sim.critical_damage_multiplier(profile["critical_damage"], rules), 1)[None, :]
            route(packet, False, dex.STYLES[profile["style"]]["school"] == "necrotic", now)
            proc = landed & (critical | (rng.random(trials) < profile["ordinary_chance"]/100))
            if family:
                rate = sim.ailment_damage_rate(ordinary, family, profile["dot_damage"], rules)
                period, duration = rules[family+"_period"], rules[family+"_duration"]
                if family == "poison":
                    for tick in np.arange(period, duration+EPS, period):
                        if now+tick <= horizon+EPS:
                            heapq.heappush(queue, (now+tick, sequence, rate*period*proc[None, :]))
                            sequence += 1
                else:
                    dex._single_application(rate, np.broadcast_to(proc, shape), now,
                        duration, period, retained)
            else:
                value = sim.ailment_potency(ordinary, profile["level"], rules)*rules["hollowed_recovery_reduction_max"]
                active = hollow_end > now+EPS
                stronger = proc[None, :] & (~active | (value > hollow+EPS))
                equal = proc[None, :] & active & np.isclose(value, hollow, rtol=1e-9, atol=EPS)
                hollow[stronger] = value[stronger]
                hollow_end[stronger] = now+rules["hollowed_duration"]
                hollow_end[equal] = np.maximum(hollow_end[equal], now+rules["hollowed_duration"])
            release_index += 1
        if config["windows"][window_index] <= now+EPS:
            window = config["windows"][window_index]
            snapshots.append({"window": window, "direct": direct.copy(), "periodic": periodic.copy(),
                              "health": health.copy(), "absorbed": absorbed.copy(),
                              "actions": int(np.count_nonzero(starts <= window+EPS)),
                              "releases": int(np.count_nonzero(releases <= window+EPS)),
                              "resource": dex.resource_at(window, starts, profile["resource_max"], profile["resource_regen"], profile["cost"]),
                              "resource_wait": sum(max(0., min(end, window)-start) for start, end in waits if start < window)})
            window_index += 1
        previous = now
    return {"snapshots": snapshots, "ttk": ttk, "targets": targets}


def summarize(profile, result, trials, config, case_id, experiment):
    rows = []
    for target_index, target in enumerate(result["targets"]):
        row = {k: v for k, v in profile.items() if k not in ("family", "spending")}
        row.update(case_id=case_id, experiment=experiment, trials=trials, **target)
        row.update({"spent_"+k: v for k, v in profile["spending"].items()})
        for snap in result["snapshots"]:
            label = f"{snap['window']:g}s"
            total = snap["direct"][target_index]+snap["periodic"][target_index]
            row["dps_"+label] = float(total.mean()/snap["window"])
            row["dps_se_"+label] = float(total.std(ddof=1)/math.sqrt(trials)/snap["window"])
            for metric in ("direct", "periodic", "health", "absorbed"):
                row[metric+"_dps_"+label] = float(snap[metric][target_index].mean()/snap["window"])
            row["periodic_fraction_"+label] = float(snap["periodic"][target_index].sum()/max(EPS, total.sum()))
            row["actions_"+label], row["resource_"+label], row["resource_wait_"+label] = snap["actions"], snap["resource"], snap["resource_wait"]
        for i, threshold in enumerate(config["target_health"]):
            values = result["ttk"][i, target_index]
            observed = values[np.isfinite(values)]
            label = f"{threshold:g}"
            row["kills_hp"+label] = len(observed)
            row["censored_hp"+label] = trials-len(observed)
            row["ttk_hp"+label] = float(np.median(observed)) if len(observed) else None
            row["restricted_mean_hp"+label] = float(np.minimum(values, max(config["windows"])).mean())
        rows.append(row)
    return rows


def cases(config, rules):
    index = 0
    for level in config["levels"]:
        for style in dex.STYLES:
            for ratio in config["primary_power_fractions"]:
                for budget in config["secondary_budgets"]:
                    for price in config["dot_price_variants"]:
                        if budget == 0 and price != "reference":
                            continue
                        for strategy in STRATEGIES:
                            if budget == 0 and strategy != "mixed":
                                continue
                            if strategy == "dot_focused" and dex.STYLES[style]["family"] is None:
                                continue
                            for candidate in range(config["candidates_per_strategy"]):
                                if budget == 0 and candidate != 0:
                                    continue
                                for cost in config["main_costs"]:
                                    profile = make_profile(level, ratio, style, strategy, candidate,
                                        budget, price, cost, config["main_other_hit"], config, rules)
                                    yield index, "main", profile
                                    index += 1
                                    if (level == config["sensitivity_level"] and budget == config["sensitivity_budget"]
                                            and price == "reference" and cost == "base_sustainable"):
                                        for other_hit, other_cost in ((50., cost), (0., "heavy")):
                                            profile = make_profile(level, ratio, style, strategy, candidate,
                                                budget, price, other_cost, other_hit, config, rules)
                                            yield index, "resource_accuracy", profile
                                            index += 1
                                        profile = make_profile(level, ratio, style, strategy, candidate,
                                            budget, price, cost, 0., config, rules)
                                        profile["availability"] = "five_on_five_off"
                                        yield index, "attack_uptime", profile
                                        index += 1
                                        if not dex.STYLES[style]["attack"]:
                                            for scale in (.5, 2.):
                                                profile = make_profile(level, ratio, style, strategy, candidate,
                                                    budget, price, cost, 0., config, rules, magic_scale=scale)
                                                yield index, "magic_coefficient", profile
                                                index += 1


def job(spec):
    index, experiment, profile, config, rules = spec
    seed = np.random.SeedSequence([config["seed"], profile["level"], list(dex.STYLES).index(profile["style"])])
    result = simulate(profile, config, rules, config["trials"], seed)
    return index, summarize(profile, result, config["trials"], config, index, experiment)


def speed_fixture(rules):
    rows = []
    for dex_rating in (0., 10., 50., 100.):
        for other in (0., 10., 50., 100.):
            correct = float(sim.rating_duration(1., .4, dex_rating+other, rules))
            wrong = float(sim.rating_duration(1., .4, dex_rating, rules)*sim.rating_duration(1., .4, other, rules))
            rows.append({"dexterity_speed_rating": dex_rating, "other_speed_rating": other,
                         "correct_duration": correct, "incorrect_multiplied_duration": wrong,
                         "correct_action_rate": 1/correct, "incorrect_action_rate": 1/wrong})
    packages = [{"package": "dexterity_10", "dexterity": 10., "hit_rating": 10.,
                 "attack_speed_rating": 10., "cast_speed_rating": 10.}]
    packages += [{"package": f"focused_speed_{speed}", "dexterity": 0., "hit_rating": 0.,
                  "attack_speed_rating": speed, "cast_speed_rating": 0.} for speed in (10., 20., 30.)]
    return {"arithmetic": rows, "equal_price_hypotheses": packages}


def write_report(folder, rows, manifest, config):
    lines = ["# Offensive investment comparison", "",
        f"Executed **{manifest['source_cases']:,} source cases** and **{manifest['source_outcomes']:,} stochastic source outcomes**. "
        f"Each source is measured against {manifest['targets_per_source']} passive defense conditions; Health thresholds are repeated measurements, not extra independent builds.", "",
        "Level primary points are conserved separately from experimental secondary funding. Primary points buy only Power/Dexterity. "
        "Secondary funding can buy Power, Dexterity, DoT Damage, Critical Chance/Damage, focused Speed, Hit, ailment chance, penetration and regeneration. "
        "All strategies retain their direct Hits and automatic ailments. No Health recovery, Evasion, Block or Block Power rule is assumed.", "",
        "The reference action has 100 base DPS. Spell coefficients are calibrated for comparable marginal source damage and tested separately at half/double. "
        "Physical fast/slow Hits have equal base DPS. Crits guarantee eligible ailments; their amplification is excluded from ailment seeds. "
        "The main cost axis includes free actions and base-speed-sustainable cost; cost and regeneration do not change when DEX shortens an action.", "",
        "DoT Damage buys 2.5/5/10 percentage points per experimental credit across expensive/reference/cheap hypotheses. "
        "Those are sensitivity inputs, not approved itemization. Caps refund excess spending into uncapped Power. Higher-level enemy content and cooldown-gated abilities are outside this study.", "",
        "Targets pair no/medium/high Armor or school resistance with 0/1000 Absorption. Bleed and Necrotic bypass Absorption; covered damage does not. "
        "Any damaging direct Hit interrupts recharge, while DoTs do not. Void's Hollowed reduces recharge, but other utility/retaliation value is absent. "
        "Finite TTK thresholds are 500/2000/10000 Health. Damage windows continue independently after those thresholds are crossed.", "",
        "## Best sampled strategy, level 60, secondary budget 75, no target mitigation or Absorption", "",
        "Best sampled within each strategy; this is a limited candidate search, not a proof of a global optimum. Main cost is base-speed-sustainable.", "",
        "| Style | DoT price | Best Hit-focused DPS | Best DoT-focused DPS | Best Mixed DPS | Best strategy |",
        "|---|---|---:|---:|---:|---|"]
    for style in dex.STYLES:
        for price in config["dot_price_variants"]:
            selection = [r for r in rows if r["experiment"] == "main" and r["level"] == 60 and r["style"] == style
                and r["secondary_budget"] == 75 and r["price"] == price and r["cost_policy"] == "base_sustainable"
                and r["mitigation_case"] == 0 and r["absorption"] == 0]
            best = {focus: max((r["dps_120s"] for r in selection if r["strategy"] == focus), default=None) for focus in STRATEGIES}
            present = {k: v for k, v in best.items() if v is not None}
            if present:
                values = " | ".join("—" if best[k] is None else f"{best[k]:.1f}" for k in STRATEGIES)
                lines.append(f"| {style} | {price} | {values} | {max(present, key=present.get)} |")
    lines += ["", "## Interpretation limits", "",
        "- Hit-focused and DoT-focused describe investment choices, never disabled damage channels. Mixed strategies can produce mostly periodic output without being labeled DoT-focused.",
        "- Void lacks a damaging ailment. Its stationary-target DPS cannot establish the overall worth of Hollowed or other schools' utility. Match investment strategies within the same action before cross-school conclusions.",
        "- Same-price direct Speed and Dexterity are not automatically equivalent packages. Dexterity grants accuracy and both speed channels; direct Speed buys two rating per credit in this experiment. The separate speed fixture shows the pricing issue and correct additive arithmetic.",
        "- More DEX and more direct Speed add into one rating before the diminishing duration curve. Attack and Cast channels are alternatives for an action, not two multipliers.",
        "- Standard errors are recorded per window. Near-tied best-sample results should not be treated as a robust archetype advantage.",
        f"- Sources unchanged during execution: **{manifest['source_revision_unchanged']}**. Health restoration is absent by construction."]
    (folder/"report.md").write_text("\n".join(lines)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path, default=HERE/"offense_results")
    parser.add_argument("--trials", type=int)
    parser.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--levels", type=int, nargs="+")
    parser.add_argument("--candidates", type=int)
    args = parser.parse_args()
    config = default_config() if args.config is None else sim.read_json(args.config)
    for argument, key in ((args.trials, "trials"), (args.levels, "levels"), (args.candidates, "candidates_per_strategy")):
        if argument is not None:
            config[key] = argument
    rules = sim.read_json(sim.DEFAULT_RULES)
    validate_config(config, rules)
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    paths = [Path(__file__), HERE/"dexterity_study.py", HERE/"simulator.py", sim.DEFAULT_RULES]
    source = {str(path.relative_to(ROOT)): path.read_bytes() for path in paths}
    before = {name: hashlib.sha256(value).hexdigest() for name, value in source.items()}
    for name, value in source.items():
        target = folder/"source_snapshot"/name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(value)
    (folder/"experiment.json").write_text(json.dumps(config, indent=2)+"\n", encoding="utf-8")
    (folder/"rules_snapshot.json").write_text(json.dumps(rules, indent=2)+"\n", encoding="utf-8")
    started, completed = time.perf_counter(), []
    work = [(index, experiment, profile, config, rules) for index, experiment, profile in cases(config, rules)]
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(job, spec) for spec in work]
        for count, future in enumerate(as_completed(futures), 1):
            completed.append(future.result())
            if count % max(1, len(work)//20) == 0 or count == len(work):
                print(json.dumps({"cases_complete": count, "cases": len(work), "elapsed": round(time.perf_counter()-started, 1)}), flush=True)
    rows = [row for _, group in sorted(completed) for row in group]
    after = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    manifest = {"command": sys.argv, "source_cases": len(work), "source_outcomes": len(work)*config["trials"],
        "targets_per_source": len(config["physical_armor"])*len(config["target_absorption"]),
        "target_streams": len(rows)*config["trials"], "metric_rows": len(rows),
        "source_sha256_before": before, "source_sha256_after": after,
        "source_revision_unchanged": before == after, "health_restoration_enabled": False,
        "elapsed_seconds": time.perf_counter()-started}
    if before != after:
        raise RuntimeError("Source changed during execution; rerun before interpreting")
    (folder/"manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    # CSV preserves all candidates/targets without duplicating a very large JSON file.
    import csv
    with (folder/"summaries.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (folder/"speed_fixture.json").write_text(json.dumps(speed_fixture(rules), indent=2)+"\n", encoding="utf-8")
    write_report(folder, rows, manifest, config)
    print(json.dumps(manifest, indent=2), flush=True)


if __name__ == "__main__":
    main()
