extends Node3D
## Coordinates source-style cached trajectories, sprite attributes, and impact effects.

const Settings = preload("res://addons/dynamic_sky/precipitation/snow/snow_settings.gd")
const PathCache = preload("res://addons/dynamic_sky/precipitation/snow/snow_path_cache.gd")
const MAXIMUM_CAMERA_SPAWN_MULTIPLIER := 7.0
const RENDER_AFTER_DOF_METHOD := &"instance_geometry_set_render_after_dof"

## Spawn volume, trajectory cache, wind units, and flake appearance.
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
var _solar_elevation := -1.0
var _active := false
var _contact_enabled := false
var _collision_enabled := true
var _camera_override: Camera3D
var _cache: PathCache
var _cached_settings: Settings
var _cached_path_count: int = 0
var _minimum_view_distance := 0.45
var _previous_camera_position := Vector3.ZERO
var _previous_camera_forward := Vector3.FORWARD
var _camera_initialized := false
var _camera_spawn_multiplier := 1.0
var _was_emitting := false
var _drain_seconds := 0.0
var _render_after_dof_applied := false

@onready var _particles: GPUParticles3D = $SnowParticles
@onready var _contact: GPUParticles3D = $SnowContact
@onready var _process_material: ShaderMaterial = _particles.process_material


func _ready() -> void:
	if settings != null and not settings.changed.is_connected(refresh_settings):
		settings.changed.connect(refresh_settings)
	refresh_settings()


## Applies authored emitter values and rebuilds the trajectory texture only when its layout changes.
func refresh_settings() -> void:
	if _particles == null:
		return
	_apply_render_after_dof()
	if settings == null:
		_apply_daytime_blizzard_visibility()
		_update_emission()
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
	var draw_material := _particles.material_override as ShaderMaterial
	if draw_material != null:
		draw_material.set_shader_parameter(&"maximum_visual_stretch", settings.maximum_visual_stretch)
		var near_cutoff: Variant = _process_material.get_shader_parameter(&"minimum_view_distance")
		_minimum_view_distance = 0.45 if near_cutoff == null else float(near_cutoff)
		draw_material.set_shader_parameter(
			&"near_feather_range",
			Vector2(_minimum_view_distance, settings.near_feather_end_meters),
		)
	_apply_daytime_blizzard_visibility()
	_update_emission()


func _apply_render_after_dof() -> void:
	var enabled := settings != null and settings.render_after_depth_of_field
	if enabled == _render_after_dof_applied:
		return
	if (
		not RenderingServer.has_method(RENDER_AFTER_DOF_METHOD)
		or RenderingServer.get_current_rendering_method() != "forward_plus"
	):
		return
	RenderingServer.call(RENDER_AFTER_DOF_METHOD, _particles.get_instance(), enabled)
	_render_after_dof_applied = enabled


## Applies normalized snowfall, world X/Z wind in meters per second, and the sun direction's Y component.
func apply_snow(
	intensity: float,
	wind: Vector2,
	active: bool,
	contact_enabled: bool = false,
	surface_collision_enabled: bool = true,
	camera: Camera3D = null,
	solar_elevation: float = -1.0,
) -> void:
	var next_intensity := clampf(intensity, 0.0, 1.0)
	var visibility_changed := (
		_intensity != next_intensity
		or _wind != wind
		or _solar_elevation != solar_elevation
	)
	_intensity = next_intensity
	_wind = wind
	_solar_elevation = solar_elevation
	_active = active
	_contact_enabled = contact_enabled
	_collision_enabled = surface_collision_enabled
	_camera_override = camera
	if is_node_ready():
		if visibility_changed:
			_apply_daytime_blizzard_visibility()
		_update_emission()


func _apply_daytime_blizzard_visibility() -> void:
	var material := _particles.material_override as ShaderMaterial
	if material == null:
		return
	var visibility := Vector3(1.0, 1.0, 0.0)
	if settings != null:
		var daylight := smoothstep(-0.02, 0.24, _solar_elevation)
		var blizzard := smoothstep(0.76, 1.0, _intensity) * smoothstep(8.0, 12.0, _wind.length())
		var weight := daylight * blizzard
		visibility.x = lerpf(1.0, settings.blizzard_daytime_opacity, weight)
		visibility.y = lerpf(1.0, settings.blizzard_distant_receiver_opacity, weight)
		if weight > 0.0 and settings.blizzard_near_feather_end_meters > _minimum_view_distance:
			visibility.z = lerpf(_minimum_view_distance, settings.blizzard_near_feather_end_meters, weight)
	if material.get_shader_parameter(&"daytime_blizzard_visibility") != visibility:
		material.set_shader_parameter(&"daytime_blizzard_visibility", visibility)


func _update_emission() -> void:
	if settings == null:
		_particles.emitting = false
		_was_emitting = false
		_drain_seconds = 0.0
		set_physics_process(false)
		return
	var emitting := _active and _intensity > 0.001
	if _was_emitting and not emitting:
		_drain_seconds = settings.maximum_lifetime_seconds + _contact.lifetime
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
			_collision_enabled, _camera_spawn_multiplier, _contact_enabled,
		)

	var twirl := lerpf(0.15, 1.0, clampf(sqrt(wind_squared) / 0.3, 0.0, 1.0))
	_process_material.set_shader_parameter(&"snow_twirl", twirl)
	_process_material.set_shader_parameter(&"custom_time_dilation", _particles.speed_scale)
	_process_material.set_shader_parameter(&"camera_position", camera_position)
	_process_material.set_shader_parameter(&"spawn_origin", spawn_origin)
	_process_material.set_shader_parameter(&"camera_velocity", camera_velocity)
	_process_material.set_shader_parameter(&"camera_forward_derivative", forward_derivative)
	_process_material.set_shader_parameter(&"emit_contact", _contact_enabled and _collision_enabled)

	set_physics_process(_was_emitting or _drain_seconds > 0.0)
