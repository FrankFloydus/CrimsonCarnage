#!/usr/bin/env python3
"""Separate outgoing/incoming TTK experiments without any Health restoration.

This reuses the current study's funded actor draws and shared combat clocks.
The passive actor never schedules or delivers actions. No inflated Health pool,
duel outcome, hypothetical potion, or itemization conclusion is substituted.
"""
from __future__ import annotations

import argparse
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
ROOT = HERE.parent.parent
DIRECTIONS = ("outgoing", "incoming")
METRICS = ("ttk", "observed_duration", "health_damage", "absorbed_damage",
           "source_stamina", "source_mana", "source_resource_wait", "actions",
           "hits", "crits", "misses", "dodges", "blocks", "target_health",
           "target_absorption", "restored", "potions_used", "passive_actions")
RESULT_DTYPE = np.dtype([(key, "f8") for key in METRICS] + [
    ("level", "i2"), ("tier", "i1"), ("repeat", "i2"), ("direction", "i1"),
    ("cohort", "i1"), ("style", "i1"), ("pattern", "i1"), ("gap", "i2"),
    ("ordinary", "?"), ("stamina_policy", "i1"), ("profile_index", "i4")])


def default_config():
    config = study.default_config()
    config.update(description="Independent no-healing outgoing/incoming TTK; provisional funding, not itemization.",
                  builds_per_context=1024, repeats=2, horizon=60.0)
    config["prices"] = {"neutral": {}}
    config["consumables"]["charges"] = 0
    return config


def validate_config(config, rules):
    if config["builds_per_context"] < 1 or config["repeats"] < 1:
        raise ValueError("Positive profile and repeat counts required")
    if not config["levels"] or any(level < 1 or level > rules["max_level"] for level in config["levels"]):
        raise ValueError("Levels must be within the game level range")
    if len(set(config["levels"])) != len(config["levels"]):
        raise ValueError("Duplicate levels would duplicate samples")
    if config["prices"] != {"neutral": {}}:
        raise ValueError("This benchmark uses neutral provisional funding only")
    if config["consumables"]["charges"] != 0:
        raise ValueError("No-healing benchmark requires zero consumable charges")
    dt, horizon = config["dt"], config["horizon"]
    if not math.isfinite(dt) or dt <= 0 or not math.isfinite(horizon) or horizon <= 0:
        raise ValueError("Positive finite timestep/horizon required")
    periods = [1., horizon] + [rules[key+"_period"] for key in ("burn", "bleed", "poison")]
    periods += [pattern.get("period", 1.) for pattern in config["enemy_patterns"]]
    if any(not math.isclose(round(period/dt)*dt, period, abs_tol=1e-9) for period in periods):
        raise ValueError("Timestep must divide the horizon and every DoT period")


def simulate_direction(attacker, passive, rules, config, seed):
    """Return directed target TTK. Passive offense is deliberately never invoked."""
    if config["consumables"]["charges"] != 0:
        raise ValueError("Health restoration is disabled in this benchmark")
    actors = []
    for actor in (attacker, passive):
        copied = dict(actor)
        copied["consumable_policy"] = np.zeros(len(actor["health"]), dtype=int)
        actors.append(copied)
    rng = np.random.default_rng(seed)
    dt = float(config["dt"])
    source, target = [study.State(actor, rng, dt, rules, config) for actor in actors]
    for step in range(int(round(config["horizon"]/dt))+1):
        now = round(step*dt, 9)
        delta = dt if step else 0.
        study._advance(source, now, step, delta, rules, config)
        study._advance(target, now, step, delta, rules, config)
        # Only the source can start an action. The target retains its actual
        # authored pools, defenses and recovery; it never retaliates.
        release = study._actions(source, target, delta)
        study._deliver(source, target, release, rng, now, step, dt, rules, config)
        done = target.hp <= 0
        source.finished |= done
        target.finished |= done
        if np.all(done):
            break
    if np.any(source.restored) or np.any(target.restored) or np.any(source.potions_used) or np.any(target.potions_used):
        raise AssertionError("No-healing experiment restored Health")
    if np.any(target.actions) or np.any(target.hits):
        raise AssertionError("Passive target acted")
    return {
        "ttk": target.death.copy(),
        "observed_duration": np.minimum(target.death, config["horizon"]),
        "health_damage": target.damage_hp, "absorbed_damage": target.damage_abs,
        "source_stamina": source.st, "source_mana": source.mp,
        "source_resource_wait": source.resource_wait, "actions": source.actions,
        "hits": source.hits, "crits": source.crits, "misses": source.misses,
        "dodges": source.dodges, "blocks": source.blocks,
        "target_health": target.hp, "target_absorption": target.abs,
        "restored": source.restored+target.restored,
        "potions_used": source.potions_used+target.potions_used,
        "passive_actions": target.actions,
    }


def summarize(data):
    count = len(data)
    if not count:
        return {"trajectories": 0}
    events = data["ttk"][np.isfinite(data["ttk"])]
    quantiles = np.quantile(events, [.1, .5, .9]) if len(events) else [None]*3
    result = {"trajectories": count, "kills": len(events), "censored": count-len(events),
              "kill_fraction": len(events)/count,
              "conditional_ttk_mean": float(events.mean()) if len(events) else None,
              "restricted_mean_observed_duration": float(data["observed_duration"].mean())}
    result.update({"conditional_ttk_"+q: None if value is None else float(value)
                   for q, value in zip(("p10", "p50", "p90"), quantiles)})
    for name in METRICS[2:]:
        result[name+"_mean"] = float(data[name].mean())
    return result


def job(spec):
    config, rules, level, tier = spec
    n, seed = config["builds_per_context"], config["seed"]
    tier_index = list(config["gear_tiers"]).index(tier)
    player, fingerprints = study.draw_profiles(n, level, tier, "neutral", seed, rules, config)
    player["consumable_policy"][:] = 0
    enemy = study.draw_enemy(player, np.random.SeedSequence([seed, level, tier_index, 701]), rules, config)
    enemy["consumable_policy"][:] = 0
    ordinary = study.ordinary_enemy_mask(player, enemy, rules, config)
    output = np.zeros(n*config["repeats"]*2, dtype=RESULT_DTYPE)
    for repeat in range(config["repeats"]):
        for direction, pair in enumerate(((player, enemy), (enemy, player))):
            result = simulate_direction(*pair, rules, config,
                                        np.random.SeedSequence([seed, level, tier_index, repeat, direction, 917]))
            start = (repeat*2+direction)*n
            target = output[start:start+n]
            for key in METRICS:
                target[key] = result[key]
            target["level"], target["tier"] = level, tier_index
            target["repeat"], target["direction"] = repeat, direction
            # Mutually exclusive cohorts: broad random, coherent, funded anchors.
            target["cohort"] = np.where(player["anchor"], 2, player["cohort"])
            target["style"], target["pattern"] = player["style"], enemy["pattern"]
            target["gap"] = enemy["level"]-player["level"]
            target["ordinary"] = ordinary
            target["stamina_policy"] = player["stamina_policy"]
            target["profile_index"] = np.arange(n)
    return output, fingerprints


def groups(data, config):
    yield "all", "all", np.ones(len(data), dtype=bool)
    for value, label in enumerate(("broad", "coherent", "anchor")):
        yield "cohort", label, data["cohort"] == value
    yield "ordinary_coherent", "all", data["ordinary"] & (data["cohort"] == 1)
    yield "same_level_coherent", "all", (data["gap"] == 0) & (data["cohort"] == 1)
    yield "joint_defense_anchor", "all", (data["cohort"] == 2) & (data["profile_index"] == len(study.FUNDING))
    for value in np.unique(data["gap"]):
        yield "level_gap", str(value), data["gap"] == value
    for value, label in enumerate(study.STYLES):
        yield "player_style", label, data["style"] == value
    for value, pattern in enumerate(config["enemy_patterns"]):
        yield "enemy_pattern", pattern["id"], data["pattern"] == value


def write_report(folder, data, config, manifest):
    def value(number):
        return "—" if number is None else f"{number:.2f}"

    lines = ["# No-healing directed combat benchmark", "",
             f"Executed **{len(data):,} directed trajectories**, with **{manifest['profile_draws']:,} profile draws** "
             f"and **{manifest['distinct_profiles']:,} distinct generated stat/weapon profiles**, across levels "
             f"{min(config['levels'])}–{max(config['levels'])}.", "",
             "Outgoing: player repeatedly attacks an enemy that never retaliates. Incoming: enemy repeatedly attacks "
             "the passive player. Both start fresh with the same sampled profiles in each direction. These are separate "
             "TTK measurements, not duel win probabilities. No Health restoration, consumables, passive Health regeneration "
             "or healing effect occurs. Stamina/Mana regeneration and Absorption recovery remain active.", "",
             f"Horizon: {config['horizon']:g}s; grid: {config['dt']:g}s. The target is censored if it survives the horizon. "
             "TTK percentiles use kills only. Restricted mean observed duration averages min(TTK, horizon), "
             "an explicitly capped observation rather than an estimate of the unobserved true kill time.", "",
             "## Same-level coherent reference", "",
             "All same-level enemies and style-coherent player allocations, including extreme defensive cases. "
             "Funding tiers are provisional raw-stat funding multipliers, not approved equipment quality or equal item values.", "",
             "| Player levels | Funding tier | Direction | Trials | Target killed | Censored | Conditional TTK p10 / p50 / p90 (s) | Restricted mean observation (s) |",
             "|---|---|---|---:|---:|---:|---|---:|"]
    for low, high in ((1, 9), (10, 19), (20, 29), (30, 39), (40, 49), (50, 60)):
        for tier_index, tier in enumerate(config["gear_tiers"]):
            for direction_index, direction in enumerate(DIRECTIONS):
                mask = ((data["level"] >= low) & (data["level"] <= high) & (data["tier"] == tier_index)
                        & (data["direction"] == direction_index) & (data["cohort"] == 1) & (data["gap"] == 0))
                row = summarize(data[mask])
                if row["trajectories"]:
                    qs = " / ".join(value(row["conditional_ttk_"+q]) for q in ("p10", "p50", "p90"))
                    lines.append(f"| {low}–{high} | {tier} | {direction} | {row['trajectories']:,} | {row['kill_fraction']:.1%} | "
                                 f"{row['censored']:,} | {qs} | {row['restricted_mean_observed_duration']:.2f} |")
    lines += ["", "## Broad stress, coherent profiles and deliberate anchors", "",
              "Includes all sampled enemy level gaps and defensive envelopes. Cohorts below are disjoint.", "",
              "| Cohort | Direction | Trials | Target killed | Conditional median TTK (s) | Restricted mean observation (s) |",
              "|---|---|---:|---:|---:|---:|"]
    for cohort, label in enumerate(("broad", "coherent", "anchor")):
        for direction, name in enumerate(DIRECTIONS):
            row = summarize(data[(data["cohort"] == cohort) & (data["direction"] == direction)])
            if row["trajectories"]:
                lines.append(f"| {label} | {name} | {row['trajectories']:,} | {row['kill_fraction']:.1%} | "
                             f"{value(row['conditional_ttk_p50'])} | {row['restricted_mean_observed_duration']:.2f} |")
    lines += ["", "## Interpretation and limits", "",
              "- All actors retain their generated Health. The passive side is disabled by never invoking its action scheduler; no huge-Health stand-in is used.",
              "- Every outgoing/incoming pair uses the same player/enemy configuration but fresh pools and an independent outcome stream. A fast player kill cannot hide a fragile player defense, and a strong enemy cannot truncate our offensive TTK measurement. Incoming TTK is a passive-player defense baseline: it excludes Chill or other interference from the player's outgoing attacks.",
              "- Enemy physical/magical Hits, short/long DoTs, bypass damage and hybrid patterns use the same shared damage/ailment/defense clocks as the leveling study. Single-sided utility limitations apply: Chill on a passive target does not improve this outgoing TTK, and Hollowed affects Absorption recovery but cannot reduce nonexistent healing.",
              "- Source Stamina/Mana remaining, resource waiting, damage to Health/Absorption, actions, criticals, misses, dodges and blocks are retained in results.npz and summaries.csv. Counts stop at death or the horizon. The inherited hits counter means accepted deliveries: for authored environmental DoTs it counts the successful application, not each tick or necessarily a direct Hit.",
              "- Joint-defense anchors remain identifiable separately in summaries.csv. They spend one conserved experimental budget on Armor, Evasion and Block; low funding does not guarantee reaching all caps. Each context has one such deliberately chosen actor, so a few outcome repeats are probes, not a high-confidence population estimate.",
              "- Existing funding rates, weapon DPS envelopes, Magic Power coefficients and enemy pressure are explicit experimental inputs. This measures their consequences; it does not establish final item budgets, weapon ratios, ability coefficients, encounter tuning or a player-skill death rate.",
              "- Raw profile fingerprints omit random outcome seeds and environment labels. Repeating an actor against a new environment does not manufacture a new build.",
              "- No comparison in this report assumes consumable charges, healing access, potion cooldowns, replenishment or route pacing.",
              f"- Provenance stable during execution: **{manifest['source_revision_unchanged']}**. Health restored: **{data['restored'].sum():g}**; consumables used: **{data['potions_used'].sum():g}**."]
    (folder/"report.md").write_text("\n".join(lines)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path, default=HERE/"no_healing_results")
    parser.add_argument("--builds", type=int)
    parser.add_argument("--repeats", type=int)
    parser.add_argument("--levels", nargs="+", type=int)
    parser.add_argument("--dt", type=float)
    parser.add_argument("--horizon", type=float)
    parser.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
    args = parser.parse_args()
    config = default_config()
    if args.config:
        config = json.loads(args.config.read_text(encoding="utf-8-sig"))
    for arg, key in ((args.builds, "builds_per_context"), (args.repeats, "repeats"), (args.levels, "levels"),
                     (args.dt, "dt"), (args.horizon, "horizon")):
        if arg is not None:
            config[key] = arg
    rules = sim.read_json(sim.DEFAULT_RULES)
    validate_config(config, rules)
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    paths = [Path(__file__), HERE/"leveling_study.py", HERE/"simulator.py", sim.DEFAULT_RULES]
    paths += sorted((ROOT/"combat").rglob("*.gd"))
    source = {str(path.relative_to(ROOT)): path.read_bytes() for path in paths}
    before = {name: hashlib.sha256(content).hexdigest() for name, content in source.items()}
    for name, content in source.items():
        destination = folder/"source_snapshot"/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
    (folder/"experiment.json").write_text(json.dumps(config, indent=2)+"\n", encoding="utf-8")
    (folder/"rules_snapshot.json").write_text(json.dumps(rules, indent=2)+"\n", encoding="utf-8")
    specs = [(config, rules, level, tier) for level in config["levels"] for tier in config["gear_tiers"]]
    started = time.perf_counter()
    completed = []
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(job, spec) for spec in specs]
        for index, future in enumerate(as_completed(futures), 1):
            data, hashes = future.result()
            completed.append((int(data['level'][0]), int(data['tier'][0]), data, hashes))
            if index % max(1, len(specs)//30) == 0 or index == len(specs):
                print(json.dumps({"contexts_complete": index, "contexts": len(specs),
                                  "elapsed_seconds": round(time.perf_counter()-started, 1)}), flush=True)
    completed.sort(key=lambda cell: cell[:2])
    data = np.concatenate([cell[2] for cell in completed])
    data.sort(order=["level", "tier", "profile_index", "repeat", "direction"])
    hashes = np.frombuffer(b"".join(cell[3] for cell in completed), dtype="V16")
    after = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    manifest = {"schema_version": 1, "command_line": sys.argv, "python_version": sys.version,
                "numpy_version": np.__version__, "contexts": len(specs), "profile_draws": len(hashes),
                "distinct_profiles": len(np.unique(hashes)), "directed_trajectories": len(data),
                "directions": list(DIRECTIONS), "repeats": config["repeats"], "horizon": config["horizon"],
                "dt": config["dt"], "elapsed_seconds": time.perf_counter()-started,
                "health_restored": float(data["restored"].sum()), "consumables_used": int(data["potions_used"].sum()),
                "passive_actions": int(data["passive_actions"].sum()), "source_sha256_before": before,
                "source_sha256_after": after, "source_revision_unchanged": before == after}
    (folder/"manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    if before != after:
        raise RuntimeError("Sources changed during the benchmark; rerun before interpreting results")
    np.savez_compressed(folder/"results.npz", results=data, profile_fingerprints=hashes)
    rows = []
    for level in config["levels"]:
        for tier_index, tier in enumerate(config["gear_tiers"]):
            for direction_index, direction in enumerate(DIRECTIONS):
                cell = data[(data["level"] == level) & (data["tier"] == tier_index) & (data["direction"] == direction_index)]
                for axis, value, mask in groups(cell, config):
                    if np.any(mask):
                        rows.append({"level": level, "funding_tier": tier, "direction": direction,
                                     "axis": axis, "value": value, **summarize(cell[mask])})
    study._write_csv(folder/"summaries.csv", rows)
    write_report(folder, data, config, manifest)
    print(json.dumps({key: value for key, value in manifest.items() if not key.startswith("source_sha256")}, indent=2), flush=True)


if __name__ == "__main__":
    main()
