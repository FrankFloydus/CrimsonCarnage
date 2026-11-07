#!/usr/bin/env python3
"""Deterministic cooldown/execution gate probe for the Dexterity proposal.

This is a resource-free throughput calculation, not Monte Carlo combat or an
itemization rule. Cooldowns start at activation, so the repetition interval is
the larger of execution duration and recovered cooldown.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import simulator as sim

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def default_config():
    return {
        "levels": [1, 10, 30, 60],
        "primary_power_fractions": [.8, .5, .2],
        "other_hit_ratings": [0., 50.],
        "base_duration": 1., "minimum_duration": .4,
        "base_cooldowns": [0., 1., 2., 4.],
        "secondary_budget": 75., "credit_step": 5.,
        "power_per_credit": 1., "speed_per_credit": 2.,
        "cooldown_recovery_per_credit": [2., 5.],
        "base_damage": 100., "dexterity_speed_per_point": 1.,
        "dexterity_hit_per_point": 1.,
    }


def allocations(budget, step):
    """Yield every exact three-way allocation on the declared credit grid."""
    if not math.isfinite(budget) or budget < 0 or not math.isfinite(step) or step <= 0:
        raise ValueError("Budget and grid step require finite nonnegative/positive values")
    count = round(budget/step)
    if not math.isclose(count*step, budget, abs_tol=1e-9):
        raise ValueError("Budget must be divisible by the allocation grid")
    for power in range(count+1):
        for speed in range(count-power+1):
            yield power*step, speed*step, (count-power-speed)*step


def evaluate(primary_power, primary_dexterity, spending, base_cooldown,
             recovery_per_credit, other_hit, level, config, rules):
    power_credits, speed_credits, recovery_credits = spending
    speed_rating = (primary_dexterity*config["dexterity_speed_per_point"]
                    + speed_credits*config["speed_per_credit"])
    duration = float(sim.rating_duration(config["base_duration"],
                                        config["minimum_duration"], speed_rating, rules))
    cooldown = float(sim.efficient_cost(base_cooldown, recovery_credits*recovery_per_credit))
    cycle = max(duration, cooldown)
    hit = float(sim.hit_chance(level, level,
                              other_hit+primary_dexterity*config["dexterity_hit_per_point"], rules))
    power = primary_power+power_credits*config["power_per_credit"]
    # Strength uses its shared physical multiplier. A calibrated INT spell with
    # coefficient/base-packet = 0.01 has the same mean source contribution;
    # that equality is an experimental fixture, not a new Magic Power rule.
    magnitude = config["base_damage"]*float(sim.strength_physical_multiplier(
        rules["base_primary"]+power, rules))
    return {
        "power_credits": power_credits, "speed_credits": speed_credits,
        "cooldown_credits": recovery_credits, "total_power_points": power,
        "speed_rating": speed_rating, "execution_duration": duration,
        "recovered_cooldown": cooldown, "cycle": cycle, "hit_chance": hit,
        "expected_direct_dps": magnitude*hit/cycle,
        "gate": "balanced" if math.isclose(duration, cooldown, abs_tol=1e-9)
                else "cooldown" if cooldown > duration else "execution",
    }


def run(config, rules):
    grid = list(allocations(config["secondary_budget"], config["credit_step"]))
    results = []
    for level in config["levels"]:
        if not isinstance(level, int) or not 1 <= level <= rules["max_level"]:
            raise ValueError("Levels must be valid game levels")
        primary_budget = int(rules["creation_points"]+rules["points_per_level"]*(level-1))
        for fraction in config["primary_power_fractions"]:
            primary_power = int(math.floor(primary_budget*fraction+.5))
            primary_dexterity = primary_budget-primary_power
            for other_hit in config["other_hit_ratings"]:
                for recovery_per_credit in config["cooldown_recovery_per_credit"]:
                    for base_cooldown in config["base_cooldowns"]:
                        rows = [evaluate(primary_power, primary_dexterity, allocation,
                                         base_cooldown, recovery_per_credit, other_hit,
                                         level, config, rules) for allocation in grid]
                        best = max(rows, key=lambda row: row["expected_direct_dps"])
                        no_recovery = max((row for row in rows if row["cooldown_credits"] == 0),
                                          key=lambda row: row["expected_direct_dps"])
                        no_speed = max((row for row in rows if row["speed_credits"] == 0),
                                       key=lambda row: row["expected_direct_dps"])
                        results.append({
                            "level": level, "primary_budget": primary_budget,
                            "primary_power": primary_power, "primary_dexterity": primary_dexterity,
                            "primary_power_fraction": fraction, "other_hit_rating": other_hit,
                            "cooldown_recovery_per_credit": recovery_per_credit,
                            "base_cooldown": base_cooldown, "best_grid_allocation": best,
                            "best_without_cooldown_recovery": no_recovery,
                            "best_without_purchased_speed": no_speed,
                            "gain_over_no_recovery": best["expected_direct_dps"]/no_recovery["expected_direct_dps"]-1,
                            "gain_over_no_purchased_speed": best["expected_direct_dps"]/no_speed["expected_direct_dps"]-1,
                        })
    return results, len(grid)*len(results)


def write_report(folder, config, results, manifest, rules):
    lines = ["# Cooldown Recovery and execution-speed probe", "",
             f"Evaluated **{manifest['allocation_evaluations']:,} deterministic allocations** across "
             f"**{manifest['contexts']:,} contexts**. These are analytic evaluations, not Monte Carlo trials.", "",
             "This isolates the direct-damage throughput gate. There are no ailments, resource costs, Health recovery, "
             "enemy retaliation or defensive effects. The proposed Dexterity contributes Hit and execution-speed rating. "
             "Power means Strength, or Intellect with a deliberately calibrated coefficient giving the same mean source damage. "
             "The experiment does not change gameplay or approve item values.", "",
             "Cooldown starts at activation, as in the game. Thus `cycle = max(execution duration, recovered cooldown)`. "
             "Execution uses the existing diminishing duration curve; Cooldown Recovery uses its existing reciprocal. "
             "Shorter execution can reduce commitment even when it cannot increase repetition frequency; that tactical benefit is not scored here.", "",
             "The action has base duration 1 s, minimum duration 0.4 s and a 100-damage source packet before Power. "
             "Each level's primary budget is allocated 80/20, 50/50 or 20/80 Power/Dexterity. A separate conserved "
             "75-credit secondary budget buys Power, focused Speed (2 rating/credit), or Cooldown Recovery "
             "(2 or 5 per credit), on a five-credit grid. Other Hit is zero or fifty within each matched condition.", "",
             "## Level-60 Power-heavy reference", "",
             "Primary investment is 102 Power / 26 Dexterity. Optima are the best points on the declared coarse grid.", "",
             "| Other Hit | Base cooldown | Recovery / credit | Power / Speed / CDR credits | Execution | Recovered CD | DPS | Gain over best without CDR |",
             "|---:|---:|---:|---|---:|---:|---:|---:|"]
    for row in results:
        if row["level"] != 60 or row["primary_power_fraction"] != .8:
            continue
        best = row["best_grid_allocation"]
        credits = " / ".join(f"{best[key]:g}" for key in ("power_credits", "speed_credits", "cooldown_credits"))
        lines.append(f"| {row['other_hit_rating']:g} | {row['base_cooldown']:g} s | "
                     f"{row['cooldown_recovery_per_credit']:g} | {credits} | "
                     f"{best['execution_duration']:.3f} s | {best['recovered_cooldown']:.3f} s | "
                     f"{best['expected_direct_dps']:.1f} | {row['gain_over_no_recovery']:.1%} |")
    lines += ["", "## Fixed-rating gate example", "",
              "This separate illustration holds damage and accuracy fixed; it does not spend the 75-credit budget. "
              "Base cooldown is 2 seconds. Dexterity supplies either zero or fifty Speed Rating.", "",
              "| Cooldown Recovery | Execution with 0 / 50 DEX rating | Repeat interval with 0 / 50 DEX rating |",
              "|---:|---|---|"]
    for recovery in (0., 100., 200.):
        cooldown = float(sim.efficient_cost(2., recovery))
        durations = [float(sim.rating_duration(1., .4, rating, rules))
                     for rating in (0., 50.)]
        cycles = [max(duration, cooldown) for duration in durations]
        lines.append(f"| {recovery:g} | {durations[0]:.2f} / {durations[1]:.2f} s | "
                     f"{cycles[0]:.2f} / {cycles[1]:.2f} s |")
    lines += ["", "## Meaning", "",
              "- Speed rating cannot increase repetition frequency while recovered cooldown is the larger gate. "
              "CDR can therefore be more valuable than additional Speed on that action.",
              "- Once CDR lowers cooldown below execution duration, further CDR has no throughput benefit "
              "for repeating this one action. Power and Speed can then be preferable investments.",
              "- CDR does not multiply the Speed result. It removes a separate gate; the larger interval still wins.",
              "- The optimum can require both stats. That is complementary investment, not applying speed twice.",
              "- This probe does not certify CDR prices, cooldown-gated ailment builds, multi-ability rotations, "
              "resource-limited output or short-fight TTK. Its rates are steady-state expectations.",
              f"- Sources unchanged during execution: **{manifest['source_revision_unchanged']}**."]
    (folder/"cooldown_probe.md").write_text("\n".join(lines)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=HERE/"offense_results")
    args = parser.parse_args()
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    config = default_config()
    rules = sim.read_json(sim.DEFAULT_RULES)
    paths = [Path(__file__), HERE/"simulator.py", sim.DEFAULT_RULES]
    before = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    results, count = run(config, rules)
    after = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    manifest = {"command": sys.argv, "contexts": len(results), "allocation_evaluations": count,
                "source_sha256_before": before, "source_sha256_after": after,
                "source_revision_unchanged": before == after}
    if before != after:
        raise RuntimeError("Source changed during calculation")
    (folder/"cooldown_probe.json").write_text(json.dumps({"config": config, "results": results}, indent=2)+"\n", encoding="utf-8")
    (folder/"cooldown_probe_manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    write_report(folder, config, results, manifest, rules)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
