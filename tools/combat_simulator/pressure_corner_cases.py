#!/usr/bin/env python3
# Funded adversarial builds repeated across the complete pressure envelope.
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np

import adversarial_audit
import simulator as sim
import pressure_sweep as sweep


BASE_NAMES = adversarial_audit.NAMES
ELEMENTS = ("fire", "frost", "lightning", "poison")
CONTEXTS = ((30, 40, 10), (60, 60, 20), (60, 100, 20))


def constructed_build(name, gear, model, rules, config, level, talents, repetitions):
    if name in BASE_NAMES:
        profile = adversarial_audit.constructed_profile(
            name, gear, model, rules, config, level, talents)
        builds = adversarial_audit.build_from_profile(profile, repetitions, config)
        # Recompute unrounded funding rather than copying presentation-rounded stats.
        builds["stats"][:] = 0
        for key in profile["gear_affixes"]:
            value = (gear / config["affix_slots"] * config["affixes"][key]
                     / config["cost_models"][model].get(key, 1))
            builds["stats"][:, builds["keys"].index(key)] += value
        return builds
    element = name.removesuffix("_resistance_specialist")
    if element not in ELEMENTS:
        raise ValueError(name)
    points = rules["creation_points"] + rules["points_per_level"] * (level - 1)
    recipe = ([element + "_resistance"] * 2 + ["health"] * 3 + ["armor"] * 3
              + ["health"] * 4 + ["health_regen"] * 4
              + ["attack_power"] * 2 + ["block"] * 2)
    keys = list(config["affixes"])
    stats = np.zeros((repetitions, len(keys)))
    slot = 0
    for group in config["slot_groups"].values():
        for _ in range(group["count"]):
            key = recipe[slot]
            if key not in group["allowed"]:
                raise ValueError(f"Illegal {name} affix {key} in slot {slot}")
            value = (gear / config["affix_slots"] * config["affixes"][key]
                     / config["cost_models"][model].get(key, 1))
            stats[:, keys.index(key)] += value
            slot += 1
    if slot != config["affix_slots"]:
        raise ValueError("Constructed profile does not use the authored affix slots")
    return {
        "stats": stats,
        "primary": np.tile([0, 0, 0, points], (repetitions, 1)).astype(np.int16),
        "talents": np.tile([talents, 0, 0], (repetitions, 1)).astype(np.int16),
        "archetype": np.zeros(repetitions, dtype=np.int16),
        "shield": np.ones(repetitions, dtype=bool),
        "choices": np.tile([keys.index(k) for k in recipe], (repetitions, 1)),
        "keys": keys, "budget": gear, "model": model, "level": level,
        "talent_budget": talents,
    }


def wilson_interval(successes, trials):
    if trials == 0:
        return [0.0, 1.0]
    z = 1.959963984540054
    fraction = successes / trials
    divisor = 1 + z * z / trials
    center = (fraction + z * z / (2 * trials)) / divisor
    radius = z * math.sqrt(fraction * (1 - fraction) / trials + z * z / (4 * trials * trials)) / divisor
    return [max(0.0, center - radius), min(1.0, center + radius)]


def describe_build(name, builds, stats):
    return {
        "name": name, "level": builds["level"], "gear_budget": builds["budget"],
        "talent_budget": builds["talent_budget"], "cost_model": builds["model"],
        "primary_points": dict(zip(("strength", "dexterity", "intellect", "vitality"),
                                   map(int, builds["primary"][0]))),
        "talent_points": dict(zip(("block", "damage", "health"),
                                  map(int, builds["talents"][0]))),
        "gear_affixes": [builds["keys"][int(i)] for i in builds["choices"][0]],
        "gear_stats": {k: float(builds["stats"][0, i])
                       for i, k in enumerate(builds["keys"]) if builds["stats"][0, i]},
        "derived": {k: float(stats[k][0]) for k in (
            "health", "health_regen", "armor_reduction", "evasion_chance", "block_chance",
            "critical_chance_fraction", "critical_multiplier_value", "attack_power_value",
            "spell_power_value", "fire_resistance_fraction", "frost_resistance_fraction",
            "lightning_resistance_fraction", "poison_resistance_fraction")},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trials", type=int, default=256,
                        help="Repeated trajectories per constructed build and incoming pattern")
    parser.add_argument("--seed", type=int, default=330177)
    parser.add_argument("--output", type=Path, default=sim.HERE / "pressure_results")
    args = parser.parse_args()
    if args.trials < 1:
        parser.error("--trials must be positive")
    pressure_path = sim.HERE / "pressure_scenarios.json"
    pressure = sim.read_json(pressure_path)
    base = sim.read_json(sim.HERE / "scenarios.json")
    rules = sim.read_json(sim.DEFAULT_RULES)
    sim.require_legacy_report_schema(rules)
    config = sweep.extended_config(base, pressure)
    names = BASE_NAMES + tuple(k + "_resistance_specialist" for k in ELEMENTS)
    records = []
    count = 0
    outgoing_count = 0
    for context_index, (level, gear, talents) in enumerate(CONTEXTS):
        for model_index, model in enumerate(config["cost_models"]):
            for profile_index, name in enumerate(names):
                builds = constructed_build(name, gear, model, rules, config, level,
                                           talents, args.trials)
                stats = sweep.derive_stats(builds, rules, config)
                description = describe_build(name, builds, stats)
                outcomes = []
                target_seed = args.seed + context_index * 100003
                for pattern_index, pattern in enumerate(pressure["incoming_patterns"]):
                    targets = sweep.sample_targets(args.trials, np.random.default_rng(target_seed),
                                                   level, rules, pressure)
                    seed = args.seed + context_index * 100003 + pattern_index * 9176
                    result = sweep.simulate_incoming(builds, stats, pattern,
                                                     np.random.default_rng(seed), rules,
                                                     pressure, targets=targets)
                    death = result["death_time"]
                    survival = {}
                    for horizon in (1, 3, 10, 30):
                        survived = int(np.count_nonzero(death > horizon))
                        survival[str(horizon)] = {
                            "fraction": survived / args.trials,
                            "wilson_95_interval": wilson_interval(survived, args.trials),
                        }
                    row = {"pattern": pattern["id"], "trials": args.trials,
                           "survival_at_seconds": survival,
                           "mean_final_health_fraction": float(np.maximum(result["hp_end"], 0).mean()
                                                               / stats["health"][0])}
                    for key in ("first_hit_lethal", "first_packet_lethal_if_landed",
                                "first_landed_hit_lethal", "events", "hits", "avoided", "blocked", "missed", "resisted"):
                        if key in result:
                            row["mean_" + key] = float(np.asarray(result[key]).mean())
                    row["by_pressure_scale"] = {}
                    for scale in np.unique(targets["pressure_scale"]):
                        mask = targets["pressure_scale"] == scale
                        trials = int(mask.sum())
                        survivors = int(np.count_nonzero(death[mask] > 30))
                        row["by_pressure_scale"][str(float(scale))] = {
                            "trials": trials, "survival_at_30_seconds": survivors / trials,
                            "wilson_95_interval": wilson_interval(survivors, trials),
                            "first_packet_lethal_if_landed": float(result["first_packet_lethal_if_landed"][mask].mean()),
                        }
                    outcomes.append(row)
                    count += args.trials
                outgoing = []
                for pattern_index, pattern in enumerate(pressure["outgoing_patterns"]):
                    targets = sweep.sample_targets(args.trials, np.random.default_rng(target_seed),
                                                   level, rules, pressure)
                    seed = args.seed + 50000017 + context_index * 100003 + pattern_index * 9176
                    result = sweep.simulate_outgoing(builds, stats, pattern,
                                                     np.random.default_rng(seed), rules,
                                                     pressure, targets=targets)
                    killed = np.isfinite(result["kill_time"])
                    kills = int(killed.sum())
                    outgoing.append({
                        "pattern": pattern["id"], "trials": args.trials,
                        "kill_fraction_at_30_seconds": kills / args.trials,
                        "wilson_95_interval": wilson_interval(kills, args.trials),
                        "median_kill_time_among_kills": float(np.median(result["kill_time"][killed])) if kills else None,
                        "mean_training_target_dps": float(result["potential_damage"].mean() / pressure["duration"]),
                        "mean_actual_health_removed": float(result["actual_health_removed"].mean()),
                        "mean_actions": float(result["actions"].mean()),
                        "mean_resource_waits": float(result["resource_waits"].mean()),
                    })
                    outgoing_count += args.trials
                records.append({**description, "outcomes": outcomes,
                                "outgoing_outcomes": outgoing})
                print(f"{len(records)} constructed profiles; {count:,} incoming and {outgoing_count:,} outgoing trajectories", flush=True)
    args.output.mkdir(parents=True, exist_ok=True)
    report = {
        "description": "Supplemental funded constructed profiles across every incoming pressure pattern. Repeated trajectories are not additional distinct builds.",
        "seed": args.seed, "repetitions_per_profile_pattern": args.trials,
        "constructed_profiles": len(records), "stochastic_incoming_trajectories": count,
        "stochastic_outgoing_trajectories": outgoing_count,
        "contexts": CONTEXTS,
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "pressure_sweep_sha256": hashlib.sha256((sim.HERE / "pressure_sweep.py").read_bytes()).hexdigest(),
        "rules_sha256": hashlib.sha256(sim.DEFAULT_RULES.read_bytes()).hexdigest(),
        "pressure_config_sha256": hashlib.sha256(pressure_path.read_bytes()).hexdigest(),
        "base_config_sha256": hashlib.sha256((sim.HERE / "scenarios.json").read_bytes()).hexdigest(),
        "notes": [
            "All gear affixes and primary/talent points are paid within the stated context. Slot-order choices use the same20 funded affix slots as the broad study.",
            "The cap-chaser is a fixed recipe, not a claim that it reaches every cap under both price models. Paid all-resistance prices differ from the historical study.",
            "Every profile faces the same target sample and random seed within a context/pattern. Changing avoidance probabilities can still consume random streams differently.",
            "Wilson intervals describe Monte Carlo uncertainty within the sampled target mixture; they do not establish production balance or individual opponent guarantees.",
            "The four horizons summarize the same trajectories and must not be added as extra trials. No kill cancels incoming pressure.",
            "First-hit-lethal counts actual fatal first direct attempts after avoidance. First-packet-lethal-if-landed tests full-Health packet lethality regardless of avoidance. First-landed-hit-lethal can include Health lost to earlier DoTs.",
            "The stats table shows Armor reduction before the sampled enemy's penetration. Enemy levels and defenses vary according to the broad study target distribution.",
            "Outgoing training-target damage continues after the first kill as a counterfactual offense probe; actual Health removed is clamped and excludes overkill. Conditional kill-time medians exclude unkillable/censored targets.",
        ],
        "profiles": records,
    }
    (args.output / "corner_cases.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = ["# Constructed pressure-envelope probes", "",
             f"{len(records)} funded constructed profiles, **{count:,} supplemental incoming trajectories**, and **{outgoing_count:,} supplemental outgoing trajectories**; {args.trials} repetitions per profile/pattern.", "",
             "All patterns run independently of enemy kills. The1/3/10/30-second horizons reuse each trajectory. The JSON contains per-pattern results, uncertainty intervals, complete funding and actual stats.", "",
             "| Model | Level | Gear | Talents | Profile | Health | Regen/s | Armor | Dodge | Block | Fire/Frost/Lightning/Poison resistance |",
             "|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---|" ]
    for record in records:
        d = record["derived"]
        resistances = "/".join(f"{100*d[k + '_resistance_fraction']:.0f}%" for k in ELEMENTS)
        lines.append(f"| {record['cost_model']} | {record['level']} | {record['gear_budget']} | {record['talent_budget']} | {record['name']} | {d['health']:.1f} | {d['health_regen']:.2f} | {d['armor_reduction']:.1%} | {d['evasion_chance']:.1%} | {d['block_chance']:.1%} | {resistances} |")
    lines += ["", "## Interpretation", ""] + ["- " + note for note in report["notes"]]
    (args.output / "corner_cases.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
