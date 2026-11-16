class_name DynamicSkyAirborneWeather
extends Node3D
## Moves a world-space volume of rain mist, drifting snow, or airborne sand with the wind.

const NOISE_PERIOD_M := 64.0
const PROBE_INTERVAL := 0.15
const SOURCE_WIND_FOG_MATERIAL := preload("res://addons/dynamic_sky/weather/airborne/wind_fog_source_material.tres")
const SnowMistRoof = preload("res://addons/dynamic_sky/weather/airborne/snow_mist_roof.gd")
const SourceDustParticles = preload("res://addons/dynamic_sky/weather/sandstorm/source_dust_particles.gd")

## Chooses the local fog path and owns the post-process wind fog's source-scale controls.
@export var wind_fog_settings: DynamicSkyWindFogSettings

## Peak near-ground mist density in heavy rain.
@export_range(0.0, 0.12, 0.001) var rain_density: float = 0.019

## Peak near-ground mist density from blowing snow.
@export_range(0.0, 0.12, 0.001) var snow_density: float = 0.033

## Peak near-ground haze density from moving sand and dust.
@export_range(0.0, 0.16, 0.001) var dust_density: float = 0.052

## Scattered ambient sky energy in airborne dust. Higher values soften dark dust pockets.
@export_range(0.0, 0.6, 0.01) var dust_ambient_scattering: float = 0.26

## Maximum low haze stirred up by strong dry wind.
@export_range(0.0, 0.04, 0.001) var dry_wind_density: float = 0.008

## Surfaces on these physics layers place the layer at ground level and shelter the camera.
@export_flags_3d_physics var shelter_mask: int = 1

## Distance to check above the camera for a roof, in meters.
@export_range(0.0, 40.0, 0.1, "suffix:m") var roof_probe_height: float = 12.0

## Distance to search below the camera for the ground, in meters.
@export_range(0.0, 100.0, 1.0, "suffix:m") var ground_probe_depth: float = 35.0

## Neutral mist tint in rain.
@export var rain_color: Color = Color(0.76, 0.82, 0.88)

## Tint of wind-driven snow under an overcast sky.
@export var snow_color: Color = Color(0.84, 0.88, 0.93)

## Warm mineral tint for airborne dust.
@export var dust_color: Color = Color(0.67, 0.56, 0.43)

var dust_particle_density_scale: float:
	get:
		var particles := get_node_or_null(^"SandstormParticles") as DynamicSkySandstormParticles
		return particles.density_scale if particles != null else 1.0
	set(value):
		var particles := get_node_or_null(^"SandstormParticles") as DynamicSkySandstormParticles
		if particles != null:
			particles.density_scale = value
		var source_particles := get_node_or_null(^"SourceDustParticles") as SourceDustParticles
		if source_particles != null:
			source_particles.density_scale = value

var _environment: Environment
var _authored_fog_enabled: bool = false
var _offset: Vector2 = Vector2.ZERO
var _post_process_offset: Vector2 = Vector2.ZERO
var _source_fog_offset: Vector3 = Vector3.ZERO
var _source_fog_material: ShaderMaterial
var _source_roof_probe: SnowMistRoof
var _source_roof_active := false
var _source_roof_half_size := Vector3.ZERO
var _source_roof_from_world := Transform3D.IDENTITY
var _source_roof_replaces_scalar := false
var _ground_height: float = 0.0
var _ground_target: float = 0.0
var _shelter: float = 0.0
var _shelter_target: float = 0.0
var _probe_time: float = 0.0
var _camera: Camera3D

@onready var _volume: FogVolume = $GroundHaze
@onready var _material: ShaderMaterial = _volume.material as ShaderMaterial
@onready var _sandstorm: DynamicSkySandstormParticles = $SandstormParticles
@onready var _source_dust := get_node_or_null(^"SourceDustParticles") as SourceDustParticles
@onready var _post_process: MeshInstance3D = $PostProcessWindFog
@onready var _post_process_material: ShaderMaterial = _post_process.material_override as ShaderMaterial


func _ready() -> void:
	_ground_height = global_position.y
	_ground_target = _ground_height
	_source_fog_material = SOURCE_WIND_FOG_MATERIAL.duplicate() as ShaderMaterial
	set_physics_process(false)


func _exit_tree() -> void:
	if _environment != null:
		_environment.volumetric_fog_enabled = _authored_fog_enabled


func bind_environment(environment: Environment) -> void:
	if _environment == environment:
		return
	if _environment != null:
		_environment.volumetric_fog_enabled = _authored_fog_enabled
	_environment = environment
	_authored_fog_enabled = environment != null and environment.volumetric_fog_enabled


## Returns the authored fog flag before local airborne weather temporarily enables it.
func get_authored_volumetric_fog_enabled() -> bool:
	return _authored_fog_enabled


## Applies local airborne weather, including depth-bounded wind fog and the selected dust field.
func apply_weather(
	rain: float,
	snow: float,
	dust: float,
	wind: Vector2,
	delta: float,
	sun_elevation: float = 0.7,
	camera_override: Camera3D = null,
	use_surface_collision: bool = false,
	exposure: float = 1.0,
	fog_amount: float = 0.0,
	nominal_wind_speed: float = -1.0,
	dust_fog_radiance_scale: float = 1.0,
) -> void:
	var local_exposure := clampf(exposure, 0.0, 1.0)
	var camera := camera_override
	if not is_instance_valid(camera) or not camera.is_inside_tree():
		camera = get_viewport().get_camera_3d()
	var wind_strength := smoothstep(2.0, 15.0, wind.length())
	var rain_mist := rain_density * pow(rain, 1.4) * lerpf(0.56, 1.0, wind_strength)
	var snow_mist := snow_density * pow(snow, 1.2) * lerpf(0.16, 1.0, wind_strength)
	var dust_mist := dust_density * dust
	var dry_mist := maxf(
		dry_wind_density * smoothstep(5.0, 16.0, wind.length())
		- rain_mist - snow_mist - dust_mist,
		0.0
	)
	var density := rain_mist + snow_mist + dust_mist + dry_mist
	var exposed_density := density * local_exposure
	var fog_mode := DynamicSkyWindFogSettings.Mode.VOLUMETRIC
	if wind_fog_settings != null:
		fog_mode = wind_fog_settings.mode
	var source_dust_mode := fog_mode == DynamicSkyWindFogSettings.Mode.SOURCE_SNOW_AND_DUST
	var source_fog := fog_mode == DynamicSkyWindFogSettings.Mode.SOURCE_SNOW or source_dust_mode
	var dust_field := source_dust_mode and _source_dust != null and dust > maxf(0.30, maxf(rain, snow))
	var post_amount := 0.0
	var source_weight := 0.0
	if fog_mode == DynamicSkyWindFogSettings.Mode.POST_PROCESS:
		post_amount = _post_process_weather_amount(rain, snow, dust, wind.length()) * local_exposure
	elif dust_field:
		source_weight = smoothstep(0.30, 0.70, dust) * (1.0 - smoothstep(0.0, 0.32, maxf(rain, snow)))
		post_amount = wind_fog_settings.dust_amount * dust * source_weight * wind_fog_settings.intensity_scale * local_exposure
	elif source_fog:
		source_weight = smoothstep(0.0, 0.20, snow) * (1.0 - smoothstep(0.0, 0.32, maxf(rain, dust)))
		post_amount = _source_snow_fog_amount(snow, fog_amount) * source_weight * local_exposure
	exposed_density *= 1.0 - source_weight
	var forward_plus := RenderingServer.get_current_rendering_method() == "forward_plus"
	var fog_active := (
		camera != null and exposed_density > 0.0002 and _environment != null
		and forward_plus
		and (fog_mode == DynamicSkyWindFogSettings.Mode.VOLUMETRIC or source_fog)
	)
	var post_active := (
		camera != null and _environment != null and post_amount > 0.0002
	)
	var roof_active := (
		camera != null and (dust_field or (post_active and source_fog and forward_plus))
		and shelter_mask != 0 and roof_probe_height > 0.0
		and camera.get_world_3d() == get_world_3d()
	)
	if _source_roof_active != roof_active:
		_source_roof_active = roof_active
		_probe_time = 0.0
		if roof_active and _source_roof_probe == null:
			_source_roof_probe = SnowMistRoof.new()
		elif not roof_active:
			_bind_source_roof({}, false)
	var tracking_active := fog_active or post_active or (camera != null and dust * local_exposure > 0.001)
	_volume.visible = fog_active
	_post_process.visible = post_active
	if _environment != null:
		_environment.volumetric_fog_enabled = _authored_fog_enabled or fog_active
	set_physics_process(tracking_active)
	if not tracking_active:
		_camera = null
		_probe_time = 0.0
		_sandstorm.apply_dust(0.0, wind, null, _ground_height, 0.0, sun_elevation)
		if _source_dust != null:
			_source_dust.stop()
		return

	if _camera != camera:
		_camera = camera
		_probe_time = 0.0
		_bind_source_roof({}, false)

	_offset = (_offset + wind * delta).posmod(NOISE_PERIOD_M)
	var tracking := 1.0 - exp(-delta * 5.0)
	_ground_height = lerpf(_ground_height, _ground_target, tracking)
	_shelter = lerpf(_shelter, _shelter_target, tracking)
	var wind_speed := nominal_wind_speed if nominal_wind_speed >= 0.0 else wind.length()
	var legacy_dust := 0.0 if dust_field else dust * local_exposure
	_sandstorm.apply_dust(legacy_dust, wind, camera, _ground_height, _shelter, sun_elevation, use_surface_collision)
	if dust_field:
		var radiance := _environment.fog_light_color.srgb_to_linear() * _environment.fog_light_energy if _environment != null else Color(0.3413, 0.2471, 0.1626)
		_source_dust.apply_dust(
			dust * local_exposure, wind, camera, _shelter, sun_elevation, radiance, wind_speed,
			shelter_mask if use_surface_collision else 0,
		)
	elif _source_dust != null:
		_source_dust.stop()
	if post_active:
		if source_fog:
			var wind_fraction := SourceDustParticles.source_wind_fraction(wind_speed) if dust_field else sqrt(clampf(wind_speed / 15.0, 0.0, 1.0))
			_update_source_fog_motion(wind.normalized(), wind_fraction, snow, delta)
		var radiance_scale := 0.12 * dust_fog_radiance_scale if dust_field else 1.0
		_update_post_process(camera, wind, post_amount, delta, source_fog, radiance_scale)
	if not fog_active:
		return

	var camera_position := camera.global_position
	_volume.global_position = Vector3(
		snappedf(camera_position.x, 8.0),
		_ground_height + _volume.size.y * 0.34,
		snappedf(camera_position.z, 8.0)
	)
	var tint := (
		rain_color * (rain_mist / density)
		+ snow_color * (snow_mist / density)
		+ dust_color * (dust_mist / density)
		+ Color(0.75, 0.76, 0.75) * (dry_mist / density)
	)
	var height := (rain_mist * 2.6 + snow_mist * 1.9 + dust_mist * 5.5 + dry_mist * 2.1) / density
	var dust_weight := dust_mist / density
	var daylight := smoothstep(-0.12, 0.32, sun_elevation)
	var dust_fill := dust_ambient_scattering * lerpf(0.45, 1.0, daylight)
	var fill_strength := lerpf(density * 0.13, dust_fill, dust_weight)
	var source_color := tint.srgb_to_linear().lerp(_environment.fog_light_color.srgb_to_linear(), dust_weight)
	var source_radiance := source_color * fill_strength * _environment.fog_light_energy * local_exposure * (1.0 - source_weight)
	_material.set_shader_parameter(&"mass_density", exposed_density)
	_material.set_shader_parameter(&"mist_color", tint)
	_material.set_shader_parameter(&"height_scale", height)
	_material.set_shader_parameter(&"wind_travel", _offset)
	_material.set_shader_parameter(&"ground_height", _ground_height)
	_material.set_shader_parameter(&"camera_position", camera_position)
	_material.set_shader_parameter(&"shelter", _shelter)
	_material.set_shader_parameter(
		&"ambient_scattering",
		Vector3(source_radiance.r, source_radiance.g, source_radiance.b)
	)


func _post_process_weather_amount(rain: float, snow: float, dust: float, wind_speed: float) -> float:
	var storm_weight := smoothstep(7.0, 17.0, wind_speed)
	var rain_amount := lerpf(wind_fog_settings.rain_amount, wind_fog_settings.storm_amount, storm_weight) * rain
	var snow_amount := wind_fog_settings.blizzard_amount * snow * lerpf(0.15, 1.0, storm_weight)
	var dust_amount := wind_fog_settings.dust_amount * dust
	var dry_amount := wind_fog_settings.dry_wind_amount * smoothstep(5.0, 16.0, wind_speed)
	return maxf(rain_amount + snow_amount + dust_amount, dry_amount) * wind_fog_settings.intensity_scale


func _source_snow_fog_amount(snow: float, fog_amount: float) -> float:
	var fog_contribution := clampf((fog_amount - 0.4) / 0.6, 0.0, 1.0)
	return (fog_contribution + snow * snow) * 0.28 * wind_fog_settings.intensity_scale


func _update_source_fog_motion(direction: Vector2, wind_fraction: float, snow: float, delta: float) -> void:
	var horizontal := direction * (7.168 * clampf(0.7 * pow(wind_fraction, 1.4), 0.05, 1.0))
	var downward := clampf((snow * 10.0 - 1.0) / 5600.0, 0.0, 0.00125) * 640.0
	var tile := maxf(wind_fog_settings.noise_scale_meters * 0.625, 0.1)
	# The long Blizzard layer repeats over eight of the short wind fog tiles.
	_source_fog_offset = (_source_fog_offset + Vector3(horizontal.x, -downward, horizontal.y) * delta).posmod(tile * 8.0)


func _update_post_process(camera: Camera3D, wind: Vector2, amount: float, delta: float, source: bool, radiance_scale: float) -> void:
	var fog_scale := maxf(wind_fog_settings.noise_scale_meters, 0.1)
	var material := _source_fog_material if source else _post_process_material
	if _post_process.material_override != material:
		_post_process.material_override = material
	if source:
		material.set_shader_parameter(&"fog_travel", _source_fog_offset)
	else:
		# Both legacy octaves repeat over ten broad tiles.
		_post_process_offset = (_post_process_offset + wind * delta).posmod(fog_scale * 10.0)
		material.set_shader_parameter(&"wind_travel", _post_process_offset)
	var observer := camera.get_camera_transform().origin
	_post_process.global_position = observer
	var color := _environment.fog_light_color.srgb_to_linear() * (_environment.fog_light_energy * radiance_scale)
	material.set_shader_parameter(&"fog_radiance", Vector3(color.r, color.g, color.b))
	material.set_shader_parameter(&"observer_world", observer)
	material.set_shader_parameter(&"weather_amount", amount)
	material.set_shader_parameter(&"trace_distance", wind_fog_settings.trace_distance_meters)
	material.set_shader_parameter(&"sample_step", wind_fog_settings.sample_step_meters)
	material.set_shader_parameter(&"noise_scale", fog_scale)
	material.set_shader_parameter(&"extinction_per_meter", wind_fog_settings.extinction_per_meter)
	material.set_shader_parameter(&"density_variation", wind_fog_settings.density_variation)
	material.set_shader_parameter(&"shelter", _shelter)


func _bind_source_roof(box: Dictionary, replace_scalar: bool) -> void:
	var half_size: Vector3 = box.get(&"half_size", Vector3.ZERO)
	var from_world: Transform3D = box.get(&"box_from_world", Transform3D.IDENTITY)
	if (
		half_size == _source_roof_half_size and from_world == _source_roof_from_world
		and replace_scalar == _source_roof_replaces_scalar
	):
		return
	_source_roof_half_size = half_size
	_source_roof_from_world = from_world
	_source_roof_replaces_scalar = replace_scalar
	_source_fog_material.set_shader_parameter(&"roof_half_size", half_size)
	_source_fog_material.set_shader_parameter(&"roof_from_world", from_world)
	_source_fog_material.set_shader_parameter(&"replace_scalar_shelter", replace_scalar)
	if _source_dust != null:
		_source_dust.bind_roof(from_world, half_size if replace_scalar else Vector3.ZERO)


func _physics_process(delta: float) -> void:
	_probe_time -= delta
	if _probe_time > 0.0 or not is_instance_valid(_camera):
		return
	_probe_time = PROBE_INTERVAL
	if shelter_mask == 0:
		_shelter_target = 0.0
		_ground_target = global_position.y
		_bind_source_roof({}, false)
		return

	var camera_position := _camera.global_position
	var space := get_world_3d().direct_space_state
	var excluded: Array[RID] = []
	var node: Node = _camera
	while node != null:
		if node is CollisionObject3D:
			excluded.append(node.get_rid())
		node = node.get_parent()

	_shelter_target = 0.0
	var roof_hit: Dictionary = {}
	if roof_probe_height > 0.0:
		var roof := PhysicsRayQueryParameters3D.create(
			camera_position, camera_position + Vector3.UP * roof_probe_height,
			shelter_mask, excluded
		)
		roof_hit = space.intersect_ray(roof)
		_shelter_target = 0.0 if roof_hit.is_empty() else 1.0
	if _source_roof_active:
		var box := _source_roof_probe.decode_roof(camera_position, roof_hit)
		var replace_scalar := not box.is_empty() or roof_hit.is_empty()
		if box.is_empty():
			box = _source_roof_probe.find_nearby_roof(
				space, camera_position, wind_fog_settings.trace_distance_meters,
				roof_probe_height, shelter_mask, excluded,
			)
		_bind_source_roof(box, replace_scalar and not box.is_empty())

	if ground_probe_depth > 0.0:
		var ground := PhysicsRayQueryParameters3D.create(
			camera_position, camera_position + Vector3.DOWN * ground_probe_depth,
			shelter_mask, excluded
		)
		var hit := space.intersect_ray(ground)
		if not hit.is_empty():
			_ground_target = hit.position.y
