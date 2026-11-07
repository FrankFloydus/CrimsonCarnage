#!/usr/bin/env python3
"""Summarize the sampled offensive frontier without changing run evidence."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent


def nondominated(scores):
    """Larger is better in every objective; equal vectors share the frontier."""
    scores = np.asarray(scores, float)
    result = np.ones(len(scores), bool)
    for index, score in enumerate(scores):
        dominates = np.all(scores >= score-1e-9, axis=1) & np.any(scores > score+1e-9, axis=1)
        if dominates.any():
            result[index] = False
    return result


def analyze(rows):
    by_case = defaultdict(list)
    for row in rows:
        by_case[row["case_id"]].append(row)
    groups = defaultdict(list)
    for case_id, targets in by_case.items():
        first = targets[0]
        if first["experiment"] != "main":
            continue
        key = tuple(first[name] for name in ("level", "style", "secondary_budget", "price", "cost_policy", "other_hit", "magic_scale"))
        targets.sort(key=lambda row: (float(row["mitigation_case"]), float(row["absorption"])))
        score = []
        for row in targets:
            score += [float(row["dps_5s"]), float(row["dps_120s"])]
            score += [-float(row["restricted_mean_hp"+threshold]) for threshold in ("500", "2000", "10000")]
        groups[key].append((first, score))
    frontiers, summaries = [], []
    for key, group in groups.items():
        keep = nondominated([score for _, score in group])
        row = dict(zip(("level", "style", "secondary_budget", "price", "cost_policy", "other_hit", "magic_scale"), key))
        row["candidates"] = len(group)
        row["sampled_frontier"] = int(keep.sum())
        for strategy in ("hit_focused", "dot_focused", "mixed"):
            row[strategy+"_frontier"] = sum(bool(flag) and candidate["strategy"] == strategy for (candidate, _), flag in zip(group, keep))
        summaries.append(row)
        for (candidate, _), flag in zip(group, keep):
            if flag:
                frontiers.append({**row, "case_id": candidate["case_id"], "strategy": candidate["strategy"],
                                  "candidate": candidate["candidate"], "primary_power": candidate["primary_power"],
                                  "primary_dex": candidate["primary_dex"]})
    return summaries, frontiers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", type=Path, default=HERE/"offense_results")
    args = parser.parse_args()
    folder = args.folder.resolve()
    source = folder/"summaries.csv"
    with source.open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    summaries, frontiers = analyze(rows)
    (folder/"frontier_summary.json").write_text(json.dumps(summaries, indent=2)+"\n", encoding="utf-8")
    with (folder/"sampled_frontier.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(frontiers[0]))
        writer.writeheader(); writer.writerows(frontiers)
    manifest = {"groups": len(summaries), "sampled_frontier_entries": len(frontiers),
                "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "objectives": "For every target: maximize 5s/120s DPS and minimize horizon-restricted mean observation at HP500/2000/10000",
                "limits": "Sampled numerical frontier, not exhaustive optimum; stochastic near ties can affect membership; capped observation is not true unobserved TTK."}
    (folder/"frontier_manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
