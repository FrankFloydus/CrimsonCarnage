#!/usr/bin/env python3
# Bounded-memory coordinator for the event-time combat pressure experiment.
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")

import numpy as np

import simulator as sim
import pressure_sweep as sweep

HERE = Path(__file__).resolve().parent
AXES = ("reference_steady_dps", "physical_hit_ehp", "weakest_resistance_hit_ehp", "weakest_periodic_ehp")


def fingerprint_count(builds):
    # Collapse irrelevant affix order, including roundoff in equivalent roll sums.
    values = np.column_stack((builds["primary"], builds["talents"], builds["archetype"],
                              builds["shield"], np.round(builds["stats"], 9)))
    return len(np.unique(values, axis=0))


def reference_axes(builds, clean, rules, config):
    payload = sim.payloads(builds, clean, rules, config)
    analytic = sim.metrics(builds, clean, payload, rules, config)
    weakest = np.min(np.column_stack([clean[k + "_resistance_fraction"] for k in sweep.TYPES]), axis=1)
    avoid = (1 - clean["evasion_chance"]) * (1 - clean["block_chance"])
    enemy_accuracy = {"hit_rating": config["encounter"].get("enemy_hit_rating", 0),
                      "spell_accuracy": config["encounter"].get("enemy_spell_accuracy", 0)}
    physical_chance = sim.delivery_chance(builds["level"], builds["level"], enemy_accuracy,
                                        config["encounter"].get("physical_accuracy_kind", "attack"), rules)
    elemental_chance = sim.delivery_chance(builds["level"], builds["level"], enemy_accuracy,
                                         config["encounter"].get("elemental_accuracy_kind", "spell"), rules)
    periodic_taken = np.maximum(1 - clean["armor_reduction"], 1 - weakest)
    return np.column_stack((analytic[:, 0], clean["health"] / ((1 - clean["armor_reduction"]) * avoid * physical_chance),
                            clean["health"] / ((1 - weakest) * avoid * elemental_chance), clean["health"] / periodic_taken))


def describe(builds, clean, debuffs, values, index, label):
    return {
        "selection": label,
        "primary_points": dict(zip(("strength", "dexterity", "intellect", "vitality"), map(int, builds["primary"][index]))),
        "talent_points": dict(zip(("block", "damage", "health"), map(int, builds["talents"][index]))),
        "archetype": sim.ARCHETYPES[int(builds["archetype"][index])], "shield": bool(builds["shield"][index]),
        "affixes": [builds["keys"][int(i)] for i in builds["choices"][index]],
        "affix_funding": builds["affix_funding"][index].tolist(),
        "gear_stats": {key: float(builds["stats"][index, i]) for i, key in enumerate(builds["keys"])},
        "clean_stats": {key: float(clean[key][index]) for key in (
            "health", "stamina", "mana", "health_regen", "armor_reduction", "evasion_chance", "block_chance",
            "critical_chance_fraction", "critical_multiplier_value", "strength_power", "dexterity_power", "intellect_power",
            "fire_resistance_fraction", "frost_resistance_fraction", "lightning_resistance_fraction", "poison_resistance_fraction")},
        "external_resistance_debuffs": {key: int(value[index]) for key, value in debuffs.items()},
        "reference_axes": dict(zip(AXES, map(float, values[index]))),
    }


def masks_for_incoming(pattern, stats, targets):
    yield "all", "all", np.ones(len(stats["health"]), dtype=bool)
    for axis in ("pressure_scale", "penetration", "enemy_level"):
        for value in np.unique(targets[axis]):
            yield axis, str(float(value)), targets[axis] == value
    elemental = next((c["damage_type"] for c in pattern["channels"] if c.get("damage_type") in sweep.TYPES), None)
    if elemental:
        resistance = 100 * stats[elemental + "_resistance_fraction"]
        edges = (-101, -50, -20, 0, 20, 40, 60, 80.000001)
        for low, high in zip(edges, edges[1:]):
            mask = (resistance >= low) & (resistance < high)
            if np.any(mask):
                yield elemental + "_effective_resistance", f"[{max(low, -100)},{min(high, 80):g})", mask


def incoming_row(result, stats, mask, horizons):
    death = result["death_time"][mask]
    row = {"trials": int(mask.sum())}
    for horizon in horizons:
        row[f"survived_{horizon}s"] = int(np.count_nonzero(death > horizon))
    for key in ("first_hit_lethal", "first_packet_lethal_if_landed", "first_landed_hit_lethal"):
        row[key] = int(np.count_nonzero(result[key][mask]))
    row["final_health_fraction_sum"] = float(np.sum(np.maximum(result["hp_end"][mask], 0) / stats["health"][mask]))
    for key in ("events", "hits", "avoided", "blocked", "missed", "resisted"):
        row[key] = int(result[key][mask].sum())
    return row


def masks_for_outgoing(pattern, targets):
    yield "all", "all", np.ones(len(targets["health"]), dtype=bool)
    axes = ["enemy_level", "health_scale", "evasion_chance", "block_chance"]
    axes.append("armor" if pattern["damage_type"] == "physical" else pattern["damage_type"] + "_resistance_fraction")
    for axis in axes:
        for value in np.unique(targets[axis]):
            yield axis, str(float(value)), targets[axis] == value


def outgoing_row(result, mask, duration):
    kill = result["kill_time"][mask]
    row = {"trials": int(mask.sum()), "kills": int(np.isfinite(kill).sum()),
           "kill_time_sum_among_kills": float(kill[np.isfinite(kill)].sum()),
           "potential_damage_sum": float(result["potential_damage"][mask].sum()),
           "actual_health_removed_sum": float(result["actual_health_removed"][mask].sum())}
    for key in ("actions", "hits", "avoided", "blocked", "missed", "resisted", "resource_waits"):
        row[key] = int(result[key][mask].sum())
    return row


def cell_job(job):
    level, gear, talents, model, seed, n = job
    rules = sim.read_json(sim.DEFAULT_RULES)
    pressure = sim.read_json(HERE / "pressure_scenarios.json")
    config = sweep.extended_config(sim.read_json(HERE / "scenarios.json"), pressure)
    identity = {"model": model, "level": level, "gear_budget": gear, "talent_budget": talents, "seed": seed}
    # Deliberately omit the price model from seed derivation: funding choices are paired.
    sampler = np.random.default_rng(np.random.SeedSequence([seed, level, gear, talents, 1]))
    builds = sweep.sample_builds(n, sampler, gear, model, rules, config, level, talents)
    clean = sweep.derive_stats(builds, rules, config)
    env = np.random.default_rng(np.random.SeedSequence([seed, level, gear, talents, 2]))
    debuffs = {kind: env.choice(pressure["resistance_debuff_cases"], n) for kind in sweep.TYPES}
    stats = clean.copy()
    for kind in sweep.TYPES:
        stats[kind + "_resistance_fraction"] = np.clip(clean["resistance"] + clean[kind + "_resistance"] + debuffs[kind],
                                                            rules["resistance_min"], rules["resistance_max"]) / 100
    targets = sweep.sample_targets(n, env, level, rules, pressure)
    values = reference_axes(builds, clean, rules, config)
    best = values.max(axis=0)
    fractions = values / np.maximum(best, 1e-12)
    summary = {**identity, "build_draws": n, "distinct_profiles_within_cell_rounded_1e_9": fingerprint_count(builds),
               "axis_bests": dict(zip(AXES, map(float, best))),
               "within_80_percent_all_four_axis_bests": int(np.all(fractions >= .8, axis=1).sum()),
               "all_four_axes_top_decile": int(np.all(values >= np.quantile(values, .9, axis=0), axis=1).sum()),
               "mean_clean_health": float(clean["health"].mean()), "mean_health_regen": float(clean["health_regen"].mean()),
               "invalid_primary_budgets": int(np.count_nonzero(builds["primary"].sum(axis=1) != rules["creation_points"] + rules["points_per_level"] * (level - 1))),
               "invalid_talent_budgets": int(np.count_nonzero(builds["talents"].sum(axis=1) != talents)),
               "invalid_gear_budgets": int(np.count_nonzero(~np.isclose(builds["affix_funding"].sum(axis=1), gear))),
               "illegal_nonshield_block_affixes": int(np.count_nonzero(builds["stats"][~builds["shield"], builds["keys"].index("block")]))}
    selected = [(int(np.argmax(values[:, i])), "best_" + axis) for i, axis in enumerate(AXES)]
    selected += [(int(np.argmax(np.min(fractions, axis=1))), "best_weakest_relative_axis"),
                 (int(np.argmax(clean["health_regen"])), "highest_health_regeneration")]
    samples = [{**identity, **describe(builds, clean, debuffs, values, i, label)} for i, label in selected]
    incoming, outgoing, race = [], [], []
    deaths = np.empty((n, len(pressure["incoming_patterns"])))
    for index, pattern in enumerate(pressure["incoming_patterns"]):
        rng = np.random.default_rng(np.random.SeedSequence([seed, level, gear, talents, 3, index]))
        result = sweep.simulate_incoming(builds, stats, pattern, rng, rules, pressure, targets)
        deaths[:, index] = result["death_time"]
        for condition, value, mask in masks_for_incoming(pattern, stats, targets):
            incoming.append({**identity, "pattern": pattern["id"], "family": pattern["family"], "condition": condition,
                             "value": value, **incoming_row(result, stats, mask, pressure["horizons"])})
    for index, pattern in enumerate(pressure["outgoing_patterns"]):
        rng = np.random.default_rng(np.random.SeedSequence([seed, level, gear, talents, 4, index]))
        result = sweep.simulate_outgoing(builds, stats, pattern, rng, rules, pressure, targets)
        for condition, value, mask in masks_for_outgoing(pattern, targets):
            outgoing.append({**identity, "pattern": pattern["id"], "condition": condition, "value": value,
                             **outgoing_row(result, mask, pressure["duration"])})
        for i, incoming_pattern in enumerate(pressure["incoming_patterns"]):
            kill, death = result["kill_time"], deaths[:, i]
            tied = np.isfinite(kill) & np.isfinite(death) & np.isclose(kill, death, rtol=0, atol=1e-8)
            race.append({**identity, "incoming_pattern": incoming_pattern["id"], "outgoing_pattern": pattern["id"],
                         "comparisons": n, "kill_before_death": int(np.count_nonzero((kill < death) & ~tied)),
                         "mutual_kill_same_time": int(np.count_nonzero(tied)),
                         "neither_dead_by_horizon": int(np.count_nonzero(np.isinf(kill) & np.isinf(death)))})
    return summary, samples, incoming, outgoing, race


def add_totals(totals, row, key_names):
    key = tuple(row[k] for k in key_names)
    total = totals.setdefault(key, {k: row[k] for k in key_names})
    for name, value in row.items():
        if name not in key_names and isinstance(value, (int, float)):
            total[name] = total.get(name, 0) + value


def run(args):
    sim.require_legacy_report_schema(sim.read_json(sim.DEFAULT_RULES))
    started = time.perf_counter()
    pressure = sim.read_json(HERE / "pressure_scenarios.json")
    sweep.validate_pressure_config(pressure)
    base = sim.read_json(HERE / "scenarios.json")
    profiles = sim.expand_budget_profiles(sim.read_json(HERE / "budget_profiles.json"))
    cells = [(p["level"], p["gear_budget"], p["talent_budget"], model, seed) for model in base["cost_models"]
             for seed in pressure["seeds"] for p in profiles]
    per_cell = math.ceil(args.builds / len(cells))
    jobs = [(*cell, per_cell) for cell in cells]
    args.output.mkdir(parents=True, exist_ok=True)
    source_files = [Path(__file__), HERE / "pressure_sweep.py", HERE / "pressure_scenarios.json",
                    HERE / "simulator.py", HERE / "scenarios.json", HERE / "budget_profiles.json", sim.DEFAULT_RULES]
    hashes = {str(path.relative_to(HERE.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files}
    handles = {name: (args.output / (name + ".csv")).open("w", newline="", encoding="utf-8") for name in ("incoming", "outgoing", "kill_race")}
    writers, groups, samples = {}, [], []
    incoming_totals, outgoing_totals, pressure_totals = {}, {}, {}
    try:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            for index, (summary, chosen, incoming, outgoing, race) in enumerate(pool.map(cell_job, jobs, chunksize=1)):
                groups.append(summary)
                samples.extend(chosen)
                for name, rows in (("incoming", incoming), ("outgoing", outgoing), ("kill_race", race)):
                    if name not in writers:
                        writers[name] = csv.DictWriter(handles[name], fieldnames=list(rows[0]))
                        writers[name].writeheader()
                    writers[name].writerows(rows)
                for row in incoming:
                    if row["condition"] == "all":
                        add_totals(incoming_totals, {k: v for k, v in row.items() if k not in ("level", "gear_budget", "talent_budget", "seed")}, ("model", "pattern", "family"))
                    if row["condition"] == "pressure_scale":
                        add_totals(pressure_totals, {k: v for k, v in row.items() if k not in ("level", "gear_budget", "talent_budget", "seed")}, ("model", "pattern", "value"))
                for row in outgoing:
                    if row["condition"] == "all":
                        add_totals(outgoing_totals, {k: v for k, v in row.items() if k not in ("level", "gear_budget", "talent_budget", "seed")}, ("model", "pattern"))
                if index == 0 or (index + 1) % 4 == 0:
                    print(f"{index + 1}/{len(cells)} cells; {(index + 1) * per_cell:,} build draws; {(index + 1) * per_cell * (len(pressure['incoming_patterns']) + len(pressure['outgoing_patterns'])):,} trajectories; {time.perf_counter() - started:.1f}s", flush=True)
    finally:
        for handle in handles.values():
            handle.close()
    for path in source_files:
        key = str(path.relative_to(HERE.parent.parent))
        if hashlib.sha256(path.read_bytes()).hexdigest() != hashes[key]:
            raise RuntimeError(f"Input changed during experiment: {path}")
    draws = per_cell * len(cells)
    report = {
        "schema_version": 1, "build_draws": draws, "requested_build_draws": args.builds,
        "incoming_trajectories": draws * len(pressure["incoming_patterns"]),
        "outgoing_trajectories": draws * len(pressure["outgoing_patterns"]),
        "kill_race_comparisons_derived_not_extra_trajectories": draws * len(pressure["incoming_patterns"]) * len(pressure["outgoing_patterns"]),
        "comparison_cells": len(cells), "budget_contexts": len(profiles), "draws_per_cell": per_cell,
        "workers": args.workers, "elapsed_seconds": time.perf_counter() - started, "input_sha256": hashes,
        "incoming_pattern_count": len(pressure["incoming_patterns"]), "outgoing_pattern_count": len(pressure["outgoing_patterns"]),
        "duration_seconds": pressure["duration"], "horizons": pressure["horizons"], "seeds": pressure["seeds"],
        "groups": groups, "incoming_totals": list(incoming_totals.values()),
        "outgoing_totals": list(outgoing_totals.values()), "incoming_by_pressure_scale": list(pressure_totals.values()),
        "notes": [
            "Draws use replacement. Distinct counts are within each cell, with stat sums rounded to1e-9; do not sum and claim globally unique builds.",
            "Same funded builds, resistance debuffs and enemy environment are crossed with all patterns. Trajectories across patterns/price models are correlated, not independent observations.",
            "Survival horizons reuse one incoming trajectory. Killrace comparisons reuse independent static incoming/outgoing tracks; they are not additional simulations. Exact simultaneous kills are reported separately.",
            "Potential output continues against a counterfactual training target after its first death, using a fixed30s denominator. Actual Health removed is separately clamped; killtime is the first death.",
            "Reference steady DPS is an analytical saved-example estimate versus fixed Armor500/resistance40, without target avoidance. It is not an extra stochastic trajectory and does not replace event-time output.",
            "Reference EHP axes exclude Health Regeneration and external curses; weakest resistance covers all four nonphysical types. All-axis comparisons hold level/gear/talents/model/seed fixed.",
            "Incoming raw packets/DoTs scale by legal enemy level, level gap and pressure multiplier. Player resistance debuffs are external stress contexts, not refunded item budget.",
            "All-resistance price multipliers are4(initial) and6(reviewed), relative to the original base single-resistance unit. Individual resistance multipliers are1and1.5, respectively; all-resistance therefore costs four contemporaneous single-resistance properties in both models. This differs from historical initial pricing. No production loot or talent prices were changed.",
            "Fixed position and static stats omit movement, aiming, kiting, crowd control, active healing decisions, parry and undefined unique-item mechanics. Simulation is not game physics or proof of exploit absence.",
        ],
    }
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (args.output / "sampled_profiles.json").write_text(json.dumps(samples, indent=2) + "\n", encoding="utf-8")
    lines = ["# Combat pressure experiment", "", f"**{draws:,} sampled build draws; {report['incoming_trajectories']:,} incoming and {report['outgoing_trajectories']:,} outgoing event-time trajectories.**", "",
             f"{len(cells)} comparison cells across{len(profiles)} level/gear/talent contexts;{args.workers} workers;{report['elapsed_seconds']:.1f}s elapsed. Samples use replacement. The trajectories share builds and environments; they are not independent.", "",
             "## Coverage", "", "- Player levels1/15/30/45/60; gear0/10/20/40/60/100; talent0/5/10/20; legal enemy levels1–60.",
             f"- {len(pressure['incoming_patterns'])} incoming patterns and{len(pressure['outgoing_patterns'])} outgoing patterns; exact event times, continuous Stamina regeneration.",
             "- Equal120rawDPS packets at0.1/0.25/1/4/8s before pressure multipliers0.25/1/4/10; all five damage types.",
             "- Standalone3/4/12/16s DoTs, mild/strong/equal-total comparisons, separate melee/spell streams, immediate bursts, armor-ignore/unavoidable hits, hit-dependent burns and stacking Poison.",
             "- Individual paid resistance affixes and external per-type debuffs0/−20/−50/−100. Target Armor0–5000, independent resistances−100–80%, penetration0/50/100%, evasion0–75%, block0–90%, HP factors0.5/1/4.",
             "", "## Incoming survival (all sampled budgets/environments pooled)", "", "These aggregates describe the deliberately broad test mixture, not a normal encounter roster. Use incoming.csv for matched budgets and conditional pressure/penetration/level/resistance slices.", "",
             "| Model | Pattern | Trials | Survive1s | Survive3s | Survive10s | Survive30s | First packet lethal if landed at full Health |", "|---|---|---:|---:|---:|---:|---:|---:|"]
    for row in report["incoming_totals"]:
        n = row["trials"]
        rates = " | ".join(f"{row[f'survived_{h}s']/n:.2%}" for h in pressure["horizons"])
        lines.append(f"| {row['model']} | {row['pattern']} | {n:,} | {rates} | {row['first_packet_lethal_if_landed']/n:.2%} |")
    lines += ["", "## Outgoing fixed-horizon potential", "", "Potential DPS is the counterfactual training continuation; actual Health removal and killtime are separately recorded. These pooled random-opponent values are not a ranking of abilities or equal-budget builds.", "",
              "| Model | Pattern | Trajectories | Mean potential DPS | Killed within30s |", "|---|---|---:|---:|---:|"]
    for row in report["outgoing_totals"]:
        lines.append(f"| {row['model']} | {row['pattern']} | {row['trials']:,} | {row['potential_damage_sum']/row['trials']/pressure['duration']:.2f} | {row['kills']/row['trials']:.2%} |")
    lines += ["", "## Files and interpretation", "", "- [Complete metadata and cell diagnostics](report.json).", "- [Incoming conditional results](incoming.csv).", "- [Outgoing conditional results](outgoing.csv).", "- [Derived killrace comparisons](kill_race.csv).", "- [Funded selected profiles](sampled_profiles.json).", ""] + ["- " + note for note in report["notes"]]
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("build_draws", "incoming_trajectories", "outgoing_trajectories", "elapsed_seconds")}), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description="Large paired event-time pressure study; budgets and enemies remain provisional.")
    parser.add_argument("--builds", type=int, default=10_000_000)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--output", type=Path, default=HERE / "pressure_results")
    args = parser.parse_args()
    if args.builds < 240 or args.workers < 1:
        parser.error("Use at least240 build draws and a positive worker count.")
    run(args)


if __name__ == "__main__":
    main()
