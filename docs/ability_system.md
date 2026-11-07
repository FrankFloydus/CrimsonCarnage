# Combat 2.0 ability authoring

The Godot project follows Unreal's single-player GAS authoring model. Attributes and ability behavior live in GDScript. Designers configure ability definitions, Gameplay Effects and animation release keys in saved Godot assets. The [Combat 2.0 implementation](combat_system.md) records the RPG-specific rules. [Epic Gameplay Effects](https://dev.epicgames.com/documentation/en-us/unreal-engine/gameplay-effects-for-the-gameplay-ability-system-in-unreal-engine)

## Actor setup

Compose an actor with `ActorAttributes` and `AbilitySystem`. Assign the attribute component, animation player, aiming/spawn origins, source physics body and unlocked abilities in the Inspector. If the explicit attribute reference is empty, AbilitySystem resolves its actor's sibling node named `Attributes` during `_ready()`; it never creates a second component. An explicit valid reference takes precedence. Player input and AI both call `try_activate(ability_id)`.

Attributes own base and current values, allocations, aggregation and clamping. The ASC grants abilities, owns counted tags and active effects, and runs ability activations. `GameplayAbilitySpec` represents one grant with its own handle, level and source. `AbilityCast` represents one running use. Use handle-based activation and revocation for multiple grants of a definition. The named prototype input can continue using ability IDs.

Use **AbilitySystem → Granted Abilities** for the actor's starting ability list. The base player lists Sprint, Jump, Crouch, Encumbered and Stamina Exhaustion. The Playground caster adds Fireball. Every action uses the same eligibility, cost and lifecycle checks. LMB or F requests the combat ability selected in F3. Fireball grants and blocks on `State.CombatAction`. Locomotion abilities can overlap the cast. Animation events go to the activation that started playback. Use `release_ability(ability_id)` or `cancel_ability(ability_id)` to address a held action.

Use **AbilitySystem → Startup Effects** for the actor's initialization effects, in application order.

| Effect | Policy | What to edit |
| --- | --- | --- |
| [GE_DefaultAttributes](../combat/effects/ge_default_attributes.tres) | Instant | Base primaries, capacities and recovery rates in Modifiers. |
| [GE_AttributeDerivations](../combat/effects/ge_attribute_derivations.tres) | Infinite | Source attribute and coefficient in each of its five Modifiers. Changes to the captured target attribute propagate while the effect is active. |
| [GE_ResourceRegeneration](../combat/effects/ge_resource_regeneration.tres) | Infinite, periodic | Period sets the recovery cadence. The execution reads the current rate for each pool and scales it by the period. |

The ASC fills the starting pools after applying the startup effects. The retained startup handles survive clearing transient combat effects and death. Recovery is inhibited while dead and resumes on revival. To tune the math bounds and level curves, edit [combat_rules.json](../combat/combat_rules.json).

## Gameplay events

Send a tagged event with `ability_system.send_gameplay_event(event_tag, payload)` on the receiving actor. The payload is an optional `Dictionary`. Author **Activation Event Tag** on a granted ability to start it from an event, or leave it blank for direct input and AI activation. A trigger matches the configured tag and its descendants. An event can start multiple matching grants, each subject to its ordinary activation checks. A grant already active when dispatch begins receives the event through its execution and cannot restart from that same delivery.

An event-started execution reads `cast.trigger_event_tag` and `cast.trigger_event_payload` in `begin()`. Override `handle_gameplay_event()` to react to further events while active. The execution can call `cast.finish()` when its work is complete. Events sent from an event handler are delivered in order after the current dispatch. Use data values for payloads. Each receiver gets a copy of its nested arrays and dictionaries, and any object references retain their identity.

For asynchronous steps in a GDScript ability, connect the task's signals and call `cast.start_task(task)`. Use `AbilityTaskWaitDelay`, `AbilityTaskWaitGameplayEvent`, `AbilityTaskWaitInputRelease` or `AbilityTaskPlayAnimationAndWait`. A task belongs to its activation and tears down when the cast ends. `send_gameplay_event()` reaches the receiving actor's waiters and triggered grants. An animation method key reaches only its playback owner's waiters. **Cancel Ability Tags** cancels matching active abilities, and **Block Ability Tags** blocks matching ability asset tags for the activation's lifetime.

For a sustained condition, add an `AttributeGameplayEventRule` under the actor's **Attributes → Gameplay Event Rules**. Choose the value and threshold attributes and author an enter and exit event tag. It compares final unscoped values using strict `>` and publishes on crossing the boundary, including initial entry if already above. It evaluates again on revival and after a retained effect clear settles. A newly granted listener can join an already active threshold. Other gameplay events are delivered as they occur. Keep a response's own modifiers from reversing the condition that controls its lifetime.

For Encumbered, **Carried Weight > Carry Capacity** sends `Event.Carry.Overloaded` and returning to or below capacity sends `Event.Carry.WithinCapacity`. The first event triggers the [granted Encumbered ability](../player/abilities/encumbered.tres). The running `MaintainEffectExecution` listens for the second through **Execution → End on Event Tag** and finishes when it arrives. The execution applies the [Encumbered effect](../player/encumbered_effect.tres), owns the handle and removes that instance on end, cancel, revoke, death or teardown. If a clear removes the effect while the activation is still active, the execution restores its owned instance. The effect grants `State.Encumbered`. Sprint declares that tag in its Blocked Tags and Interruption Tags.

**Commit Effects** accepts an instant Cost Effect with additive current-pool debits and a finite Cooldown Effect that grants its cooldown tag. Author debits as negative magnitudes. Fixed, target-attribute and Set By Caller magnitudes use the same calculation for the affordability check and commit. The active tag gates future activation, and the retained effect supplies the remaining duration. Abilities commit on activation by default. A code execution can opt to call `cast.commit()` at a later step. An ongoing cost has its own effect and lifetime.

## Locomotion abilities

**Sprint** uses held Shift and owns `State.Movement.Sprinting` while active. It declares `State.Encumbered` in **Blocked Tags** and **Interruption Tags**. In **Sprint → Execution → Upkeep Effect**, open [GE_StaminaUpkeep](../player/ge_stamina_upkeep.tres) and tune **Period** and **Executions → Stamina per Interval**. The defaults charge 2 Stamina per 0.1 seconds of grounded sprint travel with input. Sprint owns one retained upkeep handle and removes it when the activation ends. Movement preserves unpaid travel time across pauses and activations. An interval of actual travel satisfies the effect's ongoing tag requirement and executes a charge. When a paid charge would leave less than the next full charge, the debit consumes that remainder and triggers exhaustion. Releasing Shift with Stamina left allows ordinary recovery. A blocked or interrupted Sprint requires a fresh press.

**Jump** lists `State.Movement.Sprinting` in its **Blocked Tags**. When eligible, Jump requests one takeoff through Movement, using support or coyote time and the effective jump height. **Crouch** requests a stance through the crouch component, which keeps `State.Crouched` tied to the actual capsule. Releasing crouch in hold mode asks to stand and waits for clearance if the ceiling blocks the request.

The ASC publishes `Event.Stamina.Depleted` when Stamina crosses from positive to zero. The ordinarily granted [Stamina Exhaustion action](../player/abilities/stamina_exhaustion.tres) applies its [timed effect](../player/stamina_exhausted_effect.tres) and finishes. Tune the delay in the effect's **Duration**. Sprint and the exhaustion effect each own `State.Stamina.RecoveryBlocked` for their lifetime. `GE_ResourceRegeneration` reads this tag on each execution and skips Stamina only. Active Sprint therefore pauses recovery even when stationary or falling. Health and Mana continue recovering while alive.

## Attribute modifiers

Create `AttributeModifier` resources in a Gameplay Effect. Use the actor's Initial Modifiers for actor-specific foundations such as the test dummy's maximum Health.

| Operation | Meaning |
| --- | --- |
| Add Flat | Adds native stat units to the flat foundation. |
| Increased Percent | Adds to the combined increased pool after flat contributions. |
| More Percent | Multiplies independently; 20 means ×1.20. |
| Set Base | Overrides the full derived foundation before other flat/percentage modifiers. |
| Add to Derived Base | Adds a live contribution as part of the foundation. An explicit foundation override replaces it. |

Required/excluded context tags scope a modifier. For example, `Weapon.Finesse` selects Finesse attacks and `Ability.Spell` selects spells. Damage effects provide `Damage.Physical` or `Damage.Magic`, `Damage.Direct`, and the matching Magic school tag such as `Damage.Fire`. The authored damage fields determine those identities. Use `ActorAttributes.set_modifiers(owner, modifiers)` and `remove_modifiers(owner)` for removable gear/buff contributions.

Instant and periodic modifiers can change current pools and intrinsic bases. Retained modifiers contribute while their effect is active. For a live target attribute magnitude, choose **Capture Attribute** and **Capture Coefficient**. Use **Set By Caller Tag** for a magnitude supplied on a runtime spec. Capacity increases preserve current amounts. The Playground's Restore controls explicitly reset pools for testing.

Regeneration modifiers target Health Regeneration, Mana Regeneration or Stamina Regeneration in points per second. Starting rates are 0/5/10 respectively. Add Flat supplies a rate. Increased Percent and More Percent scale that rate through the normal pipeline. A positive percentage alone leaves the zero Health Regeneration foundation at zero. The rates are uncapped and independent of primaries and capacity. The player pauses Stamina recovery only during active Sprint or Stamina Exhaustion.

Hostile hit payloads resolve one shared Accuracy check before damage or attached modifier effects. Modifier-only self deliveries bypass the check; author positive modifier-only ally deliveries with `Ability.Beneficial`. An eligible damage effect still requires Accuracy even with that tag. Use direct `effects.apply_effect()` for explicit non-hit buffs. Target-required/blocked tags remain validation gates.

Fire, Cold, Lightning, Void and Necrotic Resistance are target attributes in percentage points, starting at 0%. Add Flat 20 means +20 points of that resistance. Final values clamp to −100%..+80% after all modifiers; negative values amplify matching damage. Increased and More retain the normal signed-stat calculation, so ordinary resistance bonuses generally use Add Flat.

Armor is a target rating, starting at 0. Add Flat 100 grants 100 rating; increased and More modifiers scale it before conversion to Physical reduction. The rating is nonnegative and uncapped. Reduction follows `min(0.75, Effective Armor / (Effective Armor + 1000/3))`, giving 60% at 500 effective Armor and 75% at 1000. Physical effects use it automatically, including Physical Spells; Magic effects use only their matching school resistance. Armor changes neither hit chance nor attached modifier potency. The F3 effective Armor tooltip shows reduction before incoming penetration.

Armor Penetration is an outgoing source percentage starting at 0%, clamped to 0–100% after ordinary modifiers. Add Flat 20 grants 20 percentage points. The hit treats target Armor as `Full Armor × (1 − Source Penetration / 100)` before the curve, without changing the target's stat. At 50%, 1000 Armor becomes 500 effective Armor; at 100%, Armor is fully ignored for the Physical component. Magic damage and Accuracy are unchanged. A penetration modifier can be scoped to particular actions using the existing context tags.

## Movement modifiers

Movement Speed is a **bonus percentage**, default 0%, minimum −100% and maximum +25%. Add Flat 1 grants +1% movement; Add Flat 20 grants +20%. A gear property reading +20% Movement Speed therefore uses Add Flat 20 native percentage points. Increased Percent and More Percent scale the accumulated bonus: +20 flat and 20% increased produce +24%; a percentage modifier alone leaves zero at zero. This is the same bonus-stat convention as Critical Damage above its 150% baseline.

The bonus receives no primary/level contribution. Initial Modifiers or retained buffs can target it; every gait follows the final multiplier `max(0, 1 + bonus/100)` immediately. The physical baseline is **Normal Run Speed** under **Movement → Settings → Movement Baseline**, default 4 m/s. It defines normal movement before the bonus and gait multipliers. F3 shows the bonus, 0% normally. Identity 54 is retained; old identity 27 stays inactive.

Use F3 to edit Player or Dummy Movement Speed. The player movement component references the same live attributes, while the stationary dummy stores the stat for inspection. In the player Inspector, **Movement → Settings** exposes Normal Run Speed and Walk/Sprint/Crouch multipliers. Default ratios are 0.5/1.5/0.6, with crouch-walk combining Walk and Crouch.

## Action speed modifiers

Choose **Attack Speed** or **Cast Speed**. The stats store bonus percentage points above normal playback. Add Flat 20 and Add Flat 30 combine to +50%, or 1.5× playback. Effective values clamp to 0–100%. Increased Percent and More Percent, when explicitly authored through the generic modifier operations, scale the stored bonus. The animation multiplier is 1 + effective bonus / 100.

A cast samples its action-scoped speed at activation and keeps that value through release and recovery. Spells use Cast Speed. Attacks use Attack Speed, applied after any weapon-cycle normalization. Cooldown uses its own authored duration. The effective speed readout in F3 uses percentages, and its sliders can expand above +100% to exercise the cap.

## Critical modifiers

Choose **Critical Chance** or **Critical Damage** in an inline AttributeModifier. Critical Chance starts at 0% and clamps to 0–100% after all modifiers. Add Flat 25 supplies 25 percentage points. Critical Damage starts at 0 bonus percentage points and has no upper cap; Add Flat 50 changes criticals from 150% to 200% damage. Increased Percent and More Percent scale the bonus stat, so a percentage alone does not raise a zero foundation. Neither stat receives an automatic primary contribution.

Scope critical modifiers to an action through tags such as `Ability.Spell` or `Weapon.Finesse`. One critical roll is made after a damaging hit passes Accuracy; its Physical and Magic components share the result and multiplier, then resolve their usual defenses. Damage-school tags do not select separate critical rolls. Attached modifiers keep their normal potency. Direct non-hit effect application does not roll criticals. No critical-specific effect must be added to Fireball or another ability.

## Fireball example

[Fireball](../examples/fireball/fireball.tres) uses `Ability.Spell`, the shared `ProjectileCastExecution` and a saved projectile scene. The execution starts a gameplay event wait and plays the animation with `AbilityTaskPlayAnimationAndWait`. The animation method key calls `handle_animation_event("Event.Combat.ProjectileRelease")`. Move that key to the release pose when changing the animation. The cast bar uses the key and actual playback position. If the cast ends before release, the bar disappears without a projectile.

The caster scene authors a **ProjectileOrigin** Marker3D. Fireball's **Aim Trace Distance** defaults to 100 m in its ability asset. The camera trace supplies an aim point, the marker supplies the launch position and the projectile scene owns flight. Cover between the camera and origin blocks a launch from the far side. Move the marker to adjust the origin or move the method key to adjust release timing.

The standalone [Fireball Impact](../examples/fireball/fireball_impact.tres) effect owns the Instant Magic damage in the **Fire** school, with a damage execution calculation. At release the ability prepares an outgoing spec and gives it to the projectile. The target ASC receives that spec on collision, resolves the hostile hit and applies the damage on success. The saved effect has base damage 5 and Power Coefficient 1.0. Starting 10 Intellect supplies 20 Magic Power, for 25 raw damage. Starting spell Accuracy is 10, which gives an 80% success chance against an equal-level target and 8% against +10. A failed check displays RESIST. The [Mana cost](../examples/fireball/ge_fireball_cost.tres) and [cooldown](../examples/fireball/ge_fireball_cooldown.tres) are separate effects on the ability definition. Mana Regeneration continues during casting.

For another magic effect, select Damage Type **Magic**, then choose Magic School **Fire, Cold, Lightning, Void or Necrotic**. The selector defaults to Fire for existing resources; choose the intended school explicitly. Physical effects ignore that field. A Magic component on an Attack uses the matching resistance and retains Attack Accuracy/MISS feedback. An 80% school resistance reduces damage deterministically and does not display the Accuracy-failure RESIST outcome.

Fireball applies no Burn, ailment, debuff, periodic effect or delayed damage. Its name and projectile appearance do not trigger hidden gameplay. With no other authored modifier effects, the target retains no effect instance after impact.

The per-effect coefficient is editable test authoring. A general spell-rank or spell-progression system is outside this foundation.

The [caster design](combat_system_2_0.md#caster-weapons) now places starting spells and further active unlocks in shared weapon-type trees for Orb of Power, Talisman, Relic and the future Fetish. Weapon types are unique-equipped. These catalogue, equipment and progression rules are design only; the explicit grants described here remain the live authoring workflow.

The proposed [caster calculation](combat_system_2_0.md#magic-damage-and-casting) describes weapon Magic Power ranges and a weapon-specific timing factor. The playable Fireball uses its engine-native authored animation and the live character Cast Speed bonus.

## Gameplay Effects and specs

Choose **Instant** for a single execution, **Duration** for a finite effect, and **Infinite** for an effect whose owner removes it explicitly. Add modifiers for attribute changes and calculation resources for custom executions. Set **Period** for a retained effect that executes on a cadence. Application requirements gate the initial application. Ongoing requirements inhibit an active effect while the tags do not match, and the period inhibition policy controls when it ticks again.

Use `cast.make_effect_spec(effect)` or `AbilitySystem.make_outgoing_spec()` to prepare an application. Write per-application parameters through `set_by_caller_magnitude()`. Apply the spec to an ASC directly, or deliver the outgoing spec through the projectile hit path. A retained effect owns its active handle, modifiers, duration and counted tags. Remove the exact handle when its owner is finished.

**Stacking** defaults to independent applications. Choose aggregate by source or target to group repeated applications of the same effect asset. Tune the stack limit, overflow, duration refresh, periodic reset and expiration policies on the definition. A grouped effect keeps one handle and one set of granted tags. Its modifiers use the active stack count.

**Components** add reusable application rules. Chance to Apply rolls once at application. Immunity filters incoming effect asset tags while active. Additional Effects applies authored child effects on a successful application. Remove Effects removes other instances by asset tag. Block Abilities gates matching ability tags while active. Grant Ability owns a grant handle and can remove it immediately, remove it after its active cast ends, or leave the grant in place. Use the base `GameplayEffectComponent` for a custom application rule in code.

**Gameplay Cue Tags** dispatch presentation events for activation, execution and removal. Set up the cue's `GameplayCue.*` tag on the effect, then bind it to a saved presentation scene in **AbilitySystem → Gameplay Cue Bindings**. Its root implements `handle_gameplay_cue(target, tag, event, parameters)`. Impact cues can use the projectile's hit position and normal. Keep attribute changes in modifiers and executions.

Set **Icon** to a Texture2D and **HUD Category** to **Buff** or **Debuff** to show a retained instance above the player resource bars. **None** leaves it off the HUD. Buffs grow from the left and debuffs from the right. The display follows active instances, including independently expiring copies of the same effect.

Use `MaintainEffectExecution` on a granted action when an Infinite effect should last for that action's lifetime. In **Execution → Effect**, assign the resource. Set the effect's Granted Tags for the states it publishes. Author the resulting activation restrictions on the consuming ability.

Use `AbilitySystem.remove_active_effect(handle)` to remove a specific application. Use `clear_transient_effects()` for combat resets that preserve startup effects.

## Testing

Run the main [playground](../levels/playground/playground.tscn). Choose an action and drag the whole-point primary sliders in the left F3 pane. The right character sheet displays hit chance and the normal-hit damage against the dummy. Hover the readouts to inspect the Accuracy Rating and Power used in the calculations. F1 opens measured hits and damage in Statistics. F2 toggles the combat log. R restores the dummy during gameplay. The Player tab’s ellipsis menu includes Restore resources.

Accuracy uses the implemented [attack/spell level curve](combat_system_2_0.md#accuracy-and-levels). Test a level-1 caster against a level-11 dummy at 10 Accuracy to observe an 8% predicted chance and RESIST feedback. At equal level, setting Accuracy to 30 reaches 100%. For resistance testing, keep that guaranteed chance and change the dummy's Fire Resistance through 0, 80 and −100 to observe 25, 5 and 50 damage with the saved Fireball configuration. Other schools do not change Fireball damage. F1/F2 count outcomes separately from damage. Set positive Health Regeneration and damage the dummy to observe periodic recovery. No resource recovers at zero Health. Use Restore to revive a test actor. Target level and maximum Health do not multiply successful damage.

For a guaranteed critical test, keep equal levels, set source Accuracy to 30 and source Critical Chance to 100 in F3. With source Critical Damage 0, target Fire Resistance 0 and the saved Fireball effect, a critical deals **37.5** from 25 raw damage. Critical Damage 50 raises it to **50**, and Critical Damage 150 raises it to **75**. At Fire Resistance 80, those criticals deal 7.5/10/15. Restore the dummy as needed to avoid remaining Health clipping the result. F1 counts critical deliveries, F2 marks critical damage, and floating numbers use the critical animation. Setting Critical Chance back to 0 restores ordinary hits without changing source Power.

For action-speed testing, set Player **Cast Speed** to +50% in F3 and activate Fireball. Its animation runs at 1.5×, and the cast bar disappears on the release key. At +100% the rate reaches 2×. Drag to the right edge and release to expand the slider and test higher raw values. The effective sheet stays at +100%.

For movement testing, set Player Movement Speed to +25% in F3. Every gait targets 25% above its default, subject to carry load. Hold Shift and move on level ground to see 2 Stamina spent per 0.1 seconds of actual grounded travel. Idle and blocked travel cost nothing. Stamina remains paused while Sprint is active. With 3 Stamina and a 2-point charge, the first paid interval consumes all 3. The resulting zero starts the authored exhaustion delay. Jump is blocked while Sprint is active. Release Shift to jump or to start a fresh Sprint after recovery.

For encumbrance testing, set **Carried Weight** in F3. At 100 Carry Capacity and weight 150, the Player sheet shows **−43.75%** movement speed and **−50%** jump height under **Carry load**. The Encumbered icon appears on the right above the HUD bars. Sprint is unavailable above capacity. Weight 200 gives half speed and prevents jumping with the default settings. Return to 100 or below and press Shift again to sprint. At a load within capacity, cast Fireball while sprinting to exercise both lifecycles.

Every Inspector export and active attribute has tooltip documentation. All gameplay authoring assets are saved editable files; no desktop interaction is required for headless checks.
