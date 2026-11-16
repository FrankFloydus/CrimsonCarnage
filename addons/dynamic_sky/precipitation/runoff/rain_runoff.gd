@tool
extends Path3D
## Emits rain runoff from a roof edge or other exposed ledge along an editable curve.

const SkyLookup = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")
const WEATHER_SAMPLE_PERIOD: float = 0.15
const COLLISION_SAMPLE_SPACING: float = 0.22
const MAX_COLLISION_SAMPLES: int = 128
const COLLISION_TRACES_PER_TICK: int = 4
const MAX_DROPS_PER_TICK: int = 16
const CONTACT_LIFT: float = 0.004
const EMIT_FLAGS: int = GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_CUSTOM
const IMPACT_FLAGS: int = GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_ROTATION_SCALE


class Impact:
	var time: float
	var transform: Transform3D

	func _init(impact_time: float, impact_transform: Transform3D) -> void:
		time = impact_time
		transform = impact_transform

## Local weather source. Leave empty to use Dynamic Sky in this World3D.
@export var sky_override: DynamicSky

## Maximum drops per second per meter of curve at full rain intensity.
@export_range(0.0, 100.0, 0.1, "or_greater") var drop_rate_per_meter: float = 9.0

## Surface whose accumulated wetness sustains residual drips. Empty disables residual drips.
@export var wet_surface: DynamicSkySurface

## Residual drops per second per meter of curve when the assigned surface is fully wet.
@export_range(0.0, 10.0, 0.01, "or_greater") var wet_drop_rate_per_meter: float = 0.0

## Multiplier for the rendered drop width and length. One uses the default sprite size.
@export_range(0.1, 4.0, 0.05) var drop_sprite_scale: float = 1.0:
	set(value):
		drop_sprite_scale = maxf(value, 0.1)
		if is_node_ready():
			(_drops.process_material as ShaderMaterial).set_shader_parameter(&"sprite_scale", drop_sprite_scale)

## Fraction of cached drop contacts that produce a visible splash.
@export_range(0.0, 1.0, 0.01) var splash_frequency: float = 0.74

## Seconds for the edge to stop dripping after full rain clears.
@export_range(0.1, 30.0, 0.1, "suffix:s") var drain_seconds: float = 2.5

## Static physics layers sampled below the curve for drop impacts. Zero allows free fall.
@export_flags_3d_physics var collision_mask: int = 1

## Maximum static contact search distance below the ledge, in meters.
@export_range(0.5, 12.0, 0.1, "suffix:m") var maximum_fall_distance: float = 9.0

## Distance below the curve where collision traces start, in meters. Skips the supporting ledge.
@export_range(0.0, 1.0, 0.005, "suffix:m") var collision_head_start: float = 0.025

## Stops spawning when the active camera is farther than this distance from the path origin.
@export_range(3.0, 90.0, 0.5, "or_greater", "suffix:m") var cull_distance: float = 30.0

var _sky: DynamicSky
var _random := RandomNumberGenerator.new()
var _weather_sample_left: float = 0.0
var _rain: float = 0.0
var _runoff: float = 0.0
var _wetness: float = 0.0
var _spawn_credit: float = 0.0
var _samples: PackedVector3Array
var _contacts: PackedColorArray
var _path_length: float = 0.0
var _cache_dirty: bool = true
var _cached_transform: Transform3D
var _cached_collision_mask: int
var _cached_fall_distance: float
var _cached_collision_head_start: float
var _elapsed: float = 0.0
var _fall_settings: Vector3
var _pending_impacts: Array[Impact]

@onready var _drops: GPUParticles3D = $Drops
@onready var _splashes: GPUParticles3D = $RainSplashes


func _ready() -> void:
	curve_changed.connect(_invalidate_cache)
	var material := _drops.process_material as ShaderMaterial
	_fall_settings = material.get_shader_parameter(&"fall_settings")
	material.set_shader_parameter(&"sprite_scale", drop_sprite_scale)
	set_physics_process(not Engine.is_editor_hint())


func _get_configuration_warnings() -> PackedStringArray:
	if curve == null or curve.point_count < 2:
		return PackedStringArray(["Draw at least two points along the exposed roof edge."])
	return PackedStringArray()


func _physics_process(delta: float) -> void:
	_elapsed += delta
	_emit_due_impacts()
	_update_runoff(delta)
	var rate := _runoff * drop_rate_per_meter + _wetness * wet_drop_rate_per_meter
	var camera := get_viewport().get_camera_3d()
	if (
		rate <= 0.001
		or camera == null
		or camera.global_position.distance_to(global_position) > cull_distance
	):
		_spawn_credit = 0.0
		return
	if (
		_cache_dirty
		or not _cached_transform.is_equal_approx(global_transform)
		or _cached_collision_mask != collision_mask
		or _cached_fall_distance != maximum_fall_distance
		or _cached_collision_head_start != collision_head_start
	):
		_rebuild_sample_points()
	_sample_contacts()
	if _contacts.is_empty():
		return
	_spawn_credit = minf(
		_spawn_credit + rate * _path_length * delta,
		MAX_DROPS_PER_TICK,
	)
	var spawn_count := floori(_spawn_credit)
	_spawn_credit -= spawn_count
	for _index in spawn_count:
		var along := _random.randf() * float(_contacts.size() - 1)
		var sample := roundi(along)
		var origin := _sample_drop_origin(along, sample)
		var contact := _contacts[sample]
		var water_level := _get_water_level_at(origin)
		if origin.y <= water_level:
			continue
		var can_splash := contact.b > 0.01 and contact.r > water_level
		var stop := contact
		if is_finite(water_level) and not can_splash:
			stop.r = water_level
			stop.b = 1.0
		var transform := Transform3D(Basis.IDENTITY, origin)
		_drops.emit_particle(transform, Vector3.ZERO, Color.WHITE, stop, EMIT_FLAGS)
		if can_splash and _random.randf() < splash_frequency:
			_schedule_impact(origin, contact)


func _update_runoff(delta: float) -> void:
	_weather_sample_left -= delta
	if _weather_sample_left <= 0.0:
		_weather_sample_left = WEATHER_SAMPLE_PERIOD
		_sky = SkyLookup.resolve(self, sky_override, _sky)
		_rain = 0.0
		_wetness = 0.0
		if _sky != null and not _sky.is_space_mode():
			_rain = float(_sky.get_weather_at(global_position)[&"rain"])
			if is_instance_valid(wet_surface) and wet_surface.get_surface_world() == get_world_3d():
				_wetness = wet_surface.get_accumulation().x
	var rate := 3.0 if _rain > _runoff else 1.0 / maxf(drain_seconds, 0.1)
	_runoff = move_toward(_runoff, _rain, delta * rate)


func _sample_drop_origin(along: float, nearest: int) -> Vector3:
	var lower := floori(along)
	var upper := ceili(along)
	var first := _contacts[lower]
	var second := _contacts[upper]
	# Interpolate on a shared receiver. Keep the cached point at a ledge or contact boundary.
	if first.is_equal_approx(second):
		return _samples[lower].lerp(_samples[upper], along - lower)
	return _samples[nearest]


func _schedule_impact(origin: Vector3, contact: Color) -> void:
	var distance := origin.y - contact.r
	var initial_speed := _fall_settings.x
	var gravity := _fall_settings.y
	var terminal_speed := _fall_settings.z
	var acceleration_time := (terminal_speed - initial_speed) / gravity
	var acceleration_distance := (initial_speed + terminal_speed) * 0.5 * acceleration_time
	var flight_time: float
	if distance < acceleration_distance:
		flight_time = (sqrt(initial_speed * initial_speed + 2.0 * gravity * distance) - initial_speed) / gravity
	else:
		flight_time = acceleration_time + (distance - acceleration_distance) / terminal_speed
	if flight_time > _drops.lifetime:
		return
	var normal := Vector3(contact.g, contact.b, contact.a).normalized()
	var tangent := normal.cross(Vector3.BACK).normalized()
	var position := Vector3(origin.x, contact.r, origin.z) + normal * CONTACT_LIFT
	var impact := Transform3D(Basis(tangent, normal, tangent.cross(normal)), position)
	_pending_impacts.append(Impact.new(_elapsed + flight_time, impact))


func _emit_due_impacts() -> void:
	for index in range(_pending_impacts.size() - 1, -1, -1):
		var impact := _pending_impacts[index]
		if impact.time > _elapsed:
			continue
		var receiver := impact.transform.origin - impact.transform.basis.y * CONTACT_LIFT
		if receiver.y > _get_water_level_at(receiver):
			_splashes.emit_particle(impact.transform, Vector3.ZERO, Color.WHITE, Color.BLACK, IMPACT_FLAGS)
		_pending_impacts.remove_at(index)


func _get_water_level_at(point: Vector3) -> float:
	if not is_instance_valid(_sky):
		return -INF
	var exposure := _sky.get_node_or_null(^"WeatherExposure") as DynamicSkyWeatherExposure
	return exposure.get_water_level_at(point) if exposure != null else -INF


func _invalidate_cache() -> void:
	_cache_dirty = true
	update_configuration_warnings()


func _rebuild_sample_points() -> void:
	_cache_dirty = false
	_cached_transform = global_transform
	_cached_collision_mask = collision_mask
	_cached_fall_distance = maximum_fall_distance
	_cached_collision_head_start = collision_head_start
	_samples.clear()
	_contacts.clear()
	_path_length = 0.0
	if curve == null or curve.point_count < 2:
		return
	var local_length := curve.get_baked_length()
	if is_zero_approx(local_length):
		return
	var intervals := clampi(ceili(local_length / COLLISION_SAMPLE_SPACING), 1, MAX_COLLISION_SAMPLES - 1)
	for index in range(intervals + 1):
		var point := to_global(curve.sample_baked(local_length * float(index) / intervals))
		if not _samples.is_empty():
			_path_length += point.distance_to(_samples[-1])
		_samples.append(point)


func _sample_contacts() -> void:
	if _contacts.size() >= _samples.size():
		return
	var space := get_world_3d().direct_space_state
	var count := mini(_samples.size() - _contacts.size(), COLLISION_TRACES_PER_TICK)
	var head_start := clampf(collision_head_start, 0.0, maximum_fall_distance * 0.5)
	for _index in count:
		var point := _samples[_contacts.size()]
		var contact := Color(0.0, 0.0, 0.0, 0.0)
		if collision_mask != 0:
			var ray := PhysicsRayQueryParameters3D.create(
				point - Vector3.UP * head_start, point - Vector3.UP * maximum_fall_distance, collision_mask,
			)
			var hit := space.intersect_ray(ray)
			if not hit.is_empty():
				var position: Vector3 = hit.position
				var normal: Vector3 = hit.normal
				contact = Color(position.y, normal.x, normal.y, normal.z)
		_contacts.append(contact)
