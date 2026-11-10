class_name BloodSplatterStyle
extends Resource
## Shared mask, color, and projection variation for world and skinned blood marks.

## Compact grouping of short cast-off streaks and satellite droplets.
@export var compact_mask: Texture2D
## Open cast-off spray with separate specks and clear gaps.
@export var fan_mask: Texture2D
## Optional occlusion, roughness, and metallic map for the compact pattern.
@export var compact_orm: Texture2D
## Optional occlusion, roughness, and metallic map for the fan pattern.
@export var fan_orm: Texture2D
## World deposits shared by floors and walls. Each entry pairs a silhouette with its wet surface maps.
@export var floor_variants: Array[BloodFloorSplatter] = []
## Floor blood's share of the blended color. Lower values reveal more of the receiving surface color.
@export_range(0.0, 1.0, 0.01) var floor_albedo_mix := 0.97
## Darkest sRGB tint and its opacity.
@export var dark_tint := Color("#431c1bf0")
## Lightest sRGB tint and its opacity.
@export var light_tint := Color("#733a32d6")
## Range of uniform footprint multipliers sampled once per mark.
@export var size_range := Vector2(0.62, 1.34)
## Additional fractional variation in width relative to length.
@export_range(0.0, 0.4, 0.01) var aspect_jitter := 0.16
## Maximum angle away from the projected incoming direction. Oblique marks alternate sides; head-on marks can rotate freely.
@export_range(0.0, 90.0, 1.0, "suffix:°") var rotation_jitter := 58.0
## Roughness for body and wall marks, and for floor deposits without a roughness map.
@export_range(0.0, 1.0, 0.01) var wet_roughness := 0.46

var masks: Array[Texture2D]:
	get:
		return [compact_mask, fan_mask]

var _random := RandomNumberGenerator.new()


## Picks a mask. When both are assigned, avoid using the last silhouette twice in a row.
func pick_mask(previous_index: int, candidates: Array[Texture2D]) -> int:
	if candidates[0] == null:
		return 1 if candidates[1] != null else -1
	if candidates[1] == null:
		return 0
	if previous_index == 0 or previous_index == 1:
		return 1 - previous_index
	return _random.randi_range(0, 1)


## Picks a floor deposit while excluding the last used texture when another one is available.
func pick_floor_variant(previous_albedo: Texture2D) -> BloodFloorSplatter:
	var alternatives: Array[BloodFloorSplatter] = []
	var fallback: BloodFloorSplatter
	for variant in floor_variants:
		if variant == null or variant.albedo == null:
			continue
		if variant.albedo == previous_albedo:
			fallback = variant
		else:
			alternatives.append(variant)
	if alternatives.is_empty():
		return fallback
	return alternatives[_random.randi_range(0, alternatives.size() - 1)]


## Returns separate width and length multipliers for a new mark.
func sample_size() -> Vector2:
	var smaller := maxf(minf(size_range.x, size_range.y), 0.05)
	var larger := maxf(maxf(size_range.x, size_range.y), smaller)
	var size := _random.randf_range(smaller, larger)
	return Vector2(size * _random.randf_range(1.0 - aspect_jitter, 1.0 + aspect_jitter), size)


## Returns an angle in radians, separated from the previous stamp's angle even on repeated hits.
func sample_angle(full_rotation: bool, previous_angle: float) -> float:
	if full_rotation:
		var arc := _random.randf_range(PI / 3.0, PI * 5.0 / 6.0)
		var turn := -arc if _random.randf() < 0.5 else arc
		return wrapf(previous_angle + turn, -PI, PI)
	var limit := deg_to_rad(clampf(rotation_jitter, 0.0, 90.0))
	var side := -signf(previous_angle)
	if is_zero_approx(side):
		side = -1.0 if _random.randf() < 0.5 else 1.0
	return side * _random.randf_range(limit * 0.35, limit)


## Samples an sRGB tint within the authored palette.
func sample_tint() -> Color:
	return dark_tint.lerp(light_tint, _random.randf())
