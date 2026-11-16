# Crimson Carnage

A first-person playground configured for Godot 4.8 beta, Forward Plus, and Jolt Physics. Open `project.godot` with the editor built from the sibling Godot checkout and press **F5**. The course includes a walled arena, parkour blocks, two staircases, and crouch tunnels. [Windows editor](../godot/bin/godot.windows.editor.x86_64.exe) · [Playground scene](scenes/levels/playground.tscn)

| Control | Action |
| --- | --- |
| WASD | Move |
| Mouse | Look |
| Space | Jump |
| C | Toggle crouch |
| Hold Ctrl | Walk |
| WASD + Left Shift | Dash in the chosen movement direction |
| Escape | Release the mouse |
| Left click | Recapture the mouse, or attack when a weapon and clip are assigned |
| 1–8 | Preview incoming damage from eight directions |
| 9 / 0 | Select the configured right-hand weapon slot |
| F4 | Show or hide the read-only item catalog report |
| P | Toggle the painterly post-process preview |
| Alt+1–4 | Preview Balanced, Light Footed, Long Stride, or Heavy Braced weapon gait |

The game captures the mouse on startup. Press **Escape** or switch focus to release it. Click inside the viewport to resume input. You can jump at normal speed or while holding **Ctrl** to walk.

## Try Dynamic Sky

In the Godot editor, choose **Project → Tools → Open Dynamic Sky Demo** and press **F6**. West Ridge Observatory has exposed, sheltered, and lakeshore viewpoints. Switch between **Rain**, **Snow**, **Storm**, and **Sandstorm** to compare precipitation, accumulation, and audio. **Trigger Lightning** previews a distant strike and its delayed thunder. **Project → Tools → Add Dynamic Sky** inserts the editable rig into a 3D scene. [Addon guide](docs/dynamic_sky.md) · [Ultra Dynamic Sky 9.7 audit](docs/ultra_dynamic_sky_audit.md)

## Test the dash

Press **F5**, hold a movement direction, and tap **Left Shift** to dash. With no movement direction held, tapping **Left Shift** leaves your charges and FOV alone. Jump and dash midair to test the same short burst. Tap twice, allowing the first burst to finish before pressing again. A third dash becomes available one second after the first charge was spent. Try dashing into an arena wall to check that contact ends the burst.

The view narrows from **55° to 44°** on a straight forward or backward dash and eases back when it ends, including when you hit a wall. Near the screen edges, dash distortion bends world details and stretches them outward into streaks. Try **A + Left Shift** or **W + A + Left Shift** to see the effect on side and diagonal dashes, where the FOV stays at its base value.

## Test melee reach

Open the [PlayerPresentation scene](scenes/player/player_presentation.tscn) to edit the screen effects and HUD. The Playground player starts unarmed with empty weapon controls and an empty AnimationPlayer. The weapon and blood-effect exercises below require mounting a weapon, wiring its sweep, and assigning attack clips first. [Weapon setup](docs/architecture.md#melee)

Press **F5** and click twice in quick succession. The right sword slashes from right to left, then the left sword slashes from left to right. An early second click starts the left slash when the right sword finishes recovering.

For visual debugging, enable **MeleeSweep → Debug → Show Sweeps** on the sword scenes. Face the south arena wall and compare right-hand slashes with **9** and **0** from the same spot. Allow the intervening left-hand slash to finish between right-hand tests. Cyan shows the queried volumes and orange shows a world contact.

Open **Player → Look → Camera3D → WeaponControl → Slash Reach** to tune the attack multiplier, flat bonus, and blade offset for both hands. In each weapon scene, select **MeleeSweep** to set the width, height, collision mask, and debug duration. Its **SweepStart** and **SweepEnd** markers set the base span. [Slash Reach](data/melee/slash_reach.tres) · [Long sword](scenes/weapons/prototype_sword.tscn) · [Short sword](scenes/weapons/short_sword.tscn) · [Melee authoring](docs/architecture.md#melee)

Walk toward a wall, turn across a corner, then back away. Each sword retracts toward the camera while its grip holds its horizontal screen position. The long sword starts sooner and the grips ease out as you retreat. Use **9** and **0** to compare the right-hand swords. Tune the pose under **WeaponControl → Weapon Sway → Sway Settings → Wall Tuck**. Collision layers, padding, and recovery for the final fit are under **Weapon Clearance**.

To test weapon sway, pan slowly, then make a quick turn and reverse. Watch the sword guards shift subtly relative to the scene and the blades rotate at the grips. Try **0** to compare the short sword and left-click during a turn to see the attacking sword settle into its swing. Tune the four poses and look response under **Player → Look → Camera3D → WeaponControl → Weapon Sway → Sway Settings**. Set **Turn Gain** to zero to disable sway input. [Melee and sway architecture](docs/architecture.md#melee)

For the turn-in-place comparison, stand still on open ground. Flick the mouse sideways and stop. Use **9** for the right long sword and **0** for the right short sword. The long sword follows the flick and settles a little later. The left sword uses the long response as well. Edit the extra response and turn-rate threshold under **Sway Settings → Turn in Place**. [Sway settings](scripts/melee/weapon_sway_settings.gd)

To see idle breathing, stand still with the mouse steady for a few seconds and watch the grips. They drift slightly in depth and the blades follow with a small delay. Walk or slash to see the breath fade, then stop to see it ease back. Edit **Idle Breathing** in the same **Sway Settings** resource. [Player scene](scenes/player/player.tscn)

With the mouse still, hold **D**, then switch to **A**. The blades lean slightly into travel while the grips lag acceleration and carry through braking. Tap **W** and **S** to see the guards shift in depth and the blades pitch with the forward or backward motion. After releasing a movement key, the swords ease into their idle pose. Tune travel, lean, and **Settle Time** in the **Locomotion** group under **Sway Settings**.

To compare directional carry, hold **Ctrl** and walk with **W**, then **W+D**, then **D**. Forward travel extends the grips slightly. The diagonal blends into the strafe pose, where the leading sword reaches farther than the trailing one. Try **S** to see both grips draw closer. Tune the poses under **Sway Settings → Directional Carry**. [Player scene](scenes/player/player.tscn)

Hold **Ctrl+W** to walk and watch the swords alternate as you cover ground. Strafe with **A/D** to see the stance shift into travel, then release to see the grips settle from the last loaded side. The stride stops advancing against a wall or in the air. Tune the **Walk Step Length**, **Run Step Length**, and the matching step curves under **Sway Settings → Bob**.

While holding **Ctrl+W**, press **Alt+1** for **Balanced**, **Alt+2** for **Light Footed**, **Alt+3** for **Long Stride**, or **Alt+4** for **Heavy Braced**. The preview blends into the new style at the current stride phase. To pick the style that loads with the player, assign it in **Player → Look → Camera3D → WeaponControl → Weapon Sway → Sway Settings → Bob → Style**. [Editable style resources](data/melee/bob_styles)

Compare **Alt+1** and **Alt+4** on open ground at the same **2 m/s** walk speed and **55°** vertical FOV. With the mouse still, start with **Ctrl+W**, switch from **W** to **D** while holding **Ctrl**, then release movement. Heavy Braced carries lower and wider, shifts across the stance through each stride, splits the grips during a pivot, and lets them continue along the last direction of travel before settling. The **Carry** and **Transitions** settings are editable in the [Heavy Braced resource](data/melee/bob_styles/heavy_braced.tres).

Tap **Space** on flat ground with the mouse still. The grips lag slightly downward at takeoff, the blades follow a beat later, and both return toward the carry pose in the air. Walk off a higher parkour block to compare how much the swords compress on a faster landing. The camera follows normal player movement with no extra kick from the weapon curves. Edit the curves and impact-speed range under **Player → Look → Camera3D → WeaponControl → Weapon Sway → Sway Settings → Jump and Landing**. [Player scene](scenes/player/player.tscn)

## Test blood impacts

Press **F5** and walk straight toward the animated target in front of the spawn. Get within about one sword length and left-click. Try the torso and upper arm. The burst blooms at the struck surface, then breaks into torn streaks and finer spray. Hit several times from the same spot to see the floor deposits overlap around the target. Look at the deposit from a low angle to see the wet highlights. Use consecutive slashes to test both hands, and **9** or **0** to choose the right-hand sword.

A slash on the mannequin within **3 m** of the camera also puts droplets and smears on the view. Turn or dash immediately after the hit to see the marks stay on the screen as the world moves. They clear in a few seconds. Walls and the rigid blood prop do not trigger the lens preview. Tune it in **PlayerPresentation → ScreenEffects → LensBlood**. The Playground root holds the preview range.

Hit the mannequin or an arena wall with either sword to preview the **Damage Vignette**. The edges briefly darken red on the first contact of a swing. A swing through empty air leaves the view clear. Tune pulse strength, rise time, and fade time under **PlayerPresentation → ScreenEffects → DamageVignette**. Open its **Material → Shader Parameters** to edit the tint, scale the feathered mask, or assign a different mask texture.

To add blood to a hittable scene, select its root and use **Add Child Node → BloodComponent**, or drag in the saved component scene. The object needs a physics body on a layer queried by the sword. On a rigid prop, a hit leaves a decal on the prop itself and sprays blood into the world. The component automatically uses a mesh above the hit body or the only visible rigid mesh under the prop. For a multipart prop, choose **Body Stain Mesh → Surface** if the mesh needs to be selected explicitly. **Blood Profile** defaults to **Humanoid Blood** when empty. Open the mannequin scene to see the optional skinned body stain setup. [Component scene](scenes/effects/blood_component.tscn) · [Default blood profile](data/effects/humanoid_blood_profile.tres) · [Blood effects architecture](docs/architecture.md#blood-impacts)

Enable **Blood Profile → Debug → Show Droplet Wires** to see that profile's moving collision spheres for world splatter and floor fallout in play.

## Tune post-processing

In the **3D** editor with the Playground open, choose **Post Processing → Preview in 3D**. Use **Post Processing → Edit Material** to open the settings in the Inspector. The preview applies the painterly filter, vignette, dithering, and posterization to the editor camera.

Press **F5** to play. With **Debug → Synchronize Scene Changes** enabled, edit the **Post Processing** material in the local Inspector while the game runs. Open it from the toolbar or double-click `materials/effects/post_processing.tres` in the FileSystem dock. Tap **P** in-game to bypass the painterly filter or restore it with the latest material settings. [Post Processing material](materials/effects/post_processing.tres)

Under **Shader Parameters → Painterly**, increase **Brush Stroke Strength** to bring out the elongated marks and **Edge Sharpness** to retain more original detail along high-contrast edges. **Brush Radius** sets the size of the color patches and strokes in render pixels. **Painterly Strength** sets the overall blend, and **Paper Grain Strength** sets the fine texture. Set an effect's strength to zero to disable it, or hide **PlayerPresentation → ScreenEffects → PostProcessing** to bypass the full pass. [PostProcessing scene](scenes/effects/post_processing.tscn)

## Test the damage direction HUD

Open the **DamageIndicator** scene in the **2D** editor and select its root node. Turn on **Editor Preview → Preview Enabled**, then set **Preview Marker Count** from **1–8**. Markers start at the top and are added clockwise at **45°** intervals. The saved scene previews all eight by default. The enable toggle is temporary for the open scene. Choose a **Marker Style** under **Marker**. The same Inspector holds layout, tint, **Body**, and **Glow** settings. Save the scene to use its appearance settings in the Playground. [DamageIndicator scene](scenes/ui/damage_indicator.tscn) · [Style textures](textures/ui)

For a gameplay check, press **F5**, then **1** for a front hit, **3** for right, **5** for rear, or **7** for left. Keys **2**, **4**, **6**, and **8** test the diagonals.

Turn while a marker is visible to see it keep pointing toward the test hit's world position. Nearby bearings refresh one marker, and the HUD shows at most three markers.

## Verify item edits

Open an item resource in `data/items` from Godot's FileSystem dock, edit it in the Inspector, and save it. Restart the Playground with **F5** and press **F4** to see the read-only report. Godot also prints the same values to Output at launch. [Item authoring guide](docs/item_authoring.md)

## Tune the controller

| Change | Open in the editor |
| --- | --- |
| Default controls | **Project → Project Settings → Input Map** |
| Run speed, gait multipliers, jump height, acceleration, and stair limits | **Player → Movement → Settings** |
| Move, jump, crouch, walk, and dash bindings | **Player → Controls → Edit Input Map** |
| Dash speed, duration, charge capacity, and recharge time | **Player → Movement → Settings → Dash** |
| Crouch mode, capsule height, and eye-height transition | **Player → Crouch → Settings** |
| Mouse sensitivity, pitch, camera tilt, and stair smoothing | **Player → Look → Settings** |
| Base field of view | **Player → Look → Camera3D → FOV** |
| Dash FOV multiplier and blend times | **Player → Look → Camera3D → Dash FOV** |
| Dash streak blend times, distortion strength, and radial streak length | **PlayerPresentation → ScreenEffects → DashSpeedStreaks** and its **Material → Shader Parameters** |

Open the [Player scene](scenes/player/player.tscn) to access those components. See the [project architecture](docs/architecture.md) for the configured values, scene wiring, and folder layout.
