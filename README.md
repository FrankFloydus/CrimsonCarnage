# Crimson Carnage

A first-person playground configured for Godot 4.8 beta, Forward Plus, and Jolt Physics. Open `project.godot` with the local editor built from upstream Godot and press **F5**. The course includes a walled arena, parkour blocks, two staircases, and crouch tunnels. [Windows editor](../Godot_RPG.exe) · [Playground scene](scenes/levels/playground.tscn)

| Control | Action |
| --- | --- |
| WASD | Move |
| Mouse | Look |
| Space | Jump |
| C | Toggle crouch |
| Hold Shift | Sprint |
| Hold Ctrl | Walk |
| Escape | Release the mouse |
| Left click | Alternate right- and left-hand slashes while captured, or recapture the mouse |
| 1 / 2 | Select the long / short sword for the right hand |
| F4 | Show or hide the read-only item catalog report |

The game captures the mouse on startup. Press **Escape** or switch focus to release it. Click inside the viewport to resume input. Walk and crouch take precedence over sprint. Release **Shift** before jumping from a sprint.

## Test melee reach

Press **F5** and click twice in quick succession. The right sword slashes from right to left, then the left sword slashes from left to right. An early second click starts the left slash when the right sword finishes recovering.

For visual debugging, enable **MeleeSweep → Debug → Show Sweeps** on the sword scenes. Face the south arena wall and compare right-hand slashes with **1** and **2** from the same spot. Allow the intervening left-hand slash to finish between right-hand tests. Cyan shows the queried volumes and orange shows a world contact.

Open **Player → Look → Camera3D → WeaponControl → Slash Reach** to tune the attack multiplier, flat bonus, and blade offset for both hands. In each weapon scene, select **MeleeSweep** to set the width, height, collision mask, and debug duration. Its **SweepStart** and **SweepEnd** markers set the base span. [Slash Reach](data/melee/slash_reach.tres) · [Long sword](scenes/weapons/prototype_sword.tscn) · [Short sword](scenes/weapons/short_sword.tscn) · [Melee authoring](docs/architecture.md#melee)

To test weapon clearance, walk up to an arena wall or a parkour block and slash with both hands. Turn across a corner, then back away. Each visible sword fits between the camera and world collision and returns to its authored depth as space opens up. **WeaponControl → Weapon Clearance** holds the collision layers, padding, and recovery time.

## Test blood impacts

Press **F5** and walk straight toward the animated target in front of the spawn. Get within about one sword length and left-click. Try the torso and upper arm. The burst blooms at the struck surface, then breaks into torn streaks and finer spray. Hit several times from the same spot to see the floor deposits overlap around the target. Look at the deposit from a low angle to see the wet highlights. Use consecutive slashes to test both hands, and **1** or **2** to choose the right-hand sword.

To add blood to a hittable scene, select its root and use **Add Child Node → BloodComponent**, or drag in the saved component scene. The object needs a physics body on a layer queried by the sword. On a rigid prop, a hit leaves a decal on the prop itself and sprays blood into the world. The component automatically uses a mesh above the hit body or the only visible rigid mesh under the prop. For a multipart prop, choose **Body Stain Mesh → Surface** if the mesh needs to be selected explicitly. **Blood Profile** defaults to **Humanoid Blood** when empty. Open the mannequin scene to see the optional skinned body stain setup. [Component scene](scenes/effects/blood_component.tscn) · [Default blood profile](data/effects/humanoid_blood_profile.tres) · [Blood effects architecture](docs/architecture.md#blood-impacts)

Enable **Blood Profile → Debug → Show Droplet Wires** to see that profile's moving collision spheres for world splatter and floor fallout in play.

## Verify item edits

Open an item resource in `data/items` from Godot's FileSystem dock, edit it in the Inspector, and save it. Restart the Playground with **F5** and press **F4** to see the read-only report. Godot also prints the same values to Output at launch. [Item authoring guide](docs/item_authoring.md)

## Tune the controller

| Change | Open in the editor |
| --- | --- |
| Default controls | **Project → Project Settings → Input Map** |
| Run speed, gait multipliers, jump height, acceleration, and stair limits | **Player → Movement → Settings** |
| Crouch mode, capsule height, and eye-height transition | **Player → Crouch → Settings** |
| Mouse sensitivity, pitch, camera tilt, and stair smoothing | **Player → Look → Settings** |

Open the [Player scene](scenes/player/player.tscn) to access those components. See the [project architecture](docs/architecture.md) for the configured values, scene wiring, and folder layout.
