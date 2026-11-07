# Combat 2.0 implementation

The Godot project implements the attribute and physical-weapon foundation described in the [Combat 2.0 game design](combat_system_2_0.md). Combat 1.0 gameplay rules have been removed from the live game. Historical Python tools and reports remain a separate, explicitly legacy reference.

The [new weapon design](combat_system_2_0.md#weapons) proposes unique-equipped types, shared weapon trees, Shield as a defensive weapon and the Orb of Power/Talisman/Relic/Fetish caster roster. The playable Godot rules use the current caster family names, fixed character Magic Power, authored animation timing and explicit test grants. The [caster Power range and weapon timing factor](combat_system_2_0.md#magic-damage-and-casting) remain design proposals.

The [shared Accuracy and level curve](combat_system_2_0.md#accuracy-and-levels) is implemented: 80% at starting Accuracy against equal-level enemies, 100% attainable through +5, and an 8–10% starting-to-maximum chance at +10. Connected hostile payloads share one check; failures display MISS for attacks and RESIST for spells.

## Active attributes

The code-defined catalogue contains thirty active attributes.

| Group | Attributes |
| --- | --- |
| Primary | Strength, Dexterity, Intellect, Vitality |
| Offensive | Physical Power, Magic Power, Accuracy Rating, Critical Chance, Critical Damage, Armor Penetration, Attack Speed, Cast Speed |
| Capacity | Max Health, Max Stamina, Max Mana, Carry Capacity |
| Load | Carried Weight |
| Movement | Movement Speed bonus percentage; 0% is normal |
| Regeneration | Health Regeneration, Stamina Regeneration, Mana Regeneration |
| Armor | Armor rating, converted to Physical damage reduction |
| Resistance | Fire Resistance, Cold Resistance, Lightning Resistance, Void Resistance, Necrotic Resistance |
| Current resources | Health, Stamina, Mana |

Health/Stamina/Mana Regeneration use IDs 10/11/12. Armor uses ID 18. Fire/Cold/Lightning/Necrotic/Void Resistance use IDs 19/20/21/22/44. Armor Penetration uses ID 34, Critical Chance and Critical Damage use IDs 14/15, Physical Power uses ID 53 and Accuracy Rating uses ID 40. Movement Speed, Attack Speed and Cast Speed use bonus percentage IDs 54/55/56. Their old identities 27/25/26 stay retired. Retired slots return zero and stay out of Inspector and playground choices.

| Primary | Flat contribution per point |
| --- | --- |
| Strength | +2 Physical Power and +1 Accuracy Rating for Brutality; +2 Carry Capacity |
| Dexterity | +2 Physical Power and +1 Accuracy Rating for Finesse, including bows |
| Intellect | +2 Magic Power, +5 Max Mana, +1 spell Accuracy Rating |
| Vitality | +10 Max Health, +5 Max Stamina |

A single governing primary contributes to each action. Context tags are `Weapon.Brutality`, `Weapon.Finesse` and `Ability.Spell`. Ambiguous or absent weapon categories do not guess a primary. Direct flat Power or rating modifiers can still contribute in those contexts.

## Defaults and modifier order

Starting base values are authored in [GE_DefaultAttributes](../combat/effects/ge_default_attributes.tres). [GE_AttributeDerivations](../combat/effects/ge_attribute_derivations.tres) applies the five persistent primary-to-attribute contributions. Combat bounds, level progression and context-specific combat coefficients are in [combat_rules.json](../combat/combat_rules.json).

Characters start with 10 in each primary. Base capacities before primary contributions are 100 Health, 50 Stamina, 50 Mana and 80 Carry Capacity, producing starting totals of 200/100/100/100. Level is capped at 60; the validated allocation budget grants 2 points per gained level, 118 by level 60. Level alone does not raise damage or capacities.

Persistent modifier calculation is:

```text
(Base including primary contribution + Add Flat)
× (1 + Sum of Increased Percent / 100)
× Product of (1 + Each More Percent / 100)
```

`Set Base` is an explicit override of the whole derived foundation, including its primary contribution. It is useful for authored actor profiles and playground testing. Ordinary equipment bonuses use Add Flat, Increased Percent or More Percent. Removing an owned modifier removes only that owner's contribution.

Resistances clamp to −100% through +80%. Armor Penetration, Critical Chance, Attack Speed and Cast Speed clamp to 0–100%. Critical Damage is an uncapped nonnegative bonus to the 150% base critical multiplier. Armor is an uncapped nonnegative rating with a 75% damage reduction limit. Movement Speed clamps to −100% through +25%. Capacities have a minimum of 1 and current resources clamp to their capacities. Capacity increases preserve current amounts. `restore_resources()` resets pools for testing.

## Weapon data and direct damage

[WeaponDefinition](../combat/weapons/weapon_definition.gd) stores the weapon family, physical min/max damage and base attack cycle. Family selects the governing primary. Caster profiles are casting-only. The designed Shield weapon type is not yet present in this catalogue. No weapon implicits are implemented.

An ordinary physical weapon hit resolves:

```text
Weapon min/max roll + Applicable Physical Power × Base attack cycle in seconds
```

One min/max roll is shared by a delivered hit's weapon components. A new delivered hit samples again. Weapon damage and cycle are copied into the cast so editing a shared resource cannot alter a flying arrow. The source's known effect scopes are cached for safe delivery after the source is removed.

Physical attack animations fit the authored weapon cycle when a weapon source supplies one. The Attack Speed multiplier then scales that playback rate. Cast Speed scales spell animation playback. Method keys control release or contact, and the weapon coefficient still uses its authored base cycle.

Generic explicit damage effects use `base_magnitude + applicable Power × power_coefficient` before target mitigation. The saved Fireball is a simple direct Magic/Fire payload. The [impact effect](../examples/fireball/fireball_impact.tres) owns base damage 5 and Power Coefficient 1.0. Starting Magic Power 20 gives 25 raw damage. The [ability](../examples/fireball/fireball.tres) owns Mana cost and cooldown.

## Attack Speed and Cast Speed

Both attributes default to 0%. Author ordinary bonuses with Add Flat. Add Flat 20 and Add Flat 30 contribute +50%, so the animation plays at 1.5×. Clamp the final bonus to 0–100%, then compute the multiplier as `1 + effective bonus / 100`. The generic Increased Percent and More Percent operations scale the stored bonus itself. At +100% the multiplier reaches 2×.

The active cast samples the scoped value once. Fireball's cast bar reads the animation's current position as a fraction of its authored release key. Release and recovery follow that animation and cooldown advances on its own clock. F3 speed sliders can expand beyond +100% while the character sheet shows the capped result.

## Critical hits

Critical Chance starts at **0%**, with final limits **0–100%**. Critical Damage starts at **0 bonus percentage points**, is nonnegative and has **no upper cap**. Neither receives an automatic primary or level contribution. Both use normal flat/increased/more modifiers; Add Flat 50 to Critical Damage gives a 200% critical multiplier. Increased Percent scales the bonus stat, so increasing a zero foundation leaves it at zero.

```text
Ordinary multiplier = 1
Critical multiplier = base_critical_multiplier + Critical Damage / 100
Default base_critical_multiplier = 1.5
Damage = Raw source magnitude × Resolved multiplier × Defense multiplier
```

After Accuracy succeeds, one roll selects whether the damaging delivery crits. All its Physical/Magic components share the result and multiplier, using source critical stats in the action's Ability/Weapon context. Each component then uses its ordinary Armor/penetration or matching resistance. Criticals do not amplify retained modifiers, change Accuracy or bypass defenses; modifier-only hits cannot crit. At 100% Critical Chance every successful damaging hit crits, while Accuracy can still fail. Direct non-hit `effects.apply_effect()` does not introduce another critical roll.

`combat_rules.json` owns `base_critical_chance`, `critical_chance_min_percent`, `critical_chance_max_percent`, `base_critical_damage` and `base_critical_multiplier`. Weapon, Accuracy and critical RNG streams are independent and inspection never consumes a roll. Hit outcome telemetry reports the shared critical result; damage events retain pre-critical `raw_magnitude`, critical metadata, post-critical/mitigated magnitude and actual Health loss. F1 counts critical hits once per delivery, F2 identifies critical damage, and critical floating numbers use a larger yellow pop animation.

Damage examples below assume an ordinary hit unless stated otherwise.

## Armor and Physical mitigation

Armor starts at **0 rating**, with no primary or level contribution. The ordinary flat/increased/more pipeline produces its final nonnegative, uncapped rating. `CombatMath.get_armor_reduction(armor)` returns a pure fraction from 0 through 0.75, using shared JSON tuning `armor_max_reduction = 0.75` and `armor_rating_at_cap = 1000`.

```text
K = Armor at cap × (1 − Reduction cap) / Reduction cap
Effective Armor = Full modified target Armor × (1 − Source Armor Penetration / 100)
Reduction = min(Reduction cap, Effective Armor / (Effective Armor + K))
Physical damage taken = Raw Physical damage × Critical multiplier × (1 − Reduction)
```

At the defaults, K = 1000/3. With zero source penetration, Armor 100/250/500/750/1000 produces approximately 23.08/42.86/60/69.23/75% reduction. Higher ratings retain their full stored value but cannot raise reduction above 75%. Overcap contributions remain available against later debuffs and incoming penetration.

Only Physical damage components use Armor, including Physical Spells; Magic components use their matching resistance instead. Each component uses exactly one of these mitigation paths after its hit passes Accuracy. Neither mechanism changes raw source damage, status potency or success probability. Damage events report the applied Armor rating and reduction alongside raw/mitigated/actual Health damage.

The curve has no hit-size or level factor. Its reduction percentage has diminishing gains, while Physical effective Health grows linearly with effective Armor before the cap and reaches at most 4× Health from Armor. Invalid input/configuration returns no reduction rather than dividing by zero. Block and periodic damage remain outside the implemented foundation.

## Armor Penetration

Armor Penetration is a **source percentage**, starting at 0% with no primary or level contribution. Standard modifiers combine before the final 0–100% clamp. Add Flat 20 means 20 percentage points. Numeric tuning is in `base_armor_penetration`, `armor_penetration_min_percent` and `armor_penetration_max_percent`.

For each Physical component, CombatMath queries source penetration in that component's canonical context, multiplies the full current target Armor by `1 − penetration/100`, then resolves the Armor curve. It does not change the target's stored attribute. Physical Spells use penetration too; Magic damage, Accuracy and retained modifier potency ignore it.

Against 1,000 Armor, 0/25/50/75/100% penetration leaves 1000/750/500/250/0 effective Armor, producing approximately 75/69.23/60/42.86/0% reduction. Against 2,000 Armor, 50% penetration leaves 1,000 and retains the full 75% cap. Apply penetration before the curve without first clamping target Armor to 1,000. At 100%, all valid target Armor is ignored for that component and Physical damage reaches its raw magnitude.

Source values follow the existing weak-live/cached-fallback context policy, including primed scopes for detached projectiles. Target Armor is queried at impact. Damage events preserve `armor` as the full target rating and report effective Armor and applied penetration separately. The attacker's penetration affects its outgoing Physical damage; the defender's own penetration does not reduce its incoming protection.

## Magic schools and resistance

`GameplayEffectDefinition` preserves `DamageType.PHYSICAL = 0` and `MAGIC = 1`. Its separate Magic School selector supports Fire, Cold, Lightning, Void and Necrotic, defaulting to Fire for existing Magic resources without an authored school. Fireball explicitly authors that school. Physical components ignore the selector. All schools continue to use Magic Power.

Each successful Magic damage component resolves `raw_magnitude × critical_multiplier × (1 − matching_resistance / 100)`. Only its corresponding target resistance participates, queried in that component's context. Canonical damage-type/school tags are derived from the authored fields; contradictory effect tags are rejected. The bounds/default are numeric JSON tuning: `base_resistance = 0`, `resistance_min_percent = -100`, `resistance_max_percent = 80`.

For 100 raw damage, matching resistance of −100/−50/0/50/80% yields 200/150/100/50/20 damage. Resistance applies to Magic components of Attacks as well as Spells. Physical damage ignores all five, and retained modifier/control potency is unchanged. A mixed payload shares one Accuracy check, then resolves each damage component independently.

Resistance bonuses are percentage points: Add Flat 20 grants +20 points. Increased and More multiply the signed foundation, so −50 with 20% increased becomes −60. Apply the final clamp after combining contributions; over-cap amounts can offset a later flat debuff. Damage events preserve raw/resistance/school details while reporting actual post-mitigation Health loss.

School resistance adds no random roll. A matching 80% resistance produces a successful hit dealing 20% damage; RESIST feedback still means a failed spell Accuracy check. Armor applies separately to Physical components. Automatic ailments, periodic damage and barrier mechanics remain excluded.

## Accuracy and outcomes

`CombatMath.get_hit_chance(attacker_level, target_level, accuracy)` is a pure calculation returning a fraction from 0 to 1. `get_hit_chance_details()` also exposes base/maximum probabilities and the required rating. The curve arrays, rating conversion and continuation constants are editable in `combat_rules.json`; the design table and examples are in [Accuracy and levels](combat_system_2_0.md#accuracy-and-levels).

`AbilitySystem.receive_hit()` duplicates the delivery context, samples one Accuracy outcome and applies eligible effects only on success. All damage components and attached hostile modifier effects share the result. A modifier-only hostile spell still checks Accuracy. Modifier-only self deliveries and explicitly `Ability.Beneficial` ally deliveries bypass the hostile check; any eligible damage keeps the check mandatory. Direct `effects.apply_effect()` remains the explicit buff/effect operation rather than another hit roll.

The target emits one `hit_outcome` event per eligible delivery, carrying `hit`, `miss` or `resist` and the resolved probability. Misses and resists apply no payload and refund no activation costs. Damage remains independent of level and maximum target Health. Spell classification comes from `Ability.Spell`, so a magical Attack still uses the attack outcome label. Weapon damage sampling, Accuracy and criticals use separate random streams; `configure_randomness()` provides repeatable tests/replays without making inspection consume randomness.

## Periodic regeneration

Health Regeneration starts at **0/sec**, Stamina Regeneration at **10/sec**, and Mana Regeneration at **5/sec**. These nonnegative, uncapped stats use ordinary flat/increased/more modifiers. Primaries and maximum pools do not automatically raise the rates.

The ASC applies [GE_ResourceRegeneration](../combat/effects/ge_resource_regeneration.tres) at startup. Its execution reads live rates and restores `rate × period`, capped by missing capacity. It is inhibited while dead. `State.Stamina.RecoveryBlocked` pauses Stamina recovery. The Sprint ability owns that tag throughout activation, and the exhaustion effect grants it for its authored duration after Stamina crosses from positive to zero. Health and Mana recover independently. An ordinary spend above zero adds no recovery delay.

`AbilitySystem.advance()` advances the effect clock and is also used for deterministic tests. Recovery survives a transient-effect clear and resumes after revival. The AttributeSet owns clamping and reports the resulting pool changes.

## Movement Speed and sprinting

Movement Speed starts at **0% bonus**. The standard pipeline combines all modifiers and clamps the final value to **−100% to +25%**. Add Flat 20 gives +20%. Applying Increased Percent 20 to that bonus gives +24%, while an increased modifier alone leaves zero at zero. A raw +100% F3 override displays an effective +25%. The cap applies before gait multipliers, so the default 4 m/s baseline and 1.5× Sprint ratio yield 5 m/s Run and 7.5 m/s Sprint at the cap.

F3 displays the bonus percentage. The bonus starts at zero. The JSON keys `movement_speed_min_percent` and `movement_speed_max_percent` supply its bounds. Older rule data that omits the maximum uses the +25% default. **Movement → Settings → Movement Baseline → Normal Run Speed** owns the physical baseline. Movement computes `settings.normal_run_speed × max(0, 1 + final_bonus/100) × gait_ratio × encumbrance_factor`. At a 6 m/s baseline and no overload, 0% and +20% give 6 and 7.2 m/s normal running. Active identity 54 represents the bonus. Identity 27 remains retired.

The saved player owns one ActorAttributes node, inherited by the caster example. Movement references it explicitly and reads the live attribute each step. AbilitySystem also uses that component; if its explicit reference is empty, startup resolves the sibling `Attributes` node, preserving the single actor source after an inherited-scene resave. Explicit valid references take precedence. It never stores another base-speed setting. Gait settings supply Walk ×0.5, Sprint ×1.5 and Crouch ×0.6; crouch-walk combines Walk and Crouch. At the default attribute the speeds remain 4/2/6/2.4/1.2 m/s for run/walk/sprint/crouch/crouch-walk. Jump/gravity/acceleration/braking/terrain remain independent settings.

**Sprint → Execution → Upkeep Effect** opens [GE_StaminaUpkeep](../player/ge_stamina_upkeep.tres). **Period** and **Executions → Stamina per Interval** default to 0.1 seconds and 2 points. Grounded horizontal travel adds time only when Sprint is effective and there is movement input. Movement retains unpaid travel across activation boundaries. Idle, walking, crouching, blocked wall travel and falling add no chargeable time.

The base player grants Sprint, Jump, Crouch, Encumbered and Stamina Exhaustion. The caster adds Fireball. Hold Shift to request Sprint and release it to end Sprint. Sprint requires enough Stamina for the next full charge. If a paid grounded charge would leave a positive remainder smaller than the next full charge, that same debit spends the remainder and reaches zero. For example, a 2-point charge spends all 3 when the pool holds 3. A voluntary release with Stamina left or an affordability failure from a separate spend above zero ends Sprint and allows normal recovery. Exhaustion or encumbrance interruption requires a fresh press. Jump is blocked while Sprint owns `State.Movement.Sprinting`. Running off an edge preserves horizontal momentum, with airborne steering bounded by the normal air speed.

Movement reports actual travel with the due tag. It enables the retained upkeep effect, which executes a charge and returns to its inhibited state. Active Sprint pauses Stamina regeneration even when stationary or in the air. The default 100 Stamina funds about five seconds of grounded sprint travel. A positive-to-zero transition sends `Event.Stamina.Depleted`. The granted exhaustion action applies its timed effect, which owns the recovery blocker until expiry.

## Encumbrance

`Carried Weight` uses active ID 39, defaults to zero and can exceed Carry Capacity. `Carry Capacity` retains its minimum of 1 and starts at 100 with 10 Strength. Movement reads both values from the actor each step.

Above capacity, speed falls quickly along a cubic curve toward the speed floor. Jump height declines linearly until the load reaches the full penalty ratio. The defaults reach **50% speed and 0% jump height at twice capacity**. At 150 weight and 100 capacity, the factors are **0.5625× speed and 0.5× jump height**. The speed factor multiplies the existing bonus and gait result. The height factor applies at launch before the gravity-based velocity calculation. Zero height prevents a jump.

The actor's carry rule publishes an enter event above capacity and an exit event at or below capacity. The granted Encumbered ability starts and finishes on those events. Its execution maintains the indefinite effect granting `State.Encumbered`. The Sprint ability declares the tag as both an activation blocker and an interruption. A cancelled Sprint falls back to ordinary gait selection and stops spending sprint Stamina. [Gameplay event authoring](ability_system.md#gameplay-events)

**Movement → Settings → Encumbrance** owns the full penalty load ratio and the minimum speed multiplier. In F3, edit **Carried Weight** on the left. **Carry load** shows weight and capacity together. The Player sheet reads the owned tag for the **Encumbered** badge and the movement component's speed and jump height factors for the live penalties.

## Effects and delivery

Player and AI share ASC activation. Ability definitions select GDScript execution behavior, cost and cooldown effects, and tag rules. The prototype grants Fireball directly. It owns `State.CombatAction` while the cast runs, and its animation release event goes to the activation that started playback. Locomotion can overlap the cast. The projectile carries the outgoing effect spec prepared at release.

Gameplay Effects support instant, finite and infinite lifetimes, optional periodic executions, tag requirements and configurable stacking. An effect can grant tags without stat modifiers. Retained definitions can opt into HUD presentation with an icon and a Buff or Debuff category. Fireball's impact is instant.

Dodge, Block, Absorption, cooldown recovery and consumable behavior remain design-only or outside the current prototype.

## Playground

Open [playground.tscn](../levels/playground/playground.tscn). The saved [combat HUD scene](../levels/playground/testing/combat_hud.tscn) shows Health, Mana and Stamina at the bottom center. Buffs grow from the left and debuffs from the right. Fireball's cast bar shows its live windup and hides on release or cancellation.

F3 opens the Player or Dummy tab. The left pane offers an ability selector, level and searchable sliders for all thirty attributes. The right sheet shows effective stats, including Attack Speed and Cast Speed as percentages. The Player → Dummy card uses the selected ability's hit chance and normal-hit damage against the dummy's current defenses. Hover the derived readouts for inputs such as Accuracy Rating, applicable Power, Armor and Critical Damage bonus.

Enable a row override to edit its base. Current pools edit directly within their current capacity. Level, Strength, Dexterity, Intellect and Vitality use whole steps. Other attribute sliders use 0.01 steps. Focus a slider and use the arrow keys for a single step. The saved editor scene defines practical test ranges. Tracks include existing values outside those ranges. The character sheet uses the effective values after gameplay limits apply. Damage previews use the selected action's authored hit payload. The ellipsis menu holds reset edits and clear effects, plus resource restoration for Player. R restores the dummy during gameplay. Esc or F3 closes the attribute view. LMB or F activates the selected action.

F1 opens Statistics across the full panel. F2 toggles the combat log. The saved [panel theme](../levels/playground/testing/combat_panel_theme.tres) styles the panel and its controls. Both attribute panes scroll independently, and the computed values reserve a gutter beside the scrollbar.

Inspector exports, weapon family enum entries, modifier operations, attribute descriptions and playground controls have tooltips. See [Ability authoring](ability_system.md) for the saved-resource workflow.
