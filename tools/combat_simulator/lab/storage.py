# Experiment and result files, independent of the desktop interface.
from __future__ import annotations

import csv
import json
from pathlib import Path

from . import model


def ensure_output_path(path, extension):
    target = Path(path).expanduser().resolve()
    if target.suffix.lower() != extension:
        raise ValueError(f"Choose a {extension} output file.")
    project = Path(__file__).resolve().parents[3]
    protected = [project / folder for folder in ("combat", "player", "levels", "examples", "materials")]
    if any(target == folder or folder in target.parents for folder in protected) \
            or target == Path(model.__file__).with_name("game_snapshot.json").resolve() \
            or target == model.RULES_PATH.resolve():
        raise ValueError("Choose an experiment/result destination, outside authored game assets, the imported snapshot and frozen rules.")
    return target


def load_experiment(path):
    with Path(path).open(encoding="utf-8-sig") as stream:
        document = json.load(stream)
    session = document.get("scenario_snapshot", document) if isinstance(document, dict) else document
    model.validate_session(session)
    return session


def save_experiment(path, session):
    model.validate_session(session)
    ensure_output_path(path, ".json").write_text(json.dumps(session, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def export_csv(path, rows):
    preferred = ["index", "player_name", "player_level", "enemy_name", "enemy_level", "ability_name", "variants",
                 "trials", "kills", "timeouts", "kill_rate", "ttk_mean", "ttk_p10", "ttk_median", "ttk_p90",
                 "ttk_p95", "ttk_max", "restricted_mean_time", "effective_dps", "mean_attempts", "hit_rate",
                 "miss_rate", "resist_rate", "dodge_rate", "block_rate", "crit_rate", "damage_direct",
                 "damage_periodic", "resource_wait_time", "elapsed_seconds"]
    fields = list(dict.fromkeys(preferred + [key for row in rows for key in row]))
    with ensure_output_path(path, ".csv").open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: json.dumps(value, allow_nan=False) if isinstance(value, (list, dict)) else value
                             for key, value in row.items()})
