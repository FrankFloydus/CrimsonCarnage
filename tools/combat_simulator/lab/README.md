# Legacy Combat Lab

**Model status:** this tool runs the pre-2.0 combat model. Godot now implements the new [Combat 2.0 foundation](../../../docs/combat_system_2_0.md); its Physical Power, governing attributes and modifier calculation are not represented here. Current-game imports are rejected without changing the bundled snapshot.

Combat Lab is an offline Python/NumPy application with a Tkinter interface for
repeated time-to-kill experiments. Edit actors, abilities, and experimental
curves; select a matchup matrix; run a chosen number of independent trials per
cell; then inspect distributions and export the results.

Each encounter repeats **one offensive ability against one target that does not
attack back**. Deliveries are assumed to physically connect. Accuracy, passive
Dodge, Block, criticals, defenses, resource costs/regeneration, action timing,
automatic ailments, Absorption, and authored damage-over-time effects still apply. Passive Health regeneration and healing abilities are removed. These
are not AI duels, aiming tests, or movement simulations.

## Open the application

On Windows, double-click
[launch_combat_lab.cmd](../launch_combat_lab.cmd). From the project root, the
equivalent commands are:

```powershell
.\tools\combat_simulator\launch_combat_lab.cmd
```

or:

```powershell
python tools/combat_simulator/combat_lab.py
```

Python 3.10+, NumPy 2.x, and Tkinter are required. The launcher opens a local
desktop application; running it is a manual user action. Development validation
uses module imports, numerical tests, and headless Godot export without opening
the interface.

Install the Python dependency if needed:

```powershell
python -m pip install -r tools/combat_simulator/requirements.txt
```

The same experiment engine also runs without a desktop:

```powershell
python tools/combat_simulator/combat_lab.py --headless --trials 10000 --horizon 120 --output combat_lab_run.json
python tools/combat_simulator/combat_lab.py --headless my_experiment.json --workers 4 --output combat_lab_comparison.json
```

The first command uses frozen pre-2.0 defaults; the second loads an experiment
JSON saved by the interface. `--seed`, `--trials`, `--horizon`, and `--workers`
override the corresponding run settings. `--output` saves the run and its exact
input snapshot, rather than a reusable experiment alone.

## Game defaults and experiment copies

The lab reads [frozen pre-2.0 numeric rules](../legacy_combat_rules_v1.json)
and its bundled Godot catalogue of 41 legacy attributes, actors and abilities.
The bundled snapshot retains its original source and engine metadata. These
inputs stay independent of the live Godot rules.

Resolve is the canonical control-duration attribute at ID24. Mana/Stamina Cost Efficiency IDs28/29 are retired and excluded; the current engine pays authored resource costs. Cooldown Recovery remains independent.

**Import saved game actors** and the [headless bridge](export_game.gd)
currently reject the live schema-3 project before replacing any snapshot. A
simulator migration is required to import Combat 2.0. Ordinary startup uses the
bundled legacy snapshot and frozen rules, so it does not run Godot. Previously
saved legacy experiments and the five-enemy starter remain usable.

Player/enemy profiles, edited abilities, global rule values, and the shared
Attack/Spell accuracy curve belong to the current experiment. Saving a scenario writes
that experiment JSON. It does not apply changes to `combat/combat_rules.json`
or to Godot resources. The frozen model has one shared accuracy probability
array; the lab edits one shared curve without changing the
game implementation. Legacy files with different Attack/Spell curves must be reconciled before loading.

## Build an experiment

For a first comparison, use **Open** to load
[five_enemy_matrix.json](examples/five_enemy_matrix.json). It selects one Player,
Fireball, and five different enemy profiles: five cells at 10,000 trials each,
or 50,000 independent encounters. Review the inputs, then select **Run matrix**.
The ordinary new-experiment defaults select all three imported abilities instead.

1. Select or clone player and enemy profiles. Set their names and levels, then
   edit the attributes relevant to the comparison. Auto values retain derived
   progression and imported modifiers; Set replaces a base value. Effective
   values include the remaining modifiers and gameplay bounds. Current Health,
   Mana, Stamina, and Absorption are initial pools bounded by their capacities.
2. Select or clone an ability. Direct damage automatically attempts the corresponding school ailments, with critical Hits guaranteeing them; do not duplicate Burn/Bleed/Poison payloads when testing that behavior. Configure melee/spell delivery, base damage and
   Magic Power coefficients, damage type, critical eligibility, resource cost,
   cooldown, action duration/minimum, delivery point, and any fixed travel delay.
   Add Instant and Periodic damage effects as needed. Their application chance,
   duration, period, Refresh/Replace/Stack policy, and finite stack limit are
   editable data. Optional `base_damage_min`/`base_damage_max` fields and `weapon_attacks_per_second` model basic weapon damage/cadence in JSON experiments; they do not implement the current Godot weapon resources or Physical Power calculation.
3. Adjust the experiment's accuracy curves or numeric rules if desired. Equal
   level corresponds to curve entry zero; larger gaps use later entries, with
   the final entry covering gaps beyond the edited range. Attack and Spell delivery use the same Hit Rating and one shared experiment curve. These are session curves, not edits to
   the game file.
4. Choose participating player profiles, enemy profiles, and abilities. Optional
   player/enemy level lists expand the stored profiles into more matchups; blank
   level lists use the profiles' own levels. Up to two attribute sweep axes add
   further combinations.
5. Choose trials per cell, the encounter horizon, seed, and worker count. Check
   the expanded matrix size before starting. Progress and cancellation operate
   through bounded batches rather than blocking the interface for a whole run.
6. Compare completed result rows. **Save** or **Save as** retains the editable
   experiment JSON. **Export results CSV** writes result rows for external
   analysis. **Save run + results** preserves the original run inputs alongside
   its results, even if the editor has since changed.

**Open** also accepts a saved run JSON: it restores both the original input
snapshot and the result rows. Saving its editable experiment asks for a new
destination, keeping the run/results file separate. The headless command accepts
either an experiment or a saved run and uses its input snapshot for a new run.

Auto still includes imported Set Base modifiers: it does not discard a saved
fixed Health ceiling or extra primary allocations. Level lists change level
while retaining those other profile settings. Clear manual overrides and review
the saved modifiers/allocations when you want a neutral progression comparison.
The actor preview is unscoped; ability/effect tag-filtered bonuses can change
the values used during an actual trial.

For example, one player, five enemy profiles, and three selected abilities
produce 15 cells. At 10,000 trials per cell, that is 150,000 encounters. Adding
three player levels and two enemy levels produces 90 cells before attribute
sweeps. Two further sweeps with six and four values expand that to 2,160 cells.

The default experiment starts with the saved Player and granted abilities, then
provides five editable enemy profiles:

| Profile | Starting values |
| --- | --- |
| Saved dummy | The saved Godot dummy's actual profile and modifiers. |
| Neutral target | Player level; 300 Max Health. |
| Armored target | Player level +2; 500 Max Health and 300 Armor. |
| Elemental resistant target | Player level +4; 500 Max Health and 40% Fire, Cold, and Lightning Resistance. |
| Evasive/blocking target | Player level +5; 400 Max Health, 250 Evasion Rating, and 20% Block Chance. |

Generated target levels are clamped to level 60. Change their levels, Health,
Absorption, and other attributes to suit the comparison. These illustrative
profiles are not equally priced equipment builds, and they do not alter the saved
Godot actors. No item-affix prices or investment budgets are invented by the lab.

## Read the results

The Results tab provides filtering, sortable columns, and pages of 200 matchups.
Select a row to inspect its kill-time histogram, diagnostics, and analytic
reference values. CSV export includes every available result row, including rows
outside the current page or filter.

- **Kill rate** reports how often the target was defeated within the horizon.
  Read it before comparing the kill-time percentiles.
- **P10/P50/P90/P95 kill time** describe successful kills only. P50 is the median
  among kills; P90/P95 expose their slower tail. A low median on a rarely
  successful build does not establish reliable performance. No observed kills
  means these percentiles are unavailable, not zero.
- **Timeouts** count completed trials without a kill by the horizon. A
  **resource-starved** trial spent some time waiting for resources and can still
  kill. A **resource-depleted** trial failed after the action became permanently
  unaffordable within the remaining horizon. These resource diagnostics overlap
  the kill/timeout outcomes; they are not additional mutually exclusive results.
- **Restricted mean time** uses the horizon-capped result across all trials,
  including non-kills. It is distinct from mean kill time conditional on success.
- **Effective DPS** divides total actual damage by total encounter exposure:
  kill time for a killed target, or the horizon for a non-kill. Actual damage
  excludes overkill; damage to Absorption and Health is tracked as actual resource loss. Direct/periodic damage columns are mean actual totals per
  completed trial, rather than separate DPS estimates.
- **Hit/Miss/Resist/Dodge/Block rates** divide delivery outcomes by attempted
  deliveries. Critical rate divides critical damage events by all executed
  damage events, including periodic ticks. It does not estimate the chance that
  an attempted attack will both land and critically hit.

Cancellation retains completed work and marks the run incomplete. A partially
interrupted batch excludes unfinished encounters and can therefore favor its
fast kills. Use a completed run for fair population comparisons; do not treat a
cancelled row as the requested number of independent trials.

Keep the horizon and investment assumptions consistent when comparing rows.
Increase trials to reduce sampling noise, while retaining the seed and saved
scenario. A large sample does not validate every possible build or establish
fair itemization prices.

## Modeling boundaries

The model includes repeated use of the selected action, continuous resource
regeneration, cooldown and animation gates, one accuracy/Dodge/Block decision
per delivery, critical damage, Armor Penetration, typed resistance, Absorption recovery, automatic ailments, and retained DoT snapshots. Health regeneration/healing effects are unavailable. Refresh keeps magnitude and tick phase;
Replace resolves a new snapshot/schedule; ordinary Stack uses a finite limit; automatic Poison is uncapped and Burn/Bleed use one strongest global family. A due final
tick runs before expiration. Failed delivery applies no new dependent effects,
and existing ticks do not reroll accuracy.

The target never attacks. Player defensive stats therefore do not represent
survival value in this experiment, and target offensive stats have no attack to
modify. Aim, movement, projectile geometry, melee reach, enemy AI, active control
behavior, multiple-ability rotations, and external support are outside the model.
The saved-game bridge defaults projectile travel delay to zero and assumes melee
contact at the first authored trace-start event; use a fixed delay when that is
part of your experiment.
Clip lengths and animation event positions become a continuous ideal timing
schedule. It does not reproduce Godot physics-tick or input-poll quantization,
so exact rendered-frame delivery times can differ from the lab's clock.

Imports support the saved ProjectileCastExecution/MeleeTraceExecution damage
workflow. The bridge rejects unsupported execution scripts, healing effects,
modifier/control effects, and non-Health damage targets rather than silently
treating them as equivalent damage. Imported tags and scoped modifiers still
matter to supported applications. A successful import is not a claim that every
possible Godot execution script has been simulated.

Duplicate periodic effect IDs that share a retained group within one ability
are unsupported and rejected. Target-tag conditions that can depend on tags
granted by that ability's retained effects are also rejected, including
self-granted conditions that would change later refreshes. Static actor tags
and supported tag-filtered stat modifiers remain part of the experiment.

The supported spell/projectile profile uses the Cast Speed clock and
hierarchical `Ability.Spell` tags; the melee profile uses Attack Speed and its
encumbrance penalty. Mismatched execution scripts and spell/melee tags are
rejected by this model. Damage type remains independent: a Physical spell uses
shared Hit Rating and Armor, while a Fire melee action uses the same Hit Rating and Fire Resistance.

The app does not save live playground edits back into the game, author items,
or replace testing the selected content in the main Godot playground. Historical
reports in sibling result folders remain independent frozen experiments.

Save experiment/result artifacts outside the game's authored asset folders.
The normal save/export helpers reject those folders and the imported snapshot,
and require the matching `.json` or `.csv` extension.

## Development ownership

[AGENTS.md](AGENTS.md) records the scoped implementation rules. `model.py` owns
validation, actors, saved-game import, and matrix expansion; `engine.py` owns
repeated encounters and aggregation; `app.py` coordinates Tk and background
work; `widgets.py` and `editors.py` own the reusable interface parts. Experiment
work uses an immutable snapshot, and Tk widgets stay on the main thread.
`storage.py` owns experiment/result file validation and exports;
`export_game.gd` is the saved-content bridge.

Run the focused tests from the project root without opening Tk:

```powershell
python -m unittest discover -s tools/combat_simulator/lab -p "test_*.py" -v
```

The current suite includes independent encounter expectations, live game-attribute parity, removed-healing checks, automatic ailments/Absorption, resource clocks, matrix expansion, input validation, reproducibility, and saved-run restoration. The recorded per-task handoff gives the executed test count. Earlier 39-attribute/155-test counts and sub-second throughput diagnostics predate this revision and are not current performance evidence.

The [five-enemy starter](examples/five_enemy_matrix.json) has been regenerated from the current saved game catalogue. Current first-pass analysis measures outgoing and incoming TTK independently with no Health restoration. The earlier [leveling study](../leveling_results/report.md) included hypothetical consumable policies; its consumable/route assumptions do not support recommendations for the game. Separate benchmark tools do not turn this one-way lab into an AI duel simulator.

Module imports were reviewed with Tk construction blocked. No desktop interface
was launched; native UI appearance, window fit, and mouse interaction remain
unverified.
