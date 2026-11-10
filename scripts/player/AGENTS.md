# Player

Apply the [project instructions](../../AGENTS.md) and [Godot conventions](../../docs/godot_conventions.md). [Movement architecture](../../docs/architecture.md#scenes-and-ownership) describes the saved scene and component ownership.

- Read the saved Input Map while the mouse is captured. Feed neutral input while the mouse is released so braking, gravity, and collision continue.
- Resolve crouch and gait before advancing Movement once per physics tick. Walking and crouch take precedence over sprint. Allow jump from floor or coyote support when the selected gait permits it.
- Enter crouch on a supported tick without a jump request. Keep the capsule bottom at the feet. Use the full standing volume, collision mask, and exceptions when testing clearance. Toggle standing requires a fresh press after an obstruction. One Shot retries standing once the button is released.
- Keep baseline run speed, gait multipliers, jump heights, acceleration, gravity, and stair settings under **Movement → Settings**. Keep stance and look tuning in their respective settings. Store per-player state on components and helpers.
- Keep custom gravity, coyote time, air steering, stair support, and one `move_and_slide()` per physics tick in Movement. Keep stair camera compensation in Look through the scene's terrain signal connections.
- Keep body yaw, eye pivot pitch, and camera roll on separate transforms. Crouch owns the eye pivot height and Look owns stair compensation on the camera.
