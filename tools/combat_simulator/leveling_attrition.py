#!/usr/bin/env python3
"""Finite-consumable encounter chains using the current leveling-study clocks.

Player Health, Stamina, Mana, Absorption, consumable charges, and cooldowns carry
between encounters. Remaining ailments are simulated during the inter-fight
window; reaching the next fight does not clear them or restore Health.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

import leveling_study as study
import simulator as sim


HERE = Path(__file__).resolve().parent
FIGHT, REST, COMPLETE, DEAD, TIMEOUT, INACTIVE = range(6)


def default_config():
    return {
        "seed": 20261107,
        "levels": [1, 5, 10, 20, 40, 60],
        "gear_tiers": ["low", "standard", "high"],
        "price": "neutral",
        "builds_per_context": 4096,
        "encounters": 10,
        "charges": [3, 6],
        "interfight_seconds": 10.0,
        "fight_horizon": 45.0,
        "dt": 0.1,
        "coherent_fraction": 1.0,
        "ordinary_enemy_overrides": {
            "level_gap_cases": [0],
            "enemy_health_multipliers": [0.8, 1.2],
            "enemy_armor_ratings_at60": [0, 150],
            "enemy_school_resistances": [0, 20, 40],
            "enemy_evasion_at60": [0, 100],
            "enemy_block_chances": [0, 0, 20],
            "enemy_armor_penetration": [0, 0, 25],
            "enemy_absorption_health_fractions": [0, 0, 0.3],
        },
        "enemy_pattern_ids": [
            "physical_fast", "physical_medium", "fire_fast", "cold",
            "lightning", "void", "necrotic", "hybrid",
        ],
    }


def experiment_config(config, charges):
    result = copy.deepcopy(config.get("study_template", study.default_config()))
    result.update(copy.deepcopy(config["ordinary_enemy_overrides"]))
    result["enemy_patterns"] = [
        item for item in result["enemy_patterns"]
        if item["id"] in config["enemy_pattern_ids"]
    ]
    if not result["enemy_patterns"]:
        raise ValueError("At least one enemy pattern is required")
    result["consumables"]["charges"] = int(charges)
    result["dt"] = float(config["dt"])
    result["horizon"] = float(config["fight_horizon"])
    result["coherent_fraction"] = float(config["coherent_fraction"])
    return result


def validate_config(config, rules, experiment):
    dt = float(config["dt"])
    if not math.isfinite(dt) or dt <= 0 or not math.isclose(round(1 / dt) * dt, 1):
        raise ValueError("dt must be positive and divide one second")
    if int(config["encounters"]) < 1 or int(config["builds_per_context"]) < 1:
        raise ValueError("Positive encounter and build counts are required")
    if float(config["fight_horizon"]) <= 0:
        raise ValueError("Positive fight horizon required")
    if any(int(value) != value or value < 0 for value in config["charges"]):
        raise ValueError("Consumable charges must be nonnegative integers")
    longest = max(
        rules["burn_duration"], rules["bleed_duration"], rules["poison_duration"],
        rules["chill_duration"], rules["zapped_duration"], rules["hollowed_duration"],
        *(item.get("duration", 0) for item in experiment["enemy_patterns"]),
    )
    if float(config["interfight_seconds"]) + 1e-9 < longest:
        raise ValueError(
            "This chain model requires an inter-fight window at least as long as "
            "the longest retained effect; it must tick effects to expiry before "
            "freezing completed vector rows."
        )
    if any(not 1 <= int(level) <= rules["max_level"] for level in config["levels"]):
        raise ValueError("Levels must be within the game's supported range")


def run_chain(player, rules, experiment, config, seed):
    """Run vectorized chains without pool, charge, or ailment resets.

    Every row receives its own exact inter-fight window. Early finishers freeze
    only after all their retained effects have had time to tick to expiry. They
    do not receive extra free recovery while another row finishes its battle.
    """
    n = len(player["health"])
    dt = float(config["dt"])
    state = study.State(player, np.random.default_rng(seed), dt, rules, experiment)
    active = np.ones(n, bool)
    kills = np.zeros(n, np.int16)
    attempted = np.zeros(n, np.int16)
    combat_deaths = np.zeros(n, bool)
    rest_deaths = np.zeros(n, bool)
    timeouts = np.zeros(n, bool)
    rows = []
    global_step = 0
    for encounter in range(int(config["encounters"])):
        reached = active & (state.hp > 0)
        if not np.any(reached):
            break
        attempted[reached] += 1
        state.finished[:] = ~reached
        # Ending combat cancels the remaining action without refunding its cost.
        state.active[:] = False
        state.released[:] = False
        state.progress[:] = 0
        stats = study.draw_enemy(
            player, np.random.SeedSequence([seed, encounter, 721]), rules, experiment
        )
        enemy = study.State(
            stats, np.random.default_rng(np.random.SeedSequence([seed, encounter, 722])),
            dt, rules, experiment,
        )
        enemy.hp[~reached] = 0
        enemy.finished[~reached] = True
        rng = np.random.default_rng(np.random.SeedSequence([seed, encounter, 723]))
        phase = np.full(n, INACTIVE, np.int8)
        phase[reached] = FIGHT
        rest_end = np.full(n, np.inf)
        start_hp = state.hp.copy()
        start_charges = state.charges.copy()
        start_time = global_step * dt
        combat_limit = float(config["fight_horizon"])
        total_steps = int(math.ceil(
            (combat_limit + float(config["interfight_seconds"])) / dt
        )) + 2
        for local_step in range(total_steps):
            t = round(global_step * dt, 9)
            delta = 0.0 if local_step == 0 else dt
            study._advance(state, t, global_step, delta, rules, experiment)
            study._advance(enemy, t, global_step, delta, rules, experiment)
            player_due = study._actions(state, enemy, delta) & (phase == FIGHT)
            enemy_due = study._actions(enemy, state, delta) & (phase == FIGHT)
            study._deliver(state, enemy, player_due, rng, t, global_step, dt, rules, experiment)
            study._deliver(enemy, state, enemy_due, rng, t, global_step, dt, rules, experiment)
            died = (phase <= REST) & (state.hp <= 0)
            combat_deaths |= died & (phase == FIGHT)
            rest_deaths |= died & (phase == REST)
            phase[died] = DEAD
            active[died] = False
            won = (phase == FIGHT) & (enemy.hp <= 0) & (state.hp > 0)
            kills[won] += 1
            phase[won] = REST
            rest_end[won] = t + float(config["interfight_seconds"])
            state.active[won] = False
            state.released[won] = False
            timed_out = (phase == FIGHT) & (t - start_time >= combat_limit - 1e-9)
            timeouts |= timed_out
            phase[timed_out] = TIMEOUT
            active[timed_out] = False
            rested = (phase == REST) & (t >= rest_end - 1e-9)
            phase[rested] = COMPLETE
            state.finished[:] = (phase != FIGHT) & (phase != REST)
            enemy.finished[:] = phase != FIGHT
            if not np.any((phase == FIGHT) | (phase == REST)):
                break
            global_step += 1
        if np.any((phase == FIGHT) | (phase == REST)):
            raise RuntimeError("Encounter wave ended before all rows completed their clocks")
        survivors = phase == COMPLETE
        # With the validated rest window, no lingering effect may be discarded.
        if np.any(state.dot_rate[survivors] > 1e-9) or np.any(state.poison[:, survivors] > 1e-9):
            raise RuntimeError("Retained damage remained at the next-encounter boundary")
        rows.append({
            "encounter": encounter + 1,
            "reached": int(reached.sum()),
            "killed_enemy": int((kills[reached] >= encounter + 1).sum()),
            "survived_rest": int(survivors.sum()),
            "combat_deaths": int(((phase == DEAD) & reached & ~rest_deaths).sum()),
            "rest_deaths": int(((phase == DEAD) & reached & rest_deaths).sum()),
            "timeouts": int((phase == TIMEOUT).sum()),
            "mean_start_health_fraction": float(np.mean(start_hp[reached] / player["health"][reached])),
            "mean_start_charges": float(np.mean(start_charges[reached])),
            "mean_survivor_health_fraction": float(np.mean(state.hp[survivors] / player["health"][survivors])) if np.any(survivors) else None,
            "mean_survivor_charges": float(np.mean(state.charges[survivors])) if np.any(survivors) else None,
        })
    return {
        "completed": (kills == int(config["encounters"])) & active & (state.hp > 0),
        "kills": kills, "attempted": attempted, "combat_deaths": combat_deaths,
        "rest_deaths": rest_deaths, "timeouts": timeouts, "hp": state.hp,
        "charges": state.charges, "potions_used": state.potions_used,
        "health_restored": state.restored, "stamina": state.st, "mana": state.mp,
        "absorption": state.abs, "rows": rows,
    }


def job(spec):
    config, rules, level, tier, charges = spec
    experiment = experiment_config(config, charges)
    validate_config(config, rules, experiment)
    seed = int(config["seed"]) + int(level) * 100 + list(config["gear_tiers"]).index(tier)
    requested = int(config["builds_per_context"])
    player, hashes = study.draw_profiles(
        requested + max(64, 2 * len(study.FUNDING)), level, tier,
        config["price"], seed, rules, experiment,
    )
    if "anchor" not in player:
        raise ValueError("Current study must identify deliberate stress anchors")
    keep = np.flatnonzero(~player["anchor"])[:requested]
    if len(keep) != requested:
        raise ValueError("Insufficient non-anchor player profiles")
    player = {key: np.asarray(value)[keep].copy() for key, value in player.items()}
    fingerprints = np.frombuffer(hashes, dtype="V16")[keep].tobytes()
    if float(config["coherent_fraction"]) == 1 and not np.all(player["cohort"] == 1):
        raise ValueError("Coherent chain cohort unexpectedly includes broad stress profiles")
    player["consumable_policy"][:] = 1
    result = run_chain(player, rules, experiment, config, seed)
    n = len(player["health"])
    first_kills = int(np.count_nonzero(result["kills"] >= 1))
    summary = {
        "level": level, "gear": tier, "charges_initial": charges, "chains": n,
        "encounters_attempted": int(result["attempted"].sum()),
        "enemies_killed": int(result["kills"].sum()),
        "first_enemy_killed": first_kills,
        "completed_chains": int(result["completed"].sum()),
        "combat_deaths": int(result["combat_deaths"].sum()),
        "rest_deaths": int(result["rest_deaths"].sum()),
        "timeouts": int(result["timeouts"].sum()),
        "mean_enemies_killed": float(result["kills"].mean()),
        "kill_count_p10": float(np.quantile(result["kills"], .1)),
        "kill_count_median": float(np.quantile(result["kills"], .5)),
        "kill_count_p90": float(np.quantile(result["kills"], .9)),
        "mean_potions_used": float(result["potions_used"].mean()),
        "mean_remaining_charges": float(result["charges"].mean()),
        "chain_completion_given_first_kill": int(result["completed"].sum()) / first_kills if first_kills else None,
        "kill_count_histogram": np.bincount(result["kills"], minlength=int(config["encounters"]) + 1).tolist(),
        "rounds": result["rows"],
    }
    summary["styles"] = []
    for style, name in enumerate(study.STYLES):
        mask = player["style"] == style
        count = int(mask.sum())
        if count:
            summary["styles"].append({
                "style": name, "chains": count,
                "first_enemy_killed": int(np.count_nonzero(result["kills"][mask] >= 1)),
                "completed_chains": int(result["completed"][mask].sum()),
                "mean_enemies_killed": float(result["kills"][mask].mean()),
                "rest_deaths": int(result["rest_deaths"][mask].sum()),
            })
    return summary, fingerprints


def write_report(path, summaries, manifest, config):
    lines = [
        "# Consumable-only Health attrition experiment", "",
        f"Executed **{manifest['chains']:,} persistent chains**, with **{manifest['encounters_attempted']:,} actual encounters** and up to {config['encounters']} encounters per chain.", "",
        "Every player begins full once. Health, Stamina, Mana, Absorption, consumable charges and cooldowns carry forward. No Health regeneration, healing ability, refill, free cleanse or between-encounter Health reset exists.", "",
        f"After a kill, remaining ailments continue ticking through an exact {config['interfight_seconds']:g}-second inter-fight window. A player can die during that window. Stamina, Mana and Absorption recover through their ordinary rules. Consumables may be used there under the same finite policy.", "",
        "The ordinary-enemy envelope excludes boss-like Health multipliers, maximum resistance, and cap Armor. All of its values remain explicit experimental inputs rather than approved campaign content. Player profiles use style-aligned primary/resource investments under the same funding budgets. Deliberate stress anchors are excluded. Coherent allocation does not simulate player skill.", "",
        "| Level | Gear | Initial charges | Chains | First enemy killed | All ten completed | Mean enemies killed | P10 / median / P90 kills | Death during lingering effects |",
        "|---:|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summaries:
        n = row["chains"]
        lines.append(
            f"| {row['level']} | {row['gear']} | {row['charges_initial']} | {n:,} | "
            f"{row['first_enemy_killed']/n:.1%} | {row['completed_chains']/n:.1%} | "
            f"{row['mean_enemies_killed']:.2f} | "
            f"{row['kill_count_p10']:g} / {row['kill_count_median']:g} / {row['kill_count_p90']:g} | "
            f"{row['rest_deaths']/n:.1%} |"
        )
    lines += [
        "", "## Interpretation", "",
        "- Read first-enemy success separately from full-chain completion. A build that can win one fresh-pool duel may still exhaust finite Health restoration over a route.",
        "- Three versus six starting charges is a policy sensitivity, not an approved consumable capacity. Charges never refill within the route.",
        "- Survivors are selected as the route progresses. Later-encounter average Health cannot be compared as if it described the original population.",
        "- Enemy patterns, defenses, damage, weapon envelopes, gear funding and prices are experimental. No simulation of aiming, movement, manual reaction, AI tactics or real campaign drops is provided.",
        "- Unfinished fights stop at the encounter horizon and are reported as timeouts; they are not converted into kills or deaths. A simultaneous lethal trade counts as a combat death.",
        "- Exact source revisions and the complete input configuration are recorded beside this report. Counts are separate from the broad leveling study.",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path, default=HERE / "leveling_results")
    parser.add_argument("--builds", type=int)
    parser.add_argument("--workers", type=int, default=min(4, os.cpu_count() or 1))
    parser.add_argument("--levels", type=int, nargs="+")
    args = parser.parse_args()
    config = default_config()
    if args.config:
        config.update(json.loads(args.config.read_text(encoding="utf-8-sig")))
    if args.builds is not None:
        config["builds_per_context"] = args.builds
    if args.levels is not None:
        config["levels"] = args.levels
    config.setdefault("study_template", study.default_config())
    rules = sim.read_json(sim.DEFAULT_RULES)
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    source_paths = (Path(__file__), HERE / "leveling_study.py", HERE / "simulator.py", sim.DEFAULT_RULES)
    source_before = {
        str(path.relative_to(HERE.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in source_paths
    }
    summaries, fingerprints = [], []
    specs = [
        (config, rules, level, tier, charges)
        for level in config["levels"] for tier in config["gear_tiers"] for charges in config["charges"]
    ]
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(job, spec) for spec in specs]
        for index, future in enumerate(as_completed(futures), 1):
            summary, hashes = future.result()
            summaries.append(summary)
            fingerprints.append(hashes)
            print(json.dumps({"contexts_complete": index, "contexts_total": len(specs)}), flush=True)
    summaries.sort(key=lambda row: (row["level"], row["gear"], row["charges_initial"]))
    manifest = {
        "schema_version": 1, "seed": config["seed"], "contexts": len(specs),
        "command_line": sys.argv,
        "python_version": sys.version,
        "numpy_version": np.__version__,
        "chains": sum(row["chains"] for row in summaries),
        "encounters_attempted": sum(row["encounters_attempted"] for row in summaries),
        "enemies_killed": sum(row["enemies_killed"] for row in summaries),
        "distinct_stat_weapon_profiles": len(np.unique(np.frombuffer(b"".join(fingerprints), dtype="V16"))),
        "elapsed_seconds": time.perf_counter() - started,
        "source_sha256_before": source_before,
        "source_sha256": {
            str(path.relative_to(HERE.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in source_paths
        },
    }
    manifest["source_revision_unchanged"] = manifest["source_sha256"] == source_before
    if not manifest["source_revision_unchanged"]:
        raise RuntimeError("Source files changed during the run; rerun before reporting current-rules evidence")
    for name, value in (("attrition_experiment.json", config), ("attrition_manifest.json", manifest), ("attrition_summaries.json", summaries)):
        (folder / name).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    write_report(folder / "attrition_report.md", summaries, manifest, config)
    print(json.dumps(manifest, indent=2), flush=True)


if __name__ == "__main__":
    main()
