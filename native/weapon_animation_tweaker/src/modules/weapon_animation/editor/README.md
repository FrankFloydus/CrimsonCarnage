<!-- Copyright Francesco Di Blasi 2026 - All Rights Reserved -->

# Weapon Animation editor

Open [player.tscn](../../../../../../scenes/player/player.tscn) directly in Godot and select its `AnimationPlayer`. Choose **Project → Tools → Weapon Animation (Native)**. Use **Refresh Rig** if the window is already open. The clip picker lists clips with an animated position track on a child of the first-person `Camera3D`. Carnage's trackless `sword/idle` placeholder can coexist with clips added through **Import Clips**.

These controls belong to the native window. The project's original GDScript dock is labeled **Weapon Animation Tweaker** and has its own layout.

In clip view, choose an animation and scrub its timeline. The camera is framed at 16:9 and the center crosshair marks the aim point. Play and pause with **Space** while the timeline has focus. The left and right arrows step through authored keys. Hold **Ctrl** while scrubbing to seek freely. Scroll to zoom around the pointer, drag the middle button to pan, and use **Fit** to frame the full duration.

## Edit a clip draft

1. Select a socket, mount, or rig joint under **Transform**. Edit its local position and rotation with the inspector or gizmo. **Set Key** records the clip pose at the playhead. **Set Mount** stages a model transform for **Apply**. Press **Tab** to switch to the orbit view and pick a joint when a pose hierarchy is available.
2. Use **Clip Motion** controls to change the socket path, camera depth, or clip duration. **Sockets** shows the socket guides. **Trails** shows the weapon trajectories and key positions.
3. Set the earlier and later counts in **Onion**. Zero spacing samples at the clip step. Choose another animation in the comparison picker and scrub it independently.
4. Add or edit the marker, notify, and curve rows below the ruler. Press **M** to place a marker at the playhead and **Delete** with a track item selected to remove it. The native track panel provides one-shot and state notifies, editable float curves, and **Save Preset** for curves.
5. Use **Undo**, **Redo**, and **Reset** to manage the draft. **Apply** writes the clip and mount changes to the edited scene in one Godot undo action. **Save Variant** creates an independent clip in the current library. Save the scene to persist the library changes.

For a repeated passage, select **Loop Region**, scrub to a boundary, and choose **Set In** or **Set Out**. The fields also accept seconds. **Play Once** pauses on the final pose. Use **Choose Scene** and **Play Scene** to run a saved test level.

## Author a sequence

1. Click **Combo**. Choose a source animation and click **Add Clip**, then add the next clip. **Open** also accepts a combo created by the original Tweaker plugin when the game project retains that resource's script.
2. Drag a clip block onto another to reorder it. Select a clip and use the arrow buttons for single-step changes. **Remove** deletes the step from the combo draft.
3. Click a band in **Blends**. Set the outgoing exit, incoming entry, and blend duration in the join inspector. Named markers come from the source animations. **Custom Time** sets an endpoint in seconds.
4. Choose **Loop Join** to focus on the selected blend, and choose **Sequence View** to return to the full timeline. **Close Loop** includes the final-to-first transition. Save the draft as a `.tres` with **Save As**.

The lanes show the effective sampled overlaps, including a reduced overlap when adjacent transitions compete for time. The preview evaluates copied pose tracks in an isolated viewport. Method, audio, and gameplay tracks stay on the source animation.

## Import Viewer animations

Open the scene that owns the target `AnimationPlayer` and select that node. Click **Import Clips**, choose a Vermintide Viewer clip pack, and select the clips. Choose a destination library or create one. A single import adds the selected clips in one editor undo action. Repeating the import skips source IDs already present in the destination library. Save the player scene to persist the import.

Carnage's socket tracks target the direct children `Look/Camera3D/WeaponControl` and `Look/Camera3D/LeftWeaponControl`. The camera-motion track targets `Look:attack_camera_motion`, which the player composes with its other view motion. To import joint channels, instance the [optional pose hierarchy](../../../../../../addons/weapon_animation_tweaker/native_pose/native_pose_rig.tscn) under `Camera3D` as `NativePoseRig` before importing the clip. The main player currently supplies the sockets and camera-motion channel.

## Project settings

Use `crimson/weapon_animation/default_combo` for a project resource path to an optional combo opened on first use. Use `crimson/weapon_animation/preview_stage` for the path to an optional `PackedScene` containing a reference environment and light. Set `crimson/weapon_animation/play_scene` to start with a specific gameplay test scene. The editor supplies neutral preview lighting when the stage setting is empty.

Carnage configures the private [preview stage](../../../../../../addons/weapon_animation_tweaker/preview_reference.tscn) and the [Playground](../../../../../../scenes/levels/playground.tscn) to play. The project starts without a default combo. [Project settings](../../../../../../project.godot)
