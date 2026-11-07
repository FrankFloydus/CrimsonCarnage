#!/usr/bin/env python3
"""Supplementary event-time resource audit; never changes gameplay or main-run inputs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")

import numpy as np

import pressure_sweep as sweep
import simulator as sim

HERE = Path(__file__).resolve().parent
PATTERNS = (
    "strength_physical_0.25s", "strength_physical_1s", "strength_physical_5s",
    "fire_spell_0.5s", "fire_spell_3s",
)
COST_SCALES = (0.5, 1.0, 2.0, 4.0)
MODELS = ("initial", "defense_cost_review")


def hashes(paths):
    return {
        str(path.relative_to(HERE.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in paths
    }


def distribution(values):
    return {
        "mean": float(np.mean(values)),
        "p10": float(np.quantile(values, 0.10)),
        "median": float(np.median(values)),
        "p90": float(np.quantile(values, 0.90)),
    }


def neutral_targets(n, level):
    targets = {
        "enemy_level": np.full(n, level),
        "health": np.full(n, 1e15),
        "armor": np.zeros(n),
        "penetration": np.zeros(n),
        "evasion_chance": np.zeros(n),
        "block_chance": np.zeros(n),
    }
    for kind in sweep.TYPES:
        targets[kind + "_resistance_fraction"] = np.zeros(n)
    return targets


def sustained_rate(speed, regen, pool, cost_per_second, interval, efficiency):
    """Actions per second in the infinite-time limit, excluding the initial reserve."""
    cost = sim.efficient_cost(cost_per_second * interval, efficiency)
    desired = speed / interval
    affordable = cost <= pool + 1e-9
    funded = np.minimum(desired, np.divide(
        regen, cost, out=np.full_like(regen, np.inf), where=cost > 0))
    return np.where(affordable, funded, 0), affordable, cost, desired


def validate_sustained_rate():
    speed, regen, pool = np.ones(3), np.full(3, 15.0), np.full(3, 100.0)
    interval = np.array([0.25, 1.0, 5.0])
    rate, affordable, _, _ = sustained_rate(speed, regen, pool, 12, interval, np.zeros(3))
    np.testing.assert_allclose(rate * interval, 1)
    assert np.all(affordable)
    rate, affordable, _, _ = sustained_rate(speed, regen, pool, 48, interval, np.zeros(3))
    np.testing.assert_allclose(rate[:2] * interval[:2], 15 / 48)
    assert affordable.tolist() == [True, True, False] and rate[2] == 0
    rate, _, _, _ = sustained_rate(speed, regen, pool, 48, interval, np.full(3, 100.0))
    np.testing.assert_allclose(rate[:2] * interval[:2], 15 / 24)


def audit_condition(builds, stats, pattern, scale, rng, rules, pressure, targets):
    pattern = {**pattern, "cost_per_second": pattern["cost_per_second"] * scale}
    outcome = sweep.simulate_outgoing(builds, stats, pattern, rng, rules, pressure, targets)
    resource = pattern["resource"]
    attack = resource == "stamina"
    speed = sim.action_speed_rate(
        pattern["interval"], pattern["minimum_action_duration"],
        stats["attack_speed_rating" if attack else "cast_speed_rating"], rules,
        encumbrance=stats["encumbrance_multiplier"] if attack else 1.0, attack=attack)
    regen, pool = stats[resource + "_regen"], stats[resource]
    efficiency = np.maximum(0, stats["cost_efficiency"])
    rate, affordable, cost, desired = sustained_rate(
        speed, regen, pool, pattern["cost_per_second"], pattern["interval"], efficiency)
    normalized = rate * pattern["interval"]
    fulfillment = rate / desired
    duration = pressure["duration"]
    ideal_actions = np.floor(duration * desired + 1e-8).astype(np.int32)
    waited = outcome["resource_waits"] > 0
    restricted = waited | ~affordable
    asymptotically_limited = fulfillment < 1 - 1e-9
    expected_hit = sweep._outgoing_magnitude(builds, stats, pattern, rules, targets) * (
        1 + stats["critical_chance_fraction"] * (stats["critical_multiplier_value"] - 1))
    expected_hit *= sim.delivery_chance(builds["level"], targets["enemy_level"], stats,
                                       pattern.get("accuracy_kind", "attack"), rules)
    base_regen = rules[resource + "_regen_base"] + rules[resource + "_regen_per_level"] * (
        builds["level"] - 1)
    baseline_regen = np.full_like(regen, base_regen)
    no_regen, _, _, _ = sustained_rate(
        speed, baseline_regen, pool, pattern["cost_per_second"], pattern["interval"], efficiency)
    no_efficiency, _, _, _ = sustained_rate(
        speed, regen, pool, pattern["cost_per_second"], pattern["interval"], np.zeros_like(efficiency))
    capacity_affix = builds["stats"][:, builds["keys"].index(resource)]
    no_capacity, affordable_without_capacity, _, _ = sustained_rate(
        speed, regen, pool - capacity_affix, pattern["cost_per_second"],
        pattern["interval"], efficiency)
    if not np.all(np.isfinite(outcome["potential_damage"])):
        raise ValueError("Non-finite event output")
    if np.any(outcome["actions"] > ideal_actions):
        raise ValueError("Resource-funded actions exceeded the no-cost cadence")
    if np.any(np.isfinite(outcome["kill_time"])):
        raise ValueError("Training target Health was insufficient")
    if not np.all(outcome["hits"] == outcome["actions"]):
        raise ValueError("Neutral-target hit gating changed output")
    row = {
        "pattern": pattern["id"], "resource": resource,
        "base_interval_seconds": pattern["interval"], "cost_scale": scale,
        "base_cost_per_second": pattern["cost_per_second"], "trials": len(pool),
        "event_duration_seconds": duration,
        "actual_actions_per_second": distribution(outcome["actions"] / duration),
        "desired_actions_per_second": distribution(desired),
        "normalized_observed_rate": distribution(
            outcome["actions"] * pattern["interval"] / duration),
        "normalized_sustained_rate": distribution(normalized),
        "sustained_rate_fulfillment": distribution(fulfillment),
        "observed_action_fulfillment": distribution(
            outcome["actions"] / np.maximum(ideal_actions, 1)),
        "observed_damage_per_second": distribution(outcome["potential_damage"] / duration),
        "expected_sustained_damage_per_second": distribution(expected_hit * rate),
        "resource_pool": distribution(pool), "resource_regeneration_per_second": distribution(regen),
        "cost_per_action": distribution(cost), "cost_efficiency": distribution(efficiency),
        "starved_during_window": int(np.count_nonzero(waited)),
        "action_cost_exceeds_entire_pool": int(np.count_nonzero(~affordable)),
        "resource_restricted_during_window": int(np.count_nonzero(restricted)),
        "sustained_rate_below_desired": int(np.count_nonzero(asymptotically_limited)),
        "initial_reserve_hides_long_run_limit": int(np.count_nonzero(
            asymptotically_limited & (outcome["actions"] == ideal_actions))),
        "mean_starvation_retries": float(np.mean(outcome["resource_waits"])),
        "analytic_resource_affix_marginals_not_funded_alternatives": {
            "normalized_sustained_gain_from_regeneration_affix": float(np.mean(
                np.maximum(0, rate - no_regen) * pattern["interval"])),
            "normalized_sustained_gain_from_cost_efficiency": float(np.mean(
                np.maximum(0, rate - no_efficiency) * pattern["interval"])),
            "normalized_sustained_gain_from_capacity_affix": float(np.mean(
                np.maximum(0, rate - no_capacity) * pattern["interval"])),
            "capacity_affix_makes_action_affordable": int(np.count_nonzero(
                affordable & ~affordable_without_capacity)),
        },
    }
    return row, normalized, affordable


def make_report(report):
    lines = [
        "# Supplementary continuous-regeneration resource audit", "",
        "This isolates resource pressure using synthetic normalized attacks. Gameplay rules, "
        "authored examples, and the main pressure-run inputs were not retuned.", "",
        f"- Funded build rows: **{report['funded_build_draws']:,}** across "
        f"{len(report['contexts'])} contexts.",
        f"- Paired funding identities: **{report['paired_funding_identities']:,}**, each repriced "
        "under both price models. These are not all independent observations.",
        f"- Executed outgoing trajectories: **{report['outgoing_trajectories']:,}**. "
        "Analytic steady-state comparisons and counterfactuals add no trajectories.",
        f"- Each event trajectory lasts {report['duration_seconds']:g} seconds against a "
        "same-level training target with zero defenses, dodge, and block.",
        "- The five cadences reuse the same funded builds at four cost scales. "
        "Pricing-model seed pairs are identical.", "",
        "## Interpretation", "",
        "Cheap basic attacks are allowed to be sustainable. The baseline physical control "
        "costs 12 Stamina per second at zero rating and before efficiency. Its authored "
        "minimum duration determines how much Speed Rating can raise that demand. "
        "A sustainable zero-rating attack can become resource-limited at higher rating.", "",
        "The cost scales are 0.5, 1, 2, and 4: physical demand is 6/12/24/48 Stamina per "
        "base-cadence second; spell demand is 10/20/40/80 Mana. They are synthetic pressure "
        "controls, not changes to the sample melee or fireball costs.", "",
        "Steady-state rate is the lesser of the speed-limited action rate and regeneration "
        "divided by action cost. It is zero if one action costs more than the entire resource "
        "pool. Normalized rate multiplies actions per second by the base interval, making "
        "fast and slow normalized patterns comparable. This excludes the starting reserve "
        "and the finite first-action/final-packet window effects.", "",
        "Observed DPS includes the actual 30-second event schedule and random criticals. "
        "Expected sustained DPS is an analytic long-run expectation, not another executed "
        "trajectory. A full reserve can conceal eventual starvation during the short window.", "",
        "Resource-affix marginals remove one already-funded resource bonus without refunding "
        "or reallocating its budget. They are sensitivity measurements, not equally funded "
        "alternative builds. Flat capacity changes burst reserves and can make an expensive "
        "single action affordable; once affordable, it does not create long-run resource income.", "",
        "## Cross-cadence check", "",
        f"Across {report['cadence_checks']:,} common-affordability comparisons, the maximum "
        f"normalized steady-state rate difference was "
        f"**{report['maximum_common_affordability_rate_difference']:.3g}**. "
        "Remaining cadence differences concern per-action affordability or finite windows, "
        "not a hidden recovery delay.", "",
        "## Results by context", "",
        "Rates in parentheses are normalized sustained rates; 1.00 is the base cadence, "
        "while Speed Rating raises it toward each action's authored duration limit. "
        "Synthetic cadence comparisons use proportional minimum durations. "
        "Starvation and unaffordability are separate.",
    ]
    for context in report["contexts"]:
        identity = context["identity"]
        lines += ["", f"### Level {identity['level']}, gear budget {identity['gear_budget']}, "
                  f"talent budget {identity['talent_budget']}, {identity['price_model']}", "",
                  "| Resource / base interval | Cost scale | Actions/s (steady normalized) | "
                  "Waited in window | Cannot afford one action | Below desired sustained rate | "
                  "Observed / expected sustained DPS |",
                  "|---|---:|---:|---:|---:|---:|---:|"]
        for row in context["results"]:
            n = row["trials"]
            lines.append(
                f"| {row['resource']} / {row['base_interval_seconds']:g}s | "
                f"{row['cost_scale']:g} | {row['actual_actions_per_second']['mean']:.3f} "
                f"({row['normalized_sustained_rate']['mean']:.3f}) | "
                f"{100 * row['starved_during_window'] / n:.1f}% | "
                f"{100 * row['action_cost_exceeds_entire_pool'] / n:.1f}% | "
                f"{100 * row['sustained_rate_below_desired'] / n:.1f}% | "
                f"{row['observed_damage_per_second']['mean']:.2f} / "
                f"{row['expected_sustained_damage_per_second']['mean']:.2f} |")
    lines += ["", "## Reproduction and limitations", "",
              "Run `python tools/combat_simulator/pressure_resource_audit.py`. The JSON records "
              "the seed, sample count, pattern definitions, and SHA-256 hashes. Source hashes "
              "are checked again after the run. The audit does not simulate incoming pressure, "
              "movement AI, interruptions, or actual Godot animation/collision. Random funded "
              "builds are not an optimized or exhaustive search and do not establish final balance.", ""]
    return "\n".join(lines)


def run(args):
    started = time.perf_counter()
    validate_sustained_rate()
    source_paths = [Path(__file__), HERE / "pressure_sweep.py", HERE / "simulator.py",
                    HERE / "pressure_scenarios.json", HERE / "scenarios.json", sim.DEFAULT_RULES]
    before = hashes(source_paths)
    rules = sim.read_json(sim.DEFAULT_RULES)
    sim.require_legacy_report_schema(rules)
    pressure = sim.read_json(HERE / "pressure_scenarios.json")
    sweep.validate_pressure_config(pressure)
    config = sweep.extended_config(sim.read_json(HERE / "scenarios.json"), pressure)
    selected = {pattern["id"]: pattern for pattern in pressure["outgoing_patterns"]}
    patterns = [selected[name] for name in PATTERNS]
    n, contexts, max_difference, cadence_checks = args.builds_per_context, [], 0.0, 0
    for level in (1, 30, 60):
        for gear in (20, 60, 100):
            talents = 10 if gear == 20 else 20
            paired = None
            for model in MODELS:
                sampler = np.random.default_rng(np.random.SeedSequence(
                    [args.seed, level, gear, talents, 8101]))
                builds = sweep.sample_builds(n, sampler, gear, model, rules, config, level, talents)
                funding_identity = np.column_stack((builds["primary"], builds["talents"],
                    builds["archetype"], builds["shield"], builds["choices"], builds["affix_funding"]))
                if paired is None:
                    paired = funding_identity.copy()
                else:
                    np.testing.assert_array_equal(paired, funding_identity)
                stats, targets = sweep.derive_stats(builds, rules, config), neutral_targets(n, level)
                rows, normalized_groups = [], {}
                for pattern_index, pattern in enumerate(patterns):
                    for scale_index, scale in enumerate(COST_SCALES):
                        rng = np.random.default_rng(np.random.SeedSequence(
                            [args.seed, level, gear, talents, pattern_index, scale_index, 8102]))
                        row, normalized, affordable = audit_condition(
                            builds, stats, pattern, scale, rng, rules, pressure, targets)
                        rows.append(row)
                        normalized_groups.setdefault((pattern["resource"], scale), []).append(
                            (normalized, affordable))
                for group in normalized_groups.values():
                    common = np.logical_and.reduce([item[1] for item in group])
                    values = np.stack([item[0][common] for item in group])
                    if values.shape[1]:
                        difference = float(np.max(np.ptp(values, axis=0)))
                        max_difference = max(max_difference, difference)
                        cadence_checks += int(values.shape[1])
                        if difference > 1e-10:
                            raise ValueError("Normalized sustained rate depends on packet cadence")
                contexts.append({"identity": {
                    "level": level, "gear_budget": gear, "talent_budget": talents,
                    "price_model": model, "seed": args.seed}, "funded_build_draws": n,
                    "outgoing_trajectories": n * len(patterns) * len(COST_SCALES), "results": rows})
                print(f"Resource audit: {len(contexts)}/18 contexts; "
                      f"{len(contexts) * n * 20:,} trajectories; "
                      f"{time.perf_counter() - started:.1f}s", flush=True)
    after = hashes(source_paths)
    if before != after:
        raise RuntimeError("An input changed during the supplementary resource audit")
    report = {
        "schema_version": 1, "seed": args.seed, "builds_per_context": n,
        "funded_build_draws": n * len(contexts), "paired_funding_identities": n * len(contexts) // 2,
        "outgoing_trajectories": n * len(contexts) * len(patterns) * len(COST_SCALES),
        "duration_seconds": pressure["duration"], "elapsed_seconds": time.perf_counter() - started,
        "cadence_checks": cadence_checks,
        "maximum_common_affordability_rate_difference": max_difference,
        "analytic_comparisons_are_not_additional_trajectories": True,
        "input_sha256": before, "patterns": patterns, "cost_scales": COST_SCALES,
        "contexts": contexts,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "resource_audit.json").write_text(
        json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    (args.output / "resource_audit.md").write_text(make_report(report), encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builds-per-context", type=int, default=10000)
    parser.add_argument("--seed", type=int, default=104729)
    parser.add_argument("--output", type=Path, default=HERE / "pressure_results")
    args = parser.parse_args()
    if args.builds_per_context < 1:
        parser.error("--builds-per-context must be positive")
    result = run(args)
    print(f"Completed {result['funded_build_draws']:,} funded build rows and "
          f"{result['outgoing_trajectories']:,} event trajectories.")


if __name__ == "__main__":
    main()
