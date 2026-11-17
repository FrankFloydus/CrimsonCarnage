@tool
class_name FirstPersonCameraEffects
extends Camera3D
## Authors first-person camera tuning and blends field of view during movement and straight dashes.

@export_group("Aim")
## Maximum upward and downward view pitch in degrees.
@export_range(1.0, 89.9, 0.1, "suffix:°") var pitch_limit: float = 89.0

@export_group("Strafe Roll")
## Maximum camera roll in degrees at full lateral speed. Zero disables lateral tilt.
@export_range(0.0, 15.0, 0.1, "suffix:°") var maximum_tilt: float = 3.0:
	set(value):
		maximum_tilt = value
		notify_property_list_changed()
## Lateral speed in metres per second that produces the maximum camera roll.
@export_range(0.1, 30.0, 0.1, "or_greater", "suffix:m/s") var full_tilt_speed: float = 6.0
## Camera roll convergence rate per second. Larger values make the roll respond faster.
@export_range(0.1, 30.0, 0.1, "or_greater", "suffix:1/s") var tilt_response: float = 10.0

@export_group("Movement FOV", "movement_fov_")
## FOV change in degrees at full forward speed. Positive values widen the view as you move forward.
## Start with a small value to complement the swords' forward lean. Zero disables this direction.
@export_range(-5.0, 5.0, 0.1, "suffix:°") var movement_fov_forward_offset: float = 0.8
## FOV change in degrees at full backward speed. Negative values narrow the view as you back away.
## Bring it closer to zero if the view tightens too much. Zero disables this direction.
@export_range(-5.0, 5.0, 0.1, "suffix:°") var movement_fov_backward_offset: float = -0.6
## Blend time constant in seconds for a change in movement speed. Raise it if the view shifts too
## quickly when you tap a movement key or reverse direction.
@export_range(0.02, 0.5, 0.01, "suffix:s") var movement_fov_response_time: float = 0.12

@export_group("Dash FOV", "dash_fov_")
## Fraction of the authored FOV used during a straight forward or backward dash.
## A multiplier of 1 disables the effect.
@export_range(0.5, 1.0, 0.01, "suffix:×") var dash_fov_multiplier: float = 0.8
## Seconds to narrow the FOV after a dash starts. Zero applies the change immediately.
@export_range(0.0, 1.0, 0.01, "or_greater", "suffix:s") var dash_fov_blend_in: float = 0.08
## Seconds to return to the authored FOV after a dash ends. Zero applies the change immediately.
@export_range(0.0, 1.0, 0.01, "or_greater", "suffix:s") var dash_fov_blend_out: float = 0.30

var _base_fov: float
var _movement_fov_offset := 0.0
var _dash_fov_offset := 0.0
var _dash_fov_active: bool = false
var _fov_tween: Tween


func _validate_property(property: Dictionary) -> void:
	if property.name == &"full_tilt_speed" and maximum_tilt == 0.0:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _ready() -> void:
	_base_fov = fov


## Updates the lens from signed forward speed as a fraction of the Mover's normal speed.
func advance_movement_fov(forward_fraction: float, delta: float) -> void:
	var fraction := clampf(forward_fraction, -1.0, 1.0)
	var target := maxf(fraction, 0.0) * movement_fov_forward_offset
	target += maxf(-fraction, 0.0) * movement_fov_backward_offset
	_movement_fov_offset = lerpf(
		_movement_fov_offset, target, 1.0 - exp(-delta / movement_fov_response_time)
	)
	_apply_fov()


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
	var target_offset := maxf(_base_fov * dash_fov_multiplier, 1.0) - _base_fov if active else 0.0
	var duration := dash_fov_blend_in if active else dash_fov_blend_out
	if duration <= 0.0 or is_equal_approx(_dash_fov_offset, target_offset):
		_set_dash_fov_offset(target_offset)
		return
	_fov_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fov_tween.tween_method(_set_dash_fov_offset, _dash_fov_offset, target_offset, duration)


func _set_dash_fov_offset(value: float) -> void:
	_dash_fov_offset = value
	_apply_fov()


func _apply_fov() -> void:
	var target := clampf(_base_fov + _movement_fov_offset + _dash_fov_offset, 1.0, 179.0)
	if not is_equal_approx(fov, target):
		fov = target
