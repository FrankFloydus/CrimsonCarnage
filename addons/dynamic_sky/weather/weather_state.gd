@tool
extends RefCounted
## Blends the global profile and resolves prioritized spatial overrides.

var current: Dictionary[StringName, Variant]
var view: Dictionary[StringName, Variant]
var _zones: Array[DynamicSkyWeatherZone]
var _transition_from: Dictionary[StringName, Variant]
var _transition_to: Dictionary[StringName, Variant]
var _transition_profile: DynamicSkyWeather
var _transition_elapsed: float = 0.0
var _transition_seconds: float = 0.0


func apply(profile: DynamicSkyWeather) -> void:
	_transition_profile = null
	current = profile.sample()
	view = current


func blend_to(profile: DynamicSkyWeather, seconds: float) -> void:
	_transition_from = current.duplicate()
	_transition_to = profile.sample()
	_transition_profile = profile
	_transition_elapsed = 0.0
	_transition_seconds = seconds


func advance(delta: float) -> DynamicSkyWeather:
	if _transition_profile == null:
		return null
	_transition_elapsed += delta
	var progress := clampf(_transition_elapsed / _transition_seconds, 0.0, 1.0)
	if progress < 1.0:
		var weight := smoothstep(0.0, 1.0, progress)
		for channel in current:
			current[channel] = lerp(_transition_from[channel], _transition_to[channel], weight)
		return null

	var completed_profile := _transition_profile
	current = _transition_to
	_transition_profile = null
	return completed_profile


## Writes independent copies of the weather channels and any active blend into the snapshot.
func capture_into(snapshot: DynamicSkySnapshot) -> void:
	if snapshot == null:
		return
	snapshot.current_weather = null if current.is_empty() else _make_profile(current)
	if _transition_profile == null:
		snapshot.transition_from = null
		snapshot.transition_to = null
		snapshot.transition_elapsed = 0.0
		snapshot.transition_seconds = 0.0
		return
	snapshot.transition_from = _make_profile(_transition_from)
	snapshot.transition_to = _make_profile(_transition_to, _transition_profile.resource_name)
	snapshot.transition_elapsed = _transition_elapsed
	snapshot.transition_seconds = _transition_seconds


## Restores the original blend endpoints and clock. Invalid snapshots leave the state unchanged.
func restore_from(snapshot: DynamicSkySnapshot) -> bool:
	if snapshot == null or snapshot.current_weather == null:
		return false
	var restored_current := snapshot.current_weather.sample()
	var elapsed := snapshot.transition_elapsed
	var duration := snapshot.transition_seconds
	if (
		not _has_finite_channels(restored_current)
		or not is_finite(elapsed) or elapsed < 0.0
		or not is_finite(duration) or duration < 0.0
	):
		return false

	var restored_from: Dictionary[StringName, Variant]
	var restored_to: Dictionary[StringName, Variant]
	var restored_profile: DynamicSkyWeather
	if duration > 0.0:
		if snapshot.transition_from == null or snapshot.transition_to == null or elapsed >= duration:
			return false
		restored_from = snapshot.transition_from.sample()
		restored_to = snapshot.transition_to.sample()
		if not _has_finite_channels(restored_from) or not _has_finite_channels(restored_to):
			return false
		restored_profile = _make_profile(restored_to, snapshot.transition_to.resource_name)
	elif elapsed != 0.0 or snapshot.transition_from != null or snapshot.transition_to != null:
		return false

	current = restored_current
	view = current
	_transition_from = restored_from
	_transition_to = restored_to
	_transition_profile = restored_profile
	_transition_elapsed = elapsed
	_transition_seconds = duration
	return true


func refresh_view(world: World3D, tree: SceneTree, camera: Camera3D) -> void:
	collect_zones(world, tree)
	view = current if camera == null else sample_at(camera.global_position)


func collect_zones(world: World3D, tree: SceneTree) -> void:
	_zones.clear()
	for zone: DynamicSkyWeatherZone in tree.get_nodes_in_group(DynamicSkyWeatherZone.GROUP):
		if zone.get_world_3d() == world and zone.enabled:
			_zones.append(zone)
	_zones.sort_custom(_zone_has_lower_priority)


func sample_at(world_position: Vector3) -> Dictionary[StringName, Variant]:
	var resolved := current
	var has_override := false
	for zone in _zones:
		if not is_instance_valid(zone) or not zone.is_inside_tree():
			continue
		var weight := zone.get_weather_weight(world_position)
		if weight == 0.0:
			continue
		if not has_override:
			resolved = current.duplicate()
			has_override = true
		var target := zone.weather.sample()
		for channel in resolved:
			resolved[channel] = lerp(resolved[channel], target[channel], weight)
	return resolved


func _zone_has_lower_priority(first: DynamicSkyWeatherZone, second: DynamicSkyWeatherZone) -> bool:
	if first.priority == second.priority:
		return second.is_greater_than(first)
	return first.priority < second.priority


func _make_profile(channels: Dictionary[StringName, Variant], profile_name: String = "") -> DynamicSkyWeather:
	var profile := DynamicSkyWeather.new()
	profile.resource_name = profile_name
	for channel in channels:
		profile.set(channel, channels[channel])
	return profile


func _has_finite_channels(channels: Dictionary[StringName, Variant]) -> bool:
	for value in channels.values():
		if value is float and not is_finite(value):
			return false
		if value is Vector2 and not value.is_finite():
			return false
	return true
