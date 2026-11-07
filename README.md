# untitled

A first-person RPG inspired by the spirit of *The Elder Scrolls V: Skyrim*, with action RPG elements inspired by *Diablo*, built with Godot.

The playable project uses the [Combat 2.0 foundation](docs/combat_system.md) with thirty code-defined stats, scoped modifiers, shared attack/spell Accuracy, damage and resistance rules, and tag-driven abilities and effects. Fireball is the Godot Playground’s combat ability. Historical Python tools and reports use the legacy model.

The [combat game design](docs/combat_system_2_0.md) records the full attribute descriptions and formulas, implemented Armor/Penetration/resistances, Accuracy/level curve and regeneration, current weapon roster, unique-equipped rule, shared weapon trees, Shield's blocking specialization and ten Relic visual alternatives. Its Shield and new caster families, blocking and equipment/progression rules are design only; the document separates them from implemented behavior.

## Current status

The project has a playable first-person prototype playground: WASD movement with held walking and held sprint, ground/air acceleration and braking, custom gravity and jumping, coyote time, automatic stair traversal with camera smoothing, toggle or hold crouching with standing clearance checks, mouse look, and lateral camera tilt. The saved playground arranges rising boxes, two staircases, and two crouch tunnels inside a 40 × 40 m walled arena, with a high platform, configurable grid materials, directional lighting, and horizon fog.

The same main scene also contains a damage dummy and combat testing tools:
F3 edits both actors and chooses an ability, F1 shows statistics, and F2 toggles
the combat log. Combat abilities and their effects remain editable saved assets.

The existing [Python Combat Lab](tools/combat_simulator/lab/README.md) uses a frozen pre-2.0 model. It cannot import or validate current Godot combat; its import/export boundary rejects the new revision instead of silently using obsolete formulas. Historical simulation results remain reference data.

## Open the project

1. Clone the repository:

   ```sh
   git clone https://github.com/FrankFloydus/untitled.git
   ```

2. Open a Godot editor compatible with the `4.7` feature version declared in `project.godot`. The project has been checked with `4.7.stable.official.5b4e0cb0f`.
3. In the Project Manager, choose **Import** and select the cloned project's `project.godot` file.
4. Open the project and let Godot finish importing its assets.

The current configuration uses Forward Plus rendering and Jolt Physics. On Windows, the rendering driver is D3D12. Press **F6** with `levels/playground/playground.tscn` open, or **F5** to run the configured main scene.

## Controls and tuning

Combat testing uses the same `levels/playground/playground.tscn` as movement.
Run it with F5 or F6: Player, Dummy, and the saved CombatTestTools UI are present
in the main course. There are no separate combat arenas to open.

- **F3:** edit Player/Dummy levels, all active combat attributes, and select
  Fireball.
- **LMB / F:** request the selected ability. The first click after releasing the
  mouse recaptures it.
- **R:** clear and restore the dummy.
- **F1:** toggle per-ability combat statistics.
- **F2:** toggle the combat log at the lower left.

The player's combat HUD shows Health, Mana and Stamina at the bottom center. The Fireball cast bar fills with its active animation and disappears on release or cancellation. The dummy shows an unlabeled health bar, actual damage and MISS/RESIST feedback. F3 offers searchable sliders for all thirty attributes, with effective percentages and computed outcomes on the character sheet. In F3, set Cast Speed to +50% to play Fireball at 1.5×. +100% reaches 2×. Drag a speed slider to its right edge and release to expand the test range.

[Ability authoring](docs/ability_system.md) explains the editable resources. [Combat implementation](docs/combat_system.md) lists the live catalogue and formulas. Tuning is in [combat_rules.json](combat/combat_rules.json).

Accuracy uses the shared level curve, starting at 80% against equal level and reaching at most 10% against +10. [Combat implementation](docs/combat_system.md) covers hit outcomes, damage mitigation, criticals, regeneration and action speed. Restore controls reset resources for testing.

| Input | Action |
| --- | --- |
| WASD | Move relative to facing direction |
| Mouse | Look around |
| Space | Jump, including briefly after walking off an edge when Sprint is inactive |
| C | Toggle crouch by default; hold to crouch in One Shot mode |
| Shift (hold) | Sprint while standing and affordable; release to run |
| Ctrl (hold) | Walk; also moves more slowly while crouched |
| Escape | Release the mouse, clear sprint, and stop accepting movement input |
| Left click | Capture the mouse when released; request the selected ability while captured |
| F | Request the selected combat ability |
| R | Clear and restore the test dummy |
| F1 | Toggle per-ability combat statistics |
| F2 | Toggle the lower-left combat log |
| F3 | Open the Player/Dummy attribute and ability testing editor |

The reusable player is in `player/first_person_controller.tscn`. Select its **Movement** node and expand
**Settings** in the Inspector to edit `player/default_movement_settings.tres`. This is the single place
to tune Normal Run Speed (the 100% physical baseline), Walk/Sprint/Crouch multipliers, ground/air acceleration and deceleration, custom gravity, standing/crouched jump heights, coyote time,
maximum stair height, and maximum walkable slope. Automatic stair ascent permits 0.30 m risers by
default; set maximum step height to zero to disable it. Native floor snapping follows descending stairs.
Edit `player/default_look_settings.tres` for sensitivity, pitch limit, camera tilt, and stair smoothing.
The stair spring defaults to 0.10 seconds; zero disables camera height compensation.
Movement Speed is a bonus percentage (normal 0%, minimum −100%, maximum +25%), editable in F3 or with attribute modifiers. Add Flat 1 gives +1% speed; Add Flat 20 gives +20%. Increased and More scale the accumulated bonus itself, like Critical Damage; Increased 20% alone leaves zero unchanged. Normal Run Speed under Movement → Settings → Movement Baseline defines the physical 100% baseline, default 4 m/s; F3 shows only the bonus percentage. Setting that baseline to 6 m/s makes 0%/+20% bonus produce 6/7.2 m/s normal running. Gait multipliers and jump heights are authored in `player/default_movement_settings.tres`. At Movement Speed 0%, the starting configuration produces these physical speeds:

| Movement | Maximum speed | Jump-height target |
| --- | --- | --- |
| Normal run | 4 m/s | 1.5 m |
| Walk (Ctrl held) | 2 m/s | 1.5 m |
| Sprint (Shift held) | 6 m/s | Blocked while Sprint is active |
| Crouch | 2.4 m/s | 0.75 m |
| Crouch walk (Ctrl held) | 1.2 m/s | 0.75 m |

Carried Weight is editable in F3. Crossing above capacity sends the gameplay event that starts Encumbered. Its effect grants State.Encumbered. Sprint lists that state in its activation blockers and interruption tags. Movement reduces speed and jump height based on load. At the default twice-capacity threshold, speed reaches half and jumping stops. The character sheet shows the current load and live penalties. The Encumbered debuff icon appears above the right side of the HUD, with room for buff icons above the left.

The base player grants Sprint, Jump, Crouch, Encumbered and Stamina Exhaustion. The caster adds Fireball. Press LMB or F to cast it. [Ability authoring](docs/ability_system.md)

Sprint upkeep is configured under **Sprint → Execution**. The defaults charge 2 Stamina per 0.1 seconds of grounded sprint travel with input. Movement preserves unpaid travel across pauses. Idle, blocked and airborne travel cost nothing. Stamina recovery pauses throughout active Sprint. A paid travel charge consumes any positive remainder below the next full charge, reaching zero and applying the authored exhaustion effect. Release with Stamina left to recover normally. Health and Mana keep recovering while alive. Release Shift and press again after exhaustion.

Hold Shift to sprint and release it to run. Directional input is still needed to move. Holding
Ctrl temporarily walks; releasing Ctrl while Shift is held resumes affordable sprint. Crouching
prevents sprint without ever standing the player; standing while Shift is held can sprint again.
A blocked uncrouch request keeps crouch speed. Inactive controls prevent sprint. No Caps Lock binding
or toggle-sprint mode is used. Each controller owns a `FirstPersonGait` runtime helper for gait
selection and the exhaustion release latch.
The helper has no scene node or Inspector settings. `Movement` resolves that selection through its
settings and owns acceleration and collision physics.

Edit `player/default_crouch_settings.tres` for **Mode**, **Crouched Height**, **Crouched Eye Height**,
and **Transition Time**.
**Toggle** is the default: press C to crouch and press again to stand. **One Shot** crouches while
C is held and stands on release. A blocked toggle stand request keeps the player crouched until
another press; a blocked One Shot release automatically stands once clearance becomes available.
The checker tests the entire standing capsule before allowing either mode to stand.
Entering crouch requires being grounded; pressing C during a jump or fall cannot start crouching.
If C and Space are pressed together while standing, jumping takes priority. An airborne toggle
press is ignored; in One Shot mode, holding C through landing crouches once grounded.
Jumping from an existing crouch remains allowed, with the lower jump target shown above.
Speed changes use normal acceleration/braking, and jumping uses the same gravity in every gait.
Crouch defaults to a 1.10 m capsule and 0.95 m eye height. The view eases down and up over
0.20 seconds by default; increase **Transition Time** for a slower transition, or set it to zero
for an instant height change. Reversing direction midway starts from the current view height.
Collision changes immediately, and overhead geometry limits the descending camera for safe entry.
Standing capsule and eye height remain editable in the player scene. Every exported setting has an Inspector tooltip.

Edit `materials/prototype/prototype_grid.tres` for the ground and `parkour_grid.tres` for the orange
parkour blocks. The ground uses 1 m / 4 m grids; the blocks use tighter 0.25 m / 1 m grids.
Both expose base color, major/minor line spacing, thickness, colors, and roughness.
To use a roughness texture, assign it and enable **Use Roughness Map**; the red channel multiplies
the roughness scalar. The grid stays at a consistent world scale across faces.
Ground, parkour, light, sky, and fog are saved and editable in the playground scene.
The low staircase instances `levels/playground/parkour_stairs.tscn`: six collision steps reaching
1.5 m. The tall staircase instances `levels/playground/high_parkour_stairs.tscn`: 32 steps reaching
8 m, followed by a 16 m long platform. Both have 0.25 m rise, 0.6 m tread, and orange grid material.
Each scene remains editable. Four 12 m high collision walls enclose the arena above the original
1000 × 1 × 1000 m ground. The route starts with the low stairs, continues across the rising boxes,
and joins the upper tall stairs before the high platform.
Two orange tunnels to the right of spawn instance `levels/playground/crouch_tunnels.tscn`.
They run from `z=16` to `z=10`, centered at `x=9` and `x=14`, with 1.25 m and 1.45 m headroom.
Both require crouching and provide room to test blocked standing under a roof.

## Checks

Run focused controller and combat behavior checks after importing the project:

```sh
godot --headless --path . --editor --import --quit
godot --headless --path . --script res://tests/first_person_controller_test.gd
godot --headless --path . --script res://tests/stair_traversal_test.gd --fixed-fps 60
godot --headless --path . --script res://tests/crouch_test.gd --fixed-fps 60
godot --headless --path . --script res://tests/gait_test.gd --fixed-fps 60
godot --headless --path . --script res://tests/combat_contract_test.gd
godot --headless --path . --script res://tests/accuracy_resolution_test.gd
godot --headless --path . --script res://tests/resource_regeneration_test.gd --fixed-fps 60
godot --headless --path . --script res://tests/resistance_resolution_test.gd
godot --headless --path . --script res://tests/armor_resolution_test.gd
godot --headless --path . --script res://tests/armor_penetration_test.gd
godot --headless --path . --script res://tests/action_timing_test.gd --fixed-fps 60
godot --headless --path . --script res://tests/playground_tools_test.gd
```

Behavior tests use their own in-memory tuning. Saved-asset checks validate wiring and supported configuration. You can edit gameplay values in the Inspector independently of those fixtures.

Use your local Godot executable path if `godot` is not on `PATH`.
The headless checks cover movement, jumping, coyote time, camera roll, stair traversal and
smoothing, both crouch modes, smooth height transitions, standing clearance, and authored tunnel traversal.
They also cover grounded crouch eligibility, reduced crouched speed and jump height, and restoration
of standing locomotion. Gait checks cover toggle persistence, walk priority, crouch restrictions,
all five movement speeds, sprint cancellation, and independent player state.
Combat checks cover shared Accuracy outcomes, level ceilings, payload gating, resource costs,
regeneration conditions, modifier ownership, death, animation timing and playground feedback.
Mouse capture and aiming checks are skipped by the headless display server; verify
those in a normal playground run.

For a manual check, run the playground and move/release WASD on the ground and after jumping:
speed should ramp up and slow down with distinct ground and air responses. Jump onto the boxes,
walk off a ledge, and press Space immediately to check coyote time; waiting beyond its configured
window should prevent a jump until landing. Strafe left/right to see the camera roll smoothly and
return to level, and move the mouse vertically to verify that looking stops before the camera flips.
The ground and boxes should show both grid scales, with the distant ground blending into the sky.
Walk up and down both staircases without jumping, including sideways and at diagonal angles:
the player should traverse the flight while the camera eases over supported step changes. Space should
still jump during a climb. Risers above the configured height and stairs without enough headroom
should remain blocked. Changing stair smoothing to zero should remove only the camera compensation.

For crouch, walk right from spawn to either orange tunnel and approach its south opening at
`(9, 0, 17)` or `(14, 0, 17)`, facing negative Z. Standing should block entry. Press C to crouch
and enter; pressing C under the roof should keep the player crouched. Leave the tunnel and press
C again to stand. Switch **Mode** to **One Shot** in the crouch settings, restart the playground,
and repeat while holding C: releasing under the roof should keep the player crouched, then exiting
should stand automatically. In open space, press C repeatedly, including during a transition:
the eye should ease down/up without jumping to either stance height. Look around and strafe while
crouched to check the lowered view, and enter a tunnel while lowering to check overhead clearance.
Jump while standing and press C during ascent and descent: neither press should crouch you.
After landing, crouch and compare WASD speed and jump height with standing; both should be lower.
Standing again should restore normal speed and the normal jump height on the next takeoff.

For sprint/walk, move forward and hold Shift: speed should rise to sprint. Release Shift to
return to Run. While holding Shift, hold Ctrl to walk and release Ctrl to resume affordable sprint.
Crouch while holding Shift: the player should remain crouched and move at crouch speed; standing
while still holding Shift may sprint again. Hold Ctrl while crouched to move still more slowly.
After exhaustion, keep Shift held while Stamina recovers: sprint should remain blocked. Release
and press Shift again to restart it. Press Escape to release controls and prevent sprint.

## Project documentation

- [Agent instructions](AGENTS.md): project-wide development rules and collaboration boundaries.
- [Architecture](docs/architecture.md): the master reference for implemented systems, responsibilities, and project structure.
- [Godot conventions](docs/godot_conventions.md): coding style, editable assets, export documentation, folder organization, and engine references.
- [Combat game design](docs/combat_system_2_0.md): established attributes and formulas, progression, weapon types and domains, shared trees, Relic models, and implementation status.
- [Combat implementation](docs/combat_system.md): active attribute catalogue, modifier math, physical weapon damage, direct effects and current tuning boundaries.
- [Ability authoring](docs/ability_system.md): actor setup, Fireball authoring, animation timing, effect ownership, and checks.

Read the applicable instructions before contributing. Keep documentation aligned with changes to the project.

## Version control

Commit project files, source assets, `.import` sidecars, `.uid` sidecars when generated, and `export_presets.cfg` when export presets are added.

The `.gitignore` excludes Godot's generated `.godot/` cache, generated Android Gradle files, imported translations, export credentials, temporary files, and export outputs. Use `builds/` or `exports/` for local exported builds. Godot regenerates its ignored cache when the project is imported.

See the official [Godot version-control guidance](https://docs.godotengine.org/en/4.7/tutorials/best_practices/version_control_systems.html) for generated-file handling.
