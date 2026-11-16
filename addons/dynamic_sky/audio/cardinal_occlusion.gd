extends RefCounted
## Samples surrounding geometry for the weather audio mixer.

const AZIMUTH_STEPS := 12
const ELEVATION_STEPS := 4
const TRACE_DISTANCE := 45.0
const UPDATE_PERIOD := 0.55
const CONE_HALF_ANGLE := deg_to_rad(5.0)
const MIN_GLOBAL_HIT_FRACTION := 0.20
const MAX_GLOBAL_HIT_FRACTION := 0.90
const TRACE_SEED := 955223


class Openness:
	extends RefCounted

	var global_open: float = 1.0
	var upward: float = 1.0
	# Signed world cardinal order is +X, -X, +Z, -Z.
	var cardinal: Vector4 = Vector4.ONE

	func in_direction(heading: Vector3) -> float:
		var weights := Vector2(absf(heading.x), absf(heading.z))
		var total := weights.x + weights.y
		if total <= 0.0001:
			return global_open
		var along_x := cardinal.x if heading.x >= 0.0 else cardinal.y
		var along_z := cardinal.z if heading.z >= 0.0 else cardinal.w
		return Vector2(along_x, along_z).dot(weights) / total


var _offsets := PackedVector3Array()
var _positive_total := Vector3.ZERO
var _negative_total := Vector3.ZERO
var _query := PhysicsRayQueryParameters3D.new()


func _init() -> void:
	# Cache a stable jittered upper hemisphere so recurring samples do not flicker.
	var random := RandomNumberGenerator.new()
	random.seed = TRACE_SEED
	for azimuth_step in AZIMUTH_STEPS:
		for elevation_step in ELEVATION_STEPS:
			var azimuth := TAU * (float(azimuth_step) + 0.35 * float(elevation_step)) / float(AZIMUTH_STEPS)
			var horizontal := Vector3(sin(azimuth), 0.0, -cos(azimuth))
			var elevation_weight := float(elevation_step) / (float(ELEVATION_STEPS) - 0.5)
			var direction := horizontal.lerp(Vector3.UP, elevation_weight).normalized()
			var cosine := random.randf_range(cos(CONE_HALF_ANGLE), 1.0)
			var sine := sqrt(maxf(1.0 - cosine * cosine, 0.0))
			var tangent := Vector3.UP.cross(direction).normalized()
			var bitangent := direction.cross(tangent)
			var angle := random.randf_range(0.0, TAU)
			var jittered := direction * cosine + (tangent * cos(angle) + bitangent * sin(angle)) * sine
			jittered.y = maxf(jittered.y, 0.0)
			var offset := jittered.normalized() * TRACE_DISTANCE * random.randf_range(0.9, 1.1)
			_offsets.append(offset)
			_positive_total += offset.max(Vector3.ZERO)
			_negative_total += (-offset).max(Vector3.ZERO)


func sample(space: PhysicsDirectSpaceState3D, origin: Vector3, mask: int, exclude: Array[RID]) -> Openness:
	var openness := Openness.new()
	if mask == 0 or space == null:
		return openness
	var hit_count := 0
	var positive_hit := Vector3.ZERO
	var negative_hit := Vector3.ZERO
	_query.collision_mask = mask
	_query.exclude = exclude
	_query.from = origin
	_query.hit_from_inside = true
	for offset in _offsets:
		_query.to = origin + offset
		if space.intersect_ray(_query).is_empty():
			continue
		hit_count += 1
		positive_hit += offset.max(Vector3.ZERO)
		negative_hit += (-offset).max(Vector3.ZERO)
	var blocked_fraction := float(hit_count) / float(_offsets.size())
	openness.global_open = 1.0 - clampf(
		inverse_lerp(MIN_GLOBAL_HIT_FRACTION, MAX_GLOBAL_HIT_FRACTION, blocked_fraction), 0.0, 1.0,
	)
	var positive_open := Vector3.ONE - positive_hit / _positive_total
	var negative_open := Vector3.ONE - negative_hit / _negative_total.max(Vector3(0.0001, 0.0001, 0.0001))
	openness.upward = clampf(positive_open.y, 0.0, 1.0)
	openness.cardinal = Vector4(positive_open.x, negative_open.x, positive_open.z, negative_open.z).clamp(Vector4.ZERO, Vector4.ONE)
	return openness
