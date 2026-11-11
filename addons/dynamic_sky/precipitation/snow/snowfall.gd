extends Node3D
## Coordinates source-style cached trajectories, sprite attributes, and impact effects.

const Settings = preload("res://addons/dynamic_sky/precipitation/snow/snow_settings.gd")
const PathCache = preload("res://addons/dynamic_sky/precipitation/snow/snow_path_cache.gd")
const MAXIMUM_CAMERA_SPAWN_MULTIPLIER := 7.0

## Source-authored spawn volume, trajectory cache, wind units, and sprite size.
@export var settings: Settings = preload("res://addons/dynamic_sky/precipitation/snow/snow_settings.tres"):
	set(value):
		if settings != null and settings.changed.is_connected(refresh_settings):
			settings.changed.disconnect(refresh_settings)
		settings = value
		if settings != null and not settings.changed.is_connected(refresh_settings):
			settings.changed.connect(refresh_settings)
		if is_node_ready():
			refresh_settings()

var _intensity := 0.0
var _wind := Vector2.ZERO
var _active := false
var _contact_enabled := false
var _collision_enabled := true
var _camera_override: Camera3D
var _cache: PathCache
var _cached_settings: Settings
var _cached_path_count: int = 0
var _previous_camera_position := Vector3.ZERO
var _previous_camera_forward := Vector3.FORWARD
var _camera_initialized := false
var _camera_spawn_multiplier := 1.0
var _was_emitting := false
var _drain_seconds := 0.0

@onready var _particles: GPUParticles3D = $SnowParticles
@onready var _spindrift: GPUParticles3D = $GroundDrift
@onready var _process_material: ShaderMaterial = _particles.process_material


func _ready() -> void:
	if not settings.changed.is_connected(refresh_settings):
		settings.changed.connect(refresh_settings)
	refresh_settings()


## Applies authored emitter values and rebuilds the trajectory texture only when its layout changes.
func refresh_settings() -> void:
	if settings == null:
		return
	if _cache == null or _cached_settings != settings or _cached_path_count != settings.cached_path_count:
		_cache = PathCache.new()
		_cache.initialize(settings)
		_cached_settings = settings
		_cached_path_count = settings.cached_path_count
	_particles.lifetime = settings.maximum_lifetime_seconds
	_particles.amount = ceili(settings.spawn_rate * settings.maximum_lifetime_seconds * MAXIMUM_CAMERA_SPAWN_MULTIPLIER)
	_process_material.set_shader_parameter(&"path_cache", _cache.texture)
	_process_material.set_shader_parameter(&"path_count", settings.cached_path_count)
	_process_material.set_shader_parameter(&"sprite_size_meters", settings.sprite_size_meters)
	_process_material.set_shader_parameter(&"maximum_spawn_distance", settings.spawn_radius_meters)
	_update_emission()


## Applies normalized snowfall and world X/Z wind in meters per second.
func apply_snow(
	intensity: float,
	wind: Vector2,
	active: bool,
	contact_enabled: bool = false,
	surface_collision_enabled: bool = true,
	camera: Camera3D = null,
) -> void:
	_intensity = clampf(intensity, 0.0, 1.0)
	_wind = wind
	_active = active
	_contact_enabled = contact_enabled
	_collision_enabled = surface_collision_enabled
	_camera_override = camera
	if is_node_ready():
		_update_emission()


func _update_emission() -> void:
	var emitting := _active and _intensity > 0.001
	if _was_emitting and not emitting:
		_drain_seconds = settings.maximum_lifetime_seconds + _spindrift.lifetime
	_was_emitting = emitting
	_particles.emitting = emitting
	_particles.amount_ratio = pow(_intensity, 1.5) * _camera_spawn_multiplier / MAXIMUM_CAMERA_SPAWN_MULTIPLIER
	set_physics_process(emitting or _drain_seconds > 0.0)


func _physics_process(delta: float) -> void:
	_drain_seconds = maxf(0.0, _drain_seconds - delta)
	var camera := _camera_override
	if not is_instance_valid(camera):
		camera = get_viewport().get_camera_3d()
	if camera == null:
		return
	var camera_transform := camera.get_camera_transform()
	var camera_position := camera_transform.origin
	var camera_forward := -camera_transform.basis.z.normalized()
	var effective_delta := delta / maxf(_particles.speed_scale, 0.0001)
	var camera_velocity := Vector3.ZERO
	var forward_derivative := Vector3.ZERO
	if _camera_initialized:
		camera_velocity = (camera_position - _previous_camera_position) / maxf(effective_delta, 0.000001)
		forward_derivative = (camera_forward - _previous_camera_forward) / maxf(effective_delta, 0.000001)
	_previous_camera_position = camera_position
	_previous_camera_forward = camera_forward
	_camera_initialized = true
	# Source camera speed is cm/s; convert its authored 555 cm/s denominator to m/s.
	_camera_spawn_multiplier = minf(
		1.0 + minf(camera_velocity.length(), 20.0) / 5.55
		+ minf(forward_derivative.length() / 3.0, 3.0),
		MAXIMUM_CAMERA_SPAWN_MULTIPLIER,
	)
	_particles.amount_ratio = pow(_intensity, 1.5) * _camera_spawn_multiplier / MAXIMUM_CAMERA_SPAWN_MULTIPLIER

	# Public m/s wind corresponds to source normalized W squared times its wind scale.
	var wind_squared := clampf(_wind.length() / maxf(settings.wind_velocity_scale, 0.0001), 0.0, 1.0)
	var wind_direction := _wind.normalized()
	var general_velocity := Vector3(wind_direction.x, -0.4, wind_direction.y) * wind_squared * settings.wind_velocity_scale
	general_velocity = (general_velocity + Vector3.DOWN * 2.0) * lerpf(0.4, 0.64, _intensity)
	var randomness := lerpf(0.4, 0.23, wind_squared)
	var camera_lead := (camera_velocity * Vector3(0.2, 0.4, 0.2)).clamp(Vector3.ONE * -50.0, Vector3.ONE * 50.0)
	var spawn_origin := camera_position + camera_forward * settings.camera_forward_offset_meters
	spawn_origin += camera_lead - general_velocity * Vector3(0.3, 0.0, 0.3)
	if _was_emitting:
		_cache.update(
			delta, get_world_3d(), spawn_origin, camera_forward, general_velocity, randomness,
			_collision_enabled, _camera_spawn_multiplier,
		)

	var twirl := lerpf(0.15, 1.0, clampf(sqrt(wind_squared) / 0.3, 0.0, 1.0))
	_process_material.set_shader_parameter(&"snow_twirl", twirl)
	_process_material.set_shader_parameter(&"custom_time_dilation", _particles.speed_scale)
	_process_material.set_shader_parameter(&"camera_position", camera_position)
	_process_material.set_shader_parameter(&"spawn_origin", spawn_origin)
	_process_material.set_shader_parameter(&"camera_velocity", camera_velocity)
	_process_material.set_shader_parameter(&"camera_forward_derivative", forward_derivative)
	_process_material.set_shader_parameter(&"emit_contact", _contact_enabled and _collision_enabled)

	var storm := smoothstep(7.5, 17.0, _wind.length())
	_particles.sub_emitter = NodePath("../GroundDrift") if storm > 0.1 else NodePath("../SnowContact")
	var drift_process := _spindrift.process_material as ShaderMaterial
	drift_process.set_shader_parameter(&"wind", _wind)
	drift_process.set_shader_parameter(&"blizzard", storm if _was_emitting else 0.0)
	set_physics_process(_was_emitting or _drain_seconds > 0.0)
