# Player

Apply the [project instructions](../../AGENTS.md) and [Godot conventions](../../docs/godot_conventions.md). [Movement architecture](../../docs/architecture.md#movement-and-jumping) describes the saved scene and component ownership.

- Boot the stock native controller from **Controls** and let its Mover driver advance collision once per physics tick. Use the authored **Mover** settings.
- Enable the Locomotion input map only while the mouse is captured. Keep braking, gravity, and collision active when steering is released.
- Assign the optional Crouch Action resource in Controls. The native controller routes that input to Mover, which resolves crouch before the movement step. Keep the capsule bottom at the feet and check the full standing volume using the collision mask and exceptions. Toggle standing requires a fresh press after an obstruction. One Shot retries after release.
- Subscribe to the live Mover's `landed` signal for landing effects. Read `get_last_fall_distance()` during the callback for fall damage in either combat form. WeaponControl owns the sword reaction in sword form.
- Route mapped mouse aim through Controls to Look. Keep body yaw, eye pitch, camera roll, and imported camera animation on their existing transforms. Author sensitivity on Controls and pitch, roll, and movement FOV on Camera3D. Mover owns stair smoothing and camera clearance. Look composes its output with roll and camera animation. Keep the weapon rig's physics callback after the stock Mover driver.
- Apply incoming damage through `PlayerStats.apply_damage()`. PlayerPresentation responds to `damage_taken` for hit feedback. DamageVignette owns the optional low-health pulse and draws over the ordinary post-processing vignette.
