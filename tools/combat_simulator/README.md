# Combat simulation tools

**These tools retain the pre-2.0 combat model.** Godot now uses the new [Combat 2.0 foundation](../../docs/combat_system_2_0.md), which this Python engine does not yet simulate. Existing tools use [frozen legacy rules](legacy_combat_rules_v1.json) and the bundled schema-2 catalogue/profiles. Current-game imports and schema-3 experiments are rejected before snapshots are changed. Results from these tools do not validate the new Physical Power, governing attributes or modifier calculation.

The frozen model uses Resolve at ID24 with 0..40% control-duration reduction, retires Mana/Stamina Cost Efficiency IDs28/29, pays authored nonnegative resource costs and has 41 active attributes. Historical snapshots keep their original catalogue and numeric rule names.

## Legacy commands

The [Combat Lab](lab/README.md) is a Python/NumPy repeated one-ability experiment against a non-attacking target. It has a manually opened Tk interface and a headless CLI:

```powershell
python tools/combat_simulator/combat_lab.py --headless --trials 10000 --horizon 120 --output combat_lab_run.json
python -m unittest discover -s tools/combat_simulator/lab -p "test_*.py" -v
python -m unittest discover -s tools/combat_simulator -p "test_*.py" -v
```

The [five-enemy starter](lab/examples/five_enemy_matrix.json) selects one saved Player and Fireball across five editable targets. Experiments use the bundled pre-2.0 actors, not current Godot actors or F3 overrides. Editing experiment rules never writes game assets.

The pre-2.0 first-pass analysis measures outgoing TTK and enemy TTK independently with no Health restoration. Only the attacking side acts in each direction; an early kill cannot hide the other direction's result. Stamina/Mana regeneration and Absorption recovery remain active. Report kill rates, conditional TTK percentiles and censored trials separately. A horizon-restricted mean is a capped observation metric, never a claim about unobserved true TTK.

The [directed benchmark](no_healing_benchmark.py) writes its editable experiment, source snapshot, per-trajectory data, summaries and [report](no_healing_results/report.md). It reads existing rules and never changes game assets:

```powershell
python tools/combat_simulator/no_healing_benchmark.py --builds 1024 --repeats 2 --workers 8
python tools/combat_simulator/no_healing_benchmark.py --config tools/combat_simulator/no_healing_results/experiment.json --output my_ttk_experiment
```

The same sampled player and enemy are tested independently in both directions with fresh pools. Incoming TTK measures passive defenses: the player does not attack, so an offensive Chill cannot slow the enemy in that measurement. Funding labels refer to experimental stat budgets, not implemented gear. A timeout means the target survived the stated horizon, not that it is immortal.

Read the [previous-model findings](no_healing_results/findings.md), [formula derivations](no_healing_results/formula_review.md), and [controlled defense checks](no_healing_results/defense_probe/findings.md) before interpreting a numerical outlier. The focused [defense probe](no_healing_defense_probe.py) isolates recharge, avoidance and bypass without claiming those deliberately capped combinations are funded builds.

The earlier [leveling study](leveling_results/report.md), implemented in [leveling_study.py](leveling_study.py), recorded broad levels 1..60 experiments mixing no-recovery duels with hypothetical consumable policies. Its weapon/stat/enemy values are experimental inputs. Consumables are not implemented, and its potion, refill and enemy-pressure recommendations are withdrawn. Its data and source manifests are preserved for audit, rather than used to prescribe content.

The exploratory [attrition companion](leveling_attrition.py) tests hypothetical finite-consumable routes. Its [report](leveling_results/attrition_report.md) and [withdrawn recommendations](leveling_results/attrition_findings.md) are not the current first-pass balance analysis:

```powershell
python tools/combat_simulator/leveling_attrition.py --builds 4096 --workers 4
```

## Dexterity proposal comparison

The [allocation analysis](dexterity_analysis.py) exhaustively compares integer Strength/Dexterity and Intellect/Dexterity allocations using the shared accuracy and speed formulas. The [event-based study](dexterity_study.py) adds finite Stamina/Mana, continuous regeneration, exact release/tick clocks, and automatic Bleed/Burn/Poison. Read the [analytic report](dexterity_results/analytic_report.md) and [simulation report](dexterity_results/report.md) together.

These are offline **proposal** experiments: Dexterity grants +1 Hit Rating and +1 relevant Attack/Cast Speed Rating per point above ten, with no Evasion. They do not change the live game's Dexterity, passive Dodge, or Block. Active shield guard and Block Power consumption/recovery remain undecided and are not simulated.

```powershell
python tools/combat_simulator/dexterity_analysis.py
python tools/combat_simulator/dexterity_study.py --workers 8
```

Both save editable JSON configurations and source hashes under `dexterity_results/`. The simulation measures damage over fixed windows using a damage-event ledger; a separate finite Health threshold records TTK without truncating sustained output or requiring an inflated Health pool. Its 100-DPS reference and Magic Power coefficient sensitivities isolate stat relationships rather than establish weapon or spell content. Other Hit/Speed bonuses are identical across allocations within a context; their acquisition costs are not compared between contexts.

## Hit and DoT investment comparison

The [offensive study](offense_study.py) compares Hit-focused, DoT-focused and mixed investment under separately conserved primary-point and secondary-stat budgets. Every strategy retains both direct damage and its automatic ailments. The same candidate faces several Armor/resistance and Absorption conditions, multiple finite Health thresholds, resource-cost variants and source-availability windows. It also records the correct additive Dexterity/other-speed arithmetic and compound-versus-focused stat-package comparisons.

```powershell
python tools/combat_simulator/offense_study.py --workers 8
```

Read the [report](offense_results/report.md) with its editable configuration and provenance. Secondary conversions, including half/double DoT values, are experimental price hypotheses. Best-sampled candidates are not globally optimized builds. Equal base Hit DPS does not equal equal total DPS when schools have different damaging ailments or utility; the medium Armor and resistance fixtures also represent different reduction percentages. Do not use stationary-target DPS to certify all damage archetypes or disregard utility and bypass behavior. No Healing, resource-efficiency stats or undecided Block Power behavior is assumed.

The [findings and recommendations](offense_results/findings.md) include short-versus-long-fight comparisons, attack pauses, compound-stat pricing and the [cooldown-gate probe](offense_results/cooldown_probe.md). The latter evaluates `max(execution duration, recovered cooldown)` independently; its deterministic allocation count is separate from Monte Carlo source outcomes.

## Frozen model relationships

- All direct Attack/Spell Hits share Hit Rating and can Dodge/Block. Damage schools remain separate from delivery.
- Strength scales Physical damage; Magic Power scales all five magic schools; DoT Damage scales periodic damage. Critical Damage 0means150% total direct critical damage.
- Critical Hits guarantee automatic school ailments; ordinary chance defaults20%. Matching components are aggregated perHit. DoT ticks never trigger more ailments.
- Burn/Bleed maintain one strongest target-wide family; Poison stacks independently without a count cap. Utility potency uses a target-level threshold, not actual Max Health.
- Absorption covers all damage except Bleed/Necrotic after mitigation. Any damaging direct Hit to Absorption or Health resets3seconds; eligible recovery is 10% Max/s. DoTs do not reset recovery.
- Health Regeneration, Healing Power, and healing abilities/effects are removed. Hollowed lasts 6 seconds and reduces consumable restoration and Absorption recovery.
- Basic weapon range/cadence fields are legacy simulator inputs; they do not represent the new Godot WeaponDefinition or Physical Power scaling.

## Historical reports and commands

These frozen outputs retain their original scenarios, budgets, assumptions, manifests, and counts:

- [Earlier broad report](results/report.md) and [findings](results/findings.md).
- [Pressure report](pressure_results/report.md), [corner audit](pressure_results/corner_cases.md), and [resource audit](pressure_results/resource_audit.md).
- [Matched hand-package report](loadout_results/report.md).

Their `simulator.py` funded-build pipeline, pressure/loadout wrappers, and old scenario schemas do not implement the new combat revision. Current-rule calls reject the incompatible legacy schema explicitly rather than silently treating removed stats as live ones. Preserve their evidence as historical; Combat Lab and the leveling study also remain previous-model tools and cannot validate Combat 2.0. Do not combine historical trajectory counts with a new run.

## Evidence boundaries

A fixed-contact simulation does not reproduce aiming, positioning, AI decisions, geometry, input/physics quantization, or player skill. Specify level, enemy Hit size/cadence/school, defenses, resource cost, consumable policy and stat budget before interpreting survival or kill time. Kill-time percentiles are conditional on kills; report failures/timeouts separately. High damage or low incoming damage can be valid specialization; an outlier requires comparing what it sacrificed under matched budgets.

Raw-stat prices and gear tiers are experimental controls. Sensitivity across different prices is necessary before making itemization conclusions. The current scripts use bounded NumPy batches and reproducible seeds; no native plugin or desktop interaction is required.
