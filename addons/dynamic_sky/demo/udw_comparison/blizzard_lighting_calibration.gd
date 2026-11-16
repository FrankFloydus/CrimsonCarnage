extends Node
## Applies the reference map's Blizzard calibration after DynamicSky has updated.

const HAZE_WEIGHT := &"daylight_visibility_haze_weight"
const HAZE_HORIZON := &"daylight_visibility_horizon_radiance"
const HAZE_ZENITH := &"daylight_visibility_zenith_radiance"
const HORIZON_FOG_RADIANCE := &"horizon_fog_radiance"
const TWILIGHT_SUN_HEIGHT := 0.113039
const MORNING_SUN_HEIGHT := 0.700629
const NOON_SUN_HEIGHT := 0.866025
const EVENING_MOON_HEIGHT := 0.515132
const LATE_NIGHT_MOON_HEIGHT := 0.858616
const MORNING_MIST_SCALE := Vector3(0.89645, 0.89412, 0.87493)

## Dynamic Sky instance owned by this comparison map.
@export var rig: DynamicSky

## Enables the comparison calibration. Disable to restore the rig's authored appearance.
@export var enabled: bool = true:
	set(value):
		enabled = value
		if is_node_ready():
			if not enabled:
				_restore()
			set_process(enabled)

@export_group("Source daylight")
## Ratio between the source's Blizzard and Clear directional intensity at noon.
@export_range(0.0, 1.0, 0.00001) var sun_energy_ratio: float = 0.06125

## Angular diameter of the source Sun light in a fully overcast Blizzard.
@export_range(0.0, 20.0, 0.05, "suffix:°") var sun_angular_diameter: float = 5.0

## Comparison-local multiplier for the Environment's existing tone map exposure.
@export_range(0.05, 2.0, 0.01) var exposure_ratio: float = 0.5

@export_group("Twilight and night")
## Exposure ratio at the reference twilight Sun height. The day and night values blend around this point.
@export_range(0.05, 2.0, 0.01) var twilight_exposure_ratio: float = 0.33

## Exposure ratios at lunar elevations of 31 and 59 degrees, respectively.
@export var night_exposure_ratios := Vector2(0.70, 0.97)

## Fraction of the rig's direct moonlight that reaches the ground under the reference overcast.
@export_range(0.0, 1.0, 0.005) var moon_energy_ratio: float = 0.065

## Linear RGB correction for the low Sun scattering around the reference twilight.
@export var twilight_fog_radiance_ratio := Vector3(1.46, 1.04, 0.78)

## Linear RGB correction for distance fog under the reference moonlit overcast.
@export var night_fog_radiance_ratio := Vector3(1.60, 1.08, 1.0)

@export_group("Indirect light")
## Relative reach of screen-space indirect lighting in the blizzard. The shorter reach keeps it from darkening the whole base of a prop.
@export_range(0.01, 1.0, 0.01) var ssil_radius_ratio: float = 0.13

## Relative intensity of screen-space indirect light and its obscurance. SDFGI continues to supply world-space indirect light.
@export_range(0.0, 1.0, 0.01) var ssil_intensity_ratio: float = 0.22

## Relative SDFGI energy in the daytime blizzard.
@export_range(0.0, 1.0, 0.01) var sdfgi_energy_ratio: float = 0.98

@export_group("Fog radiance")
## Linear RGB multiplier for the distance fog. It also tints the shallow sky rays that meet the terrain.
@export var distance_fog_radiance_ratio := Vector3(0.97, 0.91, 1.10)

## Per-channel linear ratio for the depth-bounded snow wind mist at noon.
@export var mist_radiance_ratio := Vector3(0.5122, 0.403, 0.72324)

@export_group("Blowing snow layer")
## Sets the world elevation of the flat comparison ground so props cannot shift the mist vertically.
@export var blowing_snow_ground: Node3D

## Extinction per meter at ground level in full Blizzard. Zero leaves only the short wind mist.
@export_range(0.0, 0.15, 0.001) var blowing_snow_extinction: float = 0.05

## Height at which the base density falls to roughly 37 percent of its ground value.
@export_range(0.1, 12.0, 0.1, "suffix:m") var blowing_snow_scale_height: float = 3.3

## Multipliers for the resolved fog radiance, from moonlit conditions to full daylight.
@export var blowing_snow_radiance_ratios := Vector2(0.80, 1.065)

@export_group("Visible sky")
## Fraction of visible sky scattered by the reference's additional optical veil.
@export_range(0.0, 1.0, 0.01) var sky_haze_weight: float = 0.62

## Linear RGB radiance scattered by the sky veil toward the horizon at the reference morning Sun height.
@export var sky_horizon_morning_radiance := Vector3(0.245, 0.298, 0.525)

## Linear RGB radiance scattered toward the horizon when the Sun reaches the reference noon height.
@export var sky_horizon_noon_radiance := Vector3(0.26, 0.341, 0.575)

## Linear RGB radiance scattered overhead at the reference morning Sun height.
@export var sky_zenith_morning_radiance := Vector3(0.315, 0.387, 0.56)

## Linear RGB radiance scattered overhead when the Sun reaches the reference noon height.
@export var sky_zenith_noon_radiance := Vector3(0.375, 0.443, 0.65)


class TrackedOverride:
	var _target: Object
	var _property: StringName
	var _uniform := false
	var _authored: Variant
	var _last_write: Variant
	var _has_write := false

	func base(target: Object, property: StringName, uniform := false, fresh := false) -> Variant:
		if target != _target:
			restore()
			_target = target
			_property = property
			_uniform = uniform
		var current: Variant = _read()
		if fresh or not _has_write or not is_same(current, _last_write):
			_authored = current
		return _authored

	func apply(value: Variant) -> void:
		if not is_same(_read(), value):
			_write(value)
		_last_write = _read()
		_has_write = true

	func restore() -> void:
		if is_instance_valid(_target) and _has_write and is_same(_read(), _last_write):
			_write(_authored)
		_target = null
		_has_write = false

	func _read() -> Variant:
		if _uniform:
			return (_target as ShaderMaterial).get_shader_parameter(_property)
		return _target.get(_property)

	func _write(value: Variant) -> void:
		if _uniform:
			(_target as ShaderMaterial).set_shader_parameter(_property, value)
		else:
			_target.set(_property, value)


var _active_rig: DynamicSky
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _world_environment: WorldEnvironment
var _mist: MeshInstance3D
var _visibility_shader: Shader
var _supports_sky_haze := false
var _has_calibration := false
var _energy := TrackedOverride.new()
var _angle := TrackedOverride.new()
var _shadow_opacity := TrackedOverride.new()
var _shadow_enabled := TrackedOverride.new()
var _moon_energy := TrackedOverride.new()
var _moon_shadow_opacity := TrackedOverride.new()
var _moon_shadow_enabled := TrackedOverride.new()
var _exposure := TrackedOverride.new()
var _ssil_radius := TrackedOverride.new()
var _ssil_intensity := TrackedOverride.new()
var _sdfgi_energy := TrackedOverride.new()
var _fog_color := TrackedOverride.new()
var _mist_color := TrackedOverride.new()
var _blowing_snow_density := TrackedOverride.new()
var _blowing_snow_radiance := TrackedOverride.new()
var _fog_horizon := TrackedOverride.new()
var _haze_weight := TrackedOverride.new()
var _haze_horizon := TrackedOverride.new()
var _haze_zenith := TrackedOverride.new()


func _ready() -> void:
	set_process(enabled)
	if enabled:
		_update()


func _process(_delta: float) -> void:
	if not is_instance_valid(rig):
		_restore()
	elif rig.weather_style != DynamicSky.WeatherStyle.REALISTIC:
		_restore()
	elif rig.is_processing():
		_update()


func _exit_tree() -> void:
	_restore()


func _update() -> void:
	if not is_instance_valid(rig) or rig.weather_style != DynamicSky.WeatherStyle.REALISTIC:
		return
	if rig != _active_rig:
		_restore()
		_active_rig = rig
		if not is_instance_valid(rig):
			return
		_sun = rig.get_node_or_null("Sun") as DirectionalLight3D
		_moon = rig.get_node_or_null("Moon") as DirectionalLight3D
		_world_environment = rig.get_node_or_null("WorldEnvironment") as WorldEnvironment
		_mist = rig.get_node_or_null("AirborneWeather/PostProcessWindFog") as MeshInstance3D
	if not is_instance_valid(_sun) or not is_instance_valid(_world_environment):
		return
	var environment := _world_environment.environment
	if environment == null:
		_restore()
		return

	var weather := rig.get_weather_state()
	var severity := minf(weather[&"cloud_coverage"], minf(weather[&"snow"], weather[&"fog_amount"]))
	var other_precipitation := maxf(weather[&"rain"], weather[&"dust"])
	var blizzard_weight := smoothstep(0.75, 1.0, severity) * (1.0 - smoothstep(0.0, 0.2, other_precipitation))
	var sun_height := rig.get_sun_direction().y
	var day_weight := smoothstep(0.03, 0.35, sun_height)
	var weight := blizzard_weight * day_weight
	if blizzard_weight <= 0.0:
		_restore()
		return

	_has_calibration = true
	var night := 1.0 - smoothstep(-0.28, TWILIGHT_SUN_HEIGHT, sun_height)
	var midday := smoothstep(TWILIGHT_SUN_HEIGHT, 0.55, sun_height)
	var moon_height := rig.get_moon_direction().y
	var lunar_mix := clampf(inverse_lerp(EVENING_MOON_HEIGHT, LATE_NIGHT_MOON_HEIGHT, moon_height), 0.0, 1.0)
	var night_exposure := lerpf(night_exposure_ratios.x, night_exposure_ratios.y, lunar_mix)
	var reference_exposure := lerpf(lerpf(twilight_exposure_ratio, night_exposure, night), exposure_ratio, midday)
	var sun_energy := float(_energy.base(_sun, &"light_energy", false, true))
	_energy.apply(sun_energy * lerpf(1.0, sun_energy_ratio, blizzard_weight))
	var sun_angle := float(_angle.base(_sun, &"light_angular_distance"))
	_angle.apply(lerpf(sun_angle, sun_angular_diameter, weight))
	_apply_shadow(_sun, _shadow_opacity, _shadow_enabled, blizzard_weight)
	if is_instance_valid(_moon):
		var moon_energy := float(_moon_energy.base(_moon, &"light_energy", false, true))
		_moon_energy.apply(moon_energy * lerpf(1.0, moon_energy_ratio, blizzard_weight))
		_apply_shadow(_moon, _moon_shadow_opacity, _moon_shadow_enabled, blizzard_weight)
	var authored_exposure := float(_exposure.base(environment, &"tonemap_exposure"))
	_exposure.apply(authored_exposure * lerpf(1.0, reference_exposure, blizzard_weight))

	_apply_indirect_light(environment, blizzard_weight)
	var solar_mix := clampf(inverse_lerp(MORNING_SUN_HEIGHT, NOON_SUN_HEIGHT, sun_height), 0.0, 1.0)
	var fog_ratio := twilight_fog_radiance_ratio.lerp(night_fog_radiance_ratio, night)
	fog_ratio = fog_ratio.lerp(distance_fog_radiance_ratio, midday)
	_apply_distance_airlight(environment, fog_ratio, blizzard_weight)
	_apply_mist(environment, blizzard_weight, weight, solar_mix, sun_height)
	_apply_sky_haze(environment, blizzard_weight, solar_mix)


func _apply_shadow(light: DirectionalLight3D, opacity: TrackedOverride, enabled_state: TrackedOverride, weight: float) -> void:
	var authored_opacity := float(opacity.base(light, &"shadow_opacity"))
	var authored_enabled := bool(enabled_state.base(light, &"shadow_enabled"))
	opacity.apply(authored_opacity * (1.0 - weight))
	enabled_state.apply(authored_enabled and weight < 1.0)


func _apply_indirect_light(environment: Environment, weight: float) -> void:
	var radius := float(_ssil_radius.base(environment, &"ssil_radius"))
	var intensity := float(_ssil_intensity.base(environment, &"ssil_intensity"))
	var energy := float(_sdfgi_energy.base(environment, &"sdfgi_energy"))
	_ssil_radius.apply(radius * lerpf(1.0, ssil_radius_ratio, weight))
	_ssil_intensity.apply(intensity * lerpf(1.0, ssil_intensity_ratio, weight))
	_sdfgi_energy.apply(energy * lerpf(1.0, sdfgi_energy_ratio, weight))


func _apply_distance_airlight(environment: Environment, ratio: Vector3, weight: float) -> void:
	if not environment.fog_enabled:
		_fog_color.restore()
		_fog_horizon.restore()
		return
	# DynamicSky resolves the authored fog color each frame before this comparison pass.
	var authored: Color = _fog_color.base(environment, &"fog_light_color", false, true)
	var linear := authored.srgb_to_linear()
	var rgb := Vector3(linear.r, linear.g, linear.b)
	var airlight := rgb.lerp(rgb * ratio, weight)
	_fog_color.apply(Color(airlight.x, airlight.y, airlight.z, authored.a).linear_to_srgb())


func _apply_mist(environment: Environment, blizzard_weight: float, weight: float, solar_mix: float, sun_height: float) -> void:
	if (
		not is_instance_valid(_mist) or not _mist.visible or rig.wind_fog_settings == null
		or rig.wind_fog_settings.mode not in [
			DynamicSkyWindFogSettings.Mode.SOURCE_SNOW,
			DynamicSkyWindFogSettings.Mode.SOURCE_SNOW_AND_DUST,
		]
	):
		_restore_mist()
		return
	var material := _mist.material_override as ShaderMaterial
	if material == null:
		_restore_mist()
		return
	var radiance: Variant = _mist_color.base(material, &"fog_radiance", true, true)
	if radiance is Vector3:
		# The source collection's ambient fog radiance is lower at the comparison map's morning sun angle.
		var source_scale := MORNING_MIST_SCALE.lerp(Vector3.ONE, solar_mix)
		_mist_color.apply(radiance.lerp(radiance * mist_radiance_ratio * source_scale, weight))
	if not environment.fog_enabled or not is_instance_valid(blowing_snow_ground):
		_blowing_snow_density.restore()
		_blowing_snow_radiance.restore()
		return
	_blowing_snow_density.base(material, &"blizzard_mist_layer", true)
	_blowing_snow_density.apply(Vector3(
		blowing_snow_extinction * blizzard_weight, blowing_snow_scale_height, blowing_snow_ground.global_position.y,
	))
	var ambient := environment.fog_light_color.srgb_to_linear() * environment.fog_light_energy
	var daylight := smoothstep(-0.15, 0.35, sun_height)
	var scale := lerpf(blowing_snow_radiance_ratios.x, blowing_snow_radiance_ratios.y, daylight)
	_blowing_snow_radiance.base(material, &"blizzard_mist_radiance", true)
	_blowing_snow_radiance.apply(Vector3(ambient.r, ambient.g, ambient.b) * scale)


func _restore_mist() -> void:
	_mist_color.restore()
	_blowing_snow_density.restore()
	_blowing_snow_radiance.restore()


func _apply_sky_haze(environment: Environment, blizzard_weight: float, solar_mix: float) -> void:
	var material := environment.sky.sky_material as ShaderMaterial if environment.sky != null else null
	var shader := material.shader if material != null else null
	if shader != _visibility_shader:
		_visibility_shader = shader
		_supports_sky_haze = shader != null and shader.get_shader_uniform_list().any(
			func(property: Dictionary) -> bool: return property["name"] == HAZE_WEIGHT
		)
	if not _supports_sky_haze:
		_restore_sky_haze()
		return
	if environment.fog_enabled and environment.fog_density > 0.0:
		# Keep the same linear scattering color on shallow sky rays and distant geometry.
		var fog := environment.fog_light_color.srgb_to_linear() * environment.fog_light_energy
		fog /= maxf(environment.background_energy_multiplier, 0.001)
		_fog_horizon.base(material, HORIZON_FOG_RADIANCE, true, true)
		_fog_horizon.apply(Vector3(fog.r, fog.g, fog.b))
	else:
		_fog_horizon.restore()
	_haze_weight.base(material, HAZE_WEIGHT, true)
	_haze_horizon.base(material, HAZE_HORIZON, true)
	_haze_zenith.base(material, HAZE_ZENITH, true)
	# The shared shader handles the daylight ramp for visible sky.
	_haze_weight.apply(sky_haze_weight * blizzard_weight)
	_haze_horizon.apply(sky_horizon_morning_radiance.lerp(sky_horizon_noon_radiance, solar_mix))
	_haze_zenith.apply(sky_zenith_morning_radiance.lerp(sky_zenith_noon_radiance, solar_mix))


func _restore_sky_haze() -> void:
	_fog_horizon.restore()
	_haze_weight.restore()
	_haze_horizon.restore()
	_haze_zenith.restore()


func _restore() -> void:
	if not _has_calibration:
		return
	_has_calibration = false
	_energy.restore()
	_angle.restore()
	_shadow_opacity.restore()
	_shadow_enabled.restore()
	_moon_energy.restore()
	_moon_shadow_opacity.restore()
	_moon_shadow_enabled.restore()
	_exposure.restore()
	_ssil_radius.restore()
	_ssil_intensity.restore()
	_sdfgi_energy.restore()
	_fog_color.restore()
	_restore_mist()
	_restore_sky_haze()

