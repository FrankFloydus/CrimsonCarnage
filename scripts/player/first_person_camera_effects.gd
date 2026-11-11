class_name FirstPersonCameraEffects
extends Node
## Applies presentation effects to its parent Camera3D.

@export_group("Dash FOV", "dash_fov_")
## Fraction of the authored FOV used during a straight forward or backward dash.
## A multiplier of 1 disables the effect.
@export_range(0.5, 1.0, 0.01, "suffix:×") var dash_fov_multiplier: float = 0.8
## Seconds to narrow the FOV after a dash starts. Zero applies the change immediately.
@export_range(0.0, 1.0, 0.01, "or_greater", "suffix:s") var dash_fov_blend_in: float = 0.08
## Seconds to return to the authored FOV after a dash ends. Zero applies the change immediately.
@export_range(0.0, 1.0, 0.01, "or_greater", "suffix:s") var dash_fov_blend_out: float = 0.30

var _base_fov: float
var _dash_fov_active: bool = false
var _fov_tween: Tween

@onready var _camera := get_parent() as Camera3D


func _ready() -> void:
	_base_fov = _camera.fov


## Blends from the current FOV for a dash with no strafe input.
func set_dash_active(active: bool, local_direction: Vector2) -> void:
	if active and (not is_zero_approx(local_direction.x) or dash_fov_multiplier >= 1.0):
		return
	if active == _dash_fov_active:
		return
	_dash_fov_active = active

	if _fov_tween != null:
		_fov_tween.kill()
		_fov_tween = null
	var target_fov := maxf(_base_fov * dash_fov_multiplier, 1.0) if active else _base_fov
	var duration := dash_fov_blend_in if active else dash_fov_blend_out
	if duration <= 0.0 or is_equal_approx(_camera.fov, target_fov):
		_camera.fov = target_fov
		return
	_fov_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fov_tween.tween_property(_camera, "fov", target_fov, duration)
