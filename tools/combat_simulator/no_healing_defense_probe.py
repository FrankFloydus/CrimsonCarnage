#!/usr/bin/env python3
"""Controlled no-healing defensive interactions, without gear funding claims."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

import leveling_study as study
import no_healing_benchmark as benchmark
import simulator as sim


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PROFILES = (
    {"id": "naked"},
    {"id": "armor_1000", "armor": 1000.},
    {"id": "evasion_1000", "evasion": 1000.},
    {"id": "block_90", "block": .9},
    {"id": "evasion_block", "evasion": 1000., "block": .9},
    {"id": "all_caps", "armor": 1000., "evasion": 1000., "block": .9, "resistance": .8},
    {"id": "all_caps_abs_500", "armor": 1000., "evasion": 1000., "block": .9, "resistance": .8, "absorption": 500.},
    {"id": "all_caps_abs_1000", "armor": 1000., "evasion": 1000., "block": .9, "resistance": .8, "absorption": 1000.},
    {"id": "all_caps_abs_1500", "armor": 1000., "evasion": 1000., "block": .9, "resistance": .8, "absorption": 1500.},
    {"id": "abs_1000", "absorption": 1000.},
    {"id": "abs_1500", "absorption": 1500.},
)
PATTERNS = (
    {"id": "physical_fast", "school": 0, "interval": .5},
    {"id": "physical_slow", "school": 0, "interval": 3.},
    {"id": "fire_fast", "school": 1, "interval": .5},
    {"id": "fire_slow", "school": 1, "interval": 3.},
    {"id": "fire_dot", "school": 1, "dot": True},
    {"id": "bleed_dot", "school": 0, "dot": True, "bleed": True},
    {"id": "necrotic_dot", "school": 5, "dot": True},
    {"id": "necrotic_fast", "school": 5, "interval": .5},
    {"id": "hybrid_fast", "school": -1, "interval": .5},
)
RESULT_DTYPE = np.dtype([(name, "f8") for name in benchmark.METRICS] + [
    ("profile", "i2"), ("pattern", "i2"), ("ordinary_proc", "i2"), ("trial", "i4")])


def actor_template(count, rules, config):
    """Real 1000-Health actor; passive behavior is disabled in the scheduler."""
    original, _ = study.draw_profiles(1, 60, "none", "neutral", 7, rules, config)
    actor = {name: np.repeat(value, count, axis=0) for name, value in original.items()}
    overrides = {
        "health": 1000., "absorption": 0., "armor": 0., "evasion": 0., "block": 0.,
        "hit_rating": 50., "critical_chance": 0., "critical_damage": 0., "dot_damage": 0.,
        "penetration": 0., "control_reduction": 0., "cost": 0., "cooldown": 0.,
        "duration": 1., "consumable_policy": 0, "is_dot": False,
        "dot_duration": 120., "dot_period": 1., "dot_bleed": False, "school": 0,
        "stamina": 100., "mana": 100., "stamina_regen": 0., "mana_regen": 0.,
        "kind_attack": True,
    }
    for key, value in overrides.items():
        actor[key][:] = value
    actor["resistance"][:] = 0.
    actor["ordinary_chances"][:] = 0.
    actor["raw_base_mean"][:] = 0.
    actor["raw_flat_magic"][:] = 0.
    actor["raw_mean"][:] = 0.
    return actor


def make_actors(pattern, proc, trials, rules, config):
    count = len(PROFILES)*trials
    source = actor_template(count, rules, config)
    target = actor_template(count, rules, config)
    profile_index = np.repeat(np.arange(len(PROFILES)), trials)
    for index, profile in enumerate(PROFILES):
        mask = profile_index == index
        for key in ("armor", "evasion", "block", "absorption"):
            target[key][mask] = profile.get(key, 0.)
        target["resistance"][mask, 1:] = profile.get("resistance", 0.)
    source["ordinary_chances"][:] = proc
    source["kind_attack"][:] = pattern["school"] in (0, -1)
    source["school"][:] = pattern["school"]
    if pattern.get("dot", False):
        source["is_dot"][:] = True
        source["duration"][:] = .1
        # One accepted application at 0.1s; first tick at 1.1s. The
        # duration is the DoT duration, not a 120-second casting clip.
        source["cooldown"][:] = config["horizon"]+1.
        source["dot_duration"][:] = config["horizon"]
        source["dot_bleed"][:] = pattern.get("bleed", False)
        source["raw_base_mean"][:, pattern["school"]] = 80.
    else:
        interval = pattern["interval"]
        source["duration"][:] = interval
        if pattern["school"] == -1:
            source["raw_base_mean"][:, 0] = 40.*interval
            source["raw_base_mean"][:, 1] = 40.*interval
        else:
            source["raw_base_mean"][:, pattern["school"]] = 80.*interval
    source["raw_mean"] = source["raw_base_mean"].copy()
    return source, target, profile_index


def job(spec):
    pattern_index, proc, trials, seed, rules, config = spec
    source, target, profile_index = make_actors(PATTERNS[pattern_index], proc, trials, rules, config)
    result = benchmark.simulate_direction(source, target, rules, config,
                                         np.random.SeedSequence([seed, pattern_index, proc, 331]))
    data = np.zeros(len(profile_index), dtype=RESULT_DTYPE)
    for name in benchmark.METRICS:
        data[name] = result[name]
    data["profile"], data["pattern"], data["ordinary_proc"] = profile_index, pattern_index, proc
    data["trial"] = np.tile(np.arange(trials), len(PROFILES))
    if np.any(data["restored"]) or np.any(data["potions_used"]) or np.any(data["passive_actions"]):
        raise AssertionError("Controlled passive/no-restoration contract failed")
    return data


def verify_isolation(data):
    def select(profile, pattern):
        return data[(data["profile"] == [p["id"] for p in PROFILES].index(profile))
                    & (data["pattern"] == [p["id"] for p in PATTERNS].index(pattern))
                    & (data["ordinary_proc"] == 0)]

    assertions = 0
    for profile in ("abs_1000", "abs_1500"):
        covered = select(profile, "fire_dot")
        if not len(covered) or np.any(covered["health_damage"] != 0) or np.any(np.isfinite(covered["ttk"])):
            raise AssertionError("Covered 80-DPS DoT exceeded adequate Absorption recovery")
        assertions += 1
        for pattern in ("bleed_dot", "necrotic_dot"):
            bypass = select(profile, pattern)
            if not np.allclose(bypass["ttk"], 13.1) or np.any(bypass["absorbed_damage"] != 0):
                raise AssertionError("Unmitigated bypass DoT must kill at 13.1s without touching Absorption")
            assertions += 1
    for pattern, expected in (("physical_fast", 12.3), ("physical_slow", 13.8),
                              ("fire_fast", 12.3), ("fire_slow", 13.8)):
        if not np.allclose(select("naked", pattern)["ttk"], expected):
            raise AssertionError("Unmitigated direct-Hit TTK differs from independent packet count")
        assertions += 1
    return assertions


def write_report(folder, data, manifest):
    rows = []
    for proc in (0, 20):
        for pattern_index, pattern in enumerate(PATTERNS):
            for profile_index, profile in enumerate(PROFILES):
                selected = data[(data["ordinary_proc"] == proc) & (data["pattern"] == pattern_index)
                                & (data["profile"] == profile_index)]
                rows.append({"ordinary_proc": proc, "pattern": pattern["id"], "profile": profile["id"],
                             **benchmark.summarize(selected)})
    study._write_csv(folder/"summaries.csv", rows)
    (folder/"summaries.json").write_text(json.dumps(rows, indent=2)+"\n", encoding="utf-8")
    lines = ["# Controlled defense interaction probe without Health restoration", "",
             f"Executed **{len(data):,} directed trials**: {len(PROFILES)} defensive profiles × "
             f"{len(PATTERNS)} incoming patterns × two ordinary-ailment probability settings × "
             f"{manifest['trials_per_case']:,} independent outcomes. These are controlled mechanical conditions, "
             "not funded builds, weapon/shield packages, or itemization recommendations.", "",
             "Every target has 1000 Health at level 60 and starts with its declared Absorption full. "
             "All sources deliver 80 raw DPS at 100% accuracy, zero Critical Chance, zero Armor Penetration, "
             "zero DoT Damage bonus, no resource cost, and a constant packet size. No Health restoration occurs. "
             "Direct attacks release at 60% of their 0.5s/3s action; the one-off 120s DoTs apply at 0.1s "
             "and tick once per second starting at 1.1s. Hybrid is 50% Physical / 50% Fire at 0.5s cadence.", "",
             "The all_caps profiles have 1000 Armor, 1000 Evasion, 90% Block and 80% of every school resistance. "
             "Other profiles have zero unlisted defenses. A 120-second horizon is right censoring: "
             "surviving it is not a claim of immortality. TTK quantiles are conditional on a kill. "
             "Mean Health/Absorption damage includes survivors and deaths.", ""]
    for proc in (0, 20):
        lines += [f"## Ordinary ailment probability {proc}%", "",
                  "Critical Chance stays zero. At 0%, the incoming direct packets cannot seed automatic ailments. "
                  "At 20%, Physical Hits can seed Bleed and Fire Hits can seed Burn; authored DoTs do not seed ailments.", "",
                  "| Pattern | Defense | Killed | Censored | Conditional TTK p10 / median / p90 (s) | Mean Health damage | Mean Absorption damage |",
                  "| --- | --- | ---: | ---: | --- | ---: | ---: |"]
        for row in rows:
            if row["ordinary_proc"] != proc:
                continue
            qs = " / ".join("—" if row["conditional_ttk_"+q] is None else f"{row['conditional_ttk_'+q]:.2f}"
                            for q in ("p10", "p50", "p90"))
            lines.append(f"| {row['pattern']} | {row['profile']} | {row['kill_fraction']:.1%} | "
                         f"{row['censored']:,} | {qs} | {row['health_damage_mean']:.2f} | {row['absorbed_damage_mean']:.2f} |")
    lines += ["", "## Interpretation boundary", "",
              "- Armor and resistance reduce the relevant bypass DoTs; bypass refers to Absorption, not mitigation.",
              "- Avoidance applies to direct Hits. It does not stop authored DoTs or already active automatic ailments.",
              "- A joint avoidance package can create recharge windows. A Physical Hit that eventually gets through can also seed a Bleed which bypasses that recharged pool.",
              "- Max Absorption adds both capacity and absolute recovery per second. A covered DoT can be fully sustained if its drain stays below recovery after the delay; Bleed/Necrotic can still remove Health.",
              "- Source.hits counts accepted deliveries, including initial authored DoT application. It is not a count of periodic ticks. Miss/Dodge/Block counters describe qualification outcomes, not amounts prevented.",
              "- The profiles deliberately assign several high defenses without any funding constraint. Their survival cannot establish that such combinations are attainable or fairly priced in the game.",
              f"- Source hashes unchanged: **{manifest['source_revision_unchanged']}**. "
              f"Health restored: **{manifest['health_restored']:g}**; consumables used: **{manifest['consumables_used']}**. "
              f"Independent packet/bypass/sustain checks passed: **{manifest['isolation_assertions']}**."]
    (folder/"report.md").write_text("\n".join(lines)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=HERE/"no_healing_results"/"defense_probe")
    parser.add_argument("--trials", type=int, default=1024)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20261106)
    args = parser.parse_args()
    if args.trials < 1 or args.workers < 1:
        raise ValueError("Positive trials/workers required")
    rules = sim.read_json(sim.DEFAULT_RULES)
    config = benchmark.default_config()
    config.update(horizon=120., dt=.1)
    config["weapon_roll_range"] = [1., 1.]
    benchmark.validate_config(config, rules)
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    paths = [Path(__file__), HERE/"no_healing_benchmark.py", HERE/"leveling_study.py", HERE/"simulator.py", sim.DEFAULT_RULES]
    paths += sorted((ROOT/"combat").rglob("*.gd"))
    contents = {str(path.relative_to(ROOT)): path.read_bytes() for path in paths}
    before = {name: hashlib.sha256(value).hexdigest() for name, value in contents.items()}
    for name, content in contents.items():
        destination = folder/"source_snapshot"/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
    experiment = {"profiles": PROFILES, "patterns": PATTERNS, "ordinary_proc": [0, 20],
                  "trials_per_case": args.trials, "seed": args.seed, "config": config}
    (folder/"experiment.json").write_text(json.dumps(experiment, indent=2)+"\n", encoding="utf-8")
    started = time.perf_counter()
    results = []
    specs = [(pattern, proc, args.trials, args.seed, rules, config)
             for pattern in range(len(PATTERNS)) for proc in (0, 20)]
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(job, spec) for spec in specs]
        for index, future in enumerate(as_completed(futures), 1):
            results.append(future.result())
            print(json.dumps({"cases_complete": index, "cases": len(specs),
                              "elapsed_seconds": round(time.perf_counter()-started, 1)}), flush=True)
    data = np.concatenate(results)
    data.sort(order=["ordinary_proc", "pattern", "profile", "trial"])
    assertions = verify_isolation(data)
    after = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    manifest = {"schema_version": 1, "command_line": sys.argv, "trajectories": len(data),
                "trials_per_case": args.trials, "profiles": len(PROFILES), "patterns": len(PATTERNS),
                "ordinary_proc": [0, 20], "dt": config["dt"], "horizon": config["horizon"],
                "health_restored": float(data["restored"].sum()), "consumables_used": int(data["potions_used"].sum()),
                "passive_actions": int(data["passive_actions"].sum()), "isolation_assertions": assertions,
                "source_sha256_before": before, "source_sha256_after": after,
                "source_revision_unchanged": before == after, "elapsed_seconds": time.perf_counter()-started}
    (folder/"manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    if before != after:
        raise RuntimeError("Sources changed during the controlled probe")
    np.savez_compressed(folder/"results.npz", results=data)
    write_report(folder, data, manifest)
    print(json.dumps({key: value for key, value in manifest.items() if not key.startswith("source_sha256")}, indent=2), flush=True)


if __name__ == "__main__":
    main()
