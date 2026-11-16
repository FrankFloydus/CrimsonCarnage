extends Node3D
## Renders coarse dust and fine spots along finite wind-driven paths.

const DustPathCache = preload("res://addons/dynamic_sky/weather/sandstorm/dust_path_cache.gd")
const CALM_PRESET_WIND := 2.20
const STORM_PRESET_WIND := 19.31

## Scales dust particle births independently of local and distance fog.
@export_range(0.0, 1.0, 0.01) var density_scale: float = 1.0

var _cache: DustPathCache
var _camera: Camera3D
var _camera_position := Vector3.ZERO
var _forward := Vector3.FORWARD
var _origin := Vector3.ZERO
var _velocity := Vector3.ZERO
var _randomness := 0.0
var _collision_mask := 0
var _excluded: Array[RID] = []
var _bound_paths := 0
var _has_roof_mask := false

@onready var _layers: Array[GPUParticles3D] = [$DustCards, $DustSpots]


func _ready() -> void:
	set_physics_process(false)


## Updates the live dust field using the resolved weather, camera and local shelter.
func apply_dust(
	dust: float, wind: Vector2, camera: Camera3D, shelter: float, sun_elevation: float,
	ambient_radiance: Color, nominal_wind_speed: float, collision_mask: int,
) -> void:
	var uncovered := 1.0 if _has_roof_mask else 1.0 - clampf(shelter, 0.0, 1.0)
	var rate := clampf(inverse_lerp(0.30, 1.0, dust), 0.0, 1.0) * density_scale
	if not is_instance_valid(camera) or rate * uncovered <= 0.001:
		stop()
		return
	var camera_pose := camera.get_camera_transform()
	if _cache == null:
		_cache = DustPathCache.new()
		for particles in _layers:
			var motion := particles.process_material as ShaderMaterial
			motion.set_shader_parameter(&"path_cache", _cache.texture)
	var next_mask := collision_mask if camera.get_world_3d() == get_world_3d() else 0
	if _camera != camera or _collision_mask != next_mask or camera_pose.origin.distance_squared_to(_camera_position) > 400.0:
		_reset_observer(camera)
	_camera_position = camera_pose.origin
	_forward = -camera_pose.basis.z
	var strength := source_wind_fraction(nominal_wind_speed if nominal_wind_speed >= 0.0 else wind.length())
	var heading := wind.normalized()
	_velocity = Vector3(heading.x, 0.0, heading.y) * (14.0 * strength * strength)
	_randomness = lerpf(0.95, 0.20, strength)
	_origin = _camera_position + _forward * 0.5 - _velocity * 0.3
	_collision_mask = next_mask
	var daylight := smoothstep(-0.16, 0.32, sun_elevation)
	var radiance := Vector3(ambient_radiance.r, ambient_radiance.g, ambient_radiance.b)
	for particles in _layers:
		# Keep the culling bounds near the observer while trajectories remain in world coordinates.
		particles.global_position = _camera_position
		particles.amount_ratio = rate
		var motion := particles.process_material as ShaderMaterial
		motion.set_shader_parameter(&"camera_position", _camera_position)
		motion.set_shader_parameter(&"spawn_origin", _origin)
		var optics := particles.material_override as ShaderMaterial
		optics.set_shader_parameter(&"dust_radiance", radiance)
		optics.set_shader_parameter(&"exposure", daylight)
		optics.set_shader_parameter(&"shelter", 1.0 - uncovered)
	set_physics_process(true)


## Masks dust beneath a resolved roof while keeping the field visible beyond its eaves.
func bind_roof(box_from_world: Transform3D, half_size: Vector3) -> void:
	_has_roof_mask = half_size.x > 0.0
	for particles in _layers:
		var optics := particles.material_override as ShaderMaterial
		optics.set_shader_parameter(&"roof_from_world", box_from_world)
		optics.set_shader_parameter(&"roof_half_size", half_size)


## Stops the field and clears its observer so that a restart resamples its surroundings.
func stop() -> void:
	_camera = null
	_set_emitting(false)


## Maps the shipped Calm Dust and Sandstorm winds to the source's normalized wind endpoints.
static func source_wind_fraction(speed: float) -> float:
	if speed <= CALM_PRESET_WIND:
		return clampf(speed / CALM_PRESET_WIND, 0.0, 1.0) * 0.1
	return lerpf(0.1, 1.0, clampf(inverse_lerp(CALM_PRESET_WIND, STORM_PRESET_WIND, speed), 0.0, 1.0))


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_camera):
		_set_emitting(false)
		return
	var space := get_world_3d().direct_space_state if _collision_mask != 0 else null
	_cache.update(delta, space, _origin, _forward, _velocity, _randomness, _collision_mask, _excluded)
	if _cache.path_count != _bound_paths:
		_bound_paths = _cache.path_count
		for particles in _layers:
			var motion := particles.process_material as ShaderMaterial
			motion.set_shader_parameter(&"path_count", _bound_paths)
	if _bound_paths > 0:
		_set_emitting(true)


func _reset_observer(camera: Camera3D) -> void:
	_set_emitting(false)
	_cache.reset()
	_camera = camera
	_bound_paths = 0
	_excluded.clear()
	var node: Node = camera
	while node != null:
		if node is CollisionObject3D:
			_excluded.append(node.get_rid())
		node = node.get_parent()
	for particles in _layers:
		particles.restart()


func _set_emitting(active: bool) -> void:
	if not active:
		set_physics_process(false)
	for particles in _layers:
		if particles.emitting != active:
			particles.emitting = active
		particles.visible = active
