#!/usr/bin/env python3
"""Offline Dexterity proposal: matched allocations, exact clocks, no Health recovery.

This is a damage-event measurement ledger, not a combat actor with inflated Health.
Its finite target-Health threshold measures TTK; damage windows continue separately
so short fights do not truncate the sustained-output measurement. Nothing writes
gameplay resources or enables the proposed Dexterity rules in Godot.
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

import simulator as sim

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
EPS = 1e-8
STYLES = {
    "physical_fast": {"school": "physical", "base_duration": .5, "family": "bleed", "attack": True},
    "physical_slow": {"school": "physical", "base_duration": 2., "family": "bleed", "attack": True},
    "magic_direct": {"school": "void", "base_duration": 1., "family": None, "attack": False},
    "fire_spell": {"school": "fire", "base_duration": 1.25, "family": "burn", "attack": False},
    "necrotic_spell": {"school": "necrotic", "base_duration": 1.25, "family": "poison", "attack": False},
}
ALLOCATIONS = {"power_only": 1., "power_heavy": .8, "mixed": .5, "dexterity_heavy": .2, "dexterity_only": 0.}


def default_config():
    return {
        "description": "Offline +1 Hit/+1 Attack Speed/+1 Cast Speed per DEX; no Evasion or Block model.",
        "seed": 20261106, "levels": [1, 10, 30, 60],
        "dexterity_hit_per_point": 1., "dexterity_speed_per_point": 1.,
        "windows": [5., 30., 120.], "base_dps": 100., "target_health": 2000.,
        "minimum_fraction": .4, "other_speed_rating": 0., "magic_coefficient_scale": 1.,
        "critical_chance": 5., "critical_damage": 0., "ordinary_ailment_chance": 20.,
        "dot_damage": 0., "damage_roll_range": [.8, 1.2],
        "hit_gear_cases": [0., 50.], "cost_cases": {"free": 0., "base_sustainable": 1., "heavy": 2.},
        "main_trials": 512, "sensitivity_trials": 256,
        "sensitivity_minimum_fractions": [.25, .6], "sensitivity_speed_ratings": [100.],
        "sensitivity_magic_coefficients": [.5, 2.],
    }


def validate_config(config, rules):
    if not config["levels"] or any(not 1 <= level <= rules["max_level"] for level in config["levels"]):
        raise ValueError("Levels must remain in the game range")
    if len(set(config["levels"])) != len(config["levels"]):
        raise ValueError("Duplicate levels duplicate observations")
    if any(not math.isfinite(x) or x <= 0 for x in config["windows"]):
        raise ValueError("Positive finite windows required")
    if config["windows"] != sorted(set(config["windows"])):
        raise ValueError("Windows must increase without duplicates")
    if not 0 < config["minimum_fraction"] <= 1:
        raise ValueError("Minimum duration fraction must be in (0,1]")
    if config["base_dps"] <= 0 or config["target_health"] <= 0:
        raise ValueError("Positive base DPS and target Health required")
    if any(config[key] < 1 for key in ("main_trials", "sensitivity_trials")):
        raise ValueError("Positive outcome counts required")


def point_budget(level, rules):
    return int(rules["creation_points"] + rules["points_per_level"]*(level-1))


def make_profile(level, allocation, style_name, gear_hit, cost_name, config, rules,
                 minimum_fraction=None, other_speed=None, magic_scale=None):
    style = STYLES[style_name]
    points = point_budget(level, rules)
    power_points = int(math.floor(points*ALLOCATIONS[allocation]+.5))
    dex_points = points-power_points
    if power_points+dex_points != points:
        raise AssertionError("Primary budget not conserved")
    minimum_fraction = config["minimum_fraction"] if minimum_fraction is None else minimum_fraction
    other_speed = config["other_speed_rating"] if other_speed is None else other_speed
    magic_scale = config["magic_coefficient_scale"] if magic_scale is None else magic_scale
    base_duration = style["base_duration"]
    resource = "stamina" if style["attack"] else "mana"
    resource_max = rules["base_"+resource] + rules[resource+"_per_level"]*(level-1)
    capacity_per_point = rules["strength_stamina_per_point"] if style["attack"] else rules["intellect_mana_per_point"]
    resource_max += power_points*capacity_per_point
    regen = rules[resource+"_regen_base"] + rules[resource+"_regen_per_level"]*(level-1)
    cost = config["cost_cases"][cost_name]*regen*base_duration
    # The parity reference gives +1 INT the same *ordinary source-side DPS*
    # increment as +1 STR on this 100-DPS fixture. Other coefficients are
    # explicit sensitivities, not approved spell ranks or item values.
    base_packet = config["base_dps"]*base_duration
    if style["attack"]:
        base_packet *= float(sim.strength_physical_multiplier(rules["base_primary"]+power_points, rules))
        flat_magic = 0.
    else:
        flat_magic = power_points*rules["intellect_magic_power_per_point"]*base_duration*config["base_dps"]/100*magic_scale
    return {
        "level": level, "allocation": allocation, "style": style_name,
        "point_budget": points, "power_points": power_points, "dexterity_points": dex_points,
        "gear_hit": gear_hit, "cost_policy": cost_name, "resource": resource,
        "resource_max": resource_max, "resource_regen": regen, "cost": cost,
        "base_duration": base_duration, "minimum_fraction": minimum_fraction,
        "other_speed_rating": other_speed, "magic_coefficient_scale": magic_scale,
        "duration": float(sim.rating_duration(base_duration, base_duration*minimum_fraction,
                                               other_speed+dex_points*config["dexterity_speed_per_point"], rules)),
        "hit_chance": float(sim.hit_chance(level, level, gear_hit+dex_points*config["dexterity_hit_per_point"], rules)),
        "base_packet": base_packet, "flat_magic": flat_magic, "family": style["family"],
    }


def action_schedule(duration, capacity, regen, cost, horizon):
    """Exact start/release clocks with continuous regeneration and no cooldown."""
    if min(duration, capacity) <= 0 or min(regen, cost) < 0:
        raise ValueError("Invalid action/resource parameters")
    starts, releases, waits = [], [], []
    current, ready, resource = 0., 0., capacity
    while ready <= horizon+EPS:
        if cost > capacity+EPS or (resource+EPS < cost and regen == 0):
            waits.append((ready, horizon))
            break
        delay = max(0., (cost-resource)/regen) if regen > 0 else 0.
        current = ready+delay
        if delay > EPS:
            waits.append((ready, min(current, horizon)))
        if current > horizon+EPS:
            break
        resource = min(capacity, resource+delay*regen)-cost
        starts.append(current)
        release = current+.6*duration
        if release <= horizon+EPS:
            releases.append(release)
        resource = min(capacity, resource+duration*regen)
        ready = current+duration
    return np.array(starts), np.array(releases), waits


def resource_at(window, starts, capacity, regen, cost):
    previous, available = 0., capacity
    for start in starts:
        if start > window+EPS:
            break
        available = min(capacity, available+(start-previous)*regen)-cost
        previous = start
    return min(capacity, available+(window-previous)*regen)


def _single_application(rate, proc, now, duration, period, state):
    active = (state["rate"] > 0) & (state["end"] > now+EPS)
    stronger = proc & (~active | (rate > state["rate"]+EPS))
    equal = proc & active & np.isclose(rate, state["rate"], rtol=1e-9, atol=EPS)
    new = stronger & ~active
    state["rate"][stronger] = rate[stronger]
    state["end"][stronger] = now+duration
    state["end"][equal] = np.maximum(state["end"][equal], now+duration)
    state["next"][new] = now+period


def _single_due(now, period, state):
    due = (state["next"] <= now+EPS) & (state["next"] <= state["end"]+EPS)
    amount = state["rate"]*period*due
    state["next"][due] += period
    # Retain the phase even if its next tick currently lies after expiration:
    # an equal/stronger refresh during that tail can make the tick eligible.
    # Event selection suppresses ineligible ticks without destroying the phase.
    expired = state["end"] <= now+EPS
    state["rate"][expired] = 0.
    state["next"][expired] = np.inf
    return amount


def simulate(profile, config, rules, trials, seed):
    """Measure a passive-target damage stream without a target Health pool."""
    rng = np.random.default_rng(seed)
    horizon = max(config["windows"])
    starts, releases, waits = action_schedule(profile["duration"], profile["resource_max"],
                                               profile["resource_regen"], profile["cost"], horizon)
    total, direct, periodic = (np.zeros(trials) for _ in range(3))
    hits, crits = np.zeros(trials, int), np.zeros(trials, int)
    ttk = np.full(trials, np.inf)
    family = profile["family"]
    retained = {"rate": np.zeros(trials), "end": np.zeros(trials), "next": np.full(trials, np.inf)}
    queue, sequence = [], 0
    snapshots = []
    release_index, window_index = 0, 0

    def damage(amount, is_periodic, now):
        nonlocal total, direct, periodic
        if np.any(amount < -EPS) or np.any(~np.isfinite(amount)):
            raise AssertionError("Invalid damage event")
        total += amount
        if is_periodic:
            periodic += amount
        else:
            direct += amount
        crossed = np.isinf(ttk) & (total+EPS >= config["target_health"])
        ttk[crossed] = now

    while window_index < len(config["windows"]):
        next_release = releases[release_index] if release_index < len(releases) else np.inf
        eligible_tick = np.where(retained["next"] <= retained["end"]+EPS, retained["next"], np.inf)
        next_tick = min(float(eligible_tick.min()), queue[0][0] if queue else np.inf)
        next_expiry = float(np.where(retained["rate"] > 0, retained["end"], np.inf).min())
        now = min(next_release, next_tick, next_expiry, config["windows"][window_index])
        # Final due ticks resolve before a same-time replacement or expiration.
        if family in ("burn", "bleed"):
            damage(_single_due(now, rules[family+"_period"], retained), True, now)
        while queue and queue[0][0] <= now+EPS:
            _, _, amount = heapq.heappop(queue)
            damage(amount, True, now)
        if next_release <= now+EPS:
            ordinary = (profile["base_packet"]*rng.uniform(*config["damage_roll_range"], trials)
                        +profile["flat_magic"])
            landed = rng.random(trials) < profile["hit_chance"]
            critical = landed & (rng.random(trials) < config["critical_chance"]/100)
            hits += landed
            crits += critical
            damage(ordinary*landed*np.where(critical, sim.critical_damage_multiplier(config["critical_damage"], rules), 1), False, now)
            if family:
                proc = landed & (critical | (rng.random(trials) < config["ordinary_ailment_chance"]/100))
                rate = sim.ailment_damage_rate(ordinary, family, config["dot_damage"], rules)
                period, duration = rules[family+"_period"], rules[family+"_duration"]
                if family == "poison":
                    for tick in np.arange(period, duration+EPS, period):
                        if now+tick <= horizon+EPS:
                            heapq.heappush(queue, (now+tick, sequence, rate*period*proc))
                            sequence += 1
                else:
                    _single_application(rate, proc, now, duration, period, retained)
            release_index += 1
        if config["windows"][window_index] <= now+EPS:
            window = config["windows"][window_index]
            snapshots.append({
                "window": window, "damage": total.copy(), "direct_damage": direct.copy(),
                "periodic_damage": periodic.copy(), "hits": hits.copy(), "crits": crits.copy(),
                "actions": int(np.count_nonzero(starts <= window+EPS)),
                "releases": int(np.count_nonzero(releases <= window+EPS)),
                "resource_remaining": resource_at(window, starts, profile["resource_max"], profile["resource_regen"], profile["cost"]),
                "resource_wait": sum(max(0., min(end, window)-start) for start, end in waits if start < window),
            })
            window_index += 1
    return {"windows": snapshots, "ttk": ttk, "health_restoration_enabled": False}


def summarize(profile, result, trials, experiment):
    ttk = result["ttk"]
    observed = ttk[np.isfinite(ttk)]
    row = {key: value for key, value in profile.items() if key != "family"}
    row.update(experiment=experiment, trials=trials, kills=len(observed), censored=trials-len(observed),
               kill_fraction=len(observed)/trials,
               conditional_ttk_median=float(np.median(observed)) if len(observed) else None,
               conditional_ttk_mean=float(observed.mean()) if len(observed) else None)
    for snapshot in result["windows"]:
        label = f"{snapshot['window']:g}s"
        for name in ("damage", "direct_damage", "periodic_damage", "hits", "crits"):
            row[name+"_"+label] = float(snapshot[name].mean())
        row["dps_"+label] = float(snapshot["damage"].mean()/snapshot["window"])
        row["dps_standard_error_"+label] = (float(snapshot["damage"].std(ddof=1)/math.sqrt(trials)/snapshot["window"])
                                                if trials > 1 else None)
        for name in ("actions", "releases", "resource_remaining", "resource_wait"):
            row[name+"_"+label] = snapshot[name]
    return row


def specs(config, rules):
    for level in config["levels"]:
        for allocation in ALLOCATIONS:
            for style in STYLES:
                for gear_hit in config["hit_gear_cases"]:
                    for cost in config["cost_cases"]:
                        yield ("main", make_profile(level, allocation, style, gear_hit, cost, config, rules), config["main_trials"])
                        for minimum in config["sensitivity_minimum_fractions"]:
                            yield ("minimum_duration", make_profile(level, allocation, style, gear_hit, cost, config, rules,
                                                                     minimum_fraction=minimum), config["sensitivity_trials"])
                        for speed in config["sensitivity_speed_ratings"]:
                            yield ("existing_speed", make_profile(level, allocation, style, gear_hit, cost, config, rules,
                                                                   other_speed=speed), config["sensitivity_trials"])
                        if not STYLES[style]["attack"]:
                            for coefficient in config["sensitivity_magic_coefficients"]:
                                yield ("magic_coefficient", make_profile(level, allocation, style, gear_hit, cost, config, rules,
                                                                          magic_scale=coefficient), config["sensitivity_trials"])


def job(spec):
    index, experiment, profile, trials, config, rules = spec
    # Counterfactual allocations share the same seed for each environment. The
    # source action timing may diverge, so this pairs outcome streams, not hits.
    seed = np.random.SeedSequence([config["seed"], profile["level"], list(STYLES).index(profile["style"])])
    result = simulate(profile, config, rules, trials, seed)
    return index, summarize(profile, result, trials, experiment)


def write_report(folder, rows, manifest, config):
    last_level = max(config["levels"])
    window_labels = [f"{window:g}s" for window in config["windows"]]
    dps_headers = " | ".join(label+" DPS" for label in window_labels)
    table_rule = "|---|---:|---|---:|"+"---:|"*len(window_labels)+"---:|---:|"
    lines = ["# Dexterity allocation proposal comparison", "",
             f"Executed **{manifest['trials']:,} outcome trials** across **{len(rows):,} controlled allocation/environment cases**. "
             "This tests an offline proposal; game attributes and resources are unchanged.", "",
             "All primary points go to Strength/Dexterity or Intellect/Dexterity. Other primaries stay at their baseline. "
             f"Dexterity grants {config['dexterity_hit_per_point']:g} Hit Rating and {config['dexterity_speed_per_point']:g} "
             "appropriate action-speed rating per point above ten; Evasion is absent. "
             "Passive targets do not attack and have no avoidance, Block, mitigation, Absorption or Health recovery.", "",
             f"Reference base damage is {config['base_dps']:g} DPS at every level, an isolation fixture rather than weapon/level content. "
             "Magic's parity coefficient gives the same ordinary source-side DPS per Intellect point as Strength's one-percent "
             "increment on that fixture. Explicit coefficient sensitivities expose that dependency. Damage rolls "
             "affect the base packet only; flat Magic Power is not randomized.", "",
             f"Crit Chance is {config['critical_chance']:g}%, Critical Damage bonus {config['critical_damage']:g}, "
             f"ordinary ailment chance {config['ordinary_ailment_chance']:g}%. Physical attacks seed Bleed, "
             "Fire seeds Burn, Necrotic seeds independent Poison stacks. The direct-magic fixture uses Void; "
             "Hollowed has no damage consequence against this target without recovery. "
             f"Damage is measured for {'/'.join(window_labels)} independently of a {config['target_health']:g}-Health TTK threshold. Crossing that "
             "threshold does not truncate sustained measurement. Unobserved kills are explicitly censored.", "",
             f"## Level-{last_level} main reference, free actions", "",
             f"Minimum duration is {config['minimum_fraction']:.0%} of base, other speed {config['other_speed_rating']:g}. "
             "The table reports complete-window damage per second, "
             "including automatic ailments, and conditional median TTK.", "",
             f"| Style | Other Hit | Allocation | Power / DEX points | {dps_headers} | Median TTK | Censored |",
             table_rule]
    for row in rows:
        if row["experiment"] == "main" and row["level"] == last_level and row["cost_policy"] == "free":
            ttk = "—" if row["conditional_ttk_median"] is None else f"{row['conditional_ttk_median']:.2f}"
            dps_values = " | ".join(f"{row['dps_'+label]:.2f}" for label in window_labels)
            lines.append(f"| {row['style']} | {row['gear_hit']:g} | {row['allocation']} | {row['power_points']} / {row['dexterity_points']} | "
                         f"{dps_values} | {ttk} | {row['censored']} |")
    lines += ["", "## Reading the full results", "",
              "- Main rows isolate the proposed coefficient. Minimum-duration, existing-speed, and half/double-Magic-Power rows vary one factor at a time.",
              "- Resource policies charge zero, one, or two times the neutral actor's regeneration during one base action. Costs are identical across allocations of the same action/level; these are sensitivity inputs, not approved weapon or spell costs.",
              "- Strength/Intellect also add their accepted resource capacity. Regeneration remains the same across allocations, and spending never pauses it. Faster actions can exhaust the resource and wait.",
              "- One ordinary Hit seed drives each ailment; critical amplification is excluded. Burn/Bleed preserve strongest-family ticks and equal refresh; Poison adds independent full-lifetime applications.",
              "- Summary rows include Monte Carlo standard errors for window DPS. A difference comparable to those errors is not a reliable ordering. Shared seeds pair streams but action timing differs, so no paired confidence interval is asserted.",
              "- These are outgoing comparisons, not enemy TTK, passive defense, movement, shield or manual-skill tests. No rule for the undecided Block Power system is assumed.",
              f"- All source hashes stable during run: **{manifest['source_revision_unchanged']}**. Health restoration is disabled by construction."]
    (folder/"report.md").write_text("\n".join(lines)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path, default=HERE/"dexterity_results")
    parser.add_argument("--trials", type=int)
    parser.add_argument("--sensitivity-trials", type=int)
    parser.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--main-only", action="store_true")
    args = parser.parse_args()
    config = default_config() if args.config is None else sim.read_json(args.config)
    if args.trials is not None:
        config["main_trials"] = args.trials
    if args.sensitivity_trials is not None:
        config["sensitivity_trials"] = args.sensitivity_trials
    if args.main_only:
        for key in ("sensitivity_minimum_fractions", "sensitivity_speed_ratings", "sensitivity_magic_coefficients"):
            config[key] = []
    rules = sim.read_json(sim.DEFAULT_RULES)
    validate_config(config, rules)
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    paths = [Path(__file__), HERE/"simulator.py", sim.DEFAULT_RULES]
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    for path in paths:
        destination = folder/"source_snapshot"/path.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(path.read_bytes())
    (folder/"experiment.json").write_text(json.dumps(config, indent=2)+"\n", encoding="utf-8")
    (folder/"rules_snapshot.json").write_text(json.dumps(rules, indent=2)+"\n", encoding="utf-8")
    cases = list(specs(config, rules))
    jobs = [(i, *case, config, rules) for i, case in enumerate(cases)]
    rows = []
    started = time.perf_counter()
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(job, spec) for spec in jobs]
        for done, future in enumerate(as_completed(futures), 1):
            rows.append(future.result())
            if done % max(1, len(jobs)//20) == 0 or done == len(jobs):
                print(json.dumps({"cases_complete": done, "total": len(jobs), "elapsed": round(time.perf_counter()-started, 1)}), flush=True)
    rows = [row for _, row in sorted(rows)]
    after = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    manifest = {"command": sys.argv, "cases": len(rows), "trials": sum(row["trials"] for row in rows),
                "source_sha256_before": before, "source_sha256_after": after,
                "source_revision_unchanged": before == after, "health_restoration_enabled": False,
                "elapsed_seconds": time.perf_counter()-started, "python": sys.version, "numpy": np.__version__}
    if before != after:
        raise RuntimeError("Sources changed during run")
    (folder/"manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    (folder/"summaries.json").write_text(json.dumps(rows, indent=2)+"\n", encoding="utf-8")
    import csv
    with (folder/"summaries.csv").open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    write_report(folder, rows, manifest, config)
    print(json.dumps({key: value for key, value in manifest.items() if not key.startswith("source_sha256")}, indent=2))


if __name__ == "__main__":
    main()
