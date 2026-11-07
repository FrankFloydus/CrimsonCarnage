#!/usr/bin/env python3
"""Configuration-only enemy-pressure and consumable-cooldown sensitivity."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

import leveling_attrition as chains
import leveling_study as study
import simulator as sim


HERE = Path(__file__).resolve().parent


def policy_config(pressure, cooldown, builds):
    config = chains.default_config()
    config["builds_per_context"] = int(builds)
    config["charges"] = [3]
    config["study_template"] = study.default_config()
    config["study_template"]["consumables"]["cooldown"] = float(cooldown)
    for pattern in config["study_template"]["enemy_patterns"]:
        pattern["pressure"] *= float(pressure)
    return config


def collect(spec):
    config, rules, level, tier, pressure, cooldown = spec
    experiment = chains.experiment_config(config, 3)
    chains.validate_config(config, rules, experiment)
    seed = int(config["seed"]) + int(level) * 100 + list(config["gear_tiers"]).index(tier)
    requested = int(config["builds_per_context"])
    player, _ = study.draw_profiles(
        requested + max(64, 2 * len(study.FUNDING)), level, tier,
        config["price"], seed, rules, experiment,
    )
    keep = np.flatnonzero(~player["anchor"])[:requested]
    if len(keep) != requested:
        raise ValueError("Insufficient non-anchor profiles")
    player = {key: np.asarray(value)[keep].copy() for key, value in player.items()}
    if not np.all(player["cohort"] == 1):
        raise ValueError("Sensitivity requires coherent profiles")
    player["consumable_policy"][:] = 1
    result = chains.run_chain(player, rules, experiment, config, seed)
    dead = result["combat_deaths"] | result["rest_deaths"]
    deaths = int(dead.sum())
    first = result["kills"] >= 1
    return {
        "level": int(level), "gear": tier, "pressure_scale": float(pressure),
        "consumable_cooldown": float(cooldown), "chains": requested,
        "encounters_attempted": int(result["attempted"].sum()),
        "first_enemy_killed": int(first.sum()),
        "completed_chains": int(result["completed"].sum()),
        "mean_enemies_killed": float(result["kills"].mean()),
        "kill_count_p10": float(np.quantile(result["kills"], .1)),
        "kill_count_median": float(np.quantile(result["kills"], .5)),
        "kill_count_p90": float(np.quantile(result["kills"], .9)),
        "deaths": deaths,
        "rest_deaths": int(result["rest_deaths"].sum()),
        "timeouts": int(result["timeouts"].sum()),
        "mean_potions_used": float(result["potions_used"].mean()),
        "deaths_with_charges_remaining": int(np.count_nonzero(dead & (result["charges"] > 0))),
        "mean_charges_remaining_at_death": float(result["charges"][dead].mean()) if deaths else None,
    }


def verify_collector(rules):
    config = policy_config(1, 8, 32)
    baseline, _ = chains.job((config, rules, 1, "standard", 3))
    collected = collect((config, rules, 1, "standard", 1, 8))
    keys = ("chains", "encounters_attempted", "first_enemy_killed", "completed_chains", "mean_enemies_killed", "kill_count_median", "timeouts", "mean_potions_used")
    for key in keys:
        if baseline[key] != collected[key]:
            raise AssertionError(f"Collector disagrees with baseline chain job: {key}")
    return len(keys)


def write_report(path, rows, manifest):
    lines = [
        "# Route pressure and consumable cooldown sensitivity", "",
        f"Executed **{manifest['chains']:,} coherent persistent chains** and **{manifest['encounters_attempted']:,} actual encounters**, separately from the baseline attrition and broad leveling runs.", "",
        "All policies keep three finite charges,35%-Max-Health restoration,35% use threshold,ten encounters and10-second inter-fight windows. Only authored enemy damage pressure and the experimental consumable cooldown change. Pressure scaling also changes the magnitude of ailments seeded by those enemy Hits; it is not a simulation of player aiming, manual dodging or skill.", "",
        "The same generated profile inputs are reused across policies. Random outcome streams can diverge after different death/timing decisions; these are reproducible population comparisons, not perfectly paired identical event sequences.", "",
        "| Level | Gear | Pressure | Consumable CD | First enemy killed | Ten completed | Median kills | Deaths with charges left | Mean charges left at death |",
        "|---:|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        deaths = row["deaths"]
        remaining = row["mean_charges_remaining_at_death"]
        lines.append(
            f"| {row['level']} | {row['gear']} | {row['pressure_scale']:.2f} | {row['consumable_cooldown']:g}s | "
            f"{row['first_enemy_killed']/row['chains']:.1%} | {row['completed_chains']/row['chains']:.1%} | "
            f"{row['kill_count_median']:g} | "
            f"{row['deaths_with_charges_remaining']/deaths:.1%} | {remaining:.2f} |"
            if deaths else
            f"| {row['level']} | {row['gear']} | {row['pressure_scale']:.2f} | {row['consumable_cooldown']:g}s | "
            f"{row['first_enemy_killed']/row['chains']:.1%} | {row['completed_chains']/row['chains']:.1%} | "
            f"{row['kill_count_median']:g} | n/a | n/a |"
        )
    lines += [
        "", "## Reading the result", "",
        "Deaths with charges remaining distinguish a burst/cooldown problem from total consumable exhaustion. Extra stock alone cannot help a player who dies while unable to consume an available charge.", "",
        "Pressure scales are what-if encounter inputs, not changes to Strength, Armor, resistance, critical, ailment or resource formulas. No exact pressure or potion cooldown is approved as game content by this experiment.",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builds", type=int, default=1024)
    parser.add_argument("--workers", type=int, default=min(4, os.cpu_count() or 1))
    parser.add_argument("--output", type=Path, default=HERE / "leveling_results" / "attrition_sensitivity")
    args = parser.parse_args()
    rules = sim.read_json(sim.DEFAULT_RULES)
    checks = verify_collector(rules)
    policies, specs = [], []
    for pressure in (1., .75, .5):
        for cooldown in (8., 4.):
            config = policy_config(pressure, cooldown, args.builds)
            policies.append({"pressure_scale": pressure, "cooldown": cooldown, "config": config})
            levels = (1, 10, 60) if cooldown == 8 else (1, 10)
            for level in levels:
                for tier in ("low", "standard"):
                    specs.append((config, rules, level, tier, pressure, cooldown))
    source_paths = (Path(__file__), HERE / "leveling_attrition.py", HERE / "leveling_study.py", HERE / "simulator.py", sim.DEFAULT_RULES)
    signature = lambda: {
        str(path.relative_to(HERE.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in source_paths
    }
    before = signature()
    started = time.perf_counter()
    rows = []
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(collect, spec) for spec in specs]
        for index, future in enumerate(as_completed(futures), 1):
            rows.append(future.result())
            print(json.dumps({"contexts_complete": index, "contexts_total": len(specs)}), flush=True)
    after = signature()
    if before != after:
        raise RuntimeError("Source changed during sensitivity run; rerun before reporting")
    rows.sort(key=lambda row: (row["level"], row["gear"], -row["pressure_scale"], -row["consumable_cooldown"]))
    manifest = {
        "schema_version": 1, "command_line": sys.argv,
        "chains": sum(row["chains"] for row in rows),
        "encounters_attempted": sum(row["encounters_attempted"] for row in rows),
        "contexts": len(rows), "collector_parity_assertions": checks,
        "elapsed_seconds": time.perf_counter() - started,
        "source_sha256_before": before, "source_sha256": after,
        "source_revision_unchanged": True,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    for name, value in (("experiment.json", policies), ("manifest.json", manifest), ("summaries.json", rows)):
        (args.output / name).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    write_report(args.output / "report.md", rows, manifest)
    print(json.dumps(manifest, indent=2), flush=True)


if __name__ == "__main__":
    main()
