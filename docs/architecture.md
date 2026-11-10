# Project architecture

## Project folders

| Folder | Contents |
| --- | --- |
| `data/items/` | Editable `ItemDefinition` resources |
| `data/player/` | Movement, look, and crouch tuning |
| `data/melee/` | Authored attack reach tuning |
| `data/effects/` | Shared blood splatter style |
| `scenes/` | Levels, player, characters, weapons, effect coordinators, and UI |
| `scripts/` | Player, melee, effect, item, and UI code in separate domain folders |
| `particles/` | Reusable particle scenes, including the directional blood burst |
| `materials/`, `shaders/`, `textures/`, `meshes/` | Standalone rendering assets |

Place new data-driven definitions under `data/<category>/`. Use type folders such as `particles/`, `textures/`, and `meshes/` when adding those assets. [Folder conventions](godot_conventions.md#folder-organization)

## Scenes and ownership

`project.godot` starts the Playground. The scene owns the ground, parkour blocks, arena walls, lighting, and environment. It instances the Player, two stair courses, crouch tunnels, the blood test target and effect coordinator, and the read-only item catalog inspector. The course uses the grid materials under `materials/prototype/`. [Project settings](../project.godot) · [Playground scene](../scenes/levels/playground.tscn)

The Player is a `CharacterBody3D` with a standing capsule **1.80 m** high and **0.35 m** in radius. The body origin is at the feet, and the `Look` pivot places the standing eye at **1.62 m**. [Player scene](../scenes/player/player.tscn)

| Owner | Responsibility | Settings |
| --- | --- | --- |
| Player | Reads the Input Map and resolves stance and gait before each movement step | [Project settings](../project.godot) |
| Movement | Advances velocity and collisions, including acceleration, braking, gravity, jumps, and stairs | [Movement settings](../data/player/default_movement_settings.tres) |
| Crouch | Resizes the capsule, checks standing clearance, and blends eye height | [Crouch settings](../data/player/default_crouch_settings.tres) |
| Look | Handles mouse capture and aiming, camera roll, and stair height compensation | [Look settings](../data/player/default_look_settings.tres) |

## Movement and jumping

The controller reads movement input while the mouse is captured. With the mouse released, it supplies neutral input while braking, gravity, and collision continue. Movement limits diagonal input to unit length, uses separate ground and air acceleration and braking, and calls `move_and_slide()` once per physics tick. [Controller](../scripts/player/player.gd) · [Movement](../scripts/player/first_person_movement.gd)

| Gait | Input and stance | Configured ground speed |
| --- | --- | --- |
| Run | Standing | 4 m/s |
| Walk | Standing with Ctrl held | 2 m/s |
| Sprint | Standing with Shift held | 6 m/s |
| Crouch | Crouched | 2.4 m/s |
| Crouch walk | Crouched with Ctrl held | 1.2 m/s |

Walk and crouch override sprint. Jump requires floor support or a remaining **0.25 s** coyote window, with a gait other than sprint. The authored jump height is **1.50 m** standing and **0.75 m** crouched, with **24 m/s²** custom gravity. Sprint speed gained on the ground carries over when leaving an edge. Air steering uses the normal run cap when sprint is selected. [Gait selection](../scripts/player/first_person_gait.gd) · [Movement tuning fields](../scripts/player/first_person_movement_settings.gd)

## Crouch, stairs, and camera

Enter crouch while supported on a tick without a jump request. The capsule immediately changes to **1.10 m**, keeping its bottom at the feet, while the eye blends to **0.95 m** over **0.20 s**. Standing checks the full standing capsule. **Toggle** is the saved input mode and requires another press after a blocked stand. **One Shot** follows the held button and retries standing after release as clearance returns. [Crouch controller](../scripts/player/first_person_crouch.gd) · [Crouch tuning fields](../scripts/player/first_person_crouch_settings.gd)

During the crouch blend, the eye can descend early to clear a low ceiling. Moving the Player from outside the locomotion step invalidates its previous floor and stair support, clears coyote time, and resets stair camera compensation. [Crouch clearance](../scripts/player/first_person_crouch.gd) · [Movement support](../scripts/player/first_person_movement.gd)

Movement uses an internal stair-step helper for risers up to **0.30 m** and walkable slopes up to **45°**. Floor snapping supports descent. The saved `terrain_advanced` and `terrain_reset` connections drive Look's **0.10 s** stair spring. The Player body turns for yaw, the Look pivot tilts for pitch, and Camera3D rolls with lateral movement. [Stair stepper](../scripts/player/first_person_stair_stepper.gd) · [Look controller](../scripts/player/first_person_look.gd)

## Melee

Open **Player → AnimationPlayer** to edit `idle`, `slash` for the right hand, and `slash_left` for the left. Key the position and rotation of **Look → Camera3D → WeaponControl** for the right mount and **LeftWeaponControl** for the left. The left mount's saved pose and idle keys mirror the right mount across camera-local X. Its slash mirrors the right-hand keys, so it travels left to right. To preview the short sword on the right while scrubbing, hide **PrototypeSword** and show **ShortSword**. [Player scene](../scenes/player/player.tscn) · [Long sword](../scenes/weapons/prototype_sword.tscn) · [Short sword](../scenes/weapons/short_sword.tscn)

With the mouse captured, left click starts on the right hand and alternates on each accepted slash. The other hand holds its idle pose. WeaponControl evaluates the animation during physics after Player movement and queries the attacking sword's sweep. The `HitStart` and `HitEnd` markers define the contact window for each clip. Both use **0.10 s to 0.30 s**, followed by animated recovery to **0.44 s**. One click during the slash queues the next hand and starts it at the end of recovery. **1** and **2** switch the right-hand sword between long and short, and the left hand holds a long sword. Switching the right sword or releasing mouse capture during a slash returns to idle and clears the queued input. [Playback](../scripts/melee/first_person_melee.gd)

Each sword owns a **MeleeSweep**. Move **SweepStart** and **SweepEnd** to set the base span. Rotate **SweepStart** around the blade axis to set the box orientation. **Width** and **Height** set the full cross-section in meters. [Sweep component](../scripts/melee/melee_sweep_3d.gd)

**WeaponControl → Slash Reach** holds the reach tuning for this attack. The same resource applies to either sword. The full length is `base span × 1.10 × Reach Multiplier + Flat Bonus`, clamped at zero. **Flat Bonus** adds meters to the length. **Blade Offset** moves both ends by the same distance along the blade, positive toward the tip and negative toward the grip. The saved values are **2×**, **+0.60 m**, and **+0.15 m**. The attack snapshots these settings when the slash starts. Clearing **Slash Reach** uses the weapon's base box. [Slash Reach](../data/melee/slash_reach.tres) · [Reach resource](../scripts/melee/melee_attack_reach.gd)

The Player scene previews the adjusted slash box as you scrub. A weapon scene opened on its own previews the base box. In play the sweep checks the opening overlap, then traces the previous blade span, blade rotation, and base translation between sampled poses. It reports one contact per physics body per swing and excludes the player.

**MeleeSweep → Debug** controls the editor preview, the in-game overlay, and the lifetime of the queried volumes. Enable **Show Sweeps** for the in-game overlay. Both saved swords have it disabled. Cyan shows the sweep geometry and orange marks contact with physics geometry. The Playground walls and blocks already have collision on the queried layer. [Reach comparison](../README.md#test-melee-reach)

**WeaponControl → Weapon Clearance** defaults to physics layer 1, **2.5 cm** of padding, and **0.12 s** for full recovery. After evaluating the final pose of each physics tick, WeaponControl checks each visible sword separately using a box enclosing the camera and the meshes under that sword's **Visuals** node. An overlap scales those meshes toward the camera while preserving their projected proportions. The grip markers and **MeleeSweep** stay on the authored pose. Put replacement meshes under **Visuals** to include their bounds. The saved sword meshes have shadow casting disabled. Lighting and reflections can still use the compressed world-space geometry. [Clearance helper](../scripts/melee/weapon_clearance.gd) · [Sword mesh settings](../scenes/weapons/prototype_sword.tscn)

## Blood impacts

The Playground places an animated, skinned test target and a backstop in front of the player. **MeleeSweep** reports a world-space point and normal when it finds a valid surface sample for a contacted body. **WeaponControl** samples each sword's **BloodMotion** marker between animation poses, falling back to **SweepEnd** and then to the sweep origin if the marker is absent. If the blade barely moves, the saved **Contact Direction Fallback** of zero resolves to camera forward. Starting with the contacted body and walking up its ancestors, **MeleeSweep** finds the nearest node that implements `receive_hit` and independently finds the nearest node with a direct **BloodComponent** child. It delivers the contact to both receivers when present, once each per swing. [Melee sweep](../scripts/melee/melee_sweep_3d.gd) · [Test target](../scenes/characters/blood_test_target.tscn)

Add **BloodComponent** directly under the scene root that owns the hit bodies, or under the hittable physics body itself. It handles the spray and world deposits with **Humanoid Blood** by default. Assign a **Blood Profile** on the component to override that preset. The profile groups the burst scene and its multipliers, world launch and projection settings, and body stain settings. Its **Splatter Style** references the shared artwork and appearance controls. Duplicate the profile for another enemy type and reuse the style or duplicate it for a different decal palette or mask set. The first hit creates a shared **BloodImpact** presenter for that level branch. The presenter starts the burst and owns **BloodWorld** as an internal child. Each queued world droplet keeps the profile until impact, so it can finish after the hit target despawns. World caps, lifetimes, and collision settings belong to the internal pool. [Component scene](../scenes/effects/blood_component.tscn) · [Coordinator](../scripts/effects/blood_impact.gd) · [Profile fields](../scripts/effects/blood_profile.gd)

On a plain collider the airborne burst starts 1.5 cm beneath the sampled contact. With a configured skinned mesh and a bone-attached hit body, the component probes the mesh's cached bind-pose triangles in the struck bone's frame. The burst starts 1.5 cm beneath the nearest rendered triangle along its normal, or uses an inward collider center if the surface probe misses. The body stain and world droplets use the original collision point. [Blood component](../scripts/effects/blood_component.gd)

The saved **BloodBurst** launches three one-shot GPU emitters in world space. **ImpactMist** builds a dense, short-lived, stippled cloud at the hit. **LiquidPatches** draws thin torn filaments and a smaller group of delayed cohesive lobes that lift and break into flecks. **Droplets** sends finer, irregular spray along independently damped trajectories. The procedural draw shader softens particles at opaque scene depth. The coordinator shuffles ten launch patterns before repeating. The scene and draw material supply the authored defaults. The profile multiplies tint, emitter counts, speed, spread, and liquid trail length per burst. [Burst scene](../particles/blood_burst.tscn) · [GPU motion shader](../shaders/effects/blood_burst_process.gdshader) · [Draw shader](../shaders/effects/blood_burst.gdshader)

**BloodWorld** launches an invisible physics droplet with a sweep radius of 1 cm. Its speed comes from the enemy profile. These world queries place decals independently of the visible burst. On character hits, **Character Spray Spread** varies the launch direction, and a second, steeper droplet deposits fallout near the target's feet. Both droplets use gravity and swept world queries, excluding the attacker and target. Fallout stops at obstructions and only marks floors. Wall projections start at 1.80 × 2.15 m and project through 22 cm. **Wall Center Shift** moves each wall stamp along the surface while keeping its collision point inside the projection. Floor projections start at 1.95 × 2.15 m with 16 cm of depth and stretch on glancing impacts. Fallout uses 76% of that footprint before style variation. World marks attach to the hit node when available and share a 60-second lifetime and 50-mark cap in the saved Playground. **Blood Profile → Debug → Show Droplet Wires** draws the active physics spheres for that profile at their query radius in play. Wires disappear when the corresponding droplets land or expire. [World settings](../scenes/effects/blood_world.tscn) · [Decal](../scenes/effects/blood_world_decal.tscn)

Rigid props get a shallow decal at the hit, attached to the mesh so it follows movement. The component uses an explicitly assigned **Body Stain Mesh → Surface**, the closest mesh on the hit body's path to the component's parent, or the sole visible rigid mesh under that parent. When the collision shape is slightly offset, the component checks for the visible surface near the contact and projects from that point. The decal uses the selected mesh's visual layers.

For skinned body stains, assign the component's **Body Stain Mesh → Skeleton** and **Surface**. Give surface 0 the stain shader and put the hit bodies directly under bone attachments on the assigned skeleton. The component converts the contact from the animated hit bone to the mesh's bind pose. The shader samples bind position and normal from `CUSTOM0` and `CUSTOM1`, so the projected textures follow the skinned surface. Both types retain up to **Stain Limit** marks per target. At the limit, a new hit replaces the oldest mark. **Stain Size** sets the footprint before variation, and **Stain Depth** defaults to 8 cm on either side of the contact plane. The mannequin renders on visual layer 2, while the world decal's render cull mask projects onto visual layer 1. The droplet separately queries physics layer 1 through **World Mask**. [Mannequin setup](../scenes/characters/blood_test_target.tscn) · [Stain shader](../shaders/effects/blood_stain.gdshader)

The shared **Blood Splatter Style** owns tint, footprint, angle variation, and wet finish. Floor and wall hits use the same sixteen generated deposits from **Floor Variants**. Each includes an albedo and coverage map and a nonmetallic roughness map. Pooled deposits also use a shallow relief normal. **Wall Drips** variants follow the surface's downhill direction with a small angle variation. The wall shuffles a pool per profile and uses every available texture before repeating, including a check against immediate repeats when reshuffling. Dense patches are smoother than their edges. **Floor Albedo Mix** controls how much receiver color remains under the deposit. Body hits alternate two generated cast-off patterns with matched roughness. **Wet Roughness** is the fallback for a pattern without a roughness texture. Oblique hits alternate rotation sides around the projected motion. Floor and wall rotation histories are tracked separately. Nearly head-on hits turn 60–150° from the previous offset. [Style settings](../data/effects/blood_splatter_style.tres) · [Godot decal material channels](https://docs.godotengine.org/en/latest/classes/class_decal.html)

The deposit textures use 640 × 640 albedo and coverage maps with 384 × 384 roughness and relief maps. Their silhouettes came from three generated grayscale atlases. The supplied *Vermintide 2* footage and read-only study of its installed textures and VFX code informed the shape, buildup, and timing. [Deposit textures](../textures/effects/blood_deposits)

## Item definitions

The Godot Inspector authors `ItemDefinition` resources in `data/items`. At startup, the Playground's read-only **F4** inspector loads and validates those resources through `ItemCatalog`. The inspector displays definition metadata and reports rejected files by filename. The test swords are wired directly in the Player scene. [Item authoring guide](item_authoring.md) · [Catalog loader](../scripts/items/item_catalog.gd) · [Inspector scene](../scenes/ui/item_definition_inspector.tscn)
