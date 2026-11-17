# Crimson Carnage

Crimson Carnage is a first-person playground running on a custom Godot 4.8 build with Forward Plus and Jolt Physics. Open `project.godot` with `Godot_RPG.exe` in the parent directory and press **F5** to start the Playground. With the Playground scene open, **F6** runs it directly. The course includes a walled arena, parkour blocks, two staircases, and crouch tunnels. [Windows editor](../Godot_RPG.exe) · [Playground scene](scenes/levels/playground.tscn)

| Control | Action |
| --- | --- |
| WASD | Move |
| Mouse | Look |
| Space | Jump |
| C | Toggle crouch |
| Escape | Release the mouse |
| Left click | Recapture the mouse, or gain 50 blood in Dual Swords while captured |
| Tab | Activate Spellcaster at 300 blood |
| 1–8 | Preview the directional damage HUD |
| P | Toggle the painterly post-processing preview |
| Alt+1–4 | Preview Balanced, Light Footed, Long Stride, or Heavy Braced weapon gait |

The Playground captures the mouse on startup. Press **Escape** to release it and click the viewport to recapture it.

## Test the blood and form mockup

The player starts with **100/100 health** and **0/300 blood**. Click six times with the mouse captured. Each mock swing grants **50 blood**, including on the saved carry-pose rig. Press **Tab** at **300 blood** to activate **Spellcaster** and hide the swords. Blood drains at **30 points per second**. At zero, the player returns to **Dual Swords**. The drain rate is exposed under **Player → Stats → Blood Drain**. [Player scene](scenes/player/player.tscn) · [Stats](scripts/player/player_stats.gd)

The saved player takes **5 HP per meter** of fall distance beyond **4 m**. The Stats script defaults are **3 m** of safe fall distance and **15 HP/m**. A fall measures from the highest point reached in the air to the landing height. Step off a ledge with a drop of more than **4 m** to test health loss and the damage vignette. Tune **Safe Distance** and **Per Meter** under **Player → Stats → Fall Damage**. [Fall damage rules](scripts/player/player_stats.gd)

## Tune the controller

The player uses Crimson Framework's native **Mover** and **Controls** components. Mover resolves locomotion, stairs, jumping, and crouch. Controls supplies the authored input layout, mouse sensitivity, and pointer capture. The player enables locomotion input while the mouse is captured. Releasing the mouse clears movement input while braking, gravity, and collision continue. [Player scene](scenes/player/player.tscn) · [Input layout](data/player/default_input_layout.tres)

| Change | Open in the editor |
| --- | --- |
| Move, aim, jump, crouch, melee, and Spellcaster bindings | **Player → Controls → Edit Input Map** |
| Crouch and mouse aim action assignments and mouse sensitivity | **Player → Controls → Player Setup** |
| Movement speed, acceleration, gravity, air control, and jump speed | **Player → Mover → Ground Movement**, **Air Movement**, and **Jumping** |
| Step height and stair camera smoothing | **Player → Mover → Stairs** |
| Crouch mode, capsule height, and eye-height transition | **Player → Mover → Crouch → Settings** |
| Pitch limit and camera roll | **Player → Look → Camera3D → Aim** and **Strafe Roll** |
| Base vertical field of view | **Player → Look → Camera3D → FOV** |
| Forward and backward field-of-view offsets and response time | **Player → Look → Camera3D → Movement FOV** |

The saved crouch uses a **1.10 m** capsule, a **0.95 m** eye height, and a **0.20 s** transition. The saved camera has a **55°** base vertical FOV. Movement adds **1.5°** at full forward speed and subtracts **0.1°** at full backward speed, with a **0.24 s** response time. The offsets follow actual movement speed. [Crouch settings](data/player/default_crouch_settings.tres) · [Camera architecture](docs/architecture.md#crouch-and-camera)

## Preview and author weapons

The saved player mounts two prototype swords and displays them in their carry pose. Both use procedural sway, breathing, directional carry, gait, wall clearance, and jump and landing response. Its `AnimationPlayer` contains an empty `sword/idle` entry. A left click currently exercises the blood gain loop. Visible attacks and weapon contact require assigned slash clips and sweep nodes. [Player scene](scenes/player/player.tscn) · [Melee setup](docs/architecture.md#melee)

Under **Player → Look → Camera3D → WeaponControl → Weapon Sway → Sway Settings**, tune **Wall Tuck**, **Turn in Place**, **Idle Breathing**, **Locomotion**, **Directional Carry**, **Bob**, and **Jump and Landing**. Switch between **W**, **W+D**, **D**, and **S** to compare carry poses, or turn and reverse the mouse to check sway. **Alt+1–4** blends between the gait presets while preserving the current stride phase. Assign **Bob → Style** to change the starting preset. [Editable gait styles](data/melee/bob_styles)

For jump and landing curves, the horizontal axis runs from the trigger at **0** to the end of **Duration** at **1**. Curve height multiplies position or rotation. Landing speed scales the result. Start and end each curve at zero to ease back to the carry pose. [Air motion settings](scripts/melee/weapon_air_motion.gd)

For a playable slash, assign the clip and blade sweep under **WeaponControl**. Use the clip's `HitStart` and `HitEnd` markers for the active contact window. The sweep's **SweepStart** and **SweepEnd** markers set the blade span. **WeaponControl → Slash Reach** exposes the reach tuning and **MeleeSweep → Debug → Show Sweeps** draws queried volumes in cyan and contacts in orange. [Melee authoring](docs/architecture.md#melee) · [Slash reach settings](data/melee/slash_reach.tres)

## Open the native Weapon Animation Tweaker

Open the player scene, select **AnimationPlayer**, and choose **Project → Tools → Weapon Animation (Native)**. Use **Refresh Rig** if the window is already open. **Import Clips** opens a Vermintide Viewer clip pack, where you can select individual clips and choose or create a library. Save the player scene after importing. Use the **Sockets** and **Trails** overlays to inspect the motion. **Combo** opens the sequence editor for arranging clips and previewing joins. Imported clips and saved combos are available to author separately from the active gameplay assignments on WeaponControl. [Player scene](scenes/player/player.tscn) · [Native editor guide](native/weapon_animation_tweaker/src/modules/weapon_animation/editor/README.md)

The native Tweaker ships as a standalone GDExtension. Its editor build provides the authoring window. The runtime library registers the clip, track, and combo resource types for loading in-game. The original GDScript **Weapon Animation Tweaker** tab remains available. [Native addon and build instructions](native/weapon_animation_tweaker/README.md)

## Tune damage feedback

Actual health loss plays a red hit vignette. The saved player uses **1.0 peak opacity**, a **0.015 s rise**, and a **1.0 s fade**. Tune the pulse under **PlayerPresentation → ScreenEffects → DamageVignette** and use its **Material → Shader Parameters** to edit the hit tint and mask. [Player presentation](scenes/player/player_presentation.tscn)

The saved player also enables **Low Health Pulse** with a **100%** threshold. The warning repeats below full health and stops when health reaches the threshold. The standalone effect defaults to disabled with a **25%** threshold. Under **Low Health Pulse → Appearance**, set **Color**, **Brightness**, minimum and peak opacity, and mask size. A smaller mask brings the edge farther into the image. Under **Timing**, set the overall **Speed**, or tune rise, hold, fade, and rest individually. The warning draws over the post-processing pass and beneath the immediate hit effect. The HUD draws above both. [Damage vignette scene](scenes/effects/damage_vignette.tscn)

Press **1** for front, **3** for right, **5** for rear, and **7** for left. The even-numbered keys through **8** preview the diagonals. These shortcuts display a directional marker without removing health. Turn while a marker is visible to see it track the test point in world space. Nearby bearings refresh one marker, and the HUD shows up to three. In the standalone **DamageIndicator** scene, enable **Editor Preview** and set **Preview Marker Count** to inspect up to eight directions. The scene also exposes marker style, tint, body, and glow. [Damage indicator](scenes/ui/damage_indicator.tscn) · [Style textures](textures/ui)

## Configure blood impacts

Once a playable attack is configured, strike the target in the Playground to inspect the body stain, airborne spray, and floor deposits. A sword contact on the mannequin within **3 m** of the camera also previews the view-space blood droplets and smears once per swing. Tune the lens effect under **PlayerPresentation → ScreenEffects → LensBlood** and the range on the Playground root. [Blood effects architecture](docs/architecture.md#blood-impacts)

To add blood to a hittable scene, add **BloodComponent** to its root. The object needs a physics body on a layer queried by the sword. A rigid prop can receive a decal on its own surface and spray blood into the surrounding world. For multipart props, use **Body Stain Mesh → Surface** to choose a mesh explicitly. **Blood Profile** falls back to **Humanoid Blood**. Enable **Blood Profile → Debug → Show Droplet Wires** to inspect the moving collision spheres. [Component scene](scenes/effects/blood_component.tscn) · [Default blood profile](data/effects/humanoid_blood_profile.tres)

## Tune post-processing

In the **3D** editor with the Playground open, choose **Post Processing → Preview in 3D**. Use **Post Processing → Edit Material** to open the settings in the Inspector. The preview applies the painterly filter, vignette, dithering, and posterization to the editor camera.

Press **F5** to play. With **Debug → Synchronize Scene Changes** enabled, edit the **Post Processing** material in the local Inspector while the game runs. Open it from the toolbar or double-click `materials/effects/post_processing.tres` in the FileSystem dock. Tap **P** in-game to bypass the painterly filter or restore it with the latest material settings. [Post-processing material](materials/effects/post_processing.tres)

Under **Shader Parameters → Painterly**, increase **Brush Stroke Strength** to bring out the elongated marks and **Edge Sharpness** to retain more original detail along high-contrast edges. **Brush Radius** sets the size of the color patches and strokes in render pixels. **Painterly Strength** sets the overall blend, and **Paper Grain Strength** sets the fine texture. Set an effect's strength to zero to disable it, or hide **PlayerPresentation → ScreenEffects → PostProcessing** to bypass the full pass. [Post-processing scene](scenes/effects/post_processing.tscn)

## Try Dynamic Sky

In the Godot editor, choose **Project → Tools → Open Dynamic Sky Demo** and press **F6**. West Ridge Observatory has exposed, sheltered, and lakeshore viewpoints. Switch between **Rain**, **Snow**, **Storm**, and **Sandstorm** to compare precipitation, accumulation, and audio. **Trigger Lightning** previews a distant strike and its delayed thunder. **Project → Tools → Add Dynamic Sky** inserts the editable rig into a 3D scene. [Addon guide](docs/dynamic_sky.md) · [Ultra Dynamic Sky 9.7 audit](docs/ultra_dynamic_sky_audit.md)
