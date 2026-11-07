# Combat 2.0 ability authoring

The live project uses the [Combat 2.0 foundation](combat_system.md) with thirty code-defined attributes. Numeric defaults and limits live in [combat_rules.json](../combat/combat_rules.json).

## Actor setup

Compose an actor with `ActorAttributes` and `AbilitySystem`. Assign the attribute component, animation player, aiming/spawn origins, source physics body and unlocked abilities in the Inspector. If the explicit attribute reference is empty, AbilitySystem resolves its actor's sibling node named `Attributes` during `_ready()`; it never creates a second component. An explicit valid reference takes precedence. Player input and AI both call `try_activate(ability_id)`.

Attributes own allocations, current resources and owned modifiers. AbilitySystem owns casts, cooldowns, counted tags and effect delivery. Shared Resource assets contain authored data; per-cast state belongs to `AbilityCast`.

Use **AbilitySystem → Granted Abilities** for the actor's starting ability list. The base player lists Sprint, Jump, Crouch, Encumbered and Stamina Exhaustion. The Playground caster adds Fireball. Every action uses the same eligibility, cost and lifecycle checks. LMB or F requests the combat ability selected in F3. Fireball grants and blocks on `State.CombatAction`. Locomotion abilities can overlap the cast. Animation events go to the activation that started playback. Use `release_ability(ability_id)` or `cancel_ability(ability_id)` to address a held action.

## Gameplay events

Send a tagged event with `ability_system.send_gameplay_event(event_tag, payload)` on the receiving actor. The payload is an optional `Dictionary`. Author **Activation Event Tag** on a granted ability to start it from an event, or leave it blank for direct input and AI activation. A trigger matches the configured tag and its descendants. An event can start multiple matching grants, each subject to its ordinary activation checks. A grant already active when dispatch begins receives the event through its execution and cannot restart from that same delivery.

An event-started execution reads `cast.trigger_event_tag` and `cast.trigger_event_payload` in `begin()`. Override `handle_gameplay_event()` to react to further events while active. The execution can call `cast.finish()` when its work is complete. Events sent from an event handler are delivered in order after the current dispatch. Use data values for payloads. Each receiver gets a copy of its nested arrays and dictionaries, and any object references retain their identity.

For a sustained condition, add an `AttributeGameplayEventRule` under the actor's **Attributes → Gameplay Event Rules**. Choose the value and threshold attributes and author an enter and exit event tag. It compares final unscoped values using strict `>` and publishes on crossing the boundary, including initial entry if already above. It evaluates again on revival and after a retained effect clear settles. A newly granted listener can join an already active threshold. Other gameplay events are delivered as they occur. Keep a response's own modifiers from reversing the condition that controls its lifetime.

For Encumbered, **Carried Weight > Carry Capacity** sends `Event.Carry.Overloaded` and returning to or below capacity sends `Event.Carry.WithinCapacity`. The first event triggers the [granted Encumbered ability](../player/abilities/encumbered.tres). The running `MaintainEffectExecution` listens for the second through **Execution → End on Event Tag** and finishes when it arrives. The execution applies the [Encumbered effect](../player/encumbered_effect.tres), owns the handle and removes that instance on end, cancel, revoke, death or teardown. If a clear removes the effect while the activation is still active, the execution restores its owned instance. The effect grants `State.Encumbered`. Sprint declares that tag in its Blocked Tags and Interruption Tags.

**Activation Cost** commits once after validation. Author ongoing costs on the execution that defines their timing and eligibility. The ASC tracks cooldowns separately.

## Locomotion abilities

**Sprint** uses held Shift and owns `State.Movement.Sprinting` while active. It declares `State.Encumbered` in **Blocked Tags** and **Interruption Tags**. Open **Sprint → Execution** to tune **Stamina per Charge** and **Charge Interval**. The defaults charge 2 Stamina per 0.1 seconds of grounded sprint travel with input. Movement reports that travel and preserves unpaid time across pauses and activations. The execution checks affordability of the full charge before Sprint starts. When a paid travel charge would leave a positive amount below the next full charge, it spends that remainder in the same debit. Stamina reaches zero through the shared resource API and starts exhaustion. Releasing Shift with Stamina left ends Sprint without the exhaustion delay. After affordability failure or an interruption, a fresh press is required.

**Jump** lists `State.Movement.Sprinting` in its **Blocked Tags**. When eligible, Jump requests one takeoff through Movement, using support or coyote time and the effective jump height. **Crouch** requests a stance through the crouch component, which keeps `State.Crouched` tied to the actual capsule. Releasing crouch in hold mode asks to stand and waits for clearance if the ceiling blocks the request.

The ASC publishes `Event.Stamina.Depleted` when Stamina crosses from positive to zero. The ordinarily granted [Stamina Exhaustion action](../player/abilities/stamina_exhaustion.tres) uses TimedSelfEffectExecution to apply its [timed effect](../player/stamina_exhausted_effect.tres) and finish. Tune the delay in the effect's **Duration**. The saved Godot effect uses two seconds. The effect grants `State.Stamina.Exhausted`. The base controller authors **Stamina Regeneration Blocked Tags** for both Sprint and Stamina Exhaustion. The Playground caster inherits that list from the base controller. An active Sprint pauses Stamina recovery even when stationary or falling. Health and Mana continue recovering while alive.

## Attribute modifiers

Create inline `AttributeModifier` resources in an actor's Initial Modifiers or a retained modifier effect.

| Operation | Meaning |
| --- | --- |
| Add Flat | Adds native stat units to the flat foundation. |
| Increased Percent | Adds to the combined increased pool after flat contributions. |
| More Percent | Multiplies independently; 20 means ×1.20. |
| Set Base | Overrides the full derived foundation before other flat/percentage modifiers. |

Required/excluded context tags scope a modifier. For example, `Weapon.Finesse` selects Finesse attacks and `Ability.Spell` selects spells. Damage effects provide `Damage.Physical` or `Damage.Magic`, `Damage.Direct`, and the matching Magic school tag such as `Damage.Fire`. The authored damage fields determine those identities. Use `ActorAttributes.set_modifiers(owner, modifiers)` and `remove_modifiers(owner)` for removable gear/buff contributions.

Persistent modifiers cannot target current resources. `modify_current()` changes current pools; capacity increases do not refill them. The playground's Restore controls explicitly reset pools for testing.

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

[Fireball](../examples/fireball/fireball.tres) uses `Ability.Spell`, the shared `ProjectileCastExecution` and a saved projectile scene. Its animation method key calls `handle_animation_event("release")`. Keep this key on the release pose. The release key sets the base windup on the Godot animation asset. The Godot execution reads the key and actual playback position for the cast bar. If a cast ends before release, the bar disappears without a projectile.

The caster scene authors a **ProjectileOrigin** Marker3D. Fireball's **Aim Trace Distance** defaults to 100 m in its ability asset. The camera trace supplies an aim point, the marker supplies the launch position and the projectile scene owns flight. Cover between the camera and origin blocks a launch from the far side. Move the marker to adjust the origin or move the method key to adjust release timing.

The standalone [Fireball Impact](../examples/fireball/fireball_impact.tres) effect owns the Instant Magic damage in the **Fire** school. The shared execution passes the authored impact payload to the projectile at release. A successful hit applies it through the target ASC. The saved effect has base damage 5 and Power Coefficient 1.0. Starting 10 Intellect supplies 20 Magic Power, for 25 raw damage. Base damage and coefficient remain editable in the effect. Starting spell Accuracy is 10, which gives an 80% success chance against an equal-level target and 8% against +10. A failed check displays RESIST. The ability authors Mana cost and cooldown, and Mana Regeneration continues during casting.

For another magic effect, select Damage Type **Magic**, then choose Magic School **Fire, Cold, Lightning, Void or Necrotic**. The selector defaults to Fire for existing resources; choose the intended school explicitly. Physical effects ignore that field. A Magic component on an Attack uses the matching resistance and retains Attack Accuracy/MISS feedback. An 80% school resistance reduces damage deterministically and does not display the Accuracy-failure RESIST outcome.

Fireball applies no Burn, ailment, debuff, periodic effect or delayed damage. Its name and projectile appearance do not trigger hidden gameplay. With no other authored modifier effects, the target retains no effect instance after impact.

The per-effect coefficient is editable test authoring. A general spell-rank or spell-progression system is outside this foundation.

The [caster design](combat_system_2_0.md#caster-weapons) now places starting spells and further active unlocks in shared weapon-type trees for Orb of Power, Talisman, Relic and the future Fetish. Weapon types are unique-equipped. These catalogue, equipment and progression rules are design only; the explicit grants described here remain the live authoring workflow.

The proposed [caster calculation](combat_system_2_0.md#magic-damage-and-casting) describes weapon Magic Power ranges and a weapon-specific timing factor. The playable Fireball uses its engine-native authored animation and the live character Cast Speed bonus.

## Retained modifier effects

Use Kind Modifiers with Timing Duration for explicit buffs. Assign stat modifiers and optional counted tags. A positive Duration expires after that many seconds; zero remains until removed. The runtime returns an independent handle for each accepted instance. Removing an instance reverses only its owned modifiers and tags.

Set **Icon** to a Texture2D and **HUD Category** to **Buff** or **Debuff** to show a retained instance above the player resource bars. **None** leaves it off the HUD. Buffs grow from the left and debuffs from the right. The display follows active instances, including independently expiring copies of the same effect.

Use `MaintainEffectExecution` on a granted action when one indefinite modifier effect should last for that action's lifetime. In **Execution → Effect**, assign a Duration modifier effect with Duration `0`. Set the effect's Granted Tags for the states it publishes, and edit the consuming abilities' tag requirements to control their responses.

Use `remove_effect(handle)` or `clear()` for cleanup. No automatic ailment family, proc chance, periodic tick, strongest-instance rule or refresh/replace policy is added.

## Testing

Run the main [playground](../levels/playground/playground.tscn). Choose an action and drag the whole-point primary sliders in the left F3 pane. The right character sheet displays hit chance and the normal-hit damage against the dummy. Hover the readouts to inspect the Accuracy Rating and Power used in the calculations. F1 opens measured hits and damage in Statistics. F2 toggles the combat log. R restores the dummy during gameplay. The Player tab’s ellipsis menu includes Restore resources.

Accuracy uses the implemented [attack/spell level curve](combat_system_2_0.md#accuracy-and-levels). Test a level-1 caster against a level-11 dummy at 10 Accuracy to observe an 8% predicted chance and RESIST feedback. At equal level, setting Accuracy to 30 reaches 100%. For resistance testing, keep that guaranteed chance and change the dummy's Fire Resistance through 0, 80 and −100 to observe 25, 5 and 50 damage with the saved Fireball configuration. Other schools do not change Fireball damage. F1/F2 count outcomes separately from damage. Regeneration is continuous; set positive Health Regeneration and damage the dummy to observe its bar recover. No resource recovers at zero Health; use Restore to revive a test actor. Target level and maximum Health do not multiply successful damage.

For a guaranteed critical test, keep equal levels, set source Accuracy to 30 and source Critical Chance to 100 in F3. With source Critical Damage 0, target Fire Resistance 0 and the saved Fireball effect, a critical deals **37.5** from 25 raw damage. Critical Damage 50 raises it to **50**, and Critical Damage 150 raises it to **75**. At Fire Resistance 80, those criticals deal 7.5/10/15. Restore the dummy as needed to avoid remaining Health clipping the result. F1 counts critical deliveries, F2 marks critical damage, and floating numbers use the critical animation. Setting Critical Chance back to 0 restores ordinary hits without changing source Power.

For action-speed testing, set Player **Cast Speed** to +50% in F3 and activate Fireball. Its animation runs at 1.5×, and the cast bar disappears on the release key. At +100% the rate reaches 2×. Drag to the right edge and release to expand the slider and test higher raw values. The effective sheet stays at +100%.

For movement testing, set Player Movement Speed to +25% in F3. Every gait targets 25% above its default, subject to carry load. Hold Shift and move on level ground to see 2 Stamina spent per 0.1 seconds of actual grounded travel. Idle and blocked travel cost nothing. Stamina remains paused while Sprint is active. With 3 Stamina and a 2-point charge, the first paid interval consumes all 3. The resulting zero starts the authored exhaustion delay. Jump is blocked while Sprint is active. Release Shift to jump or to start a fresh Sprint after recovery.

For encumbrance testing, set **Carried Weight** in F3. At 100 Carry Capacity and weight 150, the Player sheet shows **−43.75%** movement speed and **−50%** jump height under **Carry load**. The Encumbered icon appears on the right above the HUD bars. Sprint is unavailable above capacity. Weight 200 gives half speed and prevents jumping with the default settings. Return to 100 or below and press Shift again to sprint. At a load within capacity, cast Fireball while sprinting to exercise both lifecycles.

Every Inspector export and active attribute has tooltip documentation. All gameplay authoring assets are saved editable files; no desktop interaction is required for headless checks.
