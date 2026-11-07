class_name FirstPersonLook
extends Node3D
## Owns mouse capture, body yaw, eye pitch, and smoothed lateral camera roll.

## Character rotated around its vertical axis when the mouse moves horizontally.
@export var body: CharacterBody3D
## Editable mouse sensitivity, vertical look limit, and lateral camera tilt configuration.
@export var settings: FirstPersonLookSettings

@onready var _camera: Camera3D = $Camera3D

var _authored_camera_position: Vector3
var _stair_offset: float = 0.0
var _stair_velocity: float = 0.0


func _ready() -> void:
	_authored_camera_position = _camera.position
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"capture_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		body.rotate_y(-deg_to_rad(event.screen_relative.x * settings.mouse_sensitivity))
		var pitch_limit := deg_to_rad(settings.pitch_limit)
		rotation.x = clampf(
				rotation.x - deg_to_rad(event.screen_relative.y * settings.mouse_sensitivity),
				-pitch_limit,
				pitch_limit
		)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var lateral_speed := body.get_real_velocity().dot(body.global_basis.x)
	var tilt_fraction := clampf(lateral_speed / settings.full_tilt_speed, -1.0, 1.0)
	var target_roll := -deg_to_rad(settings.maximum_tilt) * tilt_fraction
	_camera.rotation.z = lerpf(
			_camera.rotation.z, target_roll, 1.0 - exp(-settings.tilt_response * delta)
	)
	if settings.stair_smoothing_time <= 0.0:
		clear_stair_smoothing()
	_update_stair_camera()


## Advances the critically damped stair spring once per movement tick.
func advance_terrain(delta: float, height_change: float) -> void:
	if settings.stair_smoothing_time <= 0.0:
		clear_stair_smoothing()
		return
	var omega := 2.0 / maxf(settings.stair_smoothing_time, 0.0001)
	var combined := _stair_velocity + omega * _stair_offset
	var decay := exp(-omega * delta)
	var next_offset := (_stair_offset + combined * delta) * decay
	var next_velocity := (_stair_velocity - omega * combined * delta) * decay
	if _stair_offset * next_offset < 0.0 or (
			absf(next_offset) < 0.000001 and absf(next_velocity) < 0.00001
	):
		next_offset = 0.0
		next_velocity = 0.0
	_stair_offset = next_offset - height_change
	_stair_velocity = next_velocity
	if _stair_offset * _stair_velocity > 0.0:
		_stair_velocity = 0.0
	_update_stair_camera()


## Drops pending stair compensation, including after teleports or disabling smoothing.
func clear_stair_smoothing() -> void:
	_stair_offset = 0.0
	_stair_velocity = 0.0
	_camera.position = _authored_camera_position


func _update_stair_camera() -> void:
	var offset := _stair_offset
	var eye := to_global(_authored_camera_position)
	if not is_zero_approx(offset):
		var padding := maxf(0.05, _camera.near)
		var excluded: Array[RID] = [body.get_rid()]
		for exception in body.get_collision_exceptions():
			excluded.append(exception.get_rid())
		var query := PhysicsRayQueryParameters3D.create(
				eye, eye + Vector3.UP * signf(offset) * (absf(offset) + padding),
				body.collision_mask, excluded
		)
		query.hit_from_inside = true
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			var hit_position: Vector3 = hit.position
			var allowed := maxf(0.0, eye.distance_to(hit_position) - padding)
			offset = signf(offset) * minf(absf(offset), allowed)
	# Translate along world up even when the Look node is pitched.
	_camera.position = _authored_camera_position + global_basis.inverse() * Vector3.UP * offset
