# Weapon Animation Tweaker runtime API

`WeaponAnimationClip` is a GDScript reader for the data saved by **Apply** or **Save As** in the Weapon Animation Tweaker. Create a snapshot when choosing a clip, then reuse it while the clip plays. It reads from an `Animation` resource and can run without the editor plugin. A snapshot and its returned rows are independent copies. Read a new snapshot to pick up later edits.

```gdscript
const ClipData := preload("res://addons/weapon_animation_tweaker/weapon_animation_clip.gd")

func inspect_attack(player: AnimationPlayer, clip_key: StringName, time: float) -> void:
	var clip := ClipData.from_player(player, clip_key)
	if clip == null:
		return

	var recovery_time := clip.get_marker_time(&"Recovery")
	var reach := clip.sample_curve(&"Reach", time, 1.0)
	var traces := clip.get_active_notify_states(time, ClipData.MELEE_TRACE)
	print(recovery_time, " ", reach, " ", traces.size())
```

Clip keys use the same names as `AnimationPlayer.play()`, including a library prefix when present. A valid animation with no authored data yields an empty snapshot with its clip length. A missing animation or invalid stored data yields `null`.

## Inspect the clip

| Function | Returns |
| --- | --- |
| `from_animation(animation)` | A snapshot from an Animation resource. |
| `from_player(player, key)` | A snapshot from an AnimationPlayer library entry. |
| `get_duration()` | The clip length in seconds. |
| `get_curve_names()` | The curve names in authoring order. |
| `get_curve_info(name)` | The curve's `name`, `key_count`, and optional `color`. |
| `get_curve_keys(name)` | Key dictionaries in time order. |
| `sample_curve(name, seconds, fallback = 0.0)` | The value at a time in seconds. |
| `sample_curve_normalized(name, phase, fallback = 0.0)` | The value at a normalized phase from 0 to 1. |
| `get_markers()` | The Tweaker's named markers in authoring order. |
| `get_marker(name)` | A marker dictionary with `name`, `time` in seconds, and optional `color`. |
| `get_marker_time(name, fallback = -1.0)` | The marker's time in seconds. |
| `get_notify_track_names()` | The notify lane names in authoring order. |
| `get_notifies(name = &"")` | One-shot notifies, optionally filtered by exact name. |
| `get_notify_states(name = &"")` | Notify states, optionally filtered by exact name. |
| `get_active_notify_states(seconds, kind = &"")` | States active at that clip time, optionally filtered by kind. |

A missing marker or curve info lookup returns an empty dictionary. An unknown curve returns an empty key array. Sampling clamps to the clip and returns the fallback for a missing or empty curve or a nonfinite time. Keys include `time` in seconds, `phase` in the normalized clip domain, `value`, `mode`, `in_slope`, `out_slope`, `in_weight`, `out_weight`, `weighted_in`, and `weighted_out`. Compare `mode` against `ClipData.CurveMode`. Slopes and weights use normalized time coordinates. Automatic slopes reflect the curve's current neighboring keys within the snapshot.

Marker names are unique within the clip. They are authored separately from Godot's built-in Animation markers. Notify dictionaries contain `name`, `kind`, `time`, `track_name`, `track_index`, `entry_index`, and optional `color`. A state adds `end_time`. A state is active on `[time, end_time)`. Generic notifies use an empty `kind`, and a MeleeTrace state uses `ClipData.MELEE_TRACE`. Use the lane and entry indices to distinguish multiple notifies with the same name in a snapshot.

## Query events between samples

`get_events_crossed(previous, current, include_start = false)` returns the events in chronological order over `(previous, current]`. Pass `true` at the beginning of playback if you want events at the initial time. Forward queries clip to the animation bounds. A query beginning before the clip also crosses events at time zero. Backward and nonfinite queries return an empty array.

```gdscript
for event in clip.get_events_crossed(previous_time, current_time):
	match event.type:
		ClipData.EventType.STATE_STARTED:
			print("Begin ", event.name, " at ", event.time)
		ClipData.EventType.STATE_ENDED:
			print("End ", event.name, " at ", event.time)
		ClipData.EventType.NOTIFY, ClipData.EventType.MARKER:
			print("Passed ", event.name, " at ", event.time)
```

Events carry the corresponding notify or marker fields and a `type`. A state event's `time` is the crossed boundary, and `start_time` and `end_time` identify the original state. At a shared time, state ends come first, then state starts, then one-shot notifies, then markers. Events within the same type retain authoring order. An update that crosses both ends of a short state returns both events.

Use `get_loop_events_crossed(previous, current, loop_start = 0.0, loop_end = -1.0)` after exactly one wrap. It returns events from `(previous, loop_end]` followed by `[loop_start, current]`. The default loop end is the clip duration. For several wraps, query each crossing in order. When a custom loop starts or ends inside a state, use `get_active_notify_states()` to reconcile state at the loop entry. The application calling the reader decides how to act on the returned data.

[Runtime script](../addons/weapon_animation_tweaker/weapon_animation_clip.gd) · [Tweaker authoring guide](architecture.md#melee)
