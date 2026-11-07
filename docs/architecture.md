# Project architecture

This is the master reference for the project's code architecture. Keep it aligned with the implementation and the project-wide rules in [AGENTS.md](../AGENTS.md). Record what exists and why; clearly label proposals until the user accepts them and they are implemented.

## Game direction

A first-person RPG inspired by the spirit of *The Elder Scrolls V: Skyrim*, with action RPG elements inspired by *Diablo*. Individual mechanics and system designs are decided through requested work.

## Combat design status

[Combat 2.0 game design](combat_system_2_0.md) is the current design reference. The [implemented foundation](combat_system.md) contains thirty active attributes and describes damage, action speed, resources and locomotion. Starting progression values are editable working defaults.

The current [weapon design](combat_system_2_0.md#weapons) proposes unique-equipped types and one shared character talent tree per type. Shield is an off-hand defensive weapon with its own proposed tree. The proposed caster families are Orb of Power (elemental), Talisman (Void), Relic (necromancy/Necrotic) and the future Fetish (minions). Relic has ten described visual alternatives. The prototype uses fixed character Magic Power, authored animations and the live Cast Speed attribute. Caster weapon Power ranges, weapon-specific timing, the new families and equipment rules are proposals.

The implemented [Accuracy and level curve](combat_system_2_0.md#accuracy-and-levels) uses the same check for attacks and spells. It allows 100% through a five-level disadvantage with sufficient rating, then applies lower ceilings, reaching an 8% base and 10% maximum at +10. Failed payloads display MISS/RESIST. Health/Mana/Stamina Regen are uncapped rates starting at 0/5/10 points/sec. Active Sprint and Stamina Exhaustion pause only Stamina recovery.

The implemented [school resistances](combat_system_2_0.md#damage-schools-and-resistances) cover Fire, Cold, Lightning, Void and Necrotic, with a 0% base and −100%/+80% final limits. Matching resistance deterministically multiplies successful Magic damage by 1 − resistance/100. It applies to Magic components of either Attacks or Spells and leaves Physical damage and modifier potency unchanged.

Implemented [Armor](combat_system_2_0.md#armor-and-physical-damage) starts at 0 rating and reduces Physical components through a diminishing-percentage curve, capped at 75% from 1,000 effective Armor after source penetration. The rating itself stays uncapped and preserves overcap contributions against debuffs and penetration. The curve uses no hit-size or level factor and does not stack Armor with school resistance on one component.

Source Armor Penetration is implemented as a 0–100% percentage, defaulting to zero. It acts on the target's full modified Armor before the reduction curve and leaves the target's attribute unchanged. At 50%, 1,000 Armor becomes 500 effective Armor; 2,000 becomes 1,000 and still reaches the 75% cap. Physical Attacks and Physical Spells use it, while Magic components and Accuracy ignore it.

Critical Chance/Damage are implemented as source action-scoped attributes with stable IDs 14/15. Chance starts at 0% and clamps to 0–100%; Critical Damage starts at 0 bonus percentage points, is nonnegative and uncapped, and adds to the base 150% multiplier. AbilitySystem owns an independent critical RNG stream; a successful damaging payload resolves one shared result before component defenses. Runtime contexts carry that result without modifying shared Resources. Telemetry preserves pre-critical raw magnitude and the critical multiplier; F1 counts once per critical delivery, F2 marks critical damage, and floating numbers animate criticals. Modifier-only and explicit non-hit effect operations introduce no critical roll.

[Movement Speed and sprinting](combat_system_2_0.md#movement-and-sprinting) use the actor's effective Movement Speed bonus (−100% to +25%, ID 54), gait ratios and live encumbrance factors. Movement Settings owns the physical Normal Run Speed baseline. Sprint execution owns its 2 Stamina / 0.1 s grounded-travel charge. Movement retains unpaid travel across activations. The Sprint state blocks Jump and pauses Stamina regeneration. A positive-to-zero Stamina crossing triggers the authored Stamina Exhaustion effect through the ordinary granted ability.

## Current implementation

The first playable scene is a prototype playground with a composed first-person controller.

| Area | Current state |
| --- | --- |
| Project configuration | `project.godot`; project name: `untitled` |
| Engine configuration | Godot `4.7.stable.official.5b4e0cb0f` verified locally; project declares `4.7` features |
| Rendering | Forward Plus; Windows rendering driver: D3D12 |
| 3D physics | Jolt Physics |
| Entry point | `levels/playground/playground.tscn` |
| Authored gameplay | First-person player scene with movement/look/crouch components and a runtime gait helper, editable tuning resources, prototype grid materials, and collision parkour course with crouch tunnels |
| Combat foundation | Thirty code-defined attributes, action and movement speed, sprint upkeep, encumbrance, regeneration, shared attack/spell Accuracy, owned/scoped modifiers, weapon profiles, explicit abilities/effects, counted tags, and a saved damage-dummy arena. [Combat system](combat_system.md) · [Ability authoring](ability_system.md) |
| Shared runtime services | No autoloads configured |
| Native code | No C++ plugin or GDExtension integration |
| Automated tests | Focused headless controller, combat formula, attribute authoring, delivery, and effect/animation checks in `tests/`; Python simulator regression checks; no external Godot test framework |

## Architectural principles

Apply these principles to the work at hand without introducing infrastructure in anticipation of future features:

- **Focused components:** compose entity behavior from small, understandable parts. Keep the entity's coordinating logic limited to what it needs.
- **Editor value determines scene exposure:** expose a behavior component as a scene node when it provides meaningful editor authoring or tuning value. Keep logic-only components internal to their owner, as with the controller's gait helper. Give each tuning concern one clear Inspector owner; see [component authoring conventions](godot_conventions.md#scene-components-and-internal-helpers).
- **Data-driven definitions:** store authored content and tuning in editable resources or another suitable data format. Let behavior consume that data.
- **Editable scene composition:** save authored scene structure, UI, and resource configuration in project files. Use runtime logic for behavior, scene instantiation, and genuinely procedural requirements.
- **Events where suitable:** communicate meaningful changes through signals when that simplifies dependencies. Do not introduce an event framework when direct, local communication is sufficient.
- **Task-sized architecture:** add boundaries and abstractions because the current implementation benefits from them. Composition does not require building a generic component framework.
- **Approved native work:** computationally heavy logic belongs in a focused C++ plugin when appropriate, with a small GDScript interface and prior user approval.

See [Godot conventions](godot_conventions.md) for authoring, naming, folder organization, export documentation, and engine references.

## Current file organization

| Location | Purpose |
| --- | --- |
| `README.md` | Project overview, setup instructions, and version-control conventions |
| `AGENTS.md` | Project-wide agent instructions and links to supporting documents |
| `docs/architecture.md` | This master architecture document |
| `docs/combat_system_2_0.md` | Combat game design: individual attribute descriptions/formulas, progression, unique-equipped weapon types, shared trees, caster domains, Relic models and implementation status |
| `docs/godot_conventions.md` | Godot authoring and coding conventions |
| `project.godot` | Godot project configuration |
| `player/` | Reusable first-person scene, focused behavior components, and editable tuning resources; [scoped instructions](../player/AGENTS.md) |
| `materials/prototype/` | World-space grid shader and reusable prototype materials |
| `references/first_person_arms/` | Single-arm T-pose reference PNGs and generation prompts: weathered palm-facing and back-of-hand studies, alternate skin appearance, inferred top/hand-end-on side camera studies, and legacy iterations. Generated references are not verified renders of shared geometry or unwrapped UV maps; no mesh or rig implemented |
| `levels/playground/` | Main movement/combat scene, authored course/environment, Player, Dummy, and saved CombatTestTools UI under `testing/` |
| `tests/` | Headless controller, attribute, weapon, effect, ability, and direct-damage feedback checks |
| `combat/` | Attribute/tag/ability/effect/hit-delivery code and shared numeric rules JSON; [scoped instructions](../combat/AGENTS.md) |
| `examples/fireball/` | Reusable direct-damage Fireball/projectile, dummy, and damage presentation used by the main playground |
| `tools/combat_simulator/` | Seeded CLI balance experiments, provisional scenarios, frozen reports, and the offline Tk/NumPy Combat Lab under `lab/`; [scoped instructions](../tools/combat_simulator/AGENTS.md) |
| `icon.svg` | Initial project icon |
| `.gitignore` | Excludes generated caches, credentials, temporary files, and export outputs |
| `.gitattributes` | Normalizes text files to LF line endings |
| `.godot/` | Godot-generated local editor and import data |

Create additional gameplay folders when the corresponding work is requested. Keep related scenes, scripts, and resources easy to find, following the folder conventions.

## First-person controller

Entry scene: [`player/first_person_controller.tscn`](../player/first_person_controller.tscn).
This is a `CharacterBody3D` composed with Movement, Crouch, Look, ActorAttributes and AbilitySystem. The caster scene inherits this composition and configures its Granted Abilities and animation bindings. The shared grants include Sprint, Jump, Crouch, Encumbered and Stamina Exhaustion. The caster also grants Fireball.

| Part | Responsibility |
| --- | --- |
| `first_person_controller.gd` | Routes input to the granted Sprint, Jump and Crouch abilities, then coordinates stance and one movement step. It runs at physics priority −10 before automatic attribute regeneration at 0. Released mouse capture supplies zero input and releases held sprint while braking and gravity continue. |
| `Crouch` / `first_person_crouch.gd` | Owns actual stance, an instance-specific capsule, standing-volume clearance, and the saved eye pivot's smooth height transition. Resolves collision stance before movement and advances visual height each render frame. |
| `first_person_gait.gd` | Per-controller helper for effective run, walk, sprint, crouch and crouch-walk selection. Actual stance and walk input can temporarily override a held sprint. |
| `Movement` / `first_person_movement.gd` | Owns movement settings, live gait speed, physical jump feasibility, actual sprint travel reporting, velocity, gravity, coyote time, stair support and the single `move_and_slide()` call. Sprint and Jump executions authorize their movement requests. `move(delta, input, gait)` advances the simulation and defaults to running. |
| `Attributes` / `ActorAttributes` | Owns the player's live stats and resources, including Movement Speed and Stamina; inherited by the caster scene rather than duplicated. |
| `AbilitySystem` | Registers the actor's Granted Abilities. Owns per-ability lifetimes and counted tags. Routes tagged gameplay events to granted and active abilities. Evaluates the actor's authored attribute event rules at threshold crossings. |
| `first_person_stair_stepper.gd` | Per-movement `RefCounted` helper that verifies capsule stair clearance and retains terrain contacts for one physics frame. |
| `Look` / `first_person_look.gd` | Captures/releases the mouse, rotates body yaw and local eye pitch, smooths lateral camera roll, and compensates stair height changes with a camera spring. Releases the pointer on application focus loss. |
| `Look/Camera3D` | Saved first-person camera at a standing eye height of 1.62 m, with 80-degree FOV. Crouch changes the `Look` pivot height; camera roll and stair translation remain independent of eye pitch and body yaw. |
| `CollisionShape3D` | Saved standing capsule, 1.8 m tall and 0.35 m in radius. The body origin is at the feet; crouch preserves its bottom while resizing. |

Movement is the sole component referencing [`default_movement_settings.tres`](../player/default_movement_settings.tres),
typed by `FirstPersonMovementSettings`. Select **Movement > Settings** in the player scene's Inspector
for gait ratios and movement physics. The resource owns Normal Run Speed (4 m/s), Walk/Sprint/Crouch multipliers
(0.5/1.5/0.6), encumbrance thresholds, standing/crouched jump heights, separate
ground/air acceleration and deceleration, gravity, coyote time, maximum stair
height, and maximum walkable slope. Gravity is independent of
`physics/3d/default_gravity`; launch velocity is derived as `sqrt(2 * gravity * jump_height)`.
The configured jump height is the continuous-motion target; fixed physics steps introduce a small apex difference.
Coyote time permits jumping briefly after walking off a floor and is consumed by a jump. There is no midair jump or jump buffering.

The look component consumes [`default_look_settings.tres`](../player/default_look_settings.tres),
typed by `FirstPersonLookSettings`. Its exported data defines mouse sensitivity, pitch limit,
maximum lateral tilt, speed at maximum tilt, tilt response, and stair smoothing time. Mouse aiming uses unscaled
`InputEventMouseMotion.screen_relative` pixels; roll uses exponential smoothing and actual movement
in the body's local right direction, including in the air.

Movement, crouch, and look reference their owning body explicitly in the saved scene. The controller
instantiates its own gait helper; Movement separately owns its stair-stepper helper. Neither helper
is an authored scene node. Settings contain authored data only; runtime state belongs to each
component or helper instance. The coordinator calls crouch, then gait,
then movement directly because the continuous simulation needs ordered execution each physics tick.
Saved scene connections route `Movement.terrain_advanced(delta, height_change)` to
`Look.advance_terrain()` and `Movement.terrain_reset` to `Look.clear_stair_smoothing()`.
These local signals keep collision movement independent of camera presentation.

### Walk, run, and held sprint

The held Sprint ability supplies sprint intent. The gait helper combines that intent with Ctrl and the resolved collision stance to select the effective gait. Movement derives speed from the selected gait, live attributes and its settings. The Sprint definition declares both starting and interruption rules for `State.Encumbered`.

| Effective gait | Input / stance | Default maximum speed |
| --- | --- | --- |
| Run | Standing, no modifier | 4 m/s |
| Walk | Standing, Ctrl held | 2 m/s |
| Sprint | Standing, Shift held, Ctrl released, affordable | 6 m/s |
| Crouch | Crouched, Ctrl released | 2.4 m/s |
| Crouch walk | Crouched, Ctrl held | 1.2 m/s |

Hold Shift to sprint; release it to run. Movement still requires directional input. Held Ctrl
temporarily walks; releasing Ctrl while Shift remains held resumes affordable sprint. Crouching
prevents sprint without ever standing the character, including beneath a blocked ceiling. Standing
while Shift remains held can sprint again. Inactive controls prevent sprint. After exhaustion or an encumbrance interruption, the player needs to release Shift and press it again.

Movement accelerates/brakes toward the selected speed without snapping velocity; diagonal input
remains normalized for every gait. Standing gaits use the authored 1.5 m jump target, and both
crouched gaits use 0.75 m. Jump height is consumed only at takeoff, leaving an ongoing jump's
vertical velocity and gravity unchanged by later gait changes. Movement Speed is an actor
bonus attribute starting at 0%; the separate internal baseline supplies 4 m/s normal running. The three settings ratios yield the table above; crouch-walk combines
Walk and Crouch. Jump heights remain authored in metres. Normal Run Speed is the single physical baseline; no JSON or attribute duplicate stores it.

Movement tracks actual grounded sprint travel with input and carries unpaid time across activation boundaries. Sprint commits each due charge through AbilitySystem. A paid charge consumes any positive remainder below the next full charge in the same debit. Idle, airborne and fully blocked travel add no chargeable time. Controller priority −10 precedes ActorAttributes priority 0. Active Sprint pauses Stamina recovery through its owned tag. If a charge empties Stamina, the exhaustion tag continues that pause for the effect's authored duration. Normal recovery resumes when its blockers clear. [Ability authoring](ability_system.md#locomotion-abilities)

### Crouching

The crouch component consumes [`default_crouch_settings.tres`](../player/default_crouch_settings.tres),
typed by `FirstPersonCrouchSettings`. Its Inspector mode defaults to **Toggle**: each fresh C press
requests the opposite of the current stance, while releasing C leaves that stance unchanged.
**One Shot** holds the crouched stance while C is down and requests standing when released.
Toggle rejects a blocked stand request until another press; One Shot keeps retrying after release
and stands automatically once the player leaves the obstruction. Releasing mouse capture suppresses
new crouch presses and counts as releasing the hold in One Shot mode.

Entering crouch requires current native floor or transient stair support through
`Movement.is_grounded()`; coyote time alone does not count, and externally moved bodies cannot
reuse stale support. Standing players cannot enter crouch while ascending, descending, or falling.
A simultaneous standing C + Space request jumps without entering crouch. Rejected airborne toggle
presses are discarded; a held One Shot action can crouch once the player lands. A player already
crouched can jump and keep that stance in flight, and may request standing if clearance permits.

The default crouched capsule is 1.10 m tall with a 0.95 m eye height. Standing dimensions come
from the saved capsule and `Look` transform. Crouch duplicates capsule resources per player,
changes their height/center without moving the body's feet, and changes only the eye pivot's
height. Collision dimensions change immediately; the eye eases between heights over the editable
`transition_time` (0.20 seconds by default). Each render frame evaluates a smoothstep curve with
gentle starts and stops; reversing a transition starts from the currently displayed height. Zero
transition time restores immediate eye-height changes. A ray from the crouched eye height limits
the descending view beneath overhead geometry, respecting the body's collision mask and exceptions
and padding for the camera's near plane. A ceiling correction restarts visual descent from the
limited height so leaving the roof cannot raise the descending view.
The capsule radius is unchanged. Crouch settings own geometry, input mode, and visual transition;
Movement resolves its speeds and jump height from the selected gait and movement settings described above.
Authored crouched height is constrained to the standing height and capsule diameter; eye height
is constrained to the crouched capsule and saved standing eye height.

Before expanding, a full standing capsule overlap query checks the body's collision mask,
excluding itself and its collision exceptions. This covers the sides of the head as well as its
center. A blocked request preserves the crouched collider and visual crouch target. Stair traversal
uses the resized body through its existing physics queries, and camera pitch, roll, and stair
compensation continue on their existing transforms.

### Automatic stair traversal

The stair algorithm is ported from `midnight-rush`. Before its single `move_and_slide()`,
movement attempts a step only when supported and not jumping or rising. The helper tests the
capsule path upward, forward, and downward, then probes across the opposing riser to verify a
walkable tread on the same terrain body. It rechecks the actual lift and uses a bounded clearance
search for rounded capsule contacts reported by Jolt. It applies only the vertical lift; normal
movement resolves horizontal travel. Contacts from the preceding physics frame preserve progress
at slow or shallow approach angles. Character bodies are excluded as stair treads.

The authored defaults allow a 0.30 m riser and a 45-degree floor or tread angle. A successful step
provides one tick of support even when a convex tread edge is not classified as a native floor.
Native floor snapping handles descent with `floor_snap_length = max(0.05, max_step_height)`.
As in the source controller, convex tread edges can temporarily lose native floor support during
descent; those intervals use ordinary gravity until floor contact resumes.
The saved body uses a 0.001 m safe margin and eight slide iterations. Setting maximum step height
to zero disables automatic ascent. External position changes clear cached contacts, transient
support, and pending camera compensation on the next movement tick.

Movement compares support planes before and after travel to identify supported terrain height
changes, including native stair descent. Continuous ramps, jumps, unsupported falls, and landing
ticks do not add stair compensation. Look applies a critically damped spring to the existing saved
camera, with a default response time of 0.10 seconds; zero immediately clears compensation.
The translation follows world up regardless of look pitch, and a clearance ray limits the displayed
offset near collision geometry. No replacement camera is constructed, and the project's physics
interpolation setting is unchanged.

Input actions are editable in `project.godot` / **Project Settings > Input Map**:
physical WASD (`move_forward`, `move_backward`, `move_left`, `move_right`), Space (`jump`), C (`crouch`),
Shift (`sprint`), Ctrl (`walk`), Escape (`release_mouse`), and left click (`capture_mouse`).
Movement follows body yaw without following camera pitch.

## Prototype materials and playground

[`materials/prototype/prototype_grid.tres`](../materials/prototype/prototype_grid.tres) and
[`parkour_grid.tres`](../materials/prototype/parkour_grid.tres) are saved `ShaderMaterial` resources using
`prototype_grid.gdshader`. The parkour blocks and stairs use a warm orange palette; the ground has its own
material, and `arena_wall_grid.tres` gives the enclosure a muted slate palette. Their palettes and grid
scales can be tuned independently. The shader exposes base color and separate
major/minor grid spacing, thickness, and color. Grid spacing and thickness use world meters; the
ground grids are 1 m minor and 4 m major. The blocks use tighter 0.25 m minor and 1 m major grids,
with proportionally thinner lines. World-space triplanar projection keeps the scale consistent
across ground and box faces, including scaled meshes. Derivative antialiasing and subpixel fading reduce distant shimmer.

The roughness scalar works alone. When `use_roughness_map` is enabled, the optional texture's red
channel multiplies the scalar. Its triplanar repeat scale is editable. Duplicate a material resource
when independently tuning further surfaces; the parkour boxes share the orange resource.

[`levels/playground/playground.tscn`](../levels/playground/playground.tscn) physically contains:

- A `Ground` static body with matching 1000 × 1 × 1000 m mesh and box shape, centered at `y=-0.5` so its top is `y=0`.
- Nine editable static collision boxes arranged as a rising route, from 2 m to 6 m tall, with reachable gaps and 0.5 m height increments.
- A low instance of [`parkour_stairs.tscn`](../levels/playground/parkour_stairs.tscn): six static collision steps reaching 1.5 m.
- A tall instance of [`high_parkour_stairs.tscn`](../levels/playground/high_parkour_stairs.tscn): 32 steps reaching 8 m, followed by a 3 m wide, 16 m long collision platform. Both stair flights are 3 m wide with 0.25 m rise and 0.6 m tread; their meshes use the orange parkour material.
- An instance of [`crouch_tunnels.tscn`](../levels/playground/crouch_tunnels.tscn) at `(9, 0, 13)`, to the right of spawn. Two orange tunnels are 2 m wide inside and 6 m long, with 1.25 m and 1.45 m roof clearance. Their centers are at world `x=9` and `x=14`, with open ends at `z=10` and `z=16`; saved wall and roof meshes have matching static colliders.
- Four 12 m high static collision walls centered at `x=±20` and `z=±20`, enclosing a 40 × 40 m open-top arena. The original large ground remains beneath it.
- A directional sun with shadows and a `WorldEnvironment` with a procedural sky and horizon-colored fog.
- Player at `(0, 0.05, 17)`, facing negative Z toward the saved Dummy at `(0, 0, 14.5)`, plus the saved CombatTestTools UI. The original stair/course geometry remains unchanged.

No gameplay geometry, camera, lighting, or environment is constructed at startup.

## Combat, abilities, and effects

The clean Combat 2.0 implementation lives in `combat/`, following [its scoped instructions](../combat/AGENTS.md). [Combat implementation](combat_system.md) records the active rules; [Ability authoring](ability_system.md) records the designer workflow.

`ActorAttributes` and `AbilitySystem` are authored components. AbilitySystem honors its explicit attributes reference; when empty, `_ready()` resolves the actor's sibling `Attributes` node without constructing another component. This keeps inherited caster scenes bound even if an editor resave clears the exported reference. The matchup UI checks missing source/target attributes and displays a diagnostic instead of calling a null reference. Attributes own allocations, Health/Stamina/Mana, derived values, removable modifiers and continuous physics regeneration. `advance_regeneration(delta)` is also callable for deterministic tests with automatic processing disabled. AbilitySystem owns grants, activation, authored costs/cooldowns, counted tags, cast lifecycle and explicit delivery; its action clock does not advance resource recovery again. Player and AI share the same activation API. Resources hold authored data; mutable casts and effect instances remain internal.

`CombatAttributes` generates Inspector choices and tooltip descriptions for thirty active attributes. Health/Stamina/Mana Regen use IDs 10/11/12, Armor 18, Armor Penetration 34, Critical Chance/Damage 14/15 and Fire/Cold/Lightning/Necrotic/Void Resistance 19/20/21/22/44. Movement Speed, Attack Speed and Cast Speed are percentage bonuses with IDs 54/55/56. Legacy slots 25/26/27 stay retired. `CombatRules` loads editable defaults and bounds from schema 3 `combat_rules.json`. See the [combat implementation](combat_system.md) for live formulas.

The playground's physical actions use their authored base damage, generic Physical Power and animation timing. The weapon formula tests separately exercise `WeaponDefinition` family, damage range, base cycle and captured source context. Weapon-backed Finesse uses Dexterity and Brutality uses Strength.

Fireball owns and blocks on `State.CombatAction`. Shared animation playback belongs to the activation that started it and routes method keys and completion to that owner. Locomotion can overlap the cast. Death and teardown clean up active instances. The cast samples Cast Speed once at activation. The projectile sweeps for its first collision.

[Gameplay events](ability_system.md#gameplay-events) carry facts to an actor's AbilitySystem. Systems can send them directly. An actor's Attributes resource list can also publish enter and exit events based on final attribute values. Granted definitions declare event triggers, active executions can react to later events, and the usual cast lifecycle owns cleanup.

The carry comparison produces the events that start and finish Encumbered. Its `MaintainEffectExecution` owns the retained effect granting `State.Encumbered`. Sprint blocks activation and interrupts its own cast on that state. Movement derives numeric speed and jump penalties from live load, and F3 reads those factors alongside the tag. The HUD reads retained effect handles and their authored icon and category, with buffs anchored left and debuffs anchored right above the resource bars.

The effect runtime gates hostile hit payloads through one shared Accuracy outcome before applying direct Health damage or retained stat modifiers/tags. GameplayEffectDefinition preserves Physical0/Magic1 and owns a separate MagicSchool field. CombatMath applies source-penetrated Armor to successful Physical components and only matching school resistance to Magic components, using component-specific canonical tags. Event data includes raw/school/resistance/full-and-effective-Armor/penetration details alongside actual Health loss. Duration expiry and removal release only that instance's contributions. Lifecycle notifications occur after setup/cleanup; authoritative clear invalidates pending setup. Modifier-only self effects and authored Ability.Beneficial ally effects bypass hostile Accuracy; damage does not. Explicit direct apply_effect remains separate from hit delivery. There are no automatic ailments, periodic damage, Dodge, Block, Absorption, level-damage scaling or consumable content.

`CombatMath` exposes pure fractional Accuracy probabilities. A connected trace/projectile resolves one outcome shared by its damage components and attached hostile effects, and modifier-only hostile spells also check. The target emits one hit_outcome with hit/miss/resist; failed checks apply no payload. Independent weapon, Accuracy and critical random streams preserve deterministic replay seeds. Successful damaging payloads share one action-scoped critical result; modifier effects retain their ordinary potency. Detached contexts retain source levels and scoped Accuracy fallbacks. Carried Weight uses identity 39 and defaults to zero. The F3 editor supplies test weight. The character sheet pairs weight with Carry Capacity and shows the Encumbered state.

The saved Playground grants Fireball as its combat ability. The dummy shows actual damage and MISS/RESIST feedback. The saved resource HUD binds current and maximum attribute signals. Its Fireball cast bar reads the owning animation's position relative to its release key and hides at release or cancellation. The F3 panel has Player, Dummy and Statistics tabs. The left editor supplies searchable overrides with whole steps for level and primaries and 0.01 steps for fractional attributes. Current-pool sliders follow live capacity. Action speed sliders can expand beyond their initial 0–100% range. The right sheet shows effective stats and the selected ability's hit chance and normal damage using the same combat calculations. F1 opens Statistics and F2 toggles the combat log.

Focused headless suites cover attributes, stable IDs, Armor anchors/cap/diminishing gains/overcap, source penetration/order/scopes/detached delivery, shared critical rolls/chance boundaries/uncapped bonus/RNG independence, signed resistance bounds/school matching/hybrid damage, modifier ownership/order, all weapon categories, physical min/max and cycle normalization, source snapshots, direct-damage/no-ailment behavior, Accuracy curves/shared payload outcomes, continuous regeneration/death/reentrancy, attribute-driven gaits/sprint expenditure/exhaustion/order, action lifecycle, generic modifier cleanup, Fireball projectile delivery and Playground feedback. Behavior tests use in-memory fixture tuning. Saved-asset checks verify wiring and configuration invariants. Headless checks do not grant desktop permission.

## Offline Combat Lab

The existing [Combat Lab](../tools/combat_simulator/lab/README.md) and Python experiments use explicit frozen pre-2.0 rules in `legacy_combat_rules_v1.json`. Follow [tool instructions](../tools/combat_simulator/AGENTS.md) and [lab instructions](../tools/combat_simulator/lab/AGENTS.md). They do not represent the live Godot foundation.

Live import rejects schema 3 before starting Godot or writing snapshots. The Godot exporter is a guard-only script with a clear unsupported-revision error. A future simulator migration requires explicit support for governing weapon profiles, Physical Power and the current modifier pipeline. Legacy results must not be presented as current balance evidence.

Historical leveling, no-healing, pressure and loadout reports and their source snapshots are preserved in local simulator result archives. The repository tracks the simulator source and leaves generated result folders local. Earlier hypothetical consumable recommendations remain withdrawn. No new balance simulation is claimed by this implementation.

## Maintaining this reference

When a task changes architecture, update the affected sections before handoff. For each implemented system, record only the details needed to understand and safely change it:

- Its purpose, owning directory, and entry scenes or scripts.
- Its components and their responsibilities.
- The data it owns, its editable definitions, and how that data is used.
- Its dependencies and meaningful signal or event interactions.
- Decisions whose reasons matter to future work, including material constraints.
- Links to deeper system documentation and scoped instructions when needed.

Keep the master document readable as the project grows by moving detailed explanations into linked system documents. Remove stale descriptions when the implementation changes. Do not fill this document with speculative systems or turn it into an unrequested roadmap.
