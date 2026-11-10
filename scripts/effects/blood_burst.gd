class_name BloodBurst3D
extends Node3D
## Launches a short GPU liquid burst, fine spray, and mist at a melee contact.

## Number of shuffled launch patterns and liquid silhouettes.
const VARIATION_COUNT := 10
const MINIMUM_OUTWARD_BIAS := 0.40

var _authored_amounts: Array[int] = []
var _authored_speed_ranges: Array[Vector2] = []
var _authored_spreads: Array[float] = []
var _authored_bounds: Array[AABB] = []
var _authored_liquid_trail: Vector2

@onready var _emitters: Array[GPUParticles3D] = [$LiquidPatches, $Droplets, $ImpactMist]


func _ready() -> void:
	for emitter in _emitters:
		var motion := emitter.process_material as ShaderMaterial
		if motion.get_local_scene() != self:
			motion = motion.duplicate() as ShaderMaterial
			emitter.process_material = motion
		_authored_amounts.append(emitter.amount)
		_authored_speed_ranges.append(_motion_parameter(motion, &"speed_range") as Vector2)
		_authored_spreads.append(float(_motion_parameter(motion, &"spread")))
		_authored_bounds.append(emitter.visibility_aabb)
	_authored_liquid_trail = _motion_parameter(_emitters[0].process_material as ShaderMaterial, &"trail_range") as Vector2


## Launches the burst from just inside the struck surface, using the given profile's airborne settings.
func play(point: Vector3, normal: Vector3, swing_direction: Vector3, variation: int, profile: BloodProfile = null) -> void:
	var direction := swing_direction.normalized()
	var surface_normal := normal.normalized()
	if not surface_normal.is_zero_approx() and direction.dot(surface_normal) < MINIMUM_OUTWARD_BIAS:
		var tangent := direction.slide(surface_normal).normalized()
		direction = (tangent + surface_normal * MINIMUM_OUTWARD_BIAS).normalized()
	var up := Vector3.RIGHT if absf(direction.dot(Vector3.UP)) > 0.99 else Vector3.UP
	global_transform = Transform3D(Basis.looking_at(direction, up), point)
	reset_physics_interpolation()

	_apply_profile(profile)
	var longest_emitter := _emitters[0]
	for emitter in _emitters:
		var motion := emitter.process_material as ShaderMaterial
		motion.set_shader_parameter(&"variation", clampi(variation, 0, VARIATION_COUNT - 1))
		emitter.restart()
		if emitter.lifetime > longest_emitter.lifetime:
			longest_emitter = emitter
	await longest_emitter.finished
	queue_free()


func _apply_profile(profile: BloodProfile) -> void:
	var amounts := Vector3.ONE
	var speed_scale := 1.0
	var spread_scale := 1.0
	var trail_scale := 1.0
	var tint := Color.WHITE
	if profile != null:
		amounts = Vector3(profile.liquid_amount_scale, profile.droplet_amount_scale, profile.mist_amount_scale)
		speed_scale = maxf(profile.burst_speed_scale, 0.1)
		spread_scale = maxf(profile.burst_spread_scale, 0.1)
		trail_scale = maxf(profile.liquid_trail_scale, 0.1)
		tint = profile.burst_tint

	for index in _emitters.size():
		var emitter := _emitters[index]
		var motion := emitter.process_material as ShaderMaterial
		var amount := maxi(1, roundi(_authored_amounts[index] * maxf(amounts[index], 0.1)))
		if emitter.amount != amount:
			emitter.amount = amount
		motion.set_shader_parameter(&"speed_range", _authored_speed_ranges[index] * speed_scale)
		motion.set_shader_parameter(&"spread", _authored_spreads[index] * spread_scale)
		var bounds := _authored_bounds[index]
		var bounds_scale := maxf(1.0, speed_scale)
		emitter.visibility_aabb = AABB(bounds.position * bounds_scale, bounds.size * bounds_scale)
		emitter.set_instance_shader_parameter(&"burst_tint", tint)
	var liquid_motion := _emitters[0].process_material as ShaderMaterial
	liquid_motion.set_shader_parameter(&"trail_range", _authored_liquid_trail * trail_scale)


func _motion_parameter(motion: ShaderMaterial, parameter: StringName) -> Variant:
	var value: Variant = motion.get_shader_parameter(parameter)
	if value == null:
		return RenderingServer.shader_get_parameter_default(motion.shader.get_rid(), parameter)
	return value
