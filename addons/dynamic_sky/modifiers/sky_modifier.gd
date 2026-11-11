@tool
class_name DynamicSkyModifier
extends Resource
## Ordered sky and environment adjustments with manual or clock-driven influence.

## Source of the modifier's raw alpha before easing and maximum alpha are applied.
enum WeightMode {
	## Uses the authored weight or the stack's per-instance weight and timed fade API.
	MANUAL,
	## Samples the two clock ranges directly, including ranges applied overnight.
	CLOCK_WINDOW,
}

## Curve applied to raw alpha before interpolation to this modifier's values.
enum Easing {
	## Keeps alpha linear.
	LINEAR,
	## Smooth acceleration and deceleration using a cubic curve.
	SMOOTHSTEP,
	## Accelerates according to the blend exponent.
	EASE_IN,
	## Decelerates according to the blend exponent.
	EASE_OUT,
	## Applies the blend exponent symmetrically on both halves of the fade.
	EASE_IN_OUT,
}

## Enables this modifier. Disabling it immediately restores the outputs below this layer.
@export var enabled: bool = true:
	set(value):
		enabled = value
		emit_changed()

## Manual alpha control or a repeating time-of-day window.
@export var weight_mode: WeightMode = WeightMode.MANUAL:
	set(value):
		weight_mode = value
		notify_property_list_changed()
		emit_changed()

## Raw manual alpha from zero to one. Changes use the corresponding fade duration.
@export_range(0.0, 1.0, 0.01) var weight: float = 1.0:
	set(value):
		weight = clampf(value, 0.0, 1.0)
		emit_changed()

## Real seconds to move manual alpha from zero to one. Zero applies an increase immediately.
@export_range(0.0, 30.0, 0.01, "or_greater", "suffix:s") var fade_in_seconds: float = 0.0:
	set(value):
		fade_in_seconds = maxf(value, 0.0)
		emit_changed()

## Real seconds to move manual alpha from one to zero. Zero applies a decrease immediately.
@export_range(0.0, 30.0, 0.01, "or_greater", "suffix:s") var fade_out_seconds: float = 0.0:
	set(value):
		fade_out_seconds = maxf(value, 0.0)
		emit_changed()

## Hours at the start and end of the clock fade-in. End must be at or after start, within 0–24.
@export var clock_fade_in: Vector2 = Vector2(17.0, 19.0):
	set(value):
		clock_fade_in = value
		emit_changed()

## Hours at the start and end of fade-out. This range may occur before fade-in for overnight use.
@export var clock_fade_out: Vector2 = Vector2(5.0, 7.0):
	set(value):
		clock_fade_out = value
		emit_changed()

## Maximum influence after the easing curve, allowing partially applied modifiers at full raw alpha.
@export_range(0.0, 1.0, 0.01) var max_alpha: float = 1.0:
	set(value):
		max_alpha = clampf(value, 0.0, 1.0)
		emit_changed()

## Alpha interpolation curve used by both manual fades and clock ranges.
@export var easing: Easing = Easing.LINEAR:
	set(value):
		easing = value
		notify_property_list_changed()
		emit_changed()

## Power controlling acceleration for Ease In, Ease Out, and Ease In Out.
@export_range(0.1, 8.0, 0.1, "or_greater") var blend_exponent: float = 2.0:
	set(value):
		blend_exponent = maxf(value, 0.1)
		emit_changed()

## Property adjustments applied in array order. Later adjustments see the previous result.
@export var properties: Array[DynamicSkyModifierProperty] = []:
	set(value):
		for adjustment in properties:
			if adjustment != null and adjustment.changed.is_connected(_property_changed):
				adjustment.changed.disconnect(_property_changed)
		properties = value
		for adjustment in properties:
			if adjustment != null and not adjustment.changed.is_connected(_property_changed):
				adjustment.changed.connect(_property_changed)
		emit_changed()


func _validate_property(property: Dictionary) -> void:
	if property.name in [&"weight", &"fade_in_seconds", &"fade_out_seconds"]:
		if weight_mode != WeightMode.MANUAL:
			property.usage &= ~PROPERTY_USAGE_EDITOR
	if property.name in [&"clock_fade_in", &"clock_fade_out"]:
		if weight_mode != WeightMode.CLOCK_WINDOW:
			property.usage &= ~PROPERTY_USAGE_EDITOR
	if property.name == &"blend_exponent" and easing in [Easing.LINEAR, Easing.SMOOTHSTEP]:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## True when the non-overlapping fade ranges describe one positive interval per 24-hour cycle.
func has_valid_clock_window() -> bool:
	if not clock_fade_in.is_finite() or not clock_fade_out.is_finite():
		return false
	if clock_fade_in.x < 0.0 or clock_fade_in.y > 24.0 or clock_fade_in.y < clock_fade_in.x:
		return false
	if clock_fade_out.x < 0.0 or clock_fade_out.y > 24.0 or clock_fade_out.y < clock_fade_out.x:
		return false
	var fade_out_start := fposmod(clock_fade_out.x - clock_fade_in.x, 24.0)
	return (
		fade_out_start > 0.0
		and clock_fade_in.y - clock_fade_in.x <= fade_out_start
		and fade_out_start + clock_fade_out.y - clock_fade_out.x <= 24.0
	)


## Samples raw clock alpha, with optional instantaneous fade boundaries when an interval is zero.
func sample_clock(hour: float) -> float:
	if not has_valid_clock_window() or not is_finite(hour):
		return 0.0
	var clock := fposmod(hour - clock_fade_in.x, 24.0)
	var fade_in_duration := clock_fade_in.y - clock_fade_in.x
	var fade_out_start := fposmod(clock_fade_out.x - clock_fade_in.x, 24.0)
	var fade_out_end := fade_out_start + clock_fade_out.y - clock_fade_out.x
	var increasing := clampf(clock / fade_in_duration, 0.0, 1.0) if fade_in_duration > 0.0 else 1.0
	var decreasing := 1.0 if clock < fade_out_start else 0.0
	if fade_out_end > fade_out_start:
		decreasing = 1.0 - clampf((clock - fade_out_start) / (fade_out_end - fade_out_start), 0.0, 1.0)
	return increasing * decreasing


## Applies the selected easing curve and maximum alpha to a normalized raw weight.
func ease_weight(raw_weight: float) -> float:
	var alpha := clampf(raw_weight, 0.0, 1.0)
	match easing:
		Easing.SMOOTHSTEP:
			alpha = smoothstep(0.0, 1.0, alpha)
		Easing.EASE_IN:
			alpha = pow(alpha, blend_exponent)
		Easing.EASE_OUT:
			alpha = 1.0 - pow(1.0 - alpha, blend_exponent)
		Easing.EASE_IN_OUT:
			if alpha < 0.5:
				alpha = pow(alpha * 2.0, blend_exponent) * 0.5
			else:
				alpha = 1.0 - pow((1.0 - alpha) * 2.0, blend_exponent) * 0.5
	return alpha * max_alpha


func _property_changed() -> void:
	emit_changed()
