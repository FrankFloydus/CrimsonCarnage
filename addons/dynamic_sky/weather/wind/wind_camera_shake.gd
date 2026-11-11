@tool
class_name DynamicSkyWindCameraShake
extends Node3D
## Adds reversible view offsets from the local wind field without changing camera rotation.

const WindSource = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")

## Opts this camera into motion from strong wind. Disable to restore the view immediately.
@export var enabled: bool = false:
	set(value):
		enabled = value
		if is_node_ready():
			set_physics_process(enabled and not Engine.is_editor_hint())
			set_process(enabled and not Engine.is_editor_hint())
			if not enabled:
				_reset_motion()

## Camera to affect. Empty uses a Camera3D parent, then the active viewport camera.
@export var camera_override: Camera3D

## Optional source of wind. Empty uses the first DynamicSky in this World3D.
@export var sky_rig: DynamicSky

## Owns the amplitude, frequency, wind thresholds, and shelter tuning for this camera.
@export var settings: DynamicSkyWindShakeSettings

var _sky: DynamicSky
var _camera: Camera3D
var _applied_offset: Vector2 = Vector2.ZERO
var _strength: float = 0.0
var _target_strength: float = 0.0
var _openness: float = 1.0
var _probe_remaining: float = 0.0
var _time: float = 0.0


func _ready() -> void:
	process_priority = 100
	set_physics_process(enabled and not Engine.is_editor_hint())
	set_process(enabled and not Engine.is_editor_hint())


func _exit_tree() -> void:
	_reset_motion()


func _get_configuration_warnings() -> PackedStringArray:
	if settings == null:
		return ["Assign Wind Shake Settings to author the camera response."]
	return []


func _physics_process(delta: float) -> void:
	if settings == null:
		_target_strength = 0.0
		return
	var target_camera := camera_override
	if not is_instance_valid(target_camera) or not target_camera.is_inside_tree():
		target_camera = get_parent() as Camera3D
	if not is_instance_valid(target_camera) or not target_camera.is_inside_tree():
		target_camera = get_viewport().get_camera_3d()
	if target_camera != _camera:
		_reset_motion()
		_camera = target_camera
	if not is_instance_valid(_camera) or _camera.get_world_3d() != get_world_3d():
		_target_strength = 0.0
		return
	_sky = WindSource.resolve(self, sky_rig, _sky)
	var wind := Vector3.ZERO if _sky == null else _sky.get_wind_at(_camera.global_position)
	_probe_remaining -= delta
	if _probe_remaining <= 0.0:
		_openness = _sample_openness(wind)
		_probe_remaining = maxf(settings.shelter_sample_interval, 0.05)
	var ramp := smoothstep(
		settings.start_wind_speed,
		maxf(settings.full_wind_speed, settings.start_wind_speed + 0.01),
		wind.length()
	)
	_target_strength = ramp * _openness


func _process(delta: float) -> void:
	if settings == null or not is_instance_valid(_camera):
		_reset_motion()
		return
	_remove_offset()
	_strength = lerpf(_strength, _target_strength, 1.0 - exp(-maxf(settings.response_rate, 0.1) * delta))
	_time += delta * maxf(settings.frequency_hz, 0.01) * TAU
	_time = fposmod(_time, TAU * 100.0)
	var broad := Vector2(sin(_time), sin(_time * 1.13 + 1.6))
	var flutter := Vector2(sin(_time * 2.31 + 0.7), sin(_time * 2.07 + 2.3))
	_applied_offset = (broad * 0.72 + flutter * 0.28) * settings.maximum_offset_meters * _strength
	_camera.h_offset += _applied_offset.x
	_camera.v_offset += _applied_offset.y


func _sample_openness(wind: Vector3) -> float:
	if settings.shelter_mask == 0:
		return 1.0
	var excluded: Array[RID] = []
	var ancestor: Node = _camera
	while ancestor != null:
		if ancestor is CollisionObject3D:
			excluded.append(ancestor.get_rid())
		ancestor = ancestor.get_parent()
	var origin := _camera.global_position
	var space := get_world_3d().direct_space_state
	var roof := PhysicsRayQueryParameters3D.create(
		origin, origin + Vector3.UP * settings.roof_probe_distance,
		settings.shelter_mask, excluded
	)
	roof.hit_from_inside = true
	if not space.intersect_ray(roof).is_empty():
		return 0.0
	if wind.is_zero_approx():
		return 1.0
	var upwind := PhysicsRayQueryParameters3D.create(
		origin, origin - wind.normalized() * settings.upwind_probe_distance,
		settings.shelter_mask, excluded
	)
	upwind.hit_from_inside = true
	return 1.0 if space.intersect_ray(upwind).is_empty() else 0.0


func _remove_offset() -> void:
	if is_instance_valid(_camera):
		_camera.h_offset -= _applied_offset.x
		_camera.v_offset -= _applied_offset.y
	_applied_offset = Vector2.ZERO


func _reset_motion() -> void:
	_remove_offset()
	_strength = 0.0
	_target_strength = 0.0
	_probe_remaining = 0.0
