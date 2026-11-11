extends ColorRect
## Warps the edges of the local view during an accepted dash.

## Seconds to ramp up the distortion after the dash starts. Zero applies it immediately.
@export_range(0.0, 0.3, 0.005, "or_greater", "suffix:s") var blend_in: float = 0.035
## Seconds to clear the distortion after the dash stops. Zero hides it immediately.
@export_range(0.0, 1.0, 0.01, "or_greater", "suffix:s") var blend_out: float = 0.14

var _elapsed: float = 0.0
var _transition: Tween


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	_elapsed += delta
	set_instance_shader_parameter(&"dash_age", _elapsed)


## Starts a shockwave on dash entry and releases the distortion when movement ends.
func set_dash_active(active: bool, _local_direction: Vector2) -> void:
	if not active and not visible:
		return
	if _transition != null:
		_transition.kill()
	if active:
		_elapsed = 0.0
		set_instance_shader_parameter(&"dash_age", _elapsed)
		show()
		set_process(true)

	var target := 1.0 if active else 0.0
	var duration := blend_in if active else blend_out
	if duration <= 0.0 or is_equal_approx(self_modulate.a, target):
		self_modulate.a = target
		if not active:
			_hide_effect()
		return

	_transition = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_transition.tween_property(self, "self_modulate:a", target, duration)
	if not active:
		_transition.tween_callback(_hide_effect)


func _hide_effect() -> void:
	hide()
	set_process(false)
