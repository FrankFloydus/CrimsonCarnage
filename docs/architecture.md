# Movement architecture

## Scenes and ownership

`project.godot` starts the Playground. The scene owns the ground, parkour blocks, arena walls, lighting, and environment. It instances the Player, Low Stairs, High Stairs, and Crouch Tunnels. The course uses the grid materials under `materials/prototype/`. [Project settings](../project.godot) · [Playground scene](../levels/playground/playground.tscn)

The Player is a `CharacterBody3D` with a standing capsule **1.80 m** high and **0.35 m** in radius. The body origin is at the feet, and the `Look` pivot places the standing eye at **1.62 m**. [Player scene](../player/player.tscn)

| Owner | Responsibility | Settings |
| --- | --- | --- |
| Player | Reads the Input Map and resolves stance and gait before each movement step | [Project settings](../project.godot) |
| Movement | Advances velocity and collisions, including acceleration, braking, gravity, jumps, and stairs | [Movement settings](../player/default_movement_settings.tres) |
| Crouch | Resizes the capsule, checks standing clearance, and blends eye height | [Crouch settings](../player/default_crouch_settings.tres) |
| Look | Handles mouse capture and aiming, camera roll, and stair height compensation | [Look settings](../player/default_look_settings.tres) |

## Movement and jumping

The controller reads movement input while the mouse is captured. With the mouse released, it supplies neutral input while braking, gravity, and collision continue. Movement limits diagonal input to unit length, uses separate ground and air acceleration and braking, and calls `move_and_slide()` once per physics tick. [Controller](../player/player.gd) · [Movement](../player/first_person_movement.gd)

| Gait | Input and stance | Configured ground speed |
| --- | --- | --- |
| Run | Standing | 4 m/s |
| Walk | Standing with Ctrl held | 2 m/s |
| Sprint | Standing with Shift held | 6 m/s |
| Crouch | Crouched | 2.4 m/s |
| Crouch walk | Crouched with Ctrl held | 1.2 m/s |

Walk and crouch override sprint. Jump requires floor support or a remaining **0.25 s** coyote window, with a gait other than sprint. The authored jump height is **1.50 m** standing and **0.75 m** crouched, with **24 m/s²** custom gravity. Sprint speed gained on the ground carries over when leaving an edge. Air steering uses the normal run cap when sprint is selected. [Gait selection](../player/first_person_gait.gd) · [Movement tuning fields](../player/first_person_movement_settings.gd)

## Crouch, stairs, and camera

Enter crouch while supported on a tick without a jump request. The capsule immediately changes to **1.10 m**, keeping its bottom at the feet, while the eye blends to **0.95 m** over **0.20 s**. Standing checks the full standing capsule. **Toggle** is the saved input mode and requires another press after a blocked stand. **One Shot** follows the held button and retries standing after release as clearance returns. [Crouch controller](../player/first_person_crouch.gd) · [Crouch tuning fields](../player/first_person_crouch_settings.gd)

Movement uses an internal stair-step helper for risers up to **0.30 m** and walkable slopes up to **45°**. Floor snapping supports descent. The saved `terrain_advanced` and `terrain_reset` connections drive Look's **0.10 s** stair spring. The Player body turns for yaw, the Look pivot tilts for pitch, and Camera3D rolls with lateral movement. [Stair stepper](../player/first_person_stair_stepper.gd) · [Look controller](../player/first_person_look.gd)

## Manny arms appearance

The Manny arms scene stores the shared skin tone and independent left and right tattoo, scar, grime, and blood selections on its root. The appearance script loads the selected textures in the Inspector and at runtime, using a separate copy of the base ShaderMaterial for each scene instance. The imported arms use the restored atlas UVs. The arm-side mask lets the shader select the matching overlays as the arms move. [Manny arms scene](../manny_arms_textured.tscn) · [Appearance script](../materials/arms/arms_appearance.gd) · [Base ShaderMaterial](../materials/arms/arms_skin.tres)

The root's **Skin Surface** controls apply to both arms. Normal strength scales the skin and nail relief from 0 to 2. Roughness strength ranges from smooth at 0 through the material's base roughness at 1 to fully matte at 2, before the shader applies the overlay finish.

The preset catalog owns the dropdown labels, texture keys, scar palettes, and finish values. Its order defines the stored selection IDs, so append new entries to preserve existing choices. Builds that use filtered resource exports must include `materials/arms/textures/` so the script can load every selectable map. [Preset catalog](../materials/arms/arms_preset_catalog.tres)
