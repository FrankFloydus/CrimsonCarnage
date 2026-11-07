# Combat 2.0 game design

The combat system combines a first-person RPG's physical weapon handling with randomized equipment and character specialization. Four primary attributes supply flat foundations; equipment, talents and buffs can add flat values, combined increased percentages and independent more multipliers.

> **Design status.** The prototype implements the attribute foundation, physical weapon scaling, the shared Accuracy curve, regeneration, action and movement speed, Sprint and exhaustion, encumbrance, criticals, Armor, penetration and five resistances. Caster weapon Power ranges and timing factors, the new caster families, equipment restrictions and weapon trees are design proposals.

This is the current design reference. The [implementation status](#design-and-implementation-status) identifies the boundary between design and code; the [implementation reference](combat_system.md) describes the live Godot behavior.

**Contents**

- [Character progression](#character-progression)
- [Attributes and modifiers](#attributes) · [Primary attributes](#primary-attributes) · [Derived attributes](#derived-attributes) · [Current resources](#current-resources)
- [Resource regeneration](#resource-regeneration)
- [Movement and sprinting](#movement-and-sprinting)
- [Encumbrance](#encumbrance)
- [Accuracy and levels](#accuracy-and-levels)
- [Critical hits](#critical-hits)
- [Armor and physical damage](#armor-and-physical-damage)
- [Damage schools and resistances](#damage-schools-and-resistances)
- [Weapon rules](#weapons) · [Physical weapons](#physical-weapons) · [Caster weapons](#caster-weapons) · [Shields](#shields)
- [Weapon talent trees](#weapon-talent-trees)
- [Magic damage and casting](#magic-damage-and-casting)
- [Design and implementation status](#design-and-implementation-status)

## Character progression

The character level cap is **60**. Characters start with **10 Strength, 10 Dexterity, 10 Intellect and 10 Vitality**, with no additional creation points. Each gained level awards **2 primary attribute points**.

```text
Earned allocation budget = 2 × (Level − 1)
Level range = 1–60
Total earned points at level 60 = 118
```

The player distributes that budget among the four primaries. Investing all earned points in one primary produces **128** before equipment. This is an allocation example, not an attribute cap. Level itself does not multiply damage or increase resource capacities; allocated attributes and equipment provide those improvements.

Starting values and contribution rates below are the current editable tuning defaults.

## Attributes

There are **thirty active attributes**, including four primaries, three current resource pools, Carried Weight, and Attack Speed and Cast Speed bonuses. The proposed caster weapon timing factor is a separate equipment property.

### Attribute value meanings

The F3 editor uses each attribute’s native units. The character sheet uses effective values to display gameplay outcomes such as hit chance, physical damage reduction and total Critical Damage. Its tooltips identify the source ratings and bonuses.

| Attribute type | Meaning of the editable attribute | Examples |
| --- | --- | --- |
| Totals and rates | The actual quantity after modifiers | Health, capacities, primaries, Armor, Power, Accuracy, Carry Capacity, Carried Weight and regeneration |
| Direct percentages | The actual chance or defense percentage | Critical Chance, Armor Penetration and school resistances |
| Bonus percentages | A bonus added to a separate built-in baseline | Critical Damage above 150%, Movement Speed above normal movement, Attack Speed and Cast Speed above authored playback |

At 0% bonus, Critical Damage uses its 150% baseline and action and movement speeds use normal playback or movement. Add Flat adds native stat units. Generic Increased and More operations scale the stored stat value. The tooltips give each attribute's units and baseline.

### Modifier calculation

Every primary and derived attribute follows the same modifier order. First calculate its foundation, including any contribution from a primary attribute. Add applicable flat bonuses, combine increased percentages, and then apply each more multiplier independently.

```text
Modified(Foundation) =
    (Foundation + Other applicable flat bonuses)
    × max(0, 1 + Sum of increased percentages / 100)
    × Product of max(0, 1 + Each more percentage / 100)

Final stat = Modified(Foundation), clamped to the stat's minimum and maximum
```

In the formulas below, **Modified** always means modifiers targeting the attribute being calculated. Primary names such as Strength and Intellect mean their **full final values**, including allocations, equipment and modifiers. For an offensive action, use values applicable to that action's context.

Most primary and derived attributes have no upper cap. Armor rating is uncapped and its Physical damage reduction caps at 75%. Armor Penetration, Critical Chance, Attack Speed and Cast Speed clamp to 0–100%. Critical Damage is an uncapped nonnegative bonus to the 150% critical multiplier. Movement Speed clamps to −100% through +25%. The five resistances clamp to −100% through +80%. Bounds apply after modifiers.

| Modifier | Meaning | Example |
| --- | --- | --- |
| Flat | Adds native stat units before percentages. | +20 Magic Power. |
| Increased | Applicable percentages add together into one multiplier. | 20% increased and 30% increased give ×1.50. |
| More | Each modifier multiplies independently. | 20% more gives ×1.20. |

For example, 50 Magic Power from Intellect and 50 from equipment produce 100 flat Power. A combined 50% increased modifier produces 150. A separate 20% more modifier produces **180**.

A modifier affects its named stat and scope once. A modifier to Intellect changes the primary before its contributions are calculated; a modifier to Magic Power acts on the resulting Power foundation. Persistent modifiers target attributes or capacities; current Health, Stamina and Mana change through explicit resource operations.

**Set Base** is an authoring override that replaces the complete foundation, including its primary contribution, before other flat and percentage modifiers. Ordinary equipment uses flat, increased or more bonuses.

Randomized gear can contain poor rolls, clear upgrades, situational combinations and exceptional drops. Individual bonuses do not require equal value or a compensating upside. There is no enforced exchange rate between an Intellect roll and a direct Magic Power roll.

## Primary attributes

### Strength

Strength represents physical force. It governs **Brutality** weapon attacks and increases the inventory weight the character can carry. Every point supplies **2 Physical Power** and **1 Accuracy Rating** to Brutality attacks, plus **2 Carry Capacity**.

```text
Strength = max(0, Modified(10 + Allocated Strength points))
Brutality Physical Power contribution = 2 × Strength
Brutality Accuracy Rating contribution = Strength
Carry Capacity contribution = 2 × Strength
```

**Limits:** minimum **0**; maximum **uncapped**.

Starting Strength is 10. Its offensive contributions apply to Brutality attacks; an action does not automatically add both Strength and Dexterity.

### Dexterity

Dexterity represents coordination and precision. It governs **Finesse** weapon attacks, including bow shots. Every point supplies **2 Physical Power** and **1 Accuracy Rating** to those attacks.

```text
Dexterity = max(0, Modified(10 + Allocated Dexterity points))
Finesse Physical Power contribution = 2 × Dexterity
Finesse Accuracy Rating contribution = Dexterity
```

**Limits:** minimum **0**; maximum **uncapped**.

Starting Dexterity is 10. Dexterity contributes Finesse Accuracy. Action speed comes from explicit Attack Speed or Cast Speed modifiers.

### Intellect

Intellect represents magical understanding and control. It governs spells and supplies **2 Magic Power**, **5 maximum Mana** and **1 spell Accuracy Rating** per point. Its flat Magic Power remains part of the foundation as stronger caster equipment adds its own Power.

```text
Intellect = max(0, Modified(10 + Allocated Intellect points))
Magic Power contribution = 2 × Intellect
Maximum Mana contribution = 5 × Intellect
Spell Accuracy Rating contribution = Intellect
```

**Limits:** minimum **0**; maximum **uncapped**.

Starting Intellect is 10. Intellect and direct Magic Power bonuses can coexist on equipment; their rolls do not need to be equally valuable. Intellect and maximum Mana do not automatically increase Mana Regeneration.

### Vitality

Vitality represents health and physical endurance. Every point supplies **10 maximum Health** and **5 maximum Stamina**, before modifiers to those capacities.

```text
Vitality = max(0, Modified(10 + Allocated Vitality points))
Maximum Health contribution = 10 × Vitality
Maximum Stamina contribution = 5 × Vitality
```

**Limits:** minimum **0**; maximum **uncapped**.

Starting Vitality is 10. Carry Capacity belongs to Strength in the current 2.0 design. Vitality and its resource capacities do not automatically increase Health or Stamina Regeneration.

## Derived attributes

### Physical Power

Physical Power supplies the character's contribution to physical weapon damage. Brutality attacks derive it from Strength; Finesse attacks derive it from Dexterity. Both melee and bow attacks use this stat.

```text
Brutality Physical Power = max(0, Modified(2 × Strength))
Finesse Physical Power = max(0, Modified(2 × Dexterity))
Physical damage contribution = Applicable Physical Power × Attack coefficient
```

**Limits:** minimum **0**; maximum **uncapped**.

With 10 in the governing primary and no other bonuses, the applicable value is **20**. The weapon's base cycle supplies the ordinary attack coefficient described under [physical weapon damage](#physical-weapon-damage). Physical Power is a flat stat; DPS is a derived comparison.

### Magic Power

Magic Power supplies the offensive foundation for spells. Intellect, applicable flat bonuses and the caster weapon's minimum–maximum Power range combine before increased and more modifiers. A spell's authored coefficient converts the resulting Power into damage.

```text
Magic Power range = max(0, Modified(
    2 × Intellect + Caster weapon Magic Power range
))
Spell damage contribution = Rolled final Magic Power × Spell coefficient
```

**Limits:** minimum **0**; maximum **uncapped**.

Apply the same calculation to both ends of the range. With 10 Intellect and no weapon or other bonuses, character Magic Power is **20**. The current code calculates that fixed character value; the weapon range is part of the pending caster extension.

Magic Power is shared by the elemental, Void and necromancy domains. Those domain labels do not introduce separate Elemental Power, Void Power or Necrotic Power attributes.

### Accuracy Rating

Accuracy Rating represents the relevant action's precision. The same attribute is used for physical attacks and spells, but its primary contribution comes from the action's governing attribute.

```text
Brutality Accuracy Rating = max(0, Modified(Strength))
Finesse Accuracy Rating = max(0, Modified(Dexterity))
Spell Accuracy Rating = max(0, Modified(Intellect))
```

**Limits:** minimum **0**; maximum **uncapped**.

Starting context-appropriate Accuracy is **10**. One point of rating is not one percentage point of hit chance. The agreed [Accuracy and level calculation](#accuracy-and-levels) uses this rating for attacks and spells, with 100% success attainable within five enemy levels and an 8–10% starting-to-maximum chance at a ten-level disadvantage. The rating is uncapped, while the resulting chance has a ceiling for each level difference.

The live game resolves that shared check for physically delivered hits and hostile modifier-only payloads. Combat 1.0 curves do not apply.

### Critical Chance

Critical Chance is the probability that a successful damaging hit becomes critical. It starts at **0%**, receives no automatic contribution from primaries or level, and uses ordinary flat, increased and more modifiers.

```text
Critical Chance = clamp(Modified(0), 0, 100)
```

**Limits:** minimum **0%**; maximum **100%**.

Add Flat 20 supplies 20 percentage points. At 100%, every successful damaging hit is critical; Accuracy still determines whether the hit succeeds. A single roll applies to the whole delivered hit, including all Physical and Magic components. An action's Ability/Weapon context selects its applicable critical modifiers.

### Critical Damage

Critical Damage increases the damage of critical hits above their **150% starting damage**. The stat starts at **0 bonus percentage points** and has no upper cap. It receives no automatic primary or level contribution.

```text
Critical Damage = max(0, Modified(0))
Critical multiplier = 1.50 + Critical Damage / 100
```

**Limits:** minimum **0 bonus percentage points**; maximum **uncapped**.

At 0 Critical Damage, a critical deals 150% of ordinary damage. At 50, it deals 200%; at 150, it deals 300%. Add Flat 50 adds 50 points to this bonus, whereas 50% increased scales the existing bonus and leaves a zero foundation at zero. Critical Damage affects neither ordinary hits nor Accuracy and does not amplify attached modifier effects.

### Maximum Health

Maximum Health determines the size of the Health pool. Its base is **100**, with **10 flat Health per Vitality** before equipment and percentage modifiers.

```text
Maximum Health = max(1, Modified(100 + 10 × Vitality))
```

**Limits:** minimum **1**; maximum **uncapped**.

At 10 Vitality with no other bonuses, maximum Health is **200**. Increasing the maximum does not restore current Health; reducing it clamps current Health to the new maximum.

### Maximum Stamina

Maximum Stamina determines the capacity available for authored Stamina costs. Its base is **50**, with **5 flat Stamina per Vitality**.

```text
Maximum Stamina = max(1, Modified(50 + 5 × Vitality))
```

**Limits:** minimum **1**; maximum **uncapped**.

At 10 Vitality with no other bonuses, maximum Stamina is **100**. A larger capacity does not refill the current pool.

### Maximum Mana

Maximum Mana determines the capacity available for authored Mana costs. Its base is **50**, with **5 flat Mana per Intellect**.

```text
Maximum Mana = max(1, Modified(50 + 5 × Intellect))
```

**Limits:** minimum **1**; maximum **uncapped**.

At 10 Intellect with no other bonuses, maximum Mana is **100**. Increasing the capacity does not restore current Mana.

### Carry Capacity

Carry Capacity represents the inventory weight the character can handle. Its base is **80**, with **2 flat capacity per Strength**.

```text
Carry Capacity = max(1, Modified(80 + 2 × Strength))
```

**Limits:** minimum **1**; maximum **uncapped**.

At 10 Strength with no other bonuses, Carry Capacity is **100**. Encumbrance starts when Carried Weight exceeds this value.

### Carried Weight

Carried Weight is the total load in the same units as Carry Capacity. It starts at **0** and uses the ordinary attribute modifier pipeline with no primary or level contribution.

```text
Carried Weight = max(0, Modified(0))
```

**Limits:** minimum **0**, maximum **uncapped**. Load can exceed Carry Capacity.

F3 exposes a **Carried Weight** slider for testing. The right sheet shows load against capacity and marks an overloaded actor as **Encumbered**. Under **Carry load**, the Player tab shows the movement speed and jump height penalties as percentages that update with weight and capacity. The slider supplies test load while inventory authoring remains a separate system.

### Movement Speed

Movement Speed is a **bonus percentage above normal movement**, starting at **0%**. Normal locomotion is the internal baseline, just as the 150% starting critical multiplier is separate from the Critical Damage bonus. Movement Speed receives no automatic primary or level contribution.

```text
Movement Speed bonus = clamp(Modified(0), −100, 25)
Movement multiplier = max(0, 1 + Movement Speed bonus / 100)
```

**Limits:** minimum **−100%**; maximum **+25%**.

| Authored modifier | Final Movement Speed bonus | Movement relative to normal |
| --- | --- | --- |
| None | 0% | Normal |
| Add Flat 1 | +1% | 1% faster |
| Add Flat 20 | +20% | 20% faster |
| Add Flat 20 and 20% increased | +24% | 24% faster |
| Add Flat 20, 20% increased and 20% more | +25% (28.8% before cap) | 25% faster |
| Add Flat −25 | −25% | 25% slower |
| Add Flat −100 | −100% | No requested horizontal movement |

An item reading **+20% Movement Speed** supplies **20 native bonus percentage points**, using Add Flat. Increased and more modifiers scale the accumulated bonus itself, exactly as for Critical Damage: an Increased modifier alone leaves a zero bonus at zero. Zero bonus means normal movement. A −100% bonus requests no horizontal movement; ordinary braking and collision physics still apply. Jump height and gravity are independent.

F3 displays the bonus percentage, **0%** by default, rather than engine m/s or an implicit 100% total multiplier. Active code identity 54 is retained; retired Combat 1.0 identity 27 stays inactive. The bonus defaults to zero, and `movement_speed_min_percent` / `movement_speed_max_percent` supply the −100 / +25 bounds. Clamp after all flat, increased and more modifiers; raw overcap bonuses still count before a later debuff is evaluated. The normal engine movement baseline is the editable **Normal Run Speed** under **Movement → Settings → Movement Baseline** in the Inspector. It defines 100% normal movement, while the attribute stores only the bonus above that. Movement Settings owns gait ratios. GE_StaminaUpkeep owns upkeep tuning.

### Attack Speed and Cast Speed

Attack Speed and Cast Speed start at **0%**. Author ordinary speed bonuses with Add Flat percentage points. +20% and +30% combine to +50%. The effective bonus clamps to **0–100%**, so +100% doubles the base playback rate. The generic Increased and More operations scale the stored bonus.

```text
Playback multiplier = 1 + Effective speed bonus / 100
Uniform windup duration = Authored time to release / Playback multiplier
```

The activation samples its own speed once. Attack Speed applies to attacks after any physical weapon-cycle normalization. Cast Speed applies to spell animation. In Godot, the animation method key controls the exact release point. Fireball's cast bar measures playback to that key and disappears at release or cancellation. Authored cooldown is independent. IDs 55/56 identify these bonuses, and legacy rating IDs 25/26 stay retired.

### Health Regeneration

Health Regeneration restores **Health points per second**. Its base is **0**; gear, talents and buffs can supply flat regeneration, then increased and more modifiers scale it. Characters receive passive Health recovery only through an explicit source of regeneration.

```text
Health Regeneration = max(0, Modified(0))
```

**Limits:** minimum **0 Health/sec**; maximum **uncapped**.

For example, +6 flat Health Regeneration and 50% increased Health Regeneration produce **9 Health/sec**. Maximum Health and Vitality do not automatically raise that rate. Acquired regeneration is an additional Health-recovery option alongside planned consumables; healing spells and Healing Power remain excluded. No consumable behavior or values are supplied by this system.

### Mana Regeneration

Mana Regeneration restores **Mana points per second**, starting at **5 Mana/sec**. It supports sustained casting independently of the size of the Mana reserve.

```text
Mana Regeneration = max(0, Modified(5))
```

**Limits:** minimum **0 Mana/sec**; maximum **uncapped**.

For example, +3 flat Mana Regeneration and 40% increased Mana Regeneration produce **11.2 Mana/sec**. Intellect and maximum Mana contribute no automatic regeneration. The starting 100-Mana pool refills from empty in **20 seconds** without further spending.

### Stamina Regeneration

Stamina Regeneration restores **Stamina points per second**, starting at **10 Stamina/sec**. It controls recovery and sustained use of actions with authored Stamina costs.

```text
Stamina Regeneration = max(0, Modified(10))
```

**Limits:** minimum **0 Stamina/sec**; maximum **uncapped**.

For example, +5 flat Stamina Regeneration, 50% increased and 20% more produce **27 Stamina/sec**. Vitality and maximum Stamina contribute no automatic regeneration. Once recovery is eligible, the starting 100-Stamina pool takes **10 seconds** to refill at the default rate. Active Sprint and Stamina Exhaustion pause that recovery.

### Armor

Armor reduces incoming **Physical damage**, from either an Attack or a Spell. Its base is **0 Armor**, with no automatic primary or level contribution. Gear, talents and buffs use the ordinary flat, increased and more modifier pipeline before converting the final rating to damage reduction.

```text
Armor = max(0, Modified(0))
Effective Armor = Armor × (1 − Incoming source Armor Penetration / 100)
Armor reduction = min(0.75, Effective Armor / (Effective Armor + 1000/3))
Physical damage taken = Raw Physical damage × Critical multiplier × (1 − Armor reduction)
```

**Limits:** minimum **0 Armor**; maximum **uncapped rating**. Calculated damage reduction ranges from **0% to 75%**.

With no incoming penetration, the reduction percentage has diminishing returns and reaches its cap at **1,000 Armor**. At 500 Armor, Physical damage is reduced by 60%; at 1,000 or more it is reduced by 75%. Armor does not reduce Magic damage or change Accuracy, control potency, attack timing or movement. Excess rating remains part of the character's underlying value and can offset Armor debuffs and incoming penetration.

### Armor Penetration

Armor Penetration is the **source's percentage of target Armor ignored by a Physical damage component**. It starts at **0%**, receives no automatic primary or level contribution, and uses normal flat, increased and more modifiers before its final limit.

```text
Armor Penetration = clamp(Modified(0), 0, 100)
Effective target Armor = Full modified target Armor × (1 − Source Armor Penetration / 100)
Physical damage taken = Raw Physical damage × Critical multiplier × (1 − ArmorReduction(Effective target Armor))
```

**Limits:** minimum **0%**; maximum **100%**.

At 50% penetration, a target's 1,000 Armor is treated as 500 for that component, reducing mitigation from 75% to 60%. At 100%, effective Armor is zero. Penetration uses the full target rating before the Armor curve; it does not permanently change the target's attribute. Physical Attacks and Physical Spells use it; Magic components, Accuracy and attached modifier potency are unaffected. Add Flat 20 grants 20 percentage points of penetration.

### Fire Resistance

Fire Resistance reduces incoming **Fire magic damage**, from either an Attack or a Spell. Its base is **0%**, with no contribution from primary attributes. Flat bonuses add percentage points before increased and more modifiers.

```text
Fire Resistance = clamp(Modified(0), −100, 80)
Fire damage taken = Raw Fire damage × Critical multiplier × (1 − Fire Resistance / 100)
```

**Limits:** minimum **−100%**; maximum **+80%**.

At 50% Fire Resistance, a successful 100-damage Fire hit deals 50 damage. At −50%, it deals 150. Fire Resistance changes neither the hit's Accuracy nor its attached status effects' potency.

### Cold Resistance

Cold Resistance reduces incoming **Cold magic damage**, from either an Attack or a Spell. Its base is **0%**, with no automatic primary contribution. It applies only to Cold damage components.

```text
Cold Resistance = clamp(Modified(0), −100, 80)
Cold damage taken = Raw Cold damage × Critical multiplier × (1 − Cold Resistance / 100)
```

**Limits:** minimum **−100%**; maximum **+80%**.

Cold Resistance uses the same modifier order and damage multiplier as the other schools. It supplies no movement, speed or control-duration reduction.

### Lightning Resistance

Lightning Resistance reduces incoming **Lightning magic damage**, from either an Attack or a Spell. Its base is **0%**, with no automatic primary contribution. It applies only to Lightning damage components.

```text
Lightning Resistance = clamp(Modified(0), −100, 80)
Lightning damage taken = Raw Lightning damage × Critical multiplier × (1 − Lightning Resistance / 100)
```

**Limits:** minimum **−100%**; maximum **+80%**.

Lightning Resistance changes damage taken without introducing an automatic Lightning ailment or affecting critical chance.

### Void Resistance

Void Resistance reduces incoming **Void magic damage**, from either an Attack or a Spell. Its base is **0%**, with no automatic primary contribution. It applies only to Void damage components.

```text
Void Resistance = clamp(Modified(0), −100, 80)
Void damage taken = Raw Void damage × Critical multiplier × (1 − Void Resistance / 100)
```

**Limits:** minimum **−100%**; maximum **+80%**.

Void Resistance supplies damage reduction without adding Hollowed or changing resource regeneration by itself.

### Necrotic Resistance

Necrotic Resistance reduces incoming **Necrotic magic damage**, from either an Attack or a Spell. Its base is **0%**, with no automatic primary contribution. Necrotic is a distinct magic school; Fire, Cold and Lightning Resistance do not reduce it.

```text
Necrotic Resistance = clamp(Modified(0), −100, 80)
Necrotic damage taken = Raw Necrotic damage × Critical multiplier × (1 − Necrotic Resistance / 100)
```

**Limits:** minimum **−100%**; maximum **+80%**.

Necrotic Resistance follows the same limits and mitigation formula as the other schools. It does not restore Poison, periodic damage or a barrier mechanic.

## Current resources

### Health

Health is the character's remaining life. Damage removes current Health, and reaching zero means death.

```text
New Health = clamp(Current Health + Explicit Health change
                   + Health Regeneration × Elapsed seconds, 0, Maximum Health)
```

**Limits:** minimum **0**; maximum **current Maximum Health**.

Capacity modifiers affect Maximum Health rather than directly restoring this pool. Regeneration applies only while alive and cannot resurrect a character. Healing spells and Healing Power are not part of the current design; consumable behavior is not defined here.

### Stamina

Stamina is the current pool spent by actions with authored Stamina costs. Each action supplies its own cost; weapon speed does not create an additional implicit cost.

```text
New Stamina = clamp(Current Stamina + Explicit Stamina change
                    + Effective Stamina recovery rate × Elapsed seconds, 0, Maximum Stamina)
Activation requires Current Stamina ≥ Authored Stamina cost
```

**Limits:** minimum **0**; maximum **current Maximum Stamina**.

Stamina recovers while alive. Its effective recovery rate is zero while Sprint or Stamina Exhaustion is active and uses the Stamina Regeneration stat otherwise. Actions spend only their authored costs.

### Mana

Mana is the current pool spent by actions with authored Mana costs. A spell's Power coefficient and casting duration do not automatically determine its Mana cost.

```text
New Mana = clamp(Current Mana + Explicit Mana change
                 + Mana Regeneration × Elapsed seconds, 0, Maximum Mana)
Activation requires Current Mana ≥ Authored Mana cost
```

**Limits:** minimum **0**; maximum **current Maximum Mana**.

Mana regenerates periodically while alive, including during casting. A miss or resist does not refund the cost effect. Mana Efficiency is outside the foundation.

## Resource regeneration

The same flat-points-per-second rules apply to player and AI actors. Regeneration uses the ordinary flat, increased and more modifier pipeline and is independent of level, primary attributes and maximum resource capacity.

### Resource recovery

The startup Resource Regeneration effect executes periodically and restores Health and Mana while alive. It also restores Stamina outside active Sprint and Stamina Exhaustion. Ordinary spending above zero adds no delay. A positive-to-zero Stamina transition starts the exhaustion effect through an ability event. The effect asset owns the duration.

Each resource remains clamped to its maximum. Recovery beyond a full pool is discarded instead of saved for later. Changing a capacity or regeneration rate does not immediately refill the pool. No resource regenerates at zero Health, and Health Regeneration cannot resurrect an actor.

The runtime integrates fractional recovery over elapsed physics time. Attribute-change signals report actual resource changes; display rounding does not round the underlying recovery.

### Capacity and sustained use

Maximum Mana and Stamina provide reserves for bursts of activity. Regeneration determines sustained expenditure and recovery after spending.

```text
Average resource expenditure per second = Action cost / Time between uses
Sustainable cadence requires Regeneration ≥ Average expenditure
Time from empty to afford an action = Action cost / Regeneration
```

At zero regeneration, recovery through this mechanism is unavailable. The maximum pool must cover the full action cost. These equations assume recovery is active and the action's timing permits that cadence.

With base recovery, a 20-Mana action becomes affordable from empty after **4 seconds** and a 20-Stamina action takes **2 seconds** once recovery starts. A 20-Mana spell has a resource-limited sustained cadence of one cast every four seconds. At an 8–10% hit chance against a +10 target, that cadence produces one successful spell every **40–50 seconds on average** after the initial reserve, assuming uninterrupted opportunities.

Larger capacities take longer to refill at the same recovery rate. With 128 Intellect, a 690-Mana pool takes **138 seconds** to fill at 5/sec. With 128 Vitality, a 690-Stamina pool takes **69 seconds** at 10/sec once recovery resumes. Useful actions can resume as soon as their costs are affordable.

## Movement and sprinting

The base player grants Sprint, Jump, Crouch, Encumbered and Stamina Exhaustion. The caster adds Fireball. Locomotion can overlap combat casting. Movement and Crouch own physical execution.

Movement applies the effective Movement Speed bonus, one gait ratio and the encumbrance factor each step. **Movement → Settings → Movement Baseline → Normal Run Speed** defines the physical baseline at **4 m/s** by default. At a 6 m/s baseline, 0% Movement Speed gives 6 m/s and +20% gives 7.2 m/s before gait ratios. The shared rules JSON supplies the bonus default and bounds.

```text
Engine run speed = Settings.Normal Run Speed × max(0, 1 + Final Movement Speed bonus / 100)
Target horizontal speed = Engine run speed × Gait multiplier × Encumbrance speed factor
```

| Gait | Speed before encumbrance | At Movement Speed 0% and no overload |
| --- | --- | --- |
| Run | Engine run speed | 4 m/s |
| Walk | Engine run speed × Walk multiplier (0.5) | 2 m/s |
| Sprint | Engine run speed × Sprint multiplier (1.5) | 6 m/s |
| Crouch | Engine run speed × Crouch multiplier (0.6) | 2.4 m/s |
| Crouch walk | Engine run speed × Crouch multiplier × Walk multiplier | 1.2 m/s |

The +25% cap applies to the character bonus before gait multipliers. With the default 4 m/s baseline and 1.5 Sprint ratio, the maximum bonus produces 5 m/s running and 7.5 m/s sprinting at or below Carry Capacity.

**Movement → Settings** owns the physical gait settings. **Sprint → Execution → Upkeep Effect** links to GE_StaminaUpkeep. Its **Period** and **Stamina per Interval** default to **2 Stamina per 0.1 seconds** of actual grounded sprint travel with directional input. Movement preserves unpaid travel across pauses and activations. Idle, walking, crouching, blocked travel and falling add no chargeable time.

```text
Default Stamina cost per second of grounded sprint travel = 2 / 0.1 = 20
Starting endurance with 100 Stamina ≈ 5 seconds of grounded sprint travel
```

Active Sprint owns `State.Movement.Sprinting`. Jump lists this state as a blocker. Sprinting off a ledge preserves takeoff momentum, and air steering cannot accelerate above the normal air cap. Stamina recovery pauses throughout active Sprint, including while idle and airborne.

Hold Shift to request Sprint and release to end it. Sprint requires enough Stamina for its next full charge. A paid grounded charge that would leave a positive remainder smaller than the next full charge consumes that remainder in the same debit. Reaching zero triggers the timed Stamina Exhaustion effect. Releasing Sprint before that charge with Stamina left allows normal recovery. The same applies if a separate spend leaves a positive pool too small to afford the next charge. A fresh Shift press is required after an affordability failure or an interruption. The controller spends before ActorAttributes processes recovery once per physics tick.

## Encumbrance

At or below Carry Capacity the actor moves and jumps at the normal values for its gait. Above capacity, speed drops quickly and then tapers toward the floor, while jump height decreases linearly. **Movement → Settings → Encumbrance** owns the load ratio that reaches the full penalty and the speed multiplier at that load. Defaults are a **2× load ratio** and **0.5× speed**.

```text
Overload progress = clamp((Carried Weight / Carry Capacity − 1) / (Full penalty ratio − 1), 0, 1)
Speed factor = lerp(Minimum speed multiplier, 1, (1 − Overload progress)³)
Jump height factor = 1 − Overload progress
Target speed = Normal Run Speed × Movement Speed multiplier × Gait multiplier × Speed factor
Jump height = Authored gait jump height × Jump height factor
```

| Carried Weight at 100 capacity | Movement speed | Jump height | Default run | Default standing jump |
| ---: | ---: | ---: | ---: | ---: |
| 100 or less | 100% | 100% | 4 m/s | 1.5 m |
| 125 | 71.09% | 75% | 2.84 m/s | 1.125 m |
| 150 | 56.25% | 50% | 2.25 m/s | 0.75 m |
| 175 | 50.78% | 25% | 2.03 m/s | 0.375 m |
| 200 or more | 50% | 0% | 2 m/s | 0 m |

The speed factor applies to every gait after the Movement Speed bonus and gait ratio. Movement reads load and capacity live, so increasing Strength or removing weight immediately changes the target speed. Jump height is evaluated at takeoff and converted to launch velocity with `sqrt(2 × gravity × height)`. A zero height prevents takeoff. Changes to load during flight affect horizontal movement and apply to the next jump height.

Crossing above Carry Capacity sends a gameplay event that starts the granted **Encumbered** ability. That activation maintains the indefinite effect granting `State.Encumbered`. The **Sprint** ability declares this tag as both an activation blocker and an interruption. A sprint in progress stops spending sprint Stamina and falls back to ordinary gait selection. Returning to or below capacity sends the finish event, which removes the activation's effect instance. A fresh Shift press can sprint again if the usual requirements are met. The effect's debuff icon appears above the right side of the player HUD. [Gameplay event authoring](ability_system.md#gameplay-events)

## Accuracy and levels

**Implemented.** Attacks and spells use the same level-based success calculation. Accuracy can eliminate misses against enemies up to five levels higher. From a six-level disadvantage onward, progressively lower success ceilings keep much higher-level encounters dangerous even with substantial Accuracy investment.

### Level curve

The base column assumes **10 total Accuracy Rating**, already supplied by the starting governing primary. It does not describe every character without equipment: primary allocations also increase Accuracy.

| Enemy level minus attacker level | Base chance at 10 Accuracy | Maximum chance with sufficient Accuracy |
| --- | ---: | ---: |
| 0 | **80%** | **100%** |
| +1 | 75% | 100% |
| +2 | 68% | 100% |
| +3 | 60% | 100% |
| +4 | 50% | 100% |
| +5 | 40% | 100% |
| +6 | **24%** | **50%** |
| +7 | 18% | 35% |
| +8 | 14% | 25% |
| +9 | 11% | 16% |
| +10 | **8%** | **10%** |

The sharp change between +5 and +6 is intentional. These ceilings are explicit level restrictions; extra Accuracy cannot exceed them. They do not impose a cap on the Accuracy Rating attribute itself.

Against lower-level enemies, the base chance gains four percentage points per level of advantage, reaching 100% at five levels below the attacker. The maximum remains 100%.

Beyond a ten-level disadvantage, multiply both the base chance and ceiling by **0.75 for each additional level**. This continues the decline instead of preserving a 10% ceiling against every higher-level target.

```text
Level gap = Enemy level − Attacker level

For a negative level gap:
    Base chance = min(100, 80 − 4 × Level gap)
    Maximum chance = 100

For level gaps 0 through +10:
    Use the base and maximum percentages in the table.

For a level gap above +10:
    Base chance = 8 × 0.75^(Level gap − 10)
    Maximum chance = 10 × 0.75^(Level gap − 10)
```

At starting Accuracy, the chance is approximately 1.90% against +15 and 0.45% against +20. The corresponding ceilings are approximately 2.37% and 0.56%. The curve remains positive without a universal chance floor; very large gaps become practically prohibitive.

### Rating conversion

The required rating grows with attacker level and enemy level difference. The subtraction of 10 accounts for the rating already included in the base curve. All chance values in this calculation use percentages, such as 80 rather than 0.80.

```text
Rating scale =
    20 + 2 × (Attacker level − 1) + 10 × max(Level gap, 0)

Rating progress =
    clamp((Total applicable Accuracy Rating − 10) / Rating scale, −1, 1)

Final success chance = clamp(
    Base chance + (Maximum chance − Base chance) × Rating progress,
    0,
    Maximum chance
)
```

Accuracy below 10 reduces the base chance. Zero Accuracy still permits a natural chance to connect: the rating improves an existing chance rather than serving as the sole permission to hit. Additional rating raises the chance until the level-specific ceiling. Where base and maximum differ, **10 + Rating scale** is sufficient to reach that ceiling.

| Character and allocation example | Target | Success chance |
| --- | --- | ---: |
| Level 60, half the earned points in the governing primary and half in Vitality: 69 Accuracy | Level 60 | **88.6%** |
| Level 60, every earned point in the governing primary: 128 Accuracy | Level 60 | **97.1%** |
| The preceding character with +20 additional Accuracy: 148 total | Level 60 | **100%** |
| Level 50, every earned point in the governing primary: 108 Accuracy | Level 60 | **8.9%** |

These examples use the current primary contribution of one Accuracy per governing attribute point. They assign no item prices or affix budgets. A caster uses Intellect, a Finesse attack uses Dexterity, and a Brutality attack uses Strength.

### Action resolution

For collision-based delivery, the trace or projectile must first connect with a valid target. Resolve one Accuracy check for each delivered hit against that target; the hit's damage components and attached hostile effects share its outcome. Merely aiming correctly does not bypass the level check.

On success, resolve the payload: Armor reduces Physical components, and matching school resistance reduces Magic components. On failure, apply no hit damage or attached hostile effects. Attacks display **MISS** and spells display **RESIST**, using the same probability. There is no second independent spell-accuracy roll and no glancing damage. The RESIST label represents this level/Accuracy failure; Armor and school resistance are deterministic mitigation after a successful check.

A hostile control-only spell also requires the same check. Omitting damage from an ability cannot bypass the level restriction to apply a stun or other hostile status. Positive effects on the user or allies do not require this hostile-target check. Modifier-only self deliveries bypass it; modifier-only ally deliveries declare the authored `Ability.Beneficial` tag. A payload containing eligible damage still requires the check even with that tag. Direct explicit buff application is separate from hit delivery.

At an 8–10% chance, a successful hit takes an average of 10–12.5 connected attempts. Positioning and kiting provide more opportunities; they do not directly alter the probability. Spell resource availability remains a separate requirement for sustaining those attempts. The curve alone does not establish encounter or time-to-kill balance.

## Critical hits

Attacks and Spells use the same critical rules, regardless of damage school. After a successful Accuracy check, a damaging payload rolls Critical Chance **once**. All damage components share the result and the source's Critical Damage multiplier; attached modifier effects retain their authored potency. A modifier-only payload cannot crit.

```text
Critical multiplier = 1 on an ordinary hit
Critical multiplier = 1.50 + Critical Damage / 100 on a critical hit
Damage before defenses = Raw source damage × Critical multiplier
Final damage = Damage before defenses × Applicable defense multiplier
```

Armor, source Armor Penetration and matching school resistance work normally on critical damage. Criticals bypass none of these defenses. A failed Accuracy check produces MISS/RESIST and no critical damage. At 100% Critical Chance, every successful damaging hit is critical, while misses/resists remain possible.

| Critical Damage | Ordinary 100-damage hit | Critical before defenses | Critical against 50% matching resistance |
| --- | --- | --- | --- |
| 0 | 100 | 150 | 75 |
| 50 | 100 | 200 | 100 |
| 100 | 100 | 250 | 125 |
| 250 | 100 | 400 | 200 |

The current base Critical Chance is 0%; gear, talents, buffs or test modifiers supply it. Both attributes follow the normal modifier pipeline and support action scopes such as `Ability.Spell` or `Weapon.Finesse`. Critical rolls use the action context, so one school component cannot give a mixed hit a separate critical outcome. There is no critical-specific ailment rule in the current foundation.

Weapon variation, Accuracy and criticals use independent random streams. Each delivered hit, including each target, gets a fresh critical roll; inspecting attributes consumes no randomness. The explicit non-hit effect API does not roll a critical by itself. Damage events preserve pre-critical raw damage, the shared critical result/multiplier, mitigation and actual Health loss. F1 counts critical hits once per delivery; F2 identifies critical damage, and floating critical numbers are larger, yellow and animated.

All damage examples elsewhere in this document assume an ordinary hit unless stated otherwise. In their mitigation formulas, **Critical multiplier** is 1 for an ordinary hit.

## Armor and physical damage

Armor supplies deterministic Physical damage reduction after a hit passes Accuracy. It applies to melee, projectile and Spell delivery when the component's damage type is Physical. Each Physical component is reduced once; Magic components use their own school resistance instead.

The editable tuning specifies a **75% reduction cap** and **1,000 effective Armor at that cap**. Apply source penetration to the full target Armor first, then use the resulting rating in the curve:

```text
Reduction cap C = 0.75
Armor at cap T = 1000
Curve constant K = T × (1 − C) / C = 333.333…

Effective Armor = Full modified target Armor × (1 − Source Armor Penetration / 100)
Armor reduction = min(C, Effective Armor / (Effective Armor + K))
Physical damage taken = Raw Physical damage × Critical multiplier × (1 − Armor reduction)
```

With zero incoming penetration:

| Armor | Physical damage reduction | Damage taken from a successful 100-damage Physical component |
| ---: | ---: | ---: |
| 0 | 0% | 100 |
| 100 | 23.08% | 76.92 |
| 250 | 42.86% | 57.14 |
| 500 | 60% | 40 |
| 750 | 69.23% | 30.77 |
| 1,000 | **75%** | **25** |
| 1,500 | **75%** | **25** |

Each additional effective Armor point provides a smaller increase in the reduction percentage until the cap. Effective Health against Physical damage grows linearly before the cap, according to **1 + Effective Armor/K**, reaching **4× Health** at 75% reduction. This describes the curve's arithmetic; it does not establish overall build balance.

Armor rating itself is nonnegative and uncapped. Apply stat modifiers before this curve, preserving overcap values: 1,200 Armor minus a 300-point debuff leaves **900 Armor**, giving approximately **72.97% reduction**. Do not clamp the rating to 1,000 before applying a debuff.

The curve has no additional dependence on attack size, target Health or either actor's level. Armor and Armor Penetration modifiers may have explicit context scopes. Invalid curve tuning must not cause division by zero; the reduction cap must lie strictly between 0 and 1, and the rating at cap must be positive.

### Penetration before mitigation

Apply penetration after target Armor modifiers and before its reduction curve. It ignores a percentage of the Armor rating rather than subtracting percentage points from damage reduction. For a successful 100-damage Physical component against 1,000 Armor:

| Source Armor Penetration | Effective target Armor | Armor reduction | Damage taken |
| ---: | ---: | ---: | ---: |
| 0% | 1,000 | 75% | 25 |
| 25% | 750 | 69.23% | 30.77 |
| 50% | 500 | 60% | 40 |
| 75% | 250 | 42.86% | 57.14 |
| 100% | 0 | 0% | 100 |

Overcap Armor also protects against penetration: **2,000 Armor with 50% penetration leaves 1,000 effective Armor**, retaining the full 75% reduction. With 60% penetration it leaves 800 effective Armor, giving approximately 70.59% reduction. Do not clamp the target's rating to 1,000 before penetration.

All source penetration modifiers combine before the final 0–100% limit. Underlying overcap contributions remain available against later debuffs; effective penetration above 100% supplies no additional benefit. The calculation cannot create negative Armor or amplify Physical damage above its unmitigated magnitude.

Penetration is evaluated separately for each Physical component using the source's applicable modifiers and current target Armor. It leaves the target's Armor stat intact and supplies no persistent Armor-break effect. Detached projectiles retain cached source penetration values when their source is removed. Damage events distinguish full target Armor, source penetration, effective Armor and the resulting reduction. Magic components continue using only matching resistance. No additional random roll, Block or periodic-damage mechanic is added.

## Damage schools and resistances

Damage type, magic school and delivery are separate authored choices. **Physical** damage uses Physical Power and ignores the five magic resistances. **Magic** damage uses Magic Power and belongs to exactly one school: **Fire, Cold, Lightning, Void or Necrotic**. Either type can be delivered by an Attack or a Spell; that action classification selects the governing Accuracy and MISS/RESIST feedback.

After the whole hit passes its shared Accuracy check, each Physical component uses penetrated Armor and each Magic component uses its matching resistance. For example, a hit with 30 Physical damage and 20 Fire damage, zero source penetration, and a target with **500 Armor and 50% Fire Resistance** deals **12 + 10 = 22** damage. Armor and school resistance do not multiply together on the same component. Neither reduces attached buffs or control effects or introduces another success roll.

```text
Effective school resistance = clamp(Modified resistance, −100, 80)
Magic damage taken = Raw magic damage × Critical multiplier × (1 − Effective school resistance / 100)
```

| Matching resistance | Damage multiplier | Damage taken from a successful 100-damage component |
| --- | ---: | ---: |
| −100% | ×2.00 | 200 |
| −50% | ×1.50 | 150 |
| 0% | ×1.00 | 100 |
| +50% | ×0.50 | 50 |
| +80% | ×0.20 | 20 |

Resistance bonuses use native percentage points: **Add Flat 20** means +20 percentage points of the named resistance. Increased and more modifiers retain their normal meaning and multiply the signed foundation. For example, −50 Fire Resistance with 20% increased Fire Resistance becomes **−60**, before its final limit. Ordinary resistance bonuses should generally use Add Flat.

Apply limits after all modifiers. A character with 100 uncapped Fire Resistance and a −30 flat debuff has **70% effective Fire Resistance**, preserving the underlying overcap rather than subtracting from a prematurely capped 80%.

Effect resources retain the existing Physical/Magic damage-type identities and add an explicit **Magic School** selector. Its default is Fire, so pre-existing Magic effects without the new field resolve as Fire; the saved Fireball explicitly selects Fire. Authors choose the appropriate school for other magic effects. Physical components ignore that selector. No generic unresistable magic school is introduced.

An 80%-resistant target still takes 20% of a successful matching magic component. That is a normal hit with reduced damage, not a RESIST outcome. Actual Health loss, damage numbers and statistics reflect mitigation, with raw and resistance details available in damage event data.

## Weapons

A **weapon type** identifies its handling, role, governing attribute where applicable, shared talent tree and equipment restriction. An individual item supplies its explicit stat values. A model variation does not create another weapon type. Shield is a defensive weapon type within this same system.

### Unique-equipped rule

**At most one weapon of each type can be equipped at a time.** Different item names, explicit rolls, rarities and visual models do not bypass this rule. Multiple copies may be owned in the inventory and used as replacements.

| Combination | Result |
| --- | --- |
| Two one-handed swords | Not allowed: both are the same weapon type. |
| Two Orb of Power items | Not allowed: both are Orb of Power. |
| Two shields | Not allowed: both are Shield. |
| A Reliquary-model Relic and a Soul Lantern-model Relic | Not allowed: both are Relic. |
| A one-handed sword and a one-handed axe | Different types; compatible with this rule, subject to hand requirements. |

One-handed and two-handed entries are separate catalogue types. A two-handed weapon occupies both hands. Distinct types can be paired only when their hand requirements allow it; unique-equipped does not establish additional slot permissions.

## Physical weapons

Physical weapons provide normal attacks and authored attack combos. Their trees specialize those attacks through passive perks; **they do not unlock separate active abilities**. Bow attacks remain physical attacks despite using projectile delivery.

**Finesse** weapons use Dexterity. **Brutality** weapons use Strength.

| Weapon type | Classification | Delivery | Governing primary |
| --- | --- | --- | --- |
| One-handed dagger | Finesse | Melee | Dexterity |
| One-handed sword | Finesse | Melee | Dexterity |
| Two-handed sword | Finesse | Melee | Dexterity |
| Bow | Finesse | Projectile | Dexterity |
| One-handed mace | Brutality | Melee | Strength |
| One-handed axe | Brutality | Melee | Strength |
| Two-handed mace | Brutality | Melee | Strength |
| Two-handed axe | Brutality | Melee | Strength |

Every type has an authored physical minimum and maximum damage and a base attack cycle. Exact item values and weapon-family implicits are not assigned by this roster. Alternative visual models for these families will be designed later.

### Physical weapon damage

For an ordinary physical weapon attack, the default Power coefficient equals the **authored base attack cycle in seconds**.

```text
Physical damage range =
    Weapon physical damage range
    + Applicable final Physical Power × Base attack cycle in seconds
```

The Power contribution is added to both ends of the range. With 20 Physical Power:

| Base attack cycle | Power coefficient | Added physical damage per attack |
| --- | --- | --- |
| 0.5 seconds | 0.5 | +10 |
| 1 second | 1.0 | +20 |
| 2 seconds | 2.0 | +40 |

This normalizes the base Power contribution per second across weapon speeds. Attack Speed scales playback after the animation fits the weapon's authored base cycle. The damage coefficient remains based on that authored cycle.

Roll the weapon damage once per delivered hit and share that roll among the hit's weapon damage components. A new hit receives a new roll. Multi-component attacks divide the authored weapon contribution instead of automatically repeating the full weapon damage for every component.

### Bow shots

A bow shot is a **Finesse physical projectile attack**. Dexterity supplies its Physical Power and Accuracy Rating; there is no separate Ranged Power attribute.

Its coefficient uses the complete authored base cycle: preparation, draw, release and recovery. Projectile flight time and extra time holding an already drawn bow do not increase damage.

For example, a bow with **20–30 physical damage**, a **1-second base cycle**, and **20 applicable Physical Power** deals **40–50 raw physical damage** per ordinary shot. The working range rule is **no damage falloff**. Aiming, travel time and positioning remain relevant.

## Caster weapons

Caster weapons are casting implements governed by **Intellect**, outside Finesse and Brutality. They provide a usable starting spell and are the weapon types whose trees can unlock further active abilities. They do not receive a substitute physical melee attack.

| Weapon type | Domain | Current role |
| --- | --- | --- |
| Orb of Power | Elemental | Fire, Cold and Lightning spellcasting. |
| Talisman | Void | Void spellcasting. |
| Relic | Necromancy | Necromancy spellcasting, primarily Necrotic damage. |
| Fetish | Minions | Reserved for a future summoner system. |

Each type has the same starting spell and tree across its item copies. An item's explicit rolls change its stats; they do not assign a different starting spell or a different tree. Exact starting spells and individual tree nodes are future content choices.

The proposed caster weapons supply a **Magic Power range**, such as **5–12**, and a positive **Casting Speed factor**, such as **1.20×**. The [magic calculation](#magic-damage-and-casting) explains their relationship to Intellect and spell coefficients.

### Orb of Power

The Orb of Power is the caster weapon for the **elemental domain**, covering Fire, Cold and Lightning spells. These schools share Magic Power and Intellect scaling. The Orb of Power tree defines the elemental choices available to its user. Alternative models and weapon implicits are not assigned yet.

### Talisman

The Talisman is the caster weapon for the **Void domain**. Its starting spell and later active unlocks belong to the shared Talisman tree. It uses the same Magic Power and casting rules as the other caster families. Alternative models and weapon implicits are not assigned yet.

### Relic

The Relic is the caster weapon for **necromancy**, primarily dealing **Necrotic damage**. It is a small held object from which the spell can visibly originate. Every Relic uses the **same Relic talent tree**, starting spell and gameplay rules.

**Visual alternatives**

The following ten objects are alternative **visual models of Relic**. A model can require a suitable grip, presentation gesture and spell emitter, but it does not create its own talent tree, spell list, implicit bonus or equipment identity.

**Reliquary.** A palm-sized vessel in a metal or bone frame, containing ashes, a preserved fragment or a trapped wisp. Magic gathers behind its front aperture and releases through it as the character presents the vessel toward the target.

**Soul Lantern.** A small lantern or cage holding restless spectral light. The light gathers inside and releases through the front opening. A short rigid handle keeps the object compact and gives the hand a stable casting grip.

**Soul Crystal.** An angular dark crystal with energy moving within it. The character grips its base; the charge travels toward the exposed tip, where the spell forms and releases.

**Funeral Candle.** A short black candle in a small metal holder, carrying a spectral flame. The flame bends toward the target while smoke and energy gather immediately above it before release.

**Grave Nail.** A large ancient iron nail marked with inscriptions. Held between the fingers or in a loose grip, it gathers magic at its point. The casting gesture raises and directs the point toward the target.

**Bone Wand.** A short carved piece of bone, tooth or horn. Energy follows its carvings toward the tip, providing a clear spell origin with a small directing gesture.

**Miniature Urn.** A small funerary vessel containing ashes or spectral smoke. Wisps emerge from its mouth, gather into the spell, and release as the character tilts or presents the urn.

**Hand Censer.** A compact incense vessel with a fixed grip and patterned openings. Smoke emerges through the openings and forms the spell just ahead of the object. Its presentation does not depend on a dangling chain.

**Death Knell Bell.** A small worn handbell with an ornate handle. A brief ringing gesture directs its mouth toward the target, and the spell releases as a spectral pulse from the opening.

**Soul Key.** An oversized elaborate key associated with the dead. The character turns it in the air; energy gathers around its teeth or tip and releases toward the target.

### Fetish

The Fetish is reserved for the future **minion or summoner domain**. Its established visual representation is a **skull**. Minion attributes, summon behavior and the Fetish's concrete active abilities are outside the current combat foundation. No alternative Fetish models are assigned here.

## Shields

A **Shield is a defensive weapon type**, with its own shared **Shield talent tree** that enhances blocking. It follows the same unique-equipped rule and character progression ownership as the other weapon types. Replacing a shield preserves the character's Shield-tree progression.

**Equipment slot:** off-hand only, on the **left arm**.

The Shield's role is blocking. A governing primary, shield statistics, blocking formulas and individual talent nodes are not assigned by this classification; those require their own design. Shield is not yet represented in the live weapon catalogue, and blocking is not implemented.

## Weapon talent trees

The character has **one shared progression tree per weapon type**. All items of that type refer to it. Replacing a sword with a better sword preserves Sword progression; replacing one Relic model with another preserves Relic progression. Items differ through explicit stats rather than individual talent trees.

Unique-equipped removes the former idea of equipping two copies of the same type to specialize further. The shared tree remains useful across replacements and owned copies; duplicate equipment grants no additional tree access.

Physical attack weapon trees improve the normal attacks and combos. The Shield tree enhances blocking. Caster weapon trees can offer passive effects and active ability grants within their domain. **Selected Perk** is the working name for the choice prepared from a weapon's unlocked perks.

### Perk selection working proposal

The current proposal is **one selected perk per equipped weapon**. A physical attack weapon selects a passive that modifies its ordinary attacks. A Shield's selected perk enhances blocking. A caster may select a passive or an active ability grant. A passive selection keeps its starting spell usable; an active selection prepares the granted spell in place of the starting spell.

This selection model is a proposal within the weapon-tree design. Talent costs, node layouts, respec rules, exact hand/input bindings and interactions between two different equipped caster weapons have not been assigned by the agreed rules.

## Magic damage and casting

The caster weapon supplies a Power range and a casting factor. Intellect supplies flat character Magic Power. The spell supplies its authored base damage, Power coefficient and base cast duration.

### Magic Power range and damage

```text
Flat Magic Power range =
    2 × Intellect + Other applicable flat Magic Power
    + Caster weapon Magic Power range

Final Magic Power range =
    Flat Magic Power range
    × max(0, 1 + Sum of increased percentages / 100)
    × Product of max(0, 1 + Each more percentage / 100)

Raw spell damage = Spell base damage + Rolled final Magic Power × Spell coefficient
```

Final Magic Power cannot fall below zero. Apply the same applicable modifiers to both ends of the displayed range.

With **10 Intellect**, **no other bonuses**, and a caster weapon supplying **5–12 Magic Power**, the Power range is **25–32**. With zero spell base damage:

| Spell coefficient | Raw spell damage range |
| --- | --- |
| 1.0 | **25–32** |
| 1.5 | **37.5–48** |
| 2.0 | **50–64** |

A combined **50% increased Magic Power** raises **25–32** Power to **37.5–48**, before the spell coefficient.

Roll the weapon's Power contribution **once per delivered hit**, uniformly between minimum and maximum, and share it across that hit's damage components. Separate hits, including deliveries to separate targets, receive separate rolls. Attribute inspection and range calculation do not reroll damage. Keep fractions internally and round presentation as needed.

The weapon range provides ordinary spell variation. There is **no additional ±10% spell-spread roll**. These examples assume one caster weapon; combining the base Power ranges of two different caster weapons is not an established rule.

### Proposed caster weapon timing factor

The equipment proposal gives a caster weapon a factor such as **1.20×**. Each spell retains its own authored timing. The table illustrates the proposed weapon factor in isolation.

```text
Cast duration = Spell base cast duration / Applicable weapon Casting Speed factor
```

| Base spell duration | Casting Speed | Resulting duration |
| --- | --- | --- |
| 1 second | 1.20× | **Approximately 0.833 seconds** |
| 2 seconds | 1.20× | **Approximately 1.667 seconds** |

The proposed factor is finite and positive. This document does not establish how it combines with the live character Cast Speed bonus or its playback cap.

The formula describes a single caster weapon's action. A policy for selecting or combining clocks in a two-caster loadout remains outside the agreed design. The earlier main-weapon/Focus rule and independent bare-handed learned-spell model are superseded by the current weapon-domain/tree direction.

The live character Cast Speed bonus is described under [Attack Speed and Cast Speed](#attack-speed-and-cast-speed).

## Design and implementation status

| Area | Current status |
| --- | --- |
| Four primaries and twenty-six other attributes | Implemented, including action and movement speed, criticals, mitigation and regeneration. |
| Level 60 and allocation defaults | Implemented as editable tuning. |
| Shared attack/spell Accuracy curve and level ceilings | Implemented, with shared payload outcomes and MISS/RESIST feedback. |
| Health/Mana/Stamina Regeneration | Uncapped rates of 0/5/10 points/sec. Active Sprint and Stamina Exhaustion pause Stamina recovery. |
| Movement Speed and sprinting | Signed movement bonus, grounded travel charges, retained travel credit, Sprint jump blocker and timed Stamina Exhaustion. |
| Encumbrance | Movement and jump height penalties and the sprint lockout start above capacity. F3 supplies test load and shows live penalties. |
| Five magic schools and matching resistances | Implemented; each resistance defaults to 0%, with −100%/+80% final limits. |
| Armor | Implemented; nonnegative, uncapped rating gives diminishing Physical reduction, capped at 75% from 1,000 effective Armor after penetration. |
| Critical Chance and Critical Damage | Implemented; chance 0–100%, 150% base critical damage, nonnegative uncapped bonus. One critical outcome per successful damaging hit. |
| Armor Penetration | Implemented; 0–100% source percentage ignores that share of full target Armor before the reduction curve. |
| Physical weapon min/max damage and base cycle | Implemented, including Finesse/Brutality scaling and bow delivery. |
| Magic Power | Fixed character value implemented; weapon min/max contribution is design only. |
| Attack Speed and Cast Speed | Implemented as 0–100% character bonuses, sampled on activation. Fireball's cast bar follows its authored release key. |
| Caster weapon timing factor | Equipment design proposal. |
| Orb of Power, Talisman, Relic and Fetish catalogue | Current design; live code still names the earlier ritual dagger, scepter, staff and focus families. |
| Shield weapon type and blocking talent tree | Current design; Shield is not in the live weapon catalogue and blocking is not implemented. |
| Inventory, equipment slots and unique-equipped enforcement | Design only. Prototype actions are listed in Granted Abilities. |
| Shared weapon trees, starting spells and active unlocks | Design only. Playground actions are explicit test grants. |
| Selected Perk behavior | Working proposal, not an implemented selection system. |
| Relic visual alternatives | Ten described models; no models or casting animations have been created by this documentation update. |

The live Playground grants Fireball directly as its combat ability. Fireball uses Magic damage in the Fire school. Its saved impact effect uses base damage 5 and a 1.0 coefficient, giving **25 raw damage** at starting Intellect. A successful hit deals 25 at 0% Fire Resistance, 5 at 80%, or 50 at −100%, subject to remaining Health. The impact effect owns damage tuning and the ability owns cost and cooldown.

The live catalogue excludes Minion and Healing Power. Level-damage multipliers, Dodge, Block, Absorption and automatic ailments remain outside the prototype.

See the [implementation reference](combat_system.md), [ability authoring guide](ability_system.md) and [architecture](architecture.md) for the live project. Historical Python tools and reports use a frozen pre-2.0 model and cannot validate current 2.0 gameplay.
