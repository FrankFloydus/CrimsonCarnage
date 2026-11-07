#!/usr/bin/env python3
# Launch the desktop app, or run the same experiment without a desktop for automation.
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description="Legacy pre-2.0 combat attribute and time-to-kill matrix lab")
    parser.add_argument("--headless", nargs="?", const="default", metavar="EXPERIMENT.json",
                        help="Run a legacy experiment without opening the interface; omit path to use the frozen pre-2.0 defaults")
    parser.add_argument("--trials", type=int, help="Override independent trials per matchup")
    parser.add_argument("--horizon", type=float, help="Override maximum fight duration in seconds")
    parser.add_argument("--seed", type=int, help="Override repeatable random seed")
    parser.add_argument("--workers", type=int, help="Override parallel matchup workers")
    parser.add_argument("--output", type=Path, help="Save full run with input snapshot as JSON")
    args = parser.parse_args()
    try:
        if args.headless is not None:
            from tools.combat_simulator.lab import engine, model
            from tools.combat_simulator.lab.storage import ensure_output_path, load_experiment
            session = model.default_session() if args.headless == "default" else load_experiment(args.headless)
            print(model.LEGACY_NOTICE)
            for key in ("trials", "horizon", "seed", "workers"):
                value = getattr(args, key)
                if value is not None:
                    session["run"][key] = value
            model.validate_session(session)
            count = model.estimate_matrix_size(session)
            print(f"Running {count:,} matchups x {session['run']['trials']:,} trials.")
            def progress(event):
                if event.get("type") == "cell":
                    row = event["result"]
                    median = "no kills" if row.get("ttk_median") is None else f"median {row['ttk_median']:.3f}s"
                    print(f"{row['player_name']} L{row['player_level']} -> {row['enemy_name']} L{row['enemy_level']} / "
                          f"{row['ability_name']}: {row['kill_rate']:.1%} killed, {median}", flush=True)
            result = engine.run_matrix(session, progress=progress)
            print(f"{result['status']}: {result['completed_trials']:,} trials in {result['elapsed_seconds']:.3f}s.")
            if args.output:
                ensure_output_path(args.output, ".json").write_text(
                    json.dumps(result, indent=2, allow_nan=False) + "\n", encoding="utf-8")
            return 0
        from tools.combat_simulator.lab.app import main as launch
        launch()
        return 0
    except (ValueError, OSError, ImportError) as exc:
        print(f"Combat Lab: {exc}", file=sys.stderr)
        if isinstance(exc, ImportError):
            print("Install dependencies with: python -m pip install -r tools/combat_simulator/requirements.txt", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
