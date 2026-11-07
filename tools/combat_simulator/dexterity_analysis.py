#!/usr/bin/env python3
"""Exhaustive direct-DPS comparison for the proposed Dexterity contributions.

This is an offline design experiment. It does not modify game rules or presume
that the Dexterity, Evasion or Block proposals have been implemented. Resource
costs, ailments, cooldowns and finite action timing require the companion
simulation; this module isolates accuracy, damage per Hit and execution speed.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

import simulator as sim


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ALLOCATION_FRACTIONS = {
    "pure_power": 0.0,
    "power_heavy_80_20": 0.2,
    "mixed_50_50": 0.5,
    "dexterity_heavy_20_80": 0.8,
    "pure_dexterity": 1.0,
}


def default_config():
    return {
        "description": "Proposed Dexterity direct-DPS analysis; no gameplay implementation or itemization.",
        "levels": [1, 10, 30, 60],
        "target_level_gaps": [0, 3, 5],
        "minimum_duration_fractions": [0.25, 0.4, 0.6],
        "other_speed_ratings": [0.0, 100.0],
        "other_hit_ratings": [0.0, 50.0],
        "dexterity_speed_per_point": [1.0, 0.5],
        "dexterity_hit_per_point": 1.0,
        "intellect_damage_ratios": [0.005, 0.01, 0.02],
        "reference_intellect_damage_ratio": 0.01,
        "base_damage_per_second": 100.0,
        "base_action_duration": 1.0,
        "near_best_fraction": 0.99,
    }


def validate_config(config, rules):
    if not config["levels"] or any(
        not isinstance(level, int) or level < 1 or level > rules["max_level"]
        for level in config["levels"]
    ):
        raise ValueError("Levels must be integers inside the current level cap")
    if len(set(config["levels"])) != len(config["levels"]):
        raise ValueError("Duplicate levels are not independent cases")
    if not config["target_level_gaps"] or any(
        not isinstance(gap, int) or gap < 0 for gap in config["target_level_gaps"]
    ):
        raise ValueError("Target level gaps must be nonnegative integers")
    if any(not math.isfinite(value) or not 0 < value <= 1
           for value in config["minimum_duration_fractions"]):
        raise ValueError("Minimum duration fractions must be in (0, 1]")
    for name in ("other_speed_ratings", "other_hit_ratings", "dexterity_speed_per_point",
                 "intellect_damage_ratios"):
        if not config[name] or any(not math.isfinite(value) or value < 0 for value in config[name]):
            raise ValueError(name+" must contain finite nonnegative values")
    for name in ("base_damage_per_second", "base_action_duration"):
        if not math.isfinite(config[name]) or config[name] <= 0:
            raise ValueError(name+" must be finite and positive")
    if not math.isfinite(config["dexterity_hit_per_point"]) or config["dexterity_hit_per_point"] < 0:
        raise ValueError("Dexterity Hit contribution must be finite and nonnegative")
    if not 0 < config["near_best_fraction"] <= 1:
        raise ValueError("Near-best fraction must be in (0, 1]")


def evaluate_curve(case, rules, config):
    """Evaluate every integer allocation; damage ratios affect source packets."""
    budget = int(case["point_budget"])
    if budget < 0:
        raise ValueError("Allocation budget cannot be negative")
    dexterity = np.arange(budget+1, dtype=float)
    power = budget-dexterity
    rating = case["other_speed_rating"]+case["dexterity_speed_per_point"]*dexterity
    base = config["base_action_duration"]
    duration = sim.rating_duration(base, base*case["minimum_duration_fraction"], rating, rules)
    hit = sim.hit_chance(case["level"], case["target_level"],
                        case["other_hit_rating"]+config["dexterity_hit_per_point"]*dexterity, rules)
    packet_multiplier = 1+case["power_damage_ratio"]*power
    level_factor = float(sim.level_gap_factor(case["level"], case["target_level"], rules))
    dps = config["base_damage_per_second"]*packet_multiplier*(base/duration)*hit*level_factor
    baseline_duration = sim.rating_duration(base, base*case["minimum_duration_fraction"],
                                          case["other_speed_rating"], rules)
    baseline_hit = sim.hit_chance(case["level"], case["target_level"], case["other_hit_rating"], rules)
    unallocated_dps = float(config["base_damage_per_second"]*base/baseline_duration*baseline_hit*level_factor)
    curve = []
    for index in range(budget+1):
        curve.append({
            "power_points": budget-index, "dexterity_points": index,
            "power_attribute": rules["base_primary"]+budget-index,
            "dexterity_attribute": rules["base_primary"]+index,
            "hit_chance": float(hit[index]), "action_duration": float(duration[index]),
            "level_damage_factor": level_factor,
            "actions_per_second": float(1/duration[index]),
            "damage_per_hit_multiplier": float(packet_multiplier[index]),
            "expected_direct_dps": float(dps[index]),
            "relative_to_unallocated": float(dps[index]/unallocated_dps),
        })
    return curve


def summarize_curve(case, curve, config):
    maximum = max(row["expected_direct_dps"] for row in curve)
    best = [row for row in curve if math.isclose(row["expected_direct_dps"], maximum,
                                               rel_tol=1e-12, abs_tol=1e-12)]
    near = [row["dexterity_points"] for row in curve
            if row["expected_direct_dps"]+1e-12 >= config["near_best_fraction"]*maximum]
    selected = {}
    for name, fraction in ALLOCATION_FRACTIONS.items():
        points = int(round(case["point_budget"]*fraction))
        selected[name] = dict(curve[points])
        selected[name]["fraction_of_best"] = curve[points]["expected_direct_dps"]/maximum
    pure = curve[0]["expected_direct_dps"]
    return {
        **case, "best_dexterity_points": [row["dexterity_points"] for row in best],
        "best_power_points": [row["power_points"] for row in best],
        "best_expected_direct_dps": maximum,
        "best_gain_over_pure_power": maximum/pure-1,
        "near_best_dexterity_points": near,
        "near_best_dexterity_min": min(near), "near_best_dexterity_max": max(near),
        "selected_allocations": selected,
    }


def generate_cases(config, rules):
    case_index = 0
    skipped = []
    cases = []
    for level in config["levels"]:
        budget = int(rules["creation_points"]+rules["points_per_level"]*(level-1))
        for gap in config["target_level_gaps"]:
            if level+gap > rules["max_level"]:
                skipped.append({"level": level, "gap": gap, "reason": "target exceeds current level cap"})
                continue
            power_ratios = [("strength", rules["strength_physical_damage_per_point"])]
            power_ratios += [("intellect", value) for value in config["intellect_damage_ratios"]]
            for family, ratio in power_ratios:
                for minimum in config["minimum_duration_fractions"]:
                    for other_speed in config["other_speed_ratings"]:
                        for other_hit in config["other_hit_ratings"]:
                            for dex_speed in config["dexterity_speed_per_point"]:
                                cases.append({
                                    "case_id": case_index, "family": family,
                                    "level": level, "target_level": level+gap, "level_gap": gap,
                                    "point_budget": budget, "power_damage_ratio": ratio,
                                    "minimum_duration_fraction": minimum,
                                    "other_speed_rating": other_speed, "other_hit_rating": other_hit,
                                    "dexterity_speed_per_point": dex_speed,
                                })
                                case_index += 1
    return cases, skipped


def write_report(folder, results, manifest, config):
    near_percent = 100*(1-config["near_best_fraction"])
    lines = ["# Proposed Dexterity: exhaustive direct-DPS allocation analysis", "",
             f"Evaluated **{manifest['case_count']:,} contexts** and **{manifest['allocation_evaluations']:,} integer allocations**. "
             "These are deterministic evaluations, not Monte Carlo trials or independently generated builds.", "",
             "The proposed main Dexterity contribution is +1 Hit Rating and +1 Attack/Cast Speed Rating per point above 10. "
             "The game is unchanged. Strength contributes the current physical multiplier; Intellect contributes flat Magic Power through an explicit experimental coefficient-to-packet ratio. "
             "All allocations spend the same primary point budget within each context.", "",
             "## Main same-level reference", "",
             "Minimum duration is 40% of base, other Speed Rating is zero, and Dexterity adds one Speed Rating per point. "
             "The normalized unscaled action is 100 raw DPS. The Intellect ratio of 0.01 is deliberately calibrated to the same marginal packet contribution as Strength for a controlled comparison; it is not a new percentage-based Magic Power formula. "
             "Both families therefore have identical direct-DPS results in this calibrated reference.", "",
             f"| Level | Points | Other Hit | Best power / DEX points | Gain over pure power | DEX points within {near_percent:g}% of best | 80/20 power/DEX as % of best | 50/50 as % of best | 20/80 as % of best |",
             "|---:|---:|---:|---|---:|---|---:|---:|---:|"]
    for row in results:
        if (row["family"] != "strength" or row["level_gap"] != 0
                or row["minimum_duration_fraction"] != 0.4 or row["other_speed_rating"] != 0
                or row["dexterity_speed_per_point"] != 1):
            continue
        chosen = row["selected_allocations"]
        lines.append(f"| {row['level']} | {row['point_budget']} | {row['other_hit_rating']:g} | "
                     f"{row['best_power_points'][0]} / {row['best_dexterity_points'][0]} | "
                     f"{row['best_gain_over_pure_power']:.1%} | "
                     f"{row['near_best_dexterity_min']}–{row['near_best_dexterity_max']} | "
                     f"{100*chosen['power_heavy_80_20']['fraction_of_best']:.1f}% | "
                     f"{100*chosen['mixed_50_50']['fraction_of_best']:.1f}% | "
                     f"{100*chosen['dexterity_heavy_20_80']['fraction_of_best']:.1f}% |")
    lines += ["", "## Interpretation", "",
              "- Accuracy availability materially changes the optimal allocation. Other Hit Rating is identical across every allocation within a context; its acquisition cost is not compared between contexts.",
              f"- The near-best band avoids presenting one maximizing integer as a mandatory character build. It contains allocations whose expected direct DPS is at least {100*config['near_best_fraction']:g}% of the context maximum.",
              "- Existing Speed Rating and the authored action minimum reduce the marginal value of additional speed. A lower minimum permits a larger Dexterity benefit.",
              "- The 0.005 and 0.02 Intellect ratios test half/double the reference marginal Magic Power contribution. They describe coefficient divided by the existing source packet, not universal item or spell values.",
              "- Targets above level 60 are skipped explicitly, not clipped into mislabeled equal-level fights. Skipped level/gap requests are listed in the manifest.",
              "- Expected direct DPS includes the shared level-difference damage factor. That factor is constant across allocations within a context, so it changes absolute DPS without changing its optimal allocation.",
              "- This is expected direct damage with continuously available resources. It excludes costs, maximum Stamina/Mana, regeneration limits, cooldowns, discrete release timing, ailments, target death and defensive utility. The companion simulation is needed before a sustained-combat conclusion.",
              "- Strength/Intellect capacity bonuses and Dexterity's shorter execution commitment are real benefits outside this damage-only comparison. No passive Dodge or shield behavior is assumed.",
              f"- Source revision unchanged during analysis: **{manifest['source_revision_unchanged']}**."]
    (folder/"analytic_report.md").write_text("\n".join(lines)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path, default=HERE/"dexterity_results")
    args = parser.parse_args()
    config = default_config() if args.config is None else sim.read_json(args.config)
    rules = sim.read_json(sim.DEFAULT_RULES)
    validate_config(config, rules)
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    paths = [Path(__file__), HERE/"simulator.py", sim.DEFAULT_RULES]
    before = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    cases, skipped = generate_cases(config, rules)
    summaries, all_curves = [], []
    for case in cases:
        curve = evaluate_curve(case, rules, config)
        summaries.append(summarize_curve(case, curve, config))
        all_curves.extend({**case, **row} for row in curve)
    after = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    manifest = {"schema_version": 1, "command_line": sys.argv, "case_count": len(cases),
                "allocation_evaluations": len(all_curves), "skipped_level_gaps": skipped,
                "source_sha256_before": before, "source_sha256_after": after,
                "source_revision_unchanged": before == after}
    if before != after:
        raise RuntimeError("Source changed during analysis")
    (folder/"analytic_experiment.json").write_text(json.dumps(config, indent=2)+"\n", encoding="utf-8")
    (folder/"analytic_results.json").write_text(json.dumps(summaries, indent=2)+"\n", encoding="utf-8")
    (folder/"analytic_manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    with (folder/"analytic_curves.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(all_curves[0]))
        writer.writeheader()
        writer.writerows(all_curves)
    write_report(folder, summaries, manifest, config)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
