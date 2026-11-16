# Player

Apply the [project instructions](../../AGENTS.md) and [Godot conventions](../../docs/godot_conventions.md). [Movement architecture](../../docs/architecture.md#scenes-and-ownership) describes the saved scene and component ownership.

- Sample the Framework input scope from **Controls → Input Layout** while the mouse is captured. Feed neutral input while the mouse is released so braking, gravity, and collision continue.
- Resolve crouch and gait before advancing Movement once per physics tick. Allow jump from floor or coyote support in each gait.
- Enter crouch on a supported tick without a jump request. Keep the capsule bottom at the feet. Use the full standing volume, collision mask, and exceptions when testing clearance. Toggle standing requires a fresh press after an obstruction. One Shot retries standing once the button is released.
- Keep baseline run speed, gait multipliers, jump heights, dash tuning, acceleration, gravity, and stair settings under **Movement → Settings**. Keep stance and look tuning in their respective settings. Store per-player state on components and helpers.
- Use Movement's native MoverComponent solver for custom gravity, coyote time, air steering, dash charge recovery, stair support, and one `move_and_slide()` per physics tick. Keep stair camera compensation in Look through the scene's terrain signal connections.
- Require a directional input to begin a dash. An idle press leaves the charge count and dash presentation alone.
- Keep body yaw, eye pivot pitch, and camera roll on separate transforms. Crouch owns the eye pivot height and Look owns stair compensation on the camera.
- Keep FOV transitions on **Look → Camera3D** and the screen-space distortion on **PlayerPresentation → ScreenEffects → DashSpeedStreaks**. Route Movement's saved dash connections to **Camera3D** and **PlayerPresentation** so they follow accepted dashes and actual stops.
