class_name DamageVignette
extends ColorRect
## Plays the incoming-hit flash and optional low-health warning for the local player.

## Maximum strength of the incoming-hit flash. Zero disables the flash.
@export_range(0.0, 1.0, 0.01) var peak_opacity: float = 0.72
## Seconds for an incoming hit to reach peak strength. Zero applies the peak immediately.
@export_range(0.0, 0.20, 0.001, "or_greater", "suffix:s") var rise_time: float = 0.015
## Seconds to fade out after an incoming hit. Zero disables the hit flash.
@export_range(0.0, 2.0, 0.001, "or_greater", "suffix:s") var fade_time: float = 0.185

@export_group("Low Health Pulse", "low_health_pulse_")
## Enables a soft repeating pulse while health is below Threshold. Off by default.
@export var low_health_pulse_enabled := false:
	set(value):
		low_health_pulse_enabled = value
		_refresh_low_health_pulse()
## Health percent below which the enabled pulse starts. At 25%, a player with 100 max HP sees it
## below 25 HP. Healing to the threshold stops it.
@export_range(0.0, 100.0, 1.0, "suffix:%") var low_health_pulse_threshold: float = 25.0:
	set(value):
		low_health_pulse_threshold = clampf(value, 0.0, 100.0)
		_refresh_low_health_pulse()

@export_subgroup("Appearance", "low_health_pulse_")
## Color of the low-health overlay. Use a saturated tint to distinguish it from the scene vignette.
@export_color_no_alpha var low_health_pulse_color := Color(1.0, 0.035, 0.085):
	set(value):
		low_health_pulse_color = value
		_apply_pulse_material()
## Light intensity of the tint. Raise it above 1 to make the colored edge show on dark backgrounds.
@export_range(0.0, 4.0, 0.05, "suffix:×") var low_health_pulse_brightness: float = 1.25:
	set(value):
		low_health_pulse_brightness = value
		_apply_pulse_material()
## Opacity at the quietest part of the pulse. Zero clears the overlay between pulses.
@export_range(0.0, 1.0, 0.01) var low_health_pulse_minimum_opacity: float = 0.0
## Opacity at the strongest part of the pulse. Raise it for a clearer warning without changing hue.
@export_range(0.0, 1.0, 0.01) var low_health_pulse_peak_opacity: float = 0.46
## Width and height of the mask relative to half the viewport diagonal. Smaller values bring the
## colored edge inward. Adjust X and Y independently for wide screens.
@export var low_health_pulse_mask_size := Vector2(2.1, 1.35):
	set(value):
		low_health_pulse_mask_size = value
		_apply_pulse_material()

@export_subgroup("Timing", "low_health_pulse_")
## Speed multiplier for the whole cycle. At 2, the warning pulses twice as often with the same shape.
@export_range(0.1, 4.0, 0.05, "suffix:×") var low_health_pulse_speed: float = 1.0
## Seconds from minimum opacity to the peak at normal speed. Lower it for a sharper beat.
@export_range(0.01, 4.0, 0.01, "suffix:s") var low_health_pulse_rise_time: float = 0.28
## Seconds the pulse holds at peak opacity. Zero starts fading as soon as the peak is reached.
@export_range(0.0, 4.0, 0.01, "suffix:s") var low_health_pulse_hold_time: float = 0.08
## Seconds for the pulse to fade from peak to minimum. Raise it for a softer tail.
@export_range(0.01, 4.0, 0.01, "suffix:s") var low_health_pulse_fade_time: float = 0.72
## Seconds spent at minimum opacity between beats. Increase it to leave a longer quiet gap.
@export_range(0.0, 4.0, 0.01, "suffix:s") var low_health_pulse_rest_time: float = 0.18

var _fade: Tween
var _health_fraction := 1.0
var _pulse_elapsed := 0.0
var _pulse_opacity := 0.0
var _hit_opacity := 0.0:
	set(value):
		_hit_opacity = value
		_apply_opacity()

@onready var _pulse_overlay: ColorRect = $LowHealthPulse


func _ready() -> void:
	set_process(false)
	_apply_pulse_material()
	_apply_opacity()
	_refresh_low_health_pulse()


func _process(delta: float) -> void:
	var rise := maxf(low_health_pulse_rise_time, 0.001)
	var fade_start := rise + low_health_pulse_hold_time
	var fade_end := fade_start + maxf(low_health_pulse_fade_time, 0.001)
	var duration := fade_end + low_health_pulse_rest_time
	_pulse_elapsed = fposmod(_pulse_elapsed + delta * low_health_pulse_speed, duration)
	var envelope := smoothstep(0.0, rise, _pulse_elapsed)
	envelope *= 1.0 - smoothstep(fade_start, fade_end, _pulse_elapsed)
	var minimum := minf(low_health_pulse_minimum_opacity, low_health_pulse_peak_opacity)
	_pulse_opacity = lerpf(minimum, low_health_pulse_peak_opacity, envelope)
	_apply_opacity()


## Restarts the pulse from its current strength so successive hits never stack the tint.
func pulse() -> void:
	if peak_opacity <= 0.0 or fade_time <= 0.0:
		return
	if _fade != null:
		_fade.kill()

	show()
	_fade = create_tween()
	if rise_time > 0.0:
		_fade.tween_property(self, "_hit_opacity", peak_opacity, rise_time)
	else:
		_hit_opacity = peak_opacity
	_fade.tween_property(self, "_hit_opacity", 0.0, fade_time)


## Updates the warning from current health as a fraction of maximum health.
func set_health_fraction(fraction: float) -> void:
	_health_fraction = fraction
	_refresh_low_health_pulse()


func _refresh_low_health_pulse() -> void:
	if not is_node_ready():
		return
	var should_pulse := low_health_pulse_enabled and _health_fraction < low_health_pulse_threshold / 100.0
	if should_pulse == is_processing():
		return
	set_process(should_pulse)
	if not should_pulse:
		_pulse_elapsed = 0.0
		_pulse_opacity = 0.0
		_apply_opacity()


func _apply_pulse_material() -> void:
	if not is_node_ready():
		return
	_pulse_overlay.set_instance_shader_parameter(&"pulse_color", low_health_pulse_color)
	_pulse_overlay.set_instance_shader_parameter(&"brightness", low_health_pulse_brightness)
	_pulse_overlay.set_instance_shader_parameter(&"mask_size", low_health_pulse_mask_size)


func _apply_opacity() -> void:
	var pulse_opacity := _pulse_opacity * (1.0 - _hit_opacity)
	self_modulate.a = _hit_opacity
	_pulse_overlay.self_modulate.a = pulse_opacity
	_pulse_overlay.visible = pulse_opacity > 0.0
	visible = _hit_opacity > 0.0 or _pulse_overlay.visible
