class_name FloatingDamageNumber
extends Label3D
## Saved normal/critical damage and MISS/RESIST feedback, with a short rise and fade.

## Seconds for the number to rise and fade before its runtime instance is removed.
@export_range(0.05, 5.0, 0.05) var lifetime: float = 1.2
## Total upward movement in world meters over the number's lifetime.
@export_range(0.0, 3.0, 0.05) var rise_distance: float = 0.35
## Tint used for the damage number before its final fade.
@export var damage_color: Color = Color.WHITE
## Tint used for critical damage numbers before their final fade.
@export var critical_color: Color = Color(1.0, 0.85, 0.12, 1.0)
## Persistent size multiplier for a critical number relative to the scene's authored scale.
@export_range(1.0, 3.0, 0.05, "or_greater") var critical_size_multiplier: float = 1.35
## Seconds for a critical number to grow, overshoot, and settle; zero disables the pop.
@export_range(0.0, 1.0, 0.01) var critical_pop_duration: float = 0.18
## Peak pop size relative to the settled critical size, reached during the short opening motion.
@export_range(1.0, 3.0, 0.05, "or_greater") var critical_pop_peak: float = 1.3

var is_critical: bool = false
var _elapsed: float = 0.0
var _origin: Vector3 = Vector3.ZERO
var _started: bool = false
var _authored_scale: Vector3 = Vector3.ONE
var _display_color: Color = Color.WHITE


func _ready() -> void:
	_authored_scale = scale


func show_damage(amount: float, critical: bool = false) -> void:
	is_critical = critical
	text = ("%.3f" % amount).rstrip("0").rstrip(".")
	_start_animation()


## Displays only recognized failed Accuracy outcomes using the same saved presentation.
func show_outcome(outcome: StringName) -> void:
	if outcome not in [&"miss", &"resist"]:
		return
	is_critical = false
	text = str(outcome).to_upper()
	_start_animation()


func _start_animation() -> void:
	_display_color = critical_color if is_critical else damage_color
	modulate = _display_color
	_elapsed = 0.0
	_origin = global_position
	_started = true
	_update_scale()


func _process(delta: float) -> void:
	if not _started:
		return
	_elapsed += delta
	var progress := clampf(_elapsed / maxf(lifetime, 0.001), 0.0, 1.0)
	global_position = _origin + Vector3.UP * rise_distance * progress
	_update_scale()
	var fade := clampf((progress - 0.25) / 0.75, 0.0, 1.0)
	modulate = Color(_display_color.r, _display_color.g, _display_color.b,
			_display_color.a * (1.0 - fade))
	if progress >= 1.0:
		queue_free()


func _update_scale() -> void:
	var multiplier := 1.0
	if is_critical:
		multiplier = critical_size_multiplier
		if critical_pop_duration > 0.0:
			var progress := clampf(_elapsed / critical_pop_duration, 0.0, 1.0)
			if progress < 0.35:
				multiplier *= lerpf(0.65, critical_pop_peak, progress / 0.35)
			else:
				var settling := (progress - 0.35) / 0.65
				multiplier *= lerpf(critical_pop_peak, 1.0, 1.0 - pow(1.0 - settling, 3.0))
	scale = _authored_scale * multiplier
