<!-- Copyright Francesco Di Blasi 2026 - All Rights Reserved -->

# Weapon animation

Use this module to preview a first-person animation library, author combo transitions, or read the metadata saved on a clip from game code.

## Preview a combo

Open the scene that owns the `AnimationPlayer`, select that node, and choose **Project → Tools → Weapon Animation (Native)**. The clip picker lists camera-rig animations with compatible pose tracks. Import clips if the scene only has a placeholder animation. Switch to **Combo** to arrange clips on the timeline. Select an overlap to choose its exit and entry markers or use exact times. **Loop Join** focuses on the selected pair. **Sequence View** restores the full timeline. **Save As** writes a combo resource that points to the same library-qualified clips.

Set `crimson/weapon_animation/default_combo` to a project resource path to preselect a combo. Carnage leaves this setting empty and configures `crimson/weapon_animation/preview_stage` for the reference environment. The preview displays a private copy of the camera rig and evaluates copied pose tracks. The project owns its player scene, preview assets, and gameplay callbacks.

[Editor guide](editor/README.md)

## Read animation data in gameplay

`CrimsonWeaponAnimationClip.from_player(player, key)` reads a detached clip snapshot. Use `sample_curve(name, seconds, fallback)` for authored float curves, `get_marker_time(name)` for named points, and `get_events_crossed(from_seconds, to_seconds)` to inspect the markers and notify events crossed in one step. Native Godot animation markers are stored independently.

`CrimsonWeaponAnimationTracks` stores clip markers, notify lanes, and float curves in the `weapon_tweaker_tracks` metadata field. `CrimsonWeaponAnimationCombo` stores clip order, named or numeric endpoints, blend durations, and loop behavior. The readers accept compatible fields saved by the original scripts and preserve their source library keys. Keep the old resource scripts available while existing assets reference their paths. [Runtime API and examples](../../../../../docs/weapon_animation_clip_api.md)
