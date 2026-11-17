class_name FirstPersonLook
extends Node3D
## Owns body yaw, eye pitch, and the composed camera pose.

## Emitted with the applied pitch (X) and yaw (Y) change in radians after mouse input.
signal mouse_turned(angles: Vector2)

## Character rotated around its vertical axis when the mouse moves horizontally.
@export var body: CharacterBody3D
## Camera-local transform keyed by weapon clips and composed with procedural view motion.
@export_storage var attack_camera_motion := Transform3D.IDENTITY:
	set(value):
		attack_camera_motion = value
		if is_node_ready():
			_apply_camera_pose()

@onready var _camera: FirstPersonCameraEffects = $Camera3D
@onready var _mover: MoverComponent = body.get_node(^"Mover")

var _authored_camera_position: Vector3
var _camera_rotation: Vector3
var _camera_scale: Vector3


func _ready() -> void:
	_authored_camera_position = _camera.position
	_camera_rotation = _camera.rotation
	_camera_scale = _camera.scale
	_mover.stair_camera_offset_changed.connect(_apply_camera_pose)
	_apply_camera_pose()


## Applies the signed yaw (X) and pitch (Y) from Controls in radians.
func apply_aim(aim_delta: Vector2) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	body.rotate_y(aim_delta.x)
	var previous_pitch := rotation.x
	var pitch_limit := deg_to_rad(_camera.pitch_limit)
	rotation.x = clampf(previous_pitch + aim_delta.y, -pitch_limit, pitch_limit)
	mouse_turned.emit(Vector2(rotation.x - previous_pitch, aim_delta.x))


func _process(delta: float) -> void:
	var actual_velocity := body.get_real_velocity()
	var body_basis := body.global_basis
	var lateral_speed := actual_velocity.dot(body_basis.x)
	var tilt_fraction := clampf(lateral_speed / _camera.full_tilt_speed, -1.0, 1.0)
	var target_roll := -deg_to_rad(_camera.maximum_tilt) * tilt_fraction
	_camera_rotation.z = lerpf(
			_camera_rotation.z, target_roll, 1.0 - exp(-_camera.tilt_response * delta)
	)
	_apply_camera_pose()
	var forward_speed := -actual_velocity.dot(body_basis.z)
	_camera.advance_movement_fov(forward_speed / maxf(_mover.move_speed, 0.001), delta)


## Returns the camera origin before stair compensation and imported motion.
func get_base_camera_position() -> Vector3:
	return _authored_camera_position


func _apply_camera_pose() -> void:
	var base := Basis.from_euler(_camera_rotation, _camera.rotation_order).scaled_local(_camera_scale)
	var camera_position := _authored_camera_position + _mover.get_stair_camera_offset()
	_camera.transform = Transform3D(base, camera_position) * attack_camera_motion
