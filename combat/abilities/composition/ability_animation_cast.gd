class_name AbilityAnimationCast
extends RefCounted
## Reads release timing from the same method track used by the active animation.


static func marker_time(animation: Animation, release_event: StringName) -> float:
	var first_time := INF
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_METHOD \
				or not animation.track_is_enabled(track):
			continue
		for key in animation.track_get_key_count(track):
			var event: Dictionary = animation.track_get_key_value(track, key)
			var arguments: Array = event.get("args", [])
			if StringName(event.get("method", "")) == &"handle_animation_event" \
					and not arguments.is_empty() and StringName(arguments[0]) == release_event:
				var key_time := animation.track_get_key_time(track, key)
				if key_time >= 0.0 and key_time <= animation.length:
					first_time = minf(first_time, key_time)
	return first_time if is_finite(first_time) else -1.0


static func windup_progress(cast: AbilityCast, animation_name: StringName) -> float:
	if cast == null or cast.released or cast.finished:
		return -1.0
	var system := cast.get_system()
	if system == null or system.get_animation_cast() != cast:
		return -1.0
	var player := system.animation_player
	var release_time := float(cast.data.get(&"release_time", -1.0))
	if not is_instance_valid(player) or not player.is_playing() \
			or player.current_animation != animation_name or release_time <= 0.0:
		return -1.0
	return clampf(player.current_animation_position / release_time, 0.0, 1.0)
