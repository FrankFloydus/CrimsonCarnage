# Composable abilities and effects

All saved ability grants use the phase runner on the actor's `AbilitySystem` and single `ActorAttributes` node. Combat still uses the game's Combat 2.0 Accuracy, Critical Chance, Armor, penetration, and school resistances. The same runner invokes the focused movement actions and drives [Fireball](../examples/fireball/fireball.tres) in the Playground.

The [fixture guide](ability_v2_fixtures.md) walks through saved Blood Lash and Crimson Bolt recipes. The [coverage report](ability_v2_coverage.md) separates the capabilities exercised here from the reference mechanics that still need an adapter or acceptance test. [World service contracts](ability_world_services.md) covers the optional link, threat, pet and resurrection integrations.

## Author and grant an ability

1. Create an `AbilityDefinition` with a stable ability ID and display name. Use **Phased Ability Execution**. Save the resource and put it in **AbilitySystem → Granted Abilities** or give it to the actor through `grant_ability_spec()`.
2. Choose the cast mode and initial targeting. Choose Immediate, Delay, Animation, Hold Release, Channel, or Sustained. For Animation, author the method-track event that releases the ability. For Channel, specify both a duration and a pulse period. For Sustained, author the event or domain action that ends the cast. An explicit Single target comes from `try_activate_target(ability_id, target)`. An ordinary direct request uses `try_activate(ability_id)`.
3. Choose a delivery and add ordered phases. Phases listen to a named lifecycle, delivery, animation, or gameplay event. Add target selection and conditions where needed, then add reusable actions. **Apply Effects** can deliver a shared hostile hit or apply a standalone effect. For a hostile hit, put its damage and attached statuses into the same action to share one Accuracy and one direct critical result.
4. Set **Commitment** and **Interruption**. Choose a resource pool and amount for each cost. Use one charge and set its recharge time for a standard cooldown. Add a reaction on the ability for an execution-wide rule, or on a payload effect for a response to that payload's outcomes.
5. Run the resource validator with the ability and its related assets. Actor-specific validation still checks scene references, eligible targets and animation when activation is requested.

The Inspector shows the fields that apply to the selected mode. Switching modes keeps the hidden values in the resource. They take effect again when you return to a mode that uses them.

| Resource | Inspector responsibility |
| --- | --- |
| `AbilityDefinition` | Stable identity, activation tags and event trigger, execution, costs, cooldown, interruption, reactions |
| `PhasedAbilityExecution` | Cast mode, duration, animation release event, initial targeting, activation conditions, delivery and ordered phases |
| `AbilityTargetingDefinition` | Origin, geometry, range, faction, life-state filters, line of sight, and explicit target limit |
| `AbilityDeliveryDefinition` | Direct, hitscan, projectile, area burst, field, aura, trap, beam or chain delivery, with authored timing and ownership |
| `AbilityPhaseDefinition` | Event key, optional target override, ordered conditions and actions, failure and repeat policy |
| `GameplayEffectDefinition` | Lifetime, period, terminal tick, stacking, modifiers, executions, independent status profile, owned behaviors and presentation |
| `AmountDefinition` | Fixed amount, stat or pool percentage, rank or level curve, outcome amount, paid resource receipt, accumulator, stacks, or unique count |
| `ReactionDefinition` | Trigger, recipient, timing, delivery and provenance filters, scope, fire limit and reusable reaction actions |

Ability conditions can check actor tags, life state, and current or fractional resource pools. Live faction filters use the target's **Faction ID** and the source's **Hostile Factions**. Actors with different factions outside that list are neutral. Area targeting considers registered AbilitySystems in the same world, so it counts an actor once even if it owns multiple collision shapes. A disk uses a horizontal radius plus explicit vertical tolerance. A ray uses physics geometry. A deliberate **Max Targets** limit is a separate balance decision.

Use **Activation Conditions** to test the caster or an explicit Single target before reservation and again at release. For a trap or field, use **Point** targeting with a terrain collision mask and author **Maximum Surface Slope**. Placement validation runs before release commitment. An aura follows its caster and tracks occupant entry and exit. For **Chain**, choose a Single or Ray initial target, then author a Contact-centered Sphere for the hops. The chain visits the nearest eligible actor it has yet to reach, up to **Chain Hops**. The contacts share one attack identity.

A channel can deliver a projectile on each pulse. An authored **Spend Resource** action on `ability.channel_tick` can pay per pulse. Set that phase's failure policy to **Cancel Cast** to stop before an unpaid pulse. Use **Apply Effects → Owned Until Cast Ends** for an independently stacked direct effect that the cast should remove on any end path. Use **Dispel** to remove selected retained effects with the casting actor as the dispel instigator.

## Execution, control and payment

`AbilityCast` owns one activation and weakly refers to its actor and explicit target. `AbilityDefinition` and its nested resources are shared templates. The actor reserves typed costs and available charges at activation and can commit cost and cooldown separately at start or release. If a delayed cast becomes unaffordable before release, commitment fails. The paid amounts in `ResourceSpendReceipt` are available to outgoing payloads, including detached ones. Cancelling releases reservations and keeps already paid costs and spent charges unless the policy authorizes a refund. A charge refund applies to the specific spent charge while it is still recharging.

Charge pools belong to an actor and can be shared by group when their profiles agree. Pools support sequential or parallel recharge. One ability grant still allows one active cast at a time. Channels with the same occupied name exclude each other unless both policies list that channel as compatible. Cast movement can be allowed, locked, or configured to cancel on movement intent during windup or a channel.

Activation blockers and cancel-on-tags are separate. `State.Control.Rooted` and `State.Control.Stunned` stop the first-person controller's horizontal movement and takeoff. Sprint and Jump consume both tags in their own definitions. Fireball blocks and cancels on `State.Control.Silenced` and `State.Control.Stunned`. Root leaves its windup intact. A cast can opt into an activation exception for a specific blocker. Explicit interrupt actions report which executions stopped and lock the schools those executions reported. Death and teardown cancel active casts. Detached deliveries follow their own lifetime policy.

## Effects, outcomes and amounts

An instant effect executes and returns. Duration and infinite effects own an active handle, counted tags, modifiers and their own behavior state. Set Period, Execute Periodic On Application, Tick At End and stacking fields together. A retained effect can snapshot its source at application while evaluating the target's defenses at each tick. A retained status profile has its own immunity, application chance, and optional resistance basis for chance, duration, or magnitude. Use separate damage and status effects if their application or removal must be independent.

`receive_hit_specs()` groups one contact and its payload. A confirmed contact can report zero Health damage when a barrier absorbs the full packet. An immune or deflected contact has its own outcome. `CombatOutcomeDispatcher` queues committed outcomes and resolves reactions after the surrounding batch. It preserves a root execution ID across projectiles, ticks and reaction children. Attack, contact, tick, and parent event identity have separate fields. Scoped reactions can run once per event, per target per execution, per attack, or per execution. Direct, periodic and channel timing are independent of copy, reflection and transfer provenance.

For an amount, select a source and basis in the Inspector. Percentages use percentage points, so **10** means ten percent. A missing receipt, result basis, actor or snapshot fails evaluation. The healing resolver applies healing rules and reports requested, restored and overheal amounts. Mana and Stamina use signed pool transactions. An ordinary heal requires a living recipient. **Snapshot Toggle** can restore selected pools and an optional body transform for a living actor. Transform restore checks range, world and collision. Effect transfer requires explicit opt-in and migrates supported runtime state, including remaining barrier budget, under the selected duration cap.

The Inspector shows the controls used by the selected source, cast mode, delivery, and effect settings. For **Amount → Fixed**, edit the fixed amount and its unit. Turn on **Clamp Enabled** to show its bounds. Inactive values remain stored and return when you switch back to a mode that uses them.

## Trace and verification

Use **F2** in the Playground to inspect activation failures, reservations, paid costs, phase and target batches, damage and prevention, rejected statuses and cleanup. Matching cast IDs group detached events. Parent event IDs relate a reaction to the committed outcome that caused it. Runtime callers can inspect effect handles and owned state through `AbilitySystem.effects.get_active_effects()`. Seed weapon, Accuracy, critical and application streams with `AbilitySystem.configure_randomness(seed_value)`. Headless tests advance isolated fixtures directly or use a fixed 60 Hz game loop. The trace records event order and helps reproduce a seeded run. There is no general replay file reader.

The baseline is **Godot 4.7.stable.official.5b4e0cb0f, Windows x86-64**. Use the console executable with `--headless`. The project declares Godot 4.7 features. Other platforms and earlier engine builds were outside this verification.

## Restore boundary

An enclosing save system can record each authored ability ID with the clocks returned by `capture_charge_recharge()`. Restore compatible clocks with `restore_charge_recharge()` on an idle actor. Cancel in-flight casts, reservations and detached scene deliveries when replacing a scene or loading a save. Pet records expose a separate persistence API. Active effects and other transient world service records are session state. `invalidate_session_effects_for_restore()` clears transient effect state while preserving the supplied startup handles. General save/load orchestration and stable identity across discarded scene representations belong to the owning game services.
