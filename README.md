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
| Left click | Alternate right- and left-hand slashes while captured, or recapture the mouse |
| 1–8 | Preview incoming damage from eight directions |
| 9 / 0 | Select the long / short sword for the right hand |
| F4 | Show or hide the read-only item catalog report |

The game captures the mouse on startup. Press **Escape** or switch focus to release it. Click inside the viewport to resume input. You can jump at normal speed or while holding **Ctrl** to walk.

## Try Dynamic Sky

In the Godot editor, choose **Project → Tools → Open Dynamic Sky Demo** and press **F6**. West Ridge Observatory has exposed, sheltered, and lakeshore viewpoints. Switch between **Rain**, **Snow**, **Storm**, and **Sandstorm** to compare precipitation, accumulation, and audio. **Trigger Lightning** previews a distant strike and its delayed thunder. **Project → Tools → Add Dynamic Sky** inserts the editable rig into a 3D scene. [Addon guide](docs/dynamic_sky.md) · [Ultra Dynamic Sky 9.7 audit](docs/ultra_dynamic_sky_audit.md)

## Test the dash

Press **F5**, hold a movement direction, and tap **Left Shift** to dash. With no movement direction held, tapping **Left Shift** leaves your charges and FOV alone. Jump and dash midair to test the same short burst. Tap twice, allowing the first burst to finish before pressing again. A third dash becomes available one second after the first charge was spent. Try dashing into an arena wall to check that contact ends the burst.

The view narrows from **50° to 40°** on a straight forward or backward dash and eases back when it ends, including when you hit a wall. Near the screen edges, dash distortion bends world details and stretches them outward into streaks. Try **A + Left Shift** or **W + A + Left Shift** to see the effect on side and diagonal dashes, where the FOV stays at its base value.

## Test melee reach

Press **F5** and click twice in quick succession. The right sword slashes from right to left, then the left sword slashes from left to right. An early second click starts the left slash when the right sword finishes recovering.

For visual debugging, enable **MeleeSweep → Debug → Show Sweeps** on the sword scenes. Face the south arena wall and compare right-hand slashes with **9** and **0** from the same spot. Allow the intervening left-hand slash to finish between right-hand tests. Cyan shows the queried volumes and orange shows a world contact.

Open **Player → Look → Camera3D → WeaponControl → Slash Reach** to tune the attack multiplier, flat bonus, and blade offset for both hands. In each weapon scene, select **MeleeSweep** to set the width, height, collision mask, and debug duration. Its **SweepStart** and **SweepEnd** markers set the base span. [Slash Reach](data/melee/slash_reach.tres) · [Long sword](scenes/weapons/prototype_sword.tscn) · [Short sword](scenes/weapons/short_sword.tscn) · [Melee authoring](docs/architecture.md#melee)

To test weapon clearance, walk up to an arena wall or a parkour block and slash with both hands. Turn across a corner, then back away. Each visible sword fits between the camera and world collision and returns to its authored depth as space opens up. **WeaponControl → Weapon Clearance** holds the collision layers, padding, and recovery time.

## Test blood impacts

Press **F5** and walk straight toward the animated target in front of the spawn. Get within about one sword length and left-click. Try the torso and upper arm. The burst blooms at the struck surface, then breaks into torn streaks and finer spray. Hit several times from the same spot to see the floor deposits overlap around the target. Look at the deposit from a low angle to see the wet highlights. Use consecutive slashes to test both hands, and **9** or **0** to choose the right-hand sword.

A slash on the mannequin within **3 m** of the camera also puts droplets and smears on the view. Turn or dash immediately after the hit to see the marks stay on the screen as the world moves. They clear in a few seconds. Walls and the rigid blood prop do not trigger the lens preview. Tune it in **Player → ScreenEffects → LensBlood**. The Playground root holds the preview range.

Hit the mannequin or an arena wall with either sword to preview the **Damage Vignette**. The edges briefly darken red on the first contact of a swing. A swing through empty air leaves the view clear. Tune pulse strength, rise time, and fade time under **Player → ScreenEffects → DamageVignette**. Open its **Material → Shader Parameters** to edit the tint, scale the feathered mask, or assign a different mask texture.

To add blood to a hittable scene, select its root and use **Add Child Node → BloodComponent**, or drag in the saved component scene. The object needs a physics body on a layer queried by the sword. On a rigid prop, a hit leaves a decal on the prop itself and sprays blood into the world. The component automatically uses a mesh above the hit body or the only visible rigid mesh under the prop. For a multipart prop, choose **Body Stain Mesh → Surface** if the mesh needs to be selected explicitly. **Blood Profile** defaults to **Humanoid Blood** when empty. Open the mannequin scene to see the optional skinned body stain setup. [Component scene](scenes/effects/blood_component.tscn) · [Default blood profile](data/effects/humanoid_blood_profile.tres) · [Blood effects architecture](docs/architecture.md#blood-impacts)

Enable **Blood Profile → Debug → Show Droplet Wires** to see that profile's moving collision spheres for world splatter and floor fallout in play.

## Tune post-processing

Press **F5** to see the vignette, posterization, and ordered dithering in the Playground. Open the **PostProcessing** scene and select **Pass → Material → Shader Parameters** to tune the three effects. **Vignette Start** and **Vignette Feather** shape the edge darkening. **Posterization Levels** sets the number of shades per color channel. **Dither Pixel Size** sets the pattern's cell size in render pixels. Set an effect's strength to zero to disable it, or hide **Player → ScreenEffects → PostProcessing** to bypass the full pass. [PostProcessing scene](scenes/effects/post_processing.tscn)

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
| Dash speed, duration, charge capacity, and recharge time | **Player → Movement → Settings → Dash** |
| Crouch mode, capsule height, and eye-height transition | **Player → Crouch → Settings** |
| Mouse sensitivity, pitch, camera tilt, and stair smoothing | **Player → Look → Settings** |
| Base field of view | **Player → Look → Camera3D → FOV** |
| Dash FOV multiplier and blend times | **Player → Look → Camera3D → CameraEffects → Dash FOV** |
| Dash streak blend times, distortion strength, and radial streak length | **Player → ScreenEffects → DashSpeedStreaks** and its **Material → Shader Parameters** |

Open the [Player scene](scenes/player/player.tscn) to access those components. See the [project architecture](docs/architecture.md) for the configured values, scene wiring, and folder layout.
