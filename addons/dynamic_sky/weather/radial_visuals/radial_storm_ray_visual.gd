extends MeshInstance3D
## Private depth-aware visual of the owning radial storm.

const SkyLookup = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")

var _storm: DynamicSkyRadialStorm
var _sky: DynamicSky
var _random := RandomNumberGenerator.new()
var _time := 0.0
var _wind_offset := Vector2.ZERO
var _center := Vector3.ZERO
var _visibility := 0.0
var _flash_offset := Vector3.ZERO
var _flash_age := INF
var _flash_duration := 1.0
var _flash_strength := 0.0
var _flash_radius := 1000.0
var _next_flash := 1.0
var _flash_budget := 0.0

@onready var _material := material_override as ShaderMaterial


func _ready() -> void:
	_storm = get_parent() as DynamicSkyRadialStorm
	_random.seed = hash(get_path())
	_next_flash = _random.randf_range(0.65, 1.35)
	hide()


func _process(delta: float) -> void:
	_flash_age += delta
	if _storm == null or not _storm.distant_visuals_enabled or _storm.get_effective_alpha() <= 0.5:
		_deactivate()
		return
	var camera := get_viewport().get_camera_3d()
	_sky = SkyLookup.resolve(self, null, _sky)
	if (
		camera == null or _sky == null or _sky.get_cloud_mode() != DynamicSky.CloudMode.VOLUMETRIC
		or _sky.is_space_mode() or _sky._observer_underwater
		or _sky.weather_style != DynamicSky.WeatherStyle.REALISTIC
		or not _sky.accepts_weather_profile(_storm.weather)
	):
		_deactivate()
		return

	var radius := _storm.outer_radius
	var profile := _storm.weather
	var observer := camera.get_camera_transform().origin
	var base := _sky.global_position.y + 1000.0 * _sky._get_cloud_layer_value(&"cloud_base_km", 0.60)
	var ground := _sky.global_position.y
	if base - ground < 10.0:
		ground = base - 750.0
	_center = Vector3(_storm.global_position.x, base, _storm.global_position.z)
	var offset := observer - _center
	var flat_distance := Vector2(offset.x, offset.z).length()
	var inner := radius * _storm.inner_radius_fraction
	var inside := 1.0 if flat_distance <= inner else pow(clampf(
		(radius - flat_distance) / maxf(radius - inner, 0.001), 0.0, 1.0
	), 2.0)
	var far_range := maxf(_storm.distant_fade_range, 1.0)
	var far_weight := 1.0 - clampf((offset.length() - radius) / far_range, 0.0, 1.0)
	var thickness := 1000.0 * _sky._get_cloud_layer_value(&"cloud_thickness_km", 0.70)
	var below := 1.0 - clampf(offset.y / maxf(0.30 * thickness, 1.0), 0.0, 1.0)
	_visibility = _storm.get_visual_alpha() * (1.0 - inside) * far_weight * below
	if _visibility <= 0.0001:
		_deactivate()
		return

	var thunder := _storm.get_thunder_strength()
	_flash_budget += _storm.obscured_lightning_rate * thunder * delta
	if _flash_budget >= _next_flash:
		_flash_budget -= _next_flash
		_next_flash = _random.randf_range(0.65, 1.35)
		var angle := _random.randf_range(0.0, TAU)
		var distance := sqrt(_random.randf()) * radius * lerpf(1.0, _storm.inner_radius_fraction, 0.40)
		var position := _center + Vector3(cos(angle) * distance, thickness * 0.08, sin(angle) * distance)
		flash_at(position, thunder * _random.randf_range(0.60, 1.0))

	var precipitation := maxf(profile.rain, profile.snow)
	var coverage := maxf(0.85 * precipitation, maxf(
		0.75 * clampf(inverse_lerp(0.70, 1.0, profile.fog_amount), 0.0, 1.0),
		0.85 * clampf(inverse_lerp(0.30, 1.0, profile.dust), 0.0, 1.0)
	))
	var fog := coverage * maxf(_storm.distant_fog_strength, 0.0)
	var flash := _flash_envelope() * _visibility * maxf(_storm.obscured_lightning_intensity, 0.0)
	visible = fog > 0.0001 or flash > 0.0001
	if not visible:
		return

	var speed := maxf(_storm.distant_fog_motion, 0.0)
	var wind := _sky.get_wind_at(_center)
	_time += delta * speed
	_wind_offset += Vector2(wind.x, wind.z) * delta * speed
	_material.set_shader_parameter(&"storm_center", _center)
	_material.set_shader_parameter(&"outer_radius_m", radius)
	_material.set_shader_parameter(&"ground_y", ground)
	_material.set_shader_parameter(&"cloud_base_y", base)
	_material.set_shader_parameter(&"fog_amount", fog)
	_material.set_shader_parameter(&"fog_scale", maxf(_storm.distant_fog_scale, 0.1))
	_material.set_shader_parameter(&"visual_opacity", _visibility)
	_material.set_shader_parameter(&"shaft_radiance", _shaft_tint(profile))
	_material.set_shader_parameter(&"wind_offset_m", _wind_offset)
	_material.set_shader_parameter(&"motion_seconds", _time)
	_material.set_shader_parameter(&"flash_position", _center + _flash_offset)
	_material.set_shader_parameter(&"flash_strength", flash)
	_material.set_shader_parameter(&"flash_radius_m", _flash_radius)


func flash_at(world_position: Vector3, strength: float) -> bool:
	if _visibility <= 0.0 or not world_position.is_finite() or not is_finite(strength) or strength <= 0.0:
		return false
	var offset := world_position - _center
	if Vector2(offset.x, offset.z).length() > _storm.outer_radius:
		return false
	_flash_offset = offset
	_flash_age = 0.0
	_flash_duration = _random.randf_range(0.75, 2.0)
	_flash_radius = _random.randf_range(2550.0, 3150.0) * 0.36
	_flash_strength = minf(strength, 1.0)
	return true


func _flash_envelope() -> float:
	if _flash_age >= _flash_duration:
		return 0.0
	var attack := smoothstep(0.0, 0.026, _flash_age)
	var tail := 1.0 - smoothstep(0.35, 1.0, _flash_age / _flash_duration)
	var pulses := exp(-5.8 * _flash_age) + 0.41 * exp(-pow((_flash_age - 0.18) * 15.0, 2.0))
	return attack * tail * pulses * _flash_strength


func _shaft_tint(profile: DynamicSkyWeather) -> Vector3:
	var daylight := smoothstep(-0.10, 0.25, _sky.get_sun_direction().y)
	var moonlight := smoothstep(0.0, 0.62, _sky.get_moon_direction().y)
	var overcast := smoothstep(0.55, 1.0, profile.cloud_coverage)
	var sky_day := _sky.day_fog_color.lerp(_sky.overcast_fog_color, overcast).srgb_to_linear()
	var deck_shade := smoothstep(0.50, 0.75, profile.cloud_coverage)
	var snow := clampf(profile.snow - profile.rain, 0.0, 1.0)
	var shade_tint := Vector3(0.27, 0.42, 0.68).lerp(Vector3(0.51, 0.60, 0.73), snow)
	var shadowed_day := Vector3(sky_day.r, sky_day.g, sky_day.b) * Vector3.ONE.lerp(shade_tint, deck_shade)
	var sky_night := _sky.night_fog_color.srgb_to_linear()
	var night := Vector3(sky_night.r, sky_night.g, sky_night.b) * (1.0 + 0.55 * moonlight)
	var tint := night.lerp(shadowed_day, daylight)
	var luma := tint.dot(Vector3(0.2126, 0.7152, 0.0722))
	tint = Vector3(luma, luma, luma).lerp(tint, 0.8)
	tint *= Vector3.ONE.lerp(Vector3(1.3, 0.699, 0.351), profile.dust)
	return tint * lerpf(1.0, 0.5, clampf(inverse_lerp(0.50, 0.75, profile.cloud_coverage), 0.0, 1.0))


func _deactivate() -> void:
	hide()
	_visibility = 0.0
	_flash_budget = 0.0
