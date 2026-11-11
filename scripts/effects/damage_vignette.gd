class_name DamageVignette
extends ColorRect
## Plays a brief, fullscreen edge tint for the local player.

## Maximum strength of the vignette pulse. Zero disables the pulse.
@export_range(0.0, 1.0, 0.01) var peak_opacity: float = 0.72
## Seconds to reach peak strength. Zero applies the peak immediately.
@export_range(0.0, 0.20, 0.001, "or_greater", "suffix:s") var rise_time: float = 0.015
## Seconds to fade out from peak strength. Zero disables the pulse.
@export_range(0.0, 2.0, 0.001, "or_greater", "suffix:s") var fade_time: float = 0.185

var _fade: Tween


## Restarts the pulse from its current strength so successive hits never stack the tint.
func pulse() -> void:
	if peak_opacity <= 0.0 or fade_time <= 0.0:
		return
	if _fade != null:
		_fade.kill()

	if not visible:
		self_modulate.a = 0.0
	show()
	_fade = create_tween()
	if rise_time > 0.0:
		_fade.tween_property(self, "self_modulate:a", peak_opacity, rise_time)
	else:
		self_modulate.a = peak_opacity
	_fade.tween_property(self, "self_modulate:a", 0.0, fade_time)
	_fade.tween_callback(hide)
