class_name DynamicSkySandstormParticles
extends Node3D
## Simulates suspended sand, ground saltation, and large drifting dust gusts.

## Controls the visible particle density independently of the atmospheric haze.
@export_range(0.0, 1.0, 0.01) var density_scale: float = 1.0

var _last_wind := Vector2(INF, INF)
var _last_exposure: float = -1.0
var _uses_surface_collision: bool = false

@onready var _grains: GPUParticles3D = $SuspendedGrains
@onready var _saltation: GPUParticles3D = $GroundSaltation
@onready var _billows: GPUParticles3D = $GustBillows
@onready var _layers: Array[GPUParticles3D] = [_grains, _saltation, _billows]


func apply_dust(
	dust: float,
	wind: Vector2,
	camera: Camera3D,
	ground_height: float,
	shelter: float,
	sun_elevation: float = 0.7,
	use_surface_collision: bool = false
) -> void:
	var density := clampf(dust, 0.0, 1.0) * density_scale * (1.0 - clampf(shelter, 0.0, 1.0))
	if camera == null or density <= 0.001:
		for particles in _layers:
			_update_layer(particles, 0.0)
		return

	var camera_position := camera.global_position
	var ground_position := Vector3(camera_position.x, ground_height, camera_position.z)
	_grains.global_position = camera_position
	_saltation.global_position = ground_position
	_billows.global_position = ground_position + Vector3.UP * 1.12

	var wind_speed := wind.length()
	var wind_strength := smoothstep(3.0, 16.0, wind_speed)
	var exposure := smoothstep(-0.16, 0.32, sun_elevation)
	if use_surface_collision != _uses_surface_collision:
		var saltation_motion := _saltation.process_material as ShaderMaterial
		saltation_motion.set_shader_parameter(&"surface_collision", use_surface_collision)
		_uses_surface_collision = use_surface_collision
	if not wind.is_equal_approx(_last_wind) or not is_equal_approx(exposure, _last_exposure):
		for particles in _layers:
			var motion := particles.process_material as ShaderMaterial
			var optical := particles.material_override as ShaderMaterial
			motion.set_shader_parameter(&"wind", wind)
			optical.set_shader_parameter(&"wind", wind)
			optical.set_shader_parameter(&"exposure", exposure)
		_last_wind = wind
		_last_exposure = exposure

	_update_layer(_grains, pow(density, 0.77) * lerpf(0.43, 1.0, wind_strength))
	_update_layer(_saltation, density * wind_strength)
	var gust_weight := smoothstep(0.15, 0.78, density) * smoothstep(5.0, 15.0, wind_speed)
	_update_layer(_billows, gust_weight)


func _update_layer(particles: GPUParticles3D, amount: float) -> void:
	var optical := particles.material_override as ShaderMaterial
	var weight := smoothstep(0.0, 0.30, amount)
	if not is_equal_approx(particles.amount_ratio, amount):
		particles.amount_ratio = amount
		optical.set_shader_parameter(&"weather_weight", weight)
	if particles.emitting != (amount > 0.001):
		particles.emitting = amount > 0.001
