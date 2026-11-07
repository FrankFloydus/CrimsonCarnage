#!/usr/bin/env python3
# Matched hand-package experiments. Does not modify gameplay or prior studies.
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
import pressure_sweep as sweep

HERE = Path(__file__).resolve().parent


def common_config(base, pressure, settings):
    config = sweep.extended_config(base, pressure)
    config["slot_groups"].pop("main_hand")
    config["slot_groups"].pop("off_hand")
    config["affix_slots"] = sum(g["count"] for g in config["slot_groups"].values())
    for group in config["slot_groups"].values():
        group["allowed"] = [k for k in group["allowed"] if k not in settings["common_affix_exclusions"]]
    return config


def packages(role, settings):
    result = [{"id": f"shield_{block}_armor_{armor}", "shield": True, "block": block, "armor": armor, "dps": 100, "spell_power": 0}
              for block in settings["shield_block_cases"] for armor in settings["shield_armor_cases"]]
    if role == "physical":
        result += [{"id": f"twohand_{dps}", "shield": False, "block": 0, "armor": 0, "dps": dps, "spell_power": 0} for dps in settings["two_hand_dps_cases"]]
        result += [{"id": "reference_100_no_shield", "shield": False, "block": 0, "armor": 0, "dps": 100, "spell_power": 0}]
    else:
        result += [{"id": f"focus_{power}", "shield": False, "block": 0, "armor": 0, "dps": 0, "spell_power": power} for power in settings["focus_spell_power_cases"]]
    return result


def make_common(n, seed, role, power, gear, model, talent, rules, base, pressure, settings):
    sim.require_legacy_report_schema(rules)
    config = common_config(base, pressure, settings)
    b = sweep.sample_builds(n, np.random.default_rng(seed), gear, model, rules, config, settings["level"], settings["talent_budget"])
    b["talents"][:] = [talent["points"], settings["talent_budget"] - talent["points"], 0]
    b["shield"][:] = False
    config["loadouts"]["shield"]["weight"] = settings["neutral_weight"]
    config["loadouts"]["two_hand"]["weight"] = settings["neutral_weight"]
    d = sweep.derive_stats(b, rules, config)
    d["strength_power"][:] = power
    d["dexterity_power"][:] = power
    d["intellect_power"][:] = power
    d["block_chance"][:] = talent["chance"] / 100
    targets = sweep.sample_targets(n, np.random.default_rng(seed + 1000003), settings["level"], rules, pressure)
    return b, d, targets, config


def apply_package(common, package, talent, settings, rules, weight_mode="neutral"):
    sim.require_legacy_report_schema(rules)
    d = {key: value.copy() if isinstance(value, np.ndarray) else value for key, value in common.items()}
    d["armor"] += package["armor"]
    d["armor_reduction"] = sim.defense(d["armor"], rules)
    d["block_chance"][:] = min(rules["block_chance_max"], talent["chance"] + package["block"]) / 100
    d["intellect_power"] += package["spell_power"]
    if weight_mode == "real":
        weight = settings["shield_weight"] if package["shield"] else settings["offense_weight"]
        encumbrance = np.clip(d["capacity"] / np.maximum(d["capacity"], weight), rules["encumbrance_multiplier_min"], 1)
        d["encumbrance_multiplier"] = encumbrance
    return d


def attack_pattern(role, package, interval, scaling, pressure, settings):
    if role == "mage":
        return copy.deepcopy(next(p for p in pressure["outgoing_patterns"] if p["id"] == "fire_hit_plus_burn"))
    coefficient = settings["physical_power_coefficient_per_second"]
    if scaling == "whole_weapon":
        coefficient *= package["dps"] / settings["reference_onehand_dps"]
    return {"id": f"physical_{interval}_{scaling}", "kind": "hit", "damage_type": "physical", "power_source": "strength",
            "interval": interval, "base_dps": package["dps"], "power_per_second": coefficient,
            "cost_per_second": settings["physical_cost_per_second"], "resource": "stamina", "first_event": "after_interval",
            "minimum_action_duration": interval * settings["synthetic_minimum_duration_ratio"]}


def family(pattern):
    if all(c["kind"] == "dot" for c in pattern["channels"]):
        return "periodic"
    if any(c.get("unavoidable", False) for c in pattern["channels"]):
        return "unavoidable"
    if pattern["family"] in ("hybrid_equal_dps", "dependent_ailment", "compound_delivery"):
        return "hybrid"
    if pattern["family"] == "first_hit_policy":
        return "first_hit_policy"
    if pattern["family"] == "one_shots":
        return "one_shots"
    return "frequent_hits" if min(c.get("interval", 99) for c in pattern["channels"]) <= 1 else "burst_hits"


def paired_difference(a, b):
    differences = np.asarray(a, dtype=float) - np.asarray(b, dtype=float)
    mean = float(differences.mean())
    se = float(differences.std(ddof=1) / math.sqrt(len(differences))) if len(differences) > 1 else 0
    return {"mean_difference": mean, "ci95_low": max(-1, mean - 1.96 * se), "ci95_high": min(1, mean + 1.96 * se),
            "profiles": len(differences), "a_better": int(np.count_nonzero(differences > 0)), "b_better": int(np.count_nonzero(differences < 0))}


def _worker(job):
    role, power, gear, model, talent, n, seed = job
    rules, base = sim.read_json(sim.DEFAULT_RULES), sim.read_json(HERE / "scenarios.json")
    pressure, settings = sim.read_json(HERE / "pressure_scenarios.json"), sim.read_json(HERE / "loadout_scenarios.json")
    builds, common, targets, config = make_common(n, seed, role, power, gear, model, talent, rules, base, pressure, settings)
    options = packages(role, settings)
    block_unit = config["affixes"]["block"] / config["cost_models"][model].get("block", 1)
    armor_unit = config["affixes"]["armor"] / config["cost_models"][model].get("armor", 1)
    spell_unit = config["affixes"]["spell_power"] / config["cost_models"][model].get("spell_power", 1)
    parity_price = 20 / block_unit + 150 / armor_unit
    if role == "mage":
        options.append({"id": "focus_affix_price_parity_20_150", "shield": False, "block": 0, "armor": 0,
                        "dps": 0, "spell_power": parity_price * spell_unit})
    n_patterns = len(pressure["incoming_patterns"])
    families = {key: np.array([i for i,p in enumerate(pressure["incoming_patterns"]) if family(p) == key])
                for key in {family(p) for p in pressure["incoming_patterns"]}}
    incoming_cache, outgoing_cache = {}, {}
    outcomes, comparisons = [], []
    incoming_trajectories = outgoing_trajectories = race_comparisons = 0
    race_scores = {}
    base_fields = {"role": role, "base_power": power, "common_gear_budget": gear, "hand_package_budget": settings["hand_package_cost"],
                   "total_gear_budget": gear + settings["hand_package_cost"], "cost_model": model, "talent_block": talent["chance"],
                   "talent_points": settings["talent_budget"], "sampled_profiles": n, "seed": seed}
    for package in options:
        defense_key = (package["block"], package["armor"])
        if defense_key not in incoming_cache:
            d = apply_package(common, package, talent, settings, rules)
            death = np.full((n, n_patterns), np.inf)
            lethal = np.zeros((n, n_patterns), dtype=bool)
            for i, pattern in enumerate(pressure["incoming_patterns"]):
                r = sweep.simulate_incoming(builds, d, pattern, np.random.default_rng(seed + i * 9176 + 101), rules, pressure, targets)
                death[:, i] = r["death_time"]
                lethal[:, i] = r["first_packet_lethal_if_landed"]
            incoming_cache[defense_key] = (death, lethal)
            incoming_trajectories += n * n_patterns
        death, lethal = incoming_cache[defense_key]
        weights = ("neutral", "real") if role == "physical" else ("neutral",)
        intervals = settings["physical_intervals"] if role == "physical" else (1.5,)
        scalings = ("base_only", "whole_weapon") if role == "physical" and power > 0 else ("base_only",)
        for weight in weights:
            d = apply_package(common, package, talent, settings, rules, weight)
            for interval in intervals:
                for scaling in scalings:
                    offense_key = (package["dps"], package["spell_power"], package["shield"] if weight == "real" else False, weight, interval, scaling)
                    if offense_key not in outgoing_cache:
                        p = attack_pattern(role, package, interval, scaling, pressure, settings)
                        r = sweep.simulate_outgoing(builds, d, p, np.random.default_rng(seed + int(interval * 1000) + 70001), rules, pressure, targets)
                        controls = {"stress": r}
                        for armor, resistance in ((0, 0), (500, 40)):
                            neutral = {key: value.copy() if isinstance(value, np.ndarray) else value for key, value in targets.items()}
                            neutral["enemy_level"][:] = settings["level"]
                            neutral["health"][:] = 1200
                            neutral["armor"][:] = armor
                            neutral["evasion_chance"][:] = 0
                            neutral["block_chance"][:] = 0
                            for kind in sweep.TYPES:
                                neutral[kind + "_resistance_fraction"][:] = resistance / 100
                            controls[f"neutral_armor{armor}_res{resistance}"] = sweep.simulate_outgoing(builds, d, p, np.random.default_rng(seed + 90001), rules, pressure, neutral)
                        outgoing_cache[offense_key] = controls
                        outgoing_trajectories += n * len(controls)
                    controls = outgoing_cache[offense_key]
                    r = controls["stress"]
                    kill = r["kill_time"]
                    race = np.isfinite(kill[:, None]) & (kill[:, None] < death) & ~np.isclose(kill[:, None], death, atol=1e-8, rtol=0)
                    race_comparisons += race.size
                    for group, columns in families.items():
                        score = race[:, columns].mean(axis=1)
                        survival = (death[:, columns] > pressure["duration"]).mean(axis=1)
                        race_scores[(package["id"], weight, interval, scaling, group)] = score
                        outcomes.append({**base_fields, "package": package["id"], "block": package["block"], "shield_armor": package["armor"],
                                         "implied_old_affix_cost": package["block"] / block_unit + package["armor"] / armor_unit if package["shield"] else (package["spell_power"] / spell_unit if role == "mage" else None),
                                         "intrinsic_weapon_dps": package["dps"], "focus_spell_power": package["spell_power"], "weight": weight,
                                         "interval": interval, "power_scaling": scaling, "pressure_family": group, "opponent_control": "stress",
                                         "kill_before_death_fraction": float(score.mean()), "fixed_30s_survival_fraction": float(survival.mean()),
                                         "first_packet_lethal_if_landed_fraction": float(lethal[:, columns].mean()),
                                         "mean_potential_dps": float(r["potential_damage"].mean() / pressure["duration"]),
                                         "mean_censored_kill_seconds": float(np.minimum(kill, pressure["duration"]).mean()),
                                         "target_not_killed_fraction": float(np.isinf(kill).mean()),
                                         "mean_actual_health_removed": float(r["actual_health_removed"].mean()),
                                         "mean_action_speed_rate": float(r["action_speed_rate"].mean()), "mean_armor": float(d["armor"].mean())})
                    for control, reference in controls.items():
                        if control == "stress":
                            continue
                        control_kill = reference["kill_time"]
                        outcomes.append({**base_fields, "package": package["id"], "block": package["block"], "shield_armor": package["armor"],
                                         "implied_old_affix_cost": package["block"] / block_unit + package["armor"] / armor_unit if package["shield"] else (package["spell_power"] / spell_unit if role == "mage" else None),
                                         "intrinsic_weapon_dps": package["dps"], "focus_spell_power": package["spell_power"], "weight": weight,
                                         "interval": interval, "power_scaling": scaling, "pressure_family": "offense_only", "opponent_control": control,
                                         "kill_before_death_fraction": None, "fixed_30s_survival_fraction": None,
                                         "first_packet_lethal_if_landed_fraction": None,
                                         "mean_potential_dps": float(reference["potential_damage"].mean() / pressure["duration"]),
                                         "mean_censored_kill_seconds": float(np.minimum(control_kill, pressure["duration"]).mean()),
                                         "target_not_killed_fraction": float(np.isinf(control_kill).mean()),
                                         "mean_actual_health_removed": float(reference["actual_health_removed"].mean()),
                                         "mean_action_speed_rate": float(reference["action_speed_rate"].mean()), "mean_armor": float(d["armor"].mean())})
    for baseline in ("shield_30_armor_0", "shield_20_armor_150"):
        for package in options:
            if package["shield"]:
                continue
            for weight in (("neutral", "real") if role == "physical" else ("neutral",)):
                for interval in (settings["physical_intervals"] if role == "physical" else (1.5,)):
                    for scaling in (("base_only", "whole_weapon") if role == "physical" and power > 0 else ("base_only",)):
                        for group in families:
                            a = race_scores[(package["id"], weight, interval, scaling, group)]
                            b = race_scores[(baseline, weight, interval, scaling, group)]
                            comparisons.append({**base_fields, "offensive_package": package["id"], "shield_package": baseline, "pressure_scale": "all",
                                                "weight": weight, "interval": interval, "power_scaling": scaling, "pressure_family": group,
                                                **paired_difference(a, b)})
                            canonical = weight == "neutral" and (role == "mage" or (interval == 1 and (scaling == "whole_weapon" or power == 0)))
                            if canonical:
                                for scale in np.unique(targets["pressure_scale"]):
                                    mask = targets["pressure_scale"] == scale
                                    comparisons.append({**base_fields, "offensive_package": package["id"], "shield_package": baseline, "pressure_scale": float(scale),
                                                        "weight": weight, "interval": interval, "power_scaling": scaling, "pressure_family": group,
                                                        **paired_difference(a[mask], b[mask])})
    example = {"context": base_fields, "common_primary_points": builds["primary"][0].tolist(),
               "common_talents": builds["talents"][0].tolist(), "common_affix_slots": config["affix_slots"],
               "common_affix_funding": builds["affix_funding"][0].tolist(), "common_affixes": [builds["keys"][i] for i in builds["choices"][0]],
               "common_gear_stats": {k: float(builds["stats"][0, i]) for i,k in enumerate(builds["keys"]) if builds["stats"][0,i]},
               "controlled_prehand_power": power}
    return {"outcomes": outcomes, "paired": comparisons, "sample": example,
            "incoming_trajectories": incoming_trajectories, "outgoing_trajectories": outgoing_trajectories,
            "derived_race_comparisons": race_comparisons, "base_profiles": n}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profiles-per-context", type=int, default=512)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit-contexts", type=int, default=0, help="Optional smoke-run context limit; zero runs the full matrix")
    parser.add_argument("--output", type=Path, default=HERE / "loadout_results")
    args = parser.parse_args()
    if args.profiles_per_context < 2:
        parser.error("Use at least two matched profiles per context")
    sim.require_legacy_report_schema(sim.read_json(sim.DEFAULT_RULES))
    source_files = ("loadout_comparison.py", "loadout_scenarios.json", "pressure_sweep.py", "pressure_scenarios.json", "simulator.py", "scenarios.json")
    starting_hashes = {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in source_files}
    starting_rules_hash = hashlib.sha256(sim.DEFAULT_RULES.read_bytes()).hexdigest()
    settings = sim.read_json(HERE / "loadout_scenarios.json")
    base = sim.read_json(HERE / "scenarios.json")
    jobs = []
    for role in ("physical", "mage"):
        powers = settings["physical_power_conditions"] if role == "physical" else settings["spell_power_conditions"]
        for power in powers:
            for gear in settings["common_gear_budgets"]:
                for model in base["cost_models"]:
                    for talent in settings["talent_block_cases"]:
                        seed = settings["seeds"][0] + int(power) * 1009 + int(gear) * 9176 + int(talent["chance"]) * 101 + (0 if role == "physical" else 500003)
                        jobs.append((role, power, gear, model, talent, args.profiles_per_context, seed))
    if args.limit_contexts:
        jobs = jobs[:args.limit_contexts]
    started = time.monotonic()
    results = []
    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        for index, result in enumerate(executor.map(_worker, jobs)):
            results.append(result)
            if index % 8 == 0 or index + 1 == len(jobs):
                print(f"{index+1}/{len(jobs)} matched contexts; {time.monotonic()-started:.1f}s", flush=True)
    ending_hashes = {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in source_files}
    if starting_hashes != ending_hashes or starting_rules_hash != hashlib.sha256(sim.DEFAULT_RULES.read_bytes()).hexdigest():
        raise RuntimeError("Source or inputs changed during the matched experiment; do not publish mixed results")
    args.output.mkdir(parents=True, exist_ok=True)
    for key, filename in (("outcomes", "outcomes.csv"), ("paired", "paired_comparisons.csv")):
        rows = [row for result in results for row in result[key]]
        with (args.output / filename).open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    report = {"schema_version": 1, "matched_contexts": len(jobs), "profiles_per_context": args.profiles_per_context,
              "matched_base_profiles": sum(r["base_profiles"] for r in results), "workers": args.workers,
              "context_limit_for_smoke": args.limit_contexts,
              "incoming_trajectories": sum(r["incoming_trajectories"] for r in results),
              "outgoing_trajectories": sum(r["outgoing_trajectories"] for r in results),
              "derived_race_comparisons_not_extra_trajectories": sum(r["derived_race_comparisons"] for r in results),
              "elapsed_seconds": time.monotonic() - started, "settings": settings,
              "hashes": starting_hashes,
              "rules_sha256": starting_rules_hash,
              "notes": ["Controlled pre-hand Power values are shared actor conditions, not optimized progression builds.",
                        "Common item slots exclude both hand groups and Power affixes. Each hand package is a mutually exclusive whole-package candidate at the same provisional intrinsic price.",
                        "Shield Armor0 is the main control;150/300 are alternate complete package designs, not extra freely stacked affixes.",
                        "Incoming tracks are reused for packages with identical defenses. Outgoing tracks are reused when offensive statistics are identical. Counts reflect executed trajectories, not derived combinations.",
                        "Kill-before-death uses independent static tracks. Existing DoTs can kill after the enemy; it is not guaranteed post-kill survival. Fixed30s survival is reported separately.",
                        "Comparisons average within each actor before confidence intervals; pressure-pattern repeats are not treated as independent player samples.",
                        "Same actors/opponents and seeds are paired, but state-dependent RNG consumption may differ after avoidance/deaths.",
                        "Neutral outgoing controls use Health1200, no enemy Dodge/Block, and Armor0/resistance0 or Armor500/resistance40. They are output-only controls, not mixed with stress kill races.",
                        "Exact ties within1e-8seconds are excluded from kill-before-death. Unkilled targets are censored at30seconds; potential output uses the full30second denominator.",
                        "Initial/review prices apply to common affixes only; intrinsic package values are what this study is testing. No production gear or cap is changed."]}
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (args.output / "sampled_common_profiles.json").write_text(json.dumps([r["sample"] for r in results], indent=2) + "\n", encoding="utf-8")
    lines = ["# Matched hand-package comparison", "", f"{report['matched_base_profiles']:,} matched actor profiles across{len(jobs)} contexts; {report['incoming_trajectories']:,} incoming and {report['outgoing_trajectories']:,} outgoing trajectories.", "",
             "Detailed outcomes and paired actor-level differences are in outcomes.csv and paired_comparisons.csv. Positive paired differences favor the offensive package; negative values favor the shield.", "", "## Interpretation limits", ""]
    lines += ["- " + note for note in report["notes"]]
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
