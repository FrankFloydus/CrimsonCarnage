@tool
class_name DynamicSky
extends Node3D
## Owns the clock, atmosphere, directional lights, and global weather for one world.

signal weather_transition_finished(profile: DynamicSkyWeather)
## Reports each civil hour crossed during normal runtime advancement.
signal civil_hour_changed(hour: int, day_offset: int)
## Reports a new Gregorian date at runtime midnight.
signal civil_date_changed(date: Dictionary)
## Reports a geometric sunrise with its civil day and local hour.
signal sunrise(day_offset: int, hour: float)
## Reports a geometric sunset with its civil day and local hour.
signal sunset(day_offset: int, hour: float)
## Reports a midnight crossed during normal runtime advancement.
signal midnight(day_offset: int)
## Reports the first visible return stroke or an obscured cloud flash.
signal lightning_struck(world_position: Vector3, intensity: float)

## Authored cloud-rendering selection. Material Default leaves the actual material's mode untouched.
enum CloudMode {
	## Uses the mode currently authored on the native sky material.
	MATERIAL_DEFAULT = -1,
	## Ray-marches the world-space volume.
	VOLUMETRIC = 0,
	## Uses the stationary packed-lighting dome.
	STATIC = 1,
	## Omits cloud rendering.
	CLEAR = 2,
	## Uses the advected layered cloud field.
	DYNAMIC_2D = 3,
	## Uses the celestial backdrop and suspends terrestrial observer effects.
	SPACE = 4,
}
## Independent sky-color selection for terrestrial cloud modes.
enum ColorMode {
	## Uses the color mode currently authored on the native sky material.
	MATERIAL_DEFAULT = -1,
	## Uses atmosphere scattering lookup tables.
	SKY_ATMOSPHERE = 0,
	## Uses the separate artist-controlled sun and moon color tables.
	SIMPLIFIED_COLOR = 1,
}

## Selects the preset family and its rendering palette.
enum WeatherStyle { REALISTIC, STYLIZED }

const CLEAR_WEATHER = preload("res://addons/dynamic_sky/presets/clear.tres")
const WeatherState = preload("res://addons/dynamic_sky/weather/weather_state.gd")
const RadialStormSpawning = preload("res://addons/dynamic_sky/weather/radial_storm_spawning.gd")
const RadialStormScheduler = preload("res://addons/dynamic_sky/weather/radial_storm_scheduler.gd")
const SkyClock = preload("res://addons/dynamic_sky/weather/clock/sky_clock.gd")
const CloudDaylightTransport = preload("res://addons/dynamic_sky/rendering/cloud_daylight_transport.gd")
const MaterialWeatherBinding = preload("res://addons/dynamic_sky/surfaces/material_weather_binding.gd")
const DEFAULT_WEATHER_LIBRARY = preload("res://addons/dynamic_sky/presets/weather_library.tres")
const DEFAULT_STYLIZED_LIBRARY = preload("res://addons/dynamic_sky/presets/stylized/weather_library.tres")
const StylizedWeather = preload("res://addons/dynamic_sky/weather/stylized_weather.gd")
const GROUP := &"dynamic_sky_worlds"
const CLOUD_OFFSET_PERIOD := 128.0
const MAX_RADIAL_CLOUD_CELLS := 8
const SOURCE_NIGHT_DUST_FOG_CHROMA := Vector3(1.048197, 0.970968, 1.145661)
const SOURCE_DAY_DUST_FOG_SCALE := Color(0.74605, 0.73285, 0.80466, 1.0)
const NATIVE_HEIGHT_FOG_SETTER := &"environment_set_fog_height_integrated"
const CONFIGURATION_REFERENCES: Array[StringName] = [
	&"astronomy", &"start_weather", &"climate", &"wind_settings", &"weather_presets", &"exposure_settings",
	&"rainbow_settings", &"snow_settings", &"airborne_settings", &"wind_fog_settings",
	&"screen_settings", &"wind_shake_settings", &"wind_debris_settings",
	&"weather_audio_settings", &"lightning_settings", &"material_weather_settings",
	&"rain_settings", &"cloud_shadow_settings", &"radial_storm_spawning",
]

@export_group("Configuration")
## Reusable Inspector configuration. Its resources travel with this rig into other scenes.
## Empty keeps this root's individually authored values and typed settings resources.
@export var configuration: DynamicSkyConfiguration:
	set(value):
		if configuration == value:
			return
		if configuration != null and configuration.changed.is_connected(_apply_configuration):
			configuration.changed.disconnect(_apply_configuration)
		configuration = value
		if configuration != null:
			configuration.changed.connect(_apply_configuration)
		notify_property_list_changed()
		if is_node_ready():
			_configuration_values.clear()
			_configuration_references.clear()
			_apply_configuration()

@export_group("Clock")
## Time in hours. With an empty Astronomy resource, sunrise is at 6 and sunset at 18.
@export_range(0.0, 24.0, 0.01, "suffix:h") var time_of_day: float = 14.0:
	set(value):
		time_of_day = fposmod(value, 24.0)
		_celestial_changed()

## Real seconds per full day. Set to zero to stop the clock.
@export_range(0.0, 3600.0, 1.0, "or_greater", "suffix:s") var day_length_seconds: float = 0.0

## Follows the computer clock in the editor and at runtime. Astronomy selects its UTC offset.
## With no Astronomy resource, the operating system's local time zone is used.
@export var use_system_time: bool = false:
	set(value):
		use_system_time = value
		notify_property_list_changed()
		if is_node_ready():
			if use_system_time:
				_synchronize_system_time()
			_clock.reset(_calendar_day_offset, time_of_day, astronomy)
			set_process(not Engine.is_editor_hint() or use_system_time)

## Geographic latitude in degrees. Positive values are north of the equator.
@export_range(-89.0, 89.0, 0.1, "degrees") var latitude: float = 35.0:
	set(value):
		latitude = clampf(value, -89.0, 89.0)
		_celestial_changed()

## Rotates the solar arc around world up. Zero places north at world negative Z.
@export_range(-180.0, 180.0, 0.1, "degrees") var north_rotation: float = 0.0:
	set(value):
		north_rotation = value
		_celestial_changed()

## Optional civil date and longitude for calculated sun, moon, and star positions.
@export var astronomy: DynamicSkyAstronomy:
	set(value):
		if astronomy != null and astronomy.changed.is_connected(_celestial_changed):
			astronomy.changed.disconnect(_celestial_changed)
		astronomy = value
		if astronomy != null:
			astronomy.changed.connect(_celestial_changed)
		_celestial_changed()

@export_group("Weather")
## Profile used on scene startup and for the editor preview. Empty uses Clear.
@export var start_weather: DynamicSkyWeather:
	set(value):
		if start_weather != null and start_weather.changed.is_connected(_preview_weather):
			start_weather.changed.disconnect(_preview_weather)
		start_weather = value
		if Engine.is_editor_hint() and start_weather != null:
			start_weather.changed.connect(_preview_weather)
		if is_node_ready() and Engine.is_editor_hint() and weather_style == WeatherStyle.REALISTIC:
			_preview_weather()

## Cloud pattern UV displacement per meter of horizontal wind travel.
@export_range(0.0, 0.01, 0.0001, "or_greater") var cloud_drift_scale: float = 0.001

## Observer effects for volumetric clouds, water surfaces, and nighttime dust exposure.
## Global weather, per-position physics wind, and surface accumulation use the unfiltered state.
@export var exposure_settings: DynamicSkyExposureSettings = preload("res://addons/dynamic_sky/weather/exposure/exposure_settings.tres"):
	set(value):
		exposure_settings = value
		if is_instance_valid(_exposure):
			_exposure.settings = value
		if is_node_ready() and not _weather.current.is_empty():
			_refresh_view_weather()
			_apply_sky()
			_apply_weather_effects(0.0)

## Shared airflow direction and gust settings for clouds, particles, audio, and wind receivers.
@export var wind_settings: DynamicSkyWindSettings = preload("res://addons/dynamic_sky/weather/wind/wind_settings.tres")

## Reusable weather library that travels with this rig into other scenes. Empty uses stock presets.
@export var weather_presets: Array[DynamicSkyWeather] = DEFAULT_WEATHER_LIBRARY.presets.duplicate():
	set(value):
		weather_presets = DEFAULT_WEATHER_LIBRARY.presets.duplicate() if value.is_empty() else value

## Optional seasonal weather schedule. Empty leaves changes under manual control.
@export var climate: DynamicSkyClimate:
	set(value):
		climate = value
		_climate_time_remaining = 0.0


@export_group("Weather Style")
## Selects which presets, zones, and rendering palette are active. A change starts the selected family's startup weather.
@export var weather_style: WeatherStyle = WeatherStyle.REALISTIC:
	set(value):
		if weather_style == value:
			return
		weather_style = value
		notify_property_list_changed()
		if not is_node_ready():
			return
		_climate_time_remaining = 0.0
		_radial_storm_scheduler.stop()
		_flash_remaining = 0.0
		_lightning_budget = 0.0
		_rainbow_moisture = 0.0
		if not Engine.is_editor_hint():
			if _strikes != null:
				_strikes.clear_flash()
			if _screen_weather != null:
				_screen_weather.reset()
		set_weather(get_starting_weather())

## Separate preset library for Stylized mode. Empty uses the Nordic Fantasy library.
@export var stylized_weather_library: DynamicSkyWeatherLibrary = DEFAULT_STYLIZED_LIBRARY:
	set(value):
		stylized_weather_library = value
		if Engine.is_editor_hint() and is_node_ready() and weather_style == WeatherStyle.STYLIZED:
			_preview_weather()

## Optional starting preset for Stylized mode. Empty uses the first stylized preset in the library.
@export var stylized_start_weather: StylizedWeather:
	set(value):
		if stylized_start_weather != null and stylized_start_weather.changed.is_connected(_preview_weather):
			stylized_start_weather.changed.disconnect(_preview_weather)
		stylized_start_weather = value
		if Engine.is_editor_hint() and stylized_start_weather != null:
			stylized_start_weather.changed.connect(_preview_weather)
		if Engine.is_editor_hint() and is_node_ready() and weather_style == WeatherStyle.STYLIZED:
			_preview_weather()


@export_group("Radial Storm Spawning")
## Optional schedule for storms that travel across the active camera. Manually placed storms remain independent.
@export var radial_storm_spawning: RadialStormSpawning


@export_group("Sky Rendering")
## Cloud renderer selected by the root. Material Default preserves the actual sky material's setting.
@export var cloud_mode: CloudMode = CloudMode.MATERIAL_DEFAULT:
	set(value):
		cloud_mode = clampi(value, CloudMode.MATERIAL_DEFAULT, CloudMode.SPACE)
		if is_node_ready() and cloud_mode >= 0:
			set_cloud_mode(cloud_mode)

## Sky-color path independent of cloud rendering. Material Default preserves native material authoring.
@export var color_mode: ColorMode = ColorMode.MATERIAL_DEFAULT:
	set(value):
		color_mode = clampi(value, ColorMode.MATERIAL_DEFAULT, ColorMode.SIMPLIFIED_COLOR)
		if is_node_ready() and color_mode >= 0:
			set_color_mode(color_mode)

## Volume sampling quality. Material Default preserves the saved sky material's setting.
@export_enum("Material Default:-1", "Balanced:0", "High:1") var volumetric_quality: int = -1:
	set(value):
		volumetric_quality = clampi(value, -1, 1)
		if is_node_ready():
			_sync_environment_resources()
		if _sky_material != null and volumetric_quality >= 0:
			_set_sky_parameter(&"volumetric_quality", volumetric_quality)

## Directional cloud-shadow projection, resolution, sampling, strength, and refresh controls.
## Empty restores the component's saved standalone values.
@export var cloud_shadow_settings: DynamicSkyCloudShadowSettings:
	set(value):
		_watch_effect_settings(cloud_shadow_settings, value)
		cloud_shadow_settings = value
		_effect_settings_changed()

@export_group("Atmospheric Optics")
## Anti-solar rainbow optics and lingering rain/fog moisture. Disabled in the saved default.
## This resource owns the effect's tuning; the sky material receives its runtime outputs.
@export var rainbow_settings: DynamicSkyRainbowSettings:
	set(value):
		if rainbow_settings != null and rainbow_settings.changed.is_connected(_rainbow_settings_changed):
			rainbow_settings.changed.disconnect(_rainbow_settings_changed)
		rainbow_settings = value
		if rainbow_settings != null:
			rainbow_settings.changed.connect(_rainbow_settings_changed)
		_rainbow_settings_changed()

@export_group("Precipitation")
## Visible near, middle, and distant rain, optics, splashes, and storm spray.
## Its enable switch leaves the weather rain channel, sky, audio, and surface wetness independent.
@export var rain_settings: DynamicSkyRainSettings:
	set(value):
		_watch_effect_settings(rain_settings, value)
		rain_settings = value
		_effect_settings_changed()

## Spawn volume, trajectory cache, wind scale, and flake size for snowfall.
## Empty restores the component's saved standalone settings.
@export var snow_settings: DynamicSkySnowSettings:
	set(value):
		_watch_effect_settings(snow_settings, value)
		snow_settings = value
		_effect_settings_changed()

## Camera used to position precipitation and update its shelter/collision field. Empty follows the active viewport camera.
@export var precipitation_camera: Camera3D:
	set(value):
		precipitation_camera = value
		_effect_settings_changed()

## Enables the camera precipitation heightfield and geometry-clipped snow trajectories.
@export var precipitation_surface_collision: bool = true:
	set(value):
		precipitation_surface_collision = value
		_effect_settings_changed()

## Enables small snow contact effects when precipitation surface collision is enabled.
@export var snow_contact_enabled: bool = true:
	set(value):
		snow_contact_enabled = value
		_effect_settings_changed()


@export_group("Airborne Weather")
## Local rain mist, snow haze, sand density, colors, and shelter probes.
## Empty restores the component's saved standalone settings.
@export var airborne_settings: DynamicSkyAirborneSettings:
	set(value):
		_watch_effect_settings(airborne_settings, value)
		airborne_settings = value
		_effect_settings_changed()

## Selects volumetric or post-process wind fog and owns its density and sampling controls.
## Empty restores the component's saved standalone settings.
@export var wind_fog_settings: DynamicSkyWindFogSettings:
	set(value):
		_watch_effect_settings(wind_fog_settings, value)
		wind_fog_settings = value
		_effect_settings_changed()


@export_group("Screen Weather")
## Camera droplets, frost, heat distortion, and shelter response.
## Empty restores the component's saved standalone settings.
@export var screen_settings: DynamicSkyScreenSettings:
	set(value):
		_watch_effect_settings(screen_settings, value)
		screen_settings = value
		_effect_settings_changed()

## Camera whose lens receives droplets, frost, and heat distortion. Empty follows the active viewport camera.
@export var screen_camera: Camera3D:
	set(value):
		screen_camera = value
		_effect_settings_changed()


@export_group("Wind Camera Shake")
## Wind thresholds, view offsets, frequency, response, and shelter for optional camera shake.
## Empty restores the component's saved standalone settings.
@export var wind_shake_settings: DynamicSkyWindShakeSettings:
	set(value):
		_watch_effect_settings(wind_shake_settings, value)
		wind_shake_settings = value
		_effect_settings_changed()

## Camera receiving optional wind offsets. Empty follows the active viewport camera.
@export var wind_shake_camera: Camera3D:
	set(value):
		wind_shake_camera = value
		_effect_settings_changed()

## Opts into reversible camera offsets from strong wind. Disabled in the saved default.
@export var wind_shake_enabled: bool = false:
	set(value):
		wind_shake_enabled = value
		_effect_settings_changed()


@export_group("Wind Debris")
## Enables flying debris and owns wind thresholds, shelter, and surface collision.
## Empty restores the component's saved standalone settings.
@export var wind_debris_settings: DynamicSkyWindDebrisSettings:
	set(value):
		_watch_effect_settings(wind_debris_settings, value)
		wind_debris_settings = value
		_effect_settings_changed()

## Camera followed by flying leaves, needles, and twigs. Empty follows the active viewport camera.
@export var wind_debris_camera: Camera3D:
	set(value):
		wind_debris_camera = value
		_effect_settings_changed()


@export_group("Weather Audio")
## Rain and wind occlusion probes, audio smoothing, thunder range, and sound speed.
## Empty restores the component's saved standalone settings.
@export var weather_audio_settings: DynamicSkyWeatherAudioSettings:
	set(value):
		_watch_effect_settings(weather_audio_settings, value)
		weather_audio_settings = value
		_effect_settings_changed()

## Listener position for rain/wind shelter and thunder propagation. Empty follows the active camera.
@export var audio_listener: Node3D:
	set(value):
		audio_listener = value
		_effect_settings_changed()


@export_group("Lightning Strikes")
## Strike geometry, observer distance, collision, branch, and return-stroke tuning.
## Empty restores the component's saved standalone settings.
@export var lightning_settings: DynamicSkyLightningSettings:
	set(value):
		_watch_effect_settings(lightning_settings, value)
		lightning_settings = value
		_effect_settings_changed()

## Observer used to place distant strikes. Empty follows the active camera.
@export var lightning_observer: Node3D:
	set(value):
		lightning_observer = value
		_effect_settings_changed()

@export_group("Material Weather")
## Applies accumulated wetness, snow, and dust to geometry whose existing shader includes the
## DynamicSky weather hook. Custom shaders are preserved; incompatible shaders are untouched.
@export var material_weather_settings: DynamicSkyMaterialWeatherSettings = preload("res://addons/dynamic_sky/surfaces/material_weather_settings.tres"):
	set(value):
		_watch_effect_settings(material_weather_settings, value)
		material_weather_settings = value
		_effect_settings_changed()

@export_group("Temperature")
## Clear-weather air temperature during the warmest part of the day, in degrees Celsius.
@export_range(-60.0, 60.0, 0.1, "suffix:°C") var day_temperature: float = 18.0

## Clear-weather air temperature at night, in degrees Celsius.
@export_range(-80.0, 60.0, 0.1, "suffix:°C") var night_temperature: float = 7.0

@export_group("Lighting")
## Direct sunlight energy at high elevation in clear conditions.
@export_range(0.0, 8.0, 0.01, "or_greater") var sun_energy: float = 1.25:
	set(value):
		sun_energy = maxf(value, 0.0)
		_apply_sky()

## Direct moonlight energy at high elevation in clear conditions.
@export_range(0.0, 2.0, 0.01, "or_greater") var moon_energy: float = 0.18:
	set(value):
		moon_energy = maxf(value, 0.0)
		_apply_sky()

## Sunlight tint when the sun is high in the sky.
@export var daylight_color: Color = Color(1.0, 0.94, 0.85):
	set(value):
		daylight_color = value
		_apply_sky()

## Authored sRGB tint of the moon directional light. Phase and weather scale its energy separately.
@export var moon_light_color: Color = Color(0.69846177, 0.77201432, 0.93793751):
	set(value):
		moon_light_color = value
		_apply_sky()

## Sunlight tint as the sun passes through the horizon.
@export var sunset_light_color: Color = Color(1.0, 0.48, 0.23):
	set(value):
		sunset_light_color = value
		_apply_sky()

## Distance fog tint at noon.
@export var day_fog_color: Color = Color(0.59, 0.67, 0.76):
	set(value):
		day_fog_color = value
		_apply_sky()

## Distance fog tint at night.
@export var night_fog_color: Color = Color(0.10, 0.15, 0.24):
	set(value):
		night_fog_color = value
		_apply_sky()

## Distance fog tint under a dense daytime cloud layer.
@export var overcast_fog_color: Color = Color(0.48, 0.54, 0.63):
	set(value):
		overcast_fog_color = value
		_apply_sky()

## Distance fog tint in dense airborne dust.
@export var dust_fog_color: Color = Color(0.62, 0.53, 0.43):
	set(value):
		dust_fog_color = value
		_apply_sky()

## Peak directional fill from sheet flashes. Zero also disables lightning glow in the sky.
@export_range(0.0, 5.0, 0.01, "or_greater") var lightning_energy: float = 1.45

## Real seconds for the sheet light and sky glow to decay.
@export_range(0.05, 1.0, 0.01, "suffix:s") var lightning_duration: float = 0.26

@export_group("Height Fog")
## Applies the active weather profile's height falloff and start distance in supported Forward+ builds.
## The active Environment still owns the fog reference height and the authored settings used on opt-out.
@export var drive_height_fog_from_weather: bool = false:
	set(value):
		if drive_height_fog_from_weather == value:
			return
		drive_height_fog_from_weather = value
		if not value:
			_restore_authored_height_fog()
		if is_node_ready():
			_apply_sky()


const EFFECT_RESOURCE_BINDINGS := {
	&"rain_settings": [^"Precipitation/Rain", &"settings"],
	&"cloud_shadow_settings": [^"CloudShadows", &""],
	&"snow_settings": [^"Precipitation/Snowfall", &"settings"],
	&"airborne_settings": [^"AirborneWeather", &""],
	&"wind_fog_settings": [^"AirborneWeather", &"wind_fog_settings"],
	&"screen_settings": [^"ScreenWeather", &"settings"],
	&"wind_shake_settings": [^"WindCameraShake", &"settings"],
	&"wind_debris_settings": [^"WindDebris", &""],
	&"weather_audio_settings": [^"WeatherAudio", &""],
	&"lightning_settings": [^"LightningStrikes", &""],
}
const EFFECT_SCALAR_FIELDS: Array[StringName] = [
	&"precipitation_surface_collision", &"snow_contact_enabled", &"wind_shake_enabled",
]

var _effect_fallbacks: Dictionary = {}
var _applying_effect_authoring: bool = false
var _material_weather := MaterialWeatherBinding.new()
var _weather := WeatherState.new()
var _radial_storm_scheduler := RadialStormScheduler.new()
var _clock := SkyClock.new()
var _advancing_clock: bool = false
var _cloud_offset: Vector2 = Vector2.ZERO
var _wind_phase: float = 0.0
var _rainbow_moisture: float = 0.0
var _flash_remaining: float = 0.0
var _flash_intensity: float = 0.0
var _flash_world_position: Vector3
var _lightning_rng := RandomNumberGenerator.new()
var _lightning_budget: float = 0.0
var _climate_rng := RandomNumberGenerator.new()
var _climate_time_remaining: float = 0.0
var _calendar_day_offset: int = 0
var _astronomy_state: Dictionary[StringName, Variant]
var _environment: Environment
var _weather_height_fog_environment: Environment
var _sky_material: ShaderMaterial
var _cloud_projector_active: bool = false
var _configuration_values: Dictionary[StringName, Variant] = {}
var _configuration_references: Dictionary[StringName, Variant] = {}
var _scene_environment: Environment
var _template_environment: Environment
var _template_environment_values: Dictionary = {}
var _template_environment_captured: bool = false
var _has_scene_environment_override: bool = false
var _applying_startup_configuration: bool = false
var _view_weather: Dictionary[StringName, Variant] = {}
var _observer_underwater: bool = false
var _airborne_exposure: float = 1.0
var _thunder_exposure: float = 1.0
var _exposure_camera_id: int = 0
var _wet_on_emerge_pending: bool = false
var _underwater_fog_environment: WeakRef
var _underwater_fog_enabled: bool = false

@onready var _sun: DirectionalLight3D = get_node_or_null("Sun")
@onready var _moon: DirectionalLight3D = get_node_or_null("Moon")
@onready var _lightning: DirectionalLight3D = get_node_or_null("Lightning")
@onready var _strikes: DynamicSkyLightning = get_node_or_null("LightningStrikes")
@onready var _cloud_shadows: DynamicSkyCloudShadows = get_node_or_null("CloudShadows")
@onready var _precipitation = get_node_or_null("Precipitation")
@onready var _stylized_precipitation = get_node_or_null("StylizedPrecipitation")
@onready var _audio = get_node_or_null("WeatherAudio")
@onready var _airborne: DynamicSkyAirborneWeather = get_node_or_null("AirborneWeather")
@onready var _wind_debris: DynamicSkyWindDebris = get_node_or_null("WindDebris")
@onready var _screen_weather: DynamicSkyScreenWeather = get_node_or_null("ScreenWeather")
@onready var _modifiers: DynamicSkyModifierStack = get_node_or_null("Modifiers")
@onready var _exposure: DynamicSkyWeatherExposure = get_node_or_null("WeatherExposure")


func _enter_tree() -> void:
	# Parent enter_tree runs before the internal emitters cache their settings in ready.
	_applying_effect_authoring = true
	if configuration != null:
		for field in EFFECT_RESOURCE_BINDINGS:
			set(field, configuration.get(field))
		for field in EFFECT_SCALAR_FIELDS:
			set(field, configuration.get(field))
	_applying_effect_authoring = false
	_apply_effect_authoring()


func _watch_effect_settings(previous: Resource, next: Resource) -> void:
	if previous != null and previous.changed.is_connected(_effect_settings_changed):
		previous.changed.disconnect(_effect_settings_changed)
	if next != null and not next.changed.is_connected(_effect_settings_changed):
		next.changed.connect(_effect_settings_changed)


func _effect_settings_changed() -> void:
	if not is_inside_tree() or _applying_effect_authoring:
		return
	_apply_effect_authoring()
	if is_node_ready() and not _weather.current.is_empty():
		if Engine.is_editor_hint():
			_apply_sky()
		_apply_weather_effects(0.0)


func _apply_effect_authoring() -> void:
	for field in EFFECT_RESOURCE_BINDINGS:
		var binding: Array = EFFECT_RESOURCE_BINDINGS[field]
		var component := get_node_or_null(binding[0])
		if component == null:
			continue
		var authored := get(field) as Resource
		_watch_effect_settings(null, authored)
		var property_name: StringName = binding[1]
		if not property_name.is_empty():
			if not _effect_fallbacks.has(field):
				_effect_fallbacks[field] = component.get(property_name)
			var target: Variant = authored if authored != null else _effect_fallbacks[field]
			if component.get(property_name) != target:
				component.set(property_name, target)
		else:
			if authored != null:
				if not _effect_fallbacks.has(field):
					_effect_fallbacks[field] = {}
				var component_changed := false
				for property in authored.get_property_list():
					if not (property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.usage & PROPERTY_USAGE_STORAGE):
						continue
					if not _effect_fallbacks[field].has(property.name):
						_effect_fallbacks[field][property.name] = component.get(property.name)
					if component.get(property.name) != authored.get(property.name):
						component.set(property.name, authored.get(property.name))
						component_changed = true
				if component_changed and field == &"cloud_shadow_settings":
					component.request_refresh()
			elif _effect_fallbacks.has(field):
				for property in _effect_fallbacks[field]:
					component.set(property, _effect_fallbacks[field][property])
	var precipitation := get_node_or_null("Precipitation")
	if precipitation != null:
		precipitation.camera_override = precipitation_camera
		precipitation.surface_collision_enabled = precipitation_surface_collision
		precipitation.enable_snow_contact = snow_contact_enabled
	var screen := get_node_or_null("ScreenWeather")
	if screen != null:
		screen.camera_override = screen_camera
	var shake := get_node_or_null("WindCameraShake")
	if shake != null:
		shake.camera_override = wind_shake_camera
		shake.sky_rig = self
		shake.enabled = wind_shake_enabled
	var debris := get_node_or_null("WindDebris")
	if debris != null:
		debris.camera_override = wind_debris_camera
	var audio := get_node_or_null("WeatherAudio")
	if audio != null:
		audio.listener_override = audio_listener
	var strikes := get_node_or_null("LightningStrikes")
	if strikes != null:
		strikes.observer = lightning_observer


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED and not _template_environment_captured:
		var world_environment := get_node_or_null("WorldEnvironment") as WorldEnvironment
		_template_environment = null if world_environment == null else world_environment.environment
		_template_environment_values = _get_environment_values(_template_environment)
		_template_environment_captured = true


func _get_environment_values(resource: Resource) -> Dictionary:
	# PackedScene can copy local-to-scene overrides into an existing resource in place.
	# Keep value snapshots for the native hierarchy; textures and shaders remain shared references.
	var values: Dictionary = {}
	if resource == null:
		return values
	for property in resource.get_property_list():
		if not (property.usage & PROPERTY_USAGE_STORAGE):
			continue
		var value: Variant = resource.get(property.name)
		if value is Environment or value is Sky or value is ShaderMaterial:
			value = _get_environment_values(value)
		elif value is Array or value is Dictionary:
			value = value.duplicate(true)
		values[property.name] = value
	return values


func _ready() -> void:
	var world_environment := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_environment != null:
		_scene_environment = world_environment.environment
		_has_scene_environment_override = (
			_template_environment_captured and (
				_scene_environment != _template_environment
				or _get_environment_values(_scene_environment) != _template_environment_values
			)
		)
	_template_environment = null
	_template_environment_values.clear()
	_applying_startup_configuration = true
	_apply_configuration()
	_applying_startup_configuration = false
	_sync_environment_resources()
	if _sun == null or _moon == null or _lightning == null or _sky_material == null:
		_sky_material = null
		push_warning("DynamicSky needs the children and resources from dynamic_sky.tscn.")
		set_process(false)
		return

	_weather.apply(get_starting_weather())
	if not Engine.is_editor_hint():
		_material_weather.bind(self)
	if rainbow_settings != null and not rainbow_settings.changed.is_connected(_rainbow_settings_changed):
		rainbow_settings.changed.connect(_rainbow_settings_changed)
	if _exposure != null:
		_exposure.settings = exposure_settings
	if volumetric_quality >= 0:
		_set_sky_parameter(&"volumetric_quality", volumetric_quality)
	if use_system_time:
		_synchronize_system_time()
	_clock.reset(_calendar_day_offset, time_of_day, astronomy)
	if _modifiers != null:
		_modifiers.changed.connect(_apply_sky)
	if not Engine.is_editor_hint():
		add_to_group(GROUP)
		if _strikes != null:
			_strikes.struck.connect(_on_lightning_struck)
		if _airborne != null:
			_airborne.bind_environment(_environment)
	_refresh_view_weather()
	_apply_sky()
	_apply_weather_effects(0.0)
	set_process(not Engine.is_editor_hint() or use_system_time)


func _exit_tree() -> void:
	_radial_storm_scheduler.stop()
	_restore_authored_height_fog()
	_material_weather.unbind()
	_apply_underwater_fog_mask(false)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if use_system_time:
			_synchronize_system_time()
		return
	if wind_settings != null:
		_wind_phase += delta * wind_settings.phase_speed()
	var clock_step := delta * 24.0 / day_length_seconds if day_length_seconds > 0.0 else 0.0
	var next_absolute_hour := float(_calendar_day_offset) * 24.0 + time_of_day + clock_step
	if use_system_time:
		var wall_time := _clock.system_sample(astronomy)
		if not wall_time.is_empty():
			next_absolute_hour = float(wall_time[&"day_offset"]) * 24.0 + float(wall_time[&"hour"])
			clock_step = maxf(next_absolute_hour - float(_calendar_day_offset) * 24.0 - time_of_day, 0.0)
	_advance_climate(delta, clock_step)
	var completed_profile := _weather.advance(delta)
	if weather_style == WeatherStyle.REALISTIC and _radial_storm_scheduler.advance(delta, radial_storm_spawning):
		_spawn_scheduled_radial_storm(next_absolute_hour)
	_refresh_view_weather()
	_advance_rainbow(delta)
	var wind := _get_observer_wind()
	# Advect the pattern downwind by sampling upstream.
	_cloud_offset -= wind * (cloud_drift_scale * delta)
	_cloud_offset = _cloud_offset.posmod(CLOUD_OFFSET_PERIOD)
	_flash_remaining = maxf(_flash_remaining - delta, 0.0)
	_advance_lightning(delta)

	if clock_step > 0.0 or use_system_time:
		_advancing_clock = true
		_calendar_day_offset = floori(next_absolute_hour / 24.0)
		time_of_day = fposmod(next_absolute_hour, 24.0)
		_advancing_clock = false
		_dispatch_clock_events(_clock.advance(
			_calendar_day_offset, time_of_day, _sun_height_at, use_system_time,
		))
	else:
		_apply_sky()
	if _cloud_shadows != null:
		var camera := get_viewport().get_camera_3d()
		_cloud_projector_active = _cloud_shadows.apply_sky(
			_sun, _sky_material, global_position, camera, delta
		)
	_apply_weather_effects(delta)
	if completed_profile != null:
		weather_transition_finished.emit(completed_profile)


func _validate_property(property: Dictionary) -> void:
	if configuration != null and (
		configuration.get_scalar_values().has(property.name)
		or property.name in CONFIGURATION_REFERENCES
	):
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if property.name == "day_length_seconds" and use_system_time:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _apply_configuration() -> void:
	if configuration == null:
		return
	var authored := configuration.get_scalar_values()
	for field in authored:
		if not _configuration_values.has(field) or _configuration_values[field] != authored[field]:
			set(field, authored[field])
	_configuration_values = authored
	for field in CONFIGURATION_REFERENCES:
		var value: Variant = configuration.get(field)
		if not _configuration_references.has(field) or _configuration_references[field] != value:
			set(field, value.duplicate() if value is Array else value)
			_configuration_references[field] = value.duplicate() if value is Array else value
	var world_environment := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if (
		not _configuration_references.has(&"environment")
		or _configuration_references[&"environment"] != configuration.environment
	):
		var target_environment := configuration.environment
		if target_environment == null:
			target_environment = _scene_environment
		if (
			world_environment != null and target_environment != null
			and (not _applying_startup_configuration or not _has_scene_environment_override)
		):
			world_environment.environment = target_environment
		_configuration_references[&"environment"] = configuration.environment
	_sync_environment_resources()
	_apply_effect_authoring()
	if _sky_material != null and volumetric_quality >= 0:
		_set_sky_parameter(&"volumetric_quality", volumetric_quality)
	if is_node_ready() and not _weather.current.is_empty():
		_refresh_view_weather()
		_apply_sky()
		_apply_weather_effects(0.0)
	notify_property_list_changed()


func _sync_environment_resources() -> void:
	var world_environment := get_node_or_null("WorldEnvironment") as WorldEnvironment
	var active_environment := null if world_environment == null else world_environment.environment
	var active_material: ShaderMaterial
	if active_environment != null and active_environment.sky != null:
		active_material = active_environment.sky.sky_material as ShaderMaterial
	if active_environment == _environment and active_material == _sky_material:
		return
	if _modifiers != null:
		_modifiers.restore_base()
	_apply_underwater_fog_mask(false)
	if _airborne != null and not Engine.is_editor_hint():
		_airborne.bind_environment(active_environment)
	if active_environment != _environment:
		_restore_authored_height_fog()
	_environment = active_environment
	_sky_material = active_material
	if _sky_material != null:
		if cloud_mode >= 0:
			_set_sky_parameter(&"cloud_mode", cloud_mode)
		if color_mode >= 0:
			_set_sky_parameter(&"sky_color_mode", color_mode)
	if _sky_material != null and volumetric_quality >= 0:
		_set_sky_parameter(&"volumetric_quality", volumetric_quality)


func _synchronize_system_time() -> void:
	var sample := _clock.system_sample(astronomy)
	if sample.is_empty():
		return
	_advancing_clock = true
	_calendar_day_offset = sample[&"day_offset"]
	time_of_day = sample[&"hour"]
	_advancing_clock = false


func _sun_height_at(absolute_hour: float) -> float:
	var hour := fposmod(absolute_hour, 24.0)
	if astronomy != null:
		var sample := astronomy.sample(hour, latitude, north_rotation, floori(absolute_hour / 24.0))
		var direction: Vector3 = sample[&"sun_direction"]
		return direction.y
	return cos((hour - 12.0) * TAU / 24.0) * cos(deg_to_rad(latitude))


func _dispatch_clock_events(events: Array[Dictionary]) -> void:
	for event in events:
		match event[&"type"]:
			&"hourly":
				civil_hour_changed.emit(roundi(event[&"hour"]), event[&"day_offset"])
			&"date_changed":
				civil_date_changed.emit(event[&"date"])
			&"sunrise":
				sunrise.emit(event[&"day_offset"], event[&"hour"])
			&"sunset":
				sunset.emit(event[&"day_offset"], event[&"hour"])
			&"midnight":
				midnight.emit(event[&"day_offset"])


## Changes the weather immediately or blends from the current state over real seconds.
## A new call during a blend starts from the values currently being displayed.
## Profiles from the inactive weather style are ignored.
func set_weather(profile: DynamicSkyWeather, seconds: float = 0.0) -> void:
	if not accepts_weather_profile(profile):
		return
	if seconds > 0.0 and is_node_ready() and not Engine.is_editor_hint():
		if _weather.current.is_empty():
			_weather.apply(get_starting_weather())
		_weather.blend_to(profile, seconds)
	else:
		_weather.apply(profile)
		if not is_node_ready():
			if weather_style == WeatherStyle.STYLIZED:
				stylized_start_weather = profile as StylizedWeather
			else:
				start_weather = profile
		else:
			_refresh_view_weather()
			_apply_sky()
			_apply_weather_effects(0.0)
			weather_transition_finished.emit(profile)


## Reports whether a preset belongs to the active weather style.
func accepts_weather_profile(profile: DynamicSkyWeather) -> bool:
	return profile != null and (profile is StylizedWeather) == (weather_style == WeatherStyle.STYLIZED)


## Lists selectable profiles from the active library in authored order.
func get_weather_presets() -> Array[DynamicSkyWeather]:
	var source := weather_presets
	if weather_style == WeatherStyle.STYLIZED:
		var library := stylized_weather_library if stylized_weather_library != null else DEFAULT_STYLIZED_LIBRARY
		source = library.presets
	var presets: Array[DynamicSkyWeather] = []
	for profile in source:
		if accepts_weather_profile(profile):
			presets.append(profile)
	return presets


## Returns the global weather before spatial overrides, as an independent snapshot.
func get_weather_state() -> Dictionary[StringName, Variant]:
	if _weather.current.is_empty():
		return get_starting_weather().sample()
	return _weather.current.duplicate()


## Selects the renderer used for clouds and the space background.
func set_cloud_mode(mode: int) -> void:
	if mode < CloudMode.VOLUMETRIC or mode > CloudMode.SPACE:
		return
	if cloud_mode != mode:
		cloud_mode = mode
		return
	_sync_environment_resources()
	if _sky_material != null and mode >= CloudMode.VOLUMETRIC and mode <= CloudMode.SPACE:
		_set_sky_parameter(&"cloud_mode", mode)
		_apply_sky()
		_apply_weather_effects(0.0)


## Returns the cloud renderer selected on the rig's saved ShaderMaterial.
func get_cloud_mode() -> int:
	_sync_environment_resources()
	if _sky_material != null:
		var mode: Variant = _sky_material.get_shader_parameter(&"cloud_mode")
		if mode != null:
			return int(mode)
	return CloudMode.VOLUMETRIC


## Selects physical atmosphere or the independent artist-controlled sky-color path.
func set_color_mode(mode: int) -> void:
	if mode < ColorMode.SKY_ATMOSPHERE or mode > ColorMode.SIMPLIFIED_COLOR:
		return
	if color_mode != mode:
		color_mode = mode
		return
	_sync_environment_resources()
	if _sky_material != null and mode >= ColorMode.SKY_ATMOSPHERE and mode <= ColorMode.SIMPLIFIED_COLOR:
		_set_sky_parameter(&"sky_color_mode", mode)
		_apply_sky()


## Returns the sky color path selected on the rig's saved ShaderMaterial.
func get_color_mode() -> int:
	_sync_environment_resources()
	if _sky_material != null:
		var mode: Variant = _sky_material.get_shader_parameter(&"sky_color_mode")
		if mode != null:
			return int(mode)
	return ColorMode.SKY_ATMOSPHERE


## Selects half-resolution Balanced or full-resolution High volume rendering.
func set_volumetric_quality(quality: int) -> void:
	if quality >= 0 and quality <= 1:
		volumetric_quality = quality


## Returns whether the active background suspends terrestrial weather effects.
func is_space_mode() -> bool:
	return (
		get_cloud_mode() == CloudMode.SPACE
		or (_sky_material != null and _sky_material.get_shader_parameter(&"celestial_mode") == 1)
	)


## Captures the clock, renderer selections, and global weather in an independent resource.
func capture_state() -> DynamicSkySnapshot:
	var snapshot := DynamicSkySnapshot.new()
	snapshot.time_of_day = time_of_day
	snapshot.day_offset = _calendar_day_offset
	snapshot.day_length_seconds = day_length_seconds
	snapshot.use_system_time = use_system_time
	snapshot.cloud_offset = _cloud_offset
	snapshot.wind_phase = _wind_phase
	snapshot.rainbow_moisture = _rainbow_moisture
	snapshot.cloud_mode = get_cloud_mode()
	snapshot.color_mode = get_color_mode()
	if _sky_material != null:
		var quality: Variant = _sky_material.get_shader_parameter(&"volumetric_quality")
		if quality != null:
			snapshot.volumetric_quality = int(quality)
	_weather.capture_into(snapshot)
	if snapshot.current_weather == null:
		snapshot.current_weather = get_starting_weather().duplicate() as DynamicSkyWeather
	return snapshot


## Restores a snapshot on a running rig. Invalid state leaves the current rig intact.
func restore_state(snapshot: DynamicSkySnapshot) -> bool:
	_sync_environment_resources()
	if snapshot == null or _sky_material == null or not is_node_ready():
		return false
	if (
		not accepts_weather_profile(snapshot.current_weather)
		or (snapshot.transition_from != null and not accepts_weather_profile(snapshot.transition_from))
		or (snapshot.transition_to != null and not accepts_weather_profile(snapshot.transition_to))
	):
		return false
	if (
		not is_finite(snapshot.time_of_day) or not is_finite(snapshot.wind_phase)
		or not is_finite(snapshot.day_length_seconds) or snapshot.day_length_seconds < 0.0
		or not snapshot.cloud_offset.is_finite()
		or not is_finite(snapshot.rainbow_moisture)
		or snapshot.rainbow_moisture < 0.0 or snapshot.rainbow_moisture > 2.0
		or snapshot.cloud_mode < CloudMode.VOLUMETRIC or snapshot.cloud_mode > CloudMode.SPACE
		or snapshot.color_mode < ColorMode.SKY_ATMOSPHERE
		or snapshot.color_mode > ColorMode.SIMPLIFIED_COLOR
		or snapshot.volumetric_quality < 0 or snapshot.volumetric_quality > 1
	):
		return false
	if not _weather.restore_from(snapshot):
		return false

	_calendar_day_offset = snapshot.day_offset
	day_length_seconds = snapshot.day_length_seconds
	use_system_time = snapshot.use_system_time
	_cloud_offset = snapshot.cloud_offset.posmod(CLOUD_OFFSET_PERIOD)
	_wind_phase = snapshot.wind_phase
	_rainbow_moisture = snapshot.rainbow_moisture
	_flash_remaining = 0.0
	_lightning_budget = 0.0
	cloud_mode = snapshot.cloud_mode
	color_mode = snapshot.color_mode
	set_volumetric_quality(snapshot.volumetric_quality)
	if _strikes != null and not Engine.is_editor_hint():
		_strikes.clear_flash()
	_refresh_view_weather()
	time_of_day = snapshot.time_of_day
	_apply_weather_effects(0.0)
	return true


## Returns an independent snapshot with the spatial overrides at a point.
func get_weather_at(world_position: Vector3) -> Dictionary[StringName, Variant]:
	if not is_inside_tree() or _weather.current.is_empty():
		return get_weather_state()
	_weather.collect_zones(get_world_3d(), get_tree())
	return _weather.sample_at(world_position, _uses_radial_cloud_field()).duplicate()


## Returns the air temperature in degrees Celsius at the given point.
func get_temperature_at(world_position: Vector3) -> float:
	return _get_clear_temperature() + float(get_weather_at(world_position)[&"temperature_offset"])


## Returns world-space wind at a point, including coherent local gusts, in meters per second.
func get_wind_at(world_position: Vector3) -> Vector3:
	if is_space_mode():
		return Vector3.ZERO
	var conditions := _weather.sample_at(world_position)
	if conditions.is_empty():
		conditions = get_starting_weather().sample()
	var base_wind: Vector2 = conditions[&"wind"]
	var gustiness: float = conditions[&"gustiness"]
	if wind_settings != null:
		return wind_settings.sample_wind(base_wind, gustiness, world_position, _wind_phase, self)
	return Vector3(base_wind.x, 0.0, base_wind.y)


func _get_observer_wind() -> Vector2:
	var camera := get_viewport().get_camera_3d()
	var point := global_position if camera == null else camera.global_position
	var velocity := get_wind_at(point)
	return Vector2(velocity.x, velocity.z)


func _get_view_wind_sample() -> Vector4:
	if is_space_mode():
		return Vector4(0.0, 0.0, 0.0, 1.0)
	var wind: Vector2 = _view_weather[&"wind"]
	if wind_settings == null:
		return Vector4(wind.x, 0.0, wind.y, 1.0)
	var camera := get_viewport().get_camera_3d()
	var point := global_position if camera == null else camera.global_position
	return wind_settings.sample_wind_and_gust(wind, _view_weather[&"gustiness"], point, _wind_phase, self)


## Returns the world-space unit direction toward the sun.
func get_sun_direction() -> Vector3:
	if astronomy != null:
		_refresh_astronomy_state()
		return _astronomy_state[&"sun_direction"]

	var hour_angle := (time_of_day - 12.0) * TAU / 24.0
	var inclination := deg_to_rad(latitude)
	var noon_component := cos(hour_angle)
	return Vector3(
		-sin(hour_angle),
		noon_component * cos(inclination),
		noon_component * sin(inclination)
	).rotated(Vector3.UP, deg_to_rad(north_rotation))


## Returns the world-space unit direction toward the moon.
func get_moon_direction() -> Vector3:
	if astronomy != null:
		_refresh_astronomy_state()
		return _astronomy_state[&"moon_direction"]
	return -get_sun_direction()


## Returns the number of elapsed civil days since the starting date.
func get_calendar_day_offset() -> int:
	return _calendar_day_offset


## Changes the simulated date relative to the Astronomy resource's starting date.
func set_calendar_day_offset(day_offset: int) -> void:
	_calendar_day_offset = day_offset
	_celestial_changed()


## Requests lightning in the distant cloud deck ahead of the active camera.
func trigger_lightning() -> void:
	if _strikes != null and not Engine.is_editor_hint() and not is_space_mode():
		_strikes.strike_near_observer(weather_style == WeatherStyle.STYLIZED)


func _advance_lightning(delta: float) -> void:
	var bolt_rate: float = _view_weather[&"lightning_rate"]
	var sheet_rate: float = _view_weather[&"sheet_lightning_rate"]
	var rate := bolt_rate + sheet_rate
	if rate < 0.05 or _strikes == null or is_space_mode():
		_lightning_budget = 0.0
		return
	if _lightning_budget == 0.0:
		_lightning_budget = _lightning_rng.randf_range(0.32, 0.55)
	_lightning_budget -= rate * delta / 60.0
	if _lightning_budget <= 0.0 and _flash_remaining == 0.0 and not _strikes.is_processing():
		var sheet_only := weather_style == WeatherStyle.STYLIZED or (
			sheet_rate > 0.0 and _lightning_rng.randf() * rate >= bolt_rate
		)
		_strikes.strike_near_observer(sheet_only)
		_lightning_budget = _lightning_rng.randf_range(0.56, 1.44)


## Starts a ground strike at a known point, such as an authored lightning rod.
func trigger_lightning_at(world_position: Vector3) -> void:
	if _strikes != null and not Engine.is_editor_hint() and not is_space_mode():
		if weather_style == WeatherStyle.STYLIZED:
			_strikes.strike_near_observer(true)
		else:
			_strikes.strike_at(world_position)


func _on_lightning_struck(world_position: Vector3, intensity: float) -> void:
	if is_space_mode():
		return
	_flash_remaining = 0.0 if _strikes.is_processing() else maxf(lightning_duration, 0.05)
	_flash_intensity = intensity
	_flash_world_position = _strikes.get_flash_position()
	if _exposure != null and _strikes.is_processing():
		_exposure.hold_night_storm_exposure()
	if _audio != null and _thunder_exposure > 0.0:
		_audio.play_thunder(world_position, intensity * _thunder_exposure)
	lightning_struck.emit(world_position, intensity)


## Resolves the current family's authored startup profile or its stock fallback.
func get_starting_weather() -> DynamicSkyWeather:
	if weather_style == WeatherStyle.STYLIZED:
		if stylized_start_weather != null:
			return stylized_start_weather
		var presets := get_weather_presets()
		return DEFAULT_STYLIZED_LIBRARY.presets[0] if presets.is_empty() else presets[0]
	return start_weather if accepts_weather_profile(start_weather) else CLEAR_WEATHER


func _preview_weather() -> void:
	if is_node_ready():
		_weather.apply(get_starting_weather())
		_refresh_view_weather()
		_apply_sky()


func _celestial_changed() -> void:
	_astronomy_state.clear()
	if not _advancing_clock and _clock != null:
		_clock.reset(_calendar_day_offset, time_of_day, astronomy)
	if is_node_ready():
		_apply_sky()


func _refresh_astronomy_state() -> void:
	if _astronomy_state.is_empty():
		_astronomy_state = astronomy.sample(time_of_day, latitude, north_rotation, _calendar_day_offset)


func _spawn_scheduled_radial_storm(absolute_hour: float) -> void:
	var camera := get_viewport().get_camera_3d()
	var control_point := global_position if camera == null else camera.global_position
	var wind: Vector2 = _weather.current[&"wind"]
	if wind.is_zero_approx():
		wind = Vector2.DOWN
	if wind_settings != null:
		var steady_wind := wind_settings.sample_wind(wind, 0.0, control_point, _wind_phase, self)
		wind = Vector2(steady_wind.x, steady_wind.z)

	var date: Dictionary = {}
	var day := floori(absolute_hour / 24.0)
	if astronomy != null:
		date = astronomy.get_civil_date(day)
	elif use_system_time:
		date = _clock.system_sample().get(&"date", {})
	var season := RadialStormScheduler.get_season(
		radial_storm_spawning, date, fposmod(absolute_hour, 24.0), latitude,
	)
	_radial_storm_scheduler.spawn(self, control_point, wind, season)


func _advance_climate(delta: float, clock_step: float) -> void:
	if climate == null:
		return

	match climate.schedule:
		DynamicSkyClimate.Schedule.REAL_SECONDS:
			if _climate_time_remaining <= 0.0:
				_climate_time_remaining = climate.sample_interval(_climate_rng)
			_climate_time_remaining -= delta
			if _climate_time_remaining > 0.0:
				return
		DynamicSkyClimate.Schedule.SIMULATED_HOUR:
			if floori(time_of_day) == floori(time_of_day + clock_step):
				return
		DynamicSkyClimate.Schedule.SIMULATED_DAY:
			if time_of_day + clock_step < 24.0:
				return

	var season: int = climate.season
	if astronomy != null:
		var upcoming_day := _calendar_day_offset + floori((time_of_day + clock_step) / 24.0)
		var month: int = astronomy.get_civil_date(upcoming_day)["month"]
		season = posmod(floori(float(month % 12) / 3.0) - 1, 4)
		if latitude < 0.0:
			season = (season + 2) % 4
	var profile := climate.sample_weather(season, _climate_rng, accepts_weather_profile)
	if profile != null:
		set_weather(profile, climate.blend_seconds)


func _refresh_view_weather() -> void:
	_sync_environment_resources()
	var camera := get_viewport().get_camera_3d()
	_weather.refresh_view(get_world_3d(), get_tree(), camera, _uses_radial_cloud_field())
	_view_weather = _weather.view
	var was_underwater := _observer_underwater
	_observer_underwater = false
	_airborne_exposure = 0.0 if is_space_mode() else 1.0
	_thunder_exposure = 1.0
	var camera_id := 0 if camera == null else camera.get_instance_id()
	if camera_id != _exposure_camera_id:
		_wet_on_emerge_pending = false
	if _exposure != null and camera != null:
		var base := _get_cloud_layer_value(&"cloud_base_km", 0.60)
		var thickness := _get_cloud_layer_value(&"cloud_thickness_km", 0.70)
		var mode := get_cloud_mode()
		var space := is_space_mode()
		var observer := camera.global_position
		_view_weather = _exposure.filter_view(_weather.view, observer, global_position, base, thickness, mode, space)
		_observer_underwater = not space and _exposure.is_underwater_at(observer)
		_airborne_exposure = _exposure.get_airborne_exposure(observer, global_position, base, thickness, mode, space)
		var suppression := _exposure.get_above_cloud_suppression(observer, global_position, base, thickness, mode, space)
		if exposure_settings != null:
			_thunder_exposure = lerpf(1.0, clampf(exposure_settings.thunder_multiplier, 0.0, 1.0), suppression)
		if _observer_underwater:
			_thunder_exposure = 0.0
			_wet_on_emerge_pending = false
		elif camera_id == _exposure_camera_id:
			_wet_on_emerge_pending = _wet_on_emerge_pending or _exposure.should_wet_on_emerge(was_underwater, false)
	_exposure_camera_id = camera_id


func _uses_radial_cloud_field() -> bool:
	return get_cloud_mode() == CloudMode.VOLUMETRIC and not is_space_mode()


func _apply_radial_cloud_field() -> void:
	var storms := _weather.get_radial_storms()
	if not _uses_radial_cloud_field() or storms.is_empty():
		if _sky_material.get_shader_parameter(&"radial_cloud_cell_count") != null:
			_set_sky_parameter(&"radial_cloud_cell_count", 0)
		return

	var cells := PackedVector4Array()
	var values := PackedVector4Array()
	# Reserve the shared renderer slots for the highest-priority valid storms.
	for index in range(storms.size() - 1, -1, -1):
		var storm := storms[index]
		var center := (storm.global_position - global_position) * 0.001
		var coverage := storm.weather.cloud_coverage
		if not center.is_finite() or not is_finite(coverage):
			continue
		cells.append(Vector4(
			center.x, center.z, storm.outer_radius * 0.001, storm.get_full_weather_radius() * 0.001,
		))
		values.append(Vector4(clampf(coverage, 0.0, 1.0), storm.get_effective_alpha(), 0.0, 0.0))
		if cells.size() == MAX_RADIAL_CLOUD_CELLS:
			break

	# Apply in the same low-to-high order as the physical weather sampler.
	cells.reverse()
	values.reverse()
	var count := cells.size()
	cells.resize(MAX_RADIAL_CLOUD_CELLS)
	values.resize(MAX_RADIAL_CLOUD_CELLS)
	_set_sky_parameter(&"radial_cloud_cells", cells)
	_set_sky_parameter(&"radial_cloud_cell_values", values)
	_set_sky_parameter(&"radial_cloud_cell_count", count)


func _get_cloud_layer_value(parameter: StringName, fallback: float) -> float:
	if _sky_material == null:
		return fallback
	var value: Variant = _sky_material.get_shader_parameter(parameter)
	if value == null and _sky_material.shader != null:
		value = RenderingServer.shader_get_parameter_default(_sky_material.shader.get_rid(), parameter)
	return float(value) if value is float or value is int else fallback


func _apply_sky() -> void:
	_sync_environment_resources()
	if _sky_material == null or _weather.current.is_empty():
		return
	_refresh_view_weather()
	if _modifiers != null:
		_modifiers.restore_base()

	var sun_direction := get_sun_direction()
	var moon_direction := get_moon_direction()
	var moon_phase: float = _astronomy_state.get(&"moon_phase", 0.5)
	var lunar_illumination := 0.5 * (1.0 - cos(TAU * moon_phase))
	var elevation := sun_direction.y
	var space_mode := is_space_mode()
	var stylized := weather_style == WeatherStyle.STYLIZED and not space_mode
	var cloud_coverage: float = _view_weather[&"cloud_coverage"]
	var dust: float = 0.0 if space_mode else _view_weather[&"dust"]
	var daylight_dust := _daylight_dust_weight(dust, elevation)
	var moonlit_dust := _moonlit_dust_weight(dust, elevation)
	var blocks_light := not space_mode and get_cloud_mode() != CloudMode.CLEAR
	var cloud_attenuation := lerpf(1.0, 0.22, cloud_coverage * cloud_coverage) if blocks_light else 1.0
	var dust_attenuation := pow(1.0 - dust * 0.93, 1.6)
	var projector_weight := smoothstep(0.035, 0.13, elevation) if _cloud_projector_active else 0.0
	var sun_attenuation := dust_attenuation * lerpf(cloud_attenuation, 1.0, projector_weight)
	var flash := 0.0
	var full_strike := false
	if not Engine.is_editor_hint() and _strikes != null:
		if space_mode:
			_strikes.clear_flash()
			_flash_remaining = 0.0
		else:
			full_strike = _strikes.is_processing()
			if full_strike:
				var cloud_base_m := global_position.y + 1000.0 * _get_cloud_layer_value(&"cloud_base_km", 0.60)
				var cloud_top_m := cloud_base_m + 1000.0 * _get_cloud_layer_value(&"cloud_thickness_km", 0.70)
				_strikes.set_glow_environment(elevation, cloud_base_m, cloud_top_m, _view_weather[&"wind"])
	if lightning_energy > 0.0 and not space_mode:
		if full_strike:
			flash = _strikes.get_full_flash_intensity()
		else:
			var fade := clampf(_flash_remaining / maxf(lightning_duration, 0.05), 0.0, 1.0)
			flash = _flash_intensity * pow(fade, 2.4)

	_point_light(_sun, sun_direction)
	_point_light(_moon, moon_direction)
	_sun.light_energy = sun_energy * smoothstep(-0.01, 0.24, elevation) * sun_attenuation * lerpf(1.0, 0.10, daylight_dust)
	_sun.light_color = sunset_light_color.lerp(daylight_color, smoothstep(0.0, 0.36, elevation))
	_moon.light_color = moon_light_color
	var night := 1.0 - smoothstep(-0.18, 0.12, elevation)
	_moon.light_energy = (
		moon_energy * smoothstep(0.0, 0.33, moon_direction.y)
		* lunar_illumination * night * cloud_attenuation * dust_attenuation
	)
	var night_storm_weight := _night_storm_weight(float(_weather.view[&"rain"]), elevation) if not space_mode and not stylized else 0.0
	var night_storm := exposure_settings.night_storm if exposure_settings != null else null
	var night_storm_irradiance := 1.0
	if night_storm_weight > 0.0 and night_storm != null:
		_moon.light_energy *= lerpf(1.0, night_storm.moon_irradiance, night_storm_weight)
		night_storm_irradiance = lerpf(1.0, night_storm.sky_irradiance, night_storm_weight)
	_set_sky_parameter(&"night_storm_irradiance", night_storm_irradiance)
	_lightning.light_energy = 0.0 if full_strike else lightning_energy * flash

	var horizon_fog_strength := _apply_distance_fog(
		space_mode, cloud_coverage, dust, elevation, daylight_dust, moonlit_dust,
	)
	_set_sky_parameter(&"stylized_weather_enabled", stylized)
	if stylized:
		_apply_stylized_palette(elevation)

	_set_sky_parameter(&"sun_direction", sun_direction)
	_set_sky_parameter(&"moon_direction", moon_direction)
	_set_sky_parameter(&"moon_phase", moon_phase)
	_set_sky_parameter(&"star_rotation", _astronomy_state.get(&"star_rotation", Basis.IDENTITY))
	_set_sky_parameter(&"cloud_coverage", cloud_coverage)
	var daylight_transport := 0.0
	if not space_mode and not stylized and get_cloud_mode() == CloudMode.VOLUMETRIC and get_color_mode() == ColorMode.SKY_ATMOSPHERE:
		daylight_transport = float(_view_weather[&"daylight_cloud_transport"]) * smoothstep(0.03, 0.35, elevation)
	_set_sky_parameter(&"daylight_cloud_transport", daylight_transport)
	if daylight_transport > 0.0:
		_set_sky_parameter(&"daylight_cloud_distant_sky", CloudDaylightTransport.sample(elevation))
	_apply_radial_cloud_field()
	_set_sky_parameter(&"cloud_offset", _cloud_offset)
	_set_sky_parameter(&"dust_density", dust)
	_set_sky_parameter(&"daylight_dust_scattering_scale", lerpf(1.0, 1.68, daylight_dust))
	_set_sky_parameter(&"lightning_flash", minf(flash, 1.0))
	var camera := get_viewport().get_camera_3d()
	var flash_from_camera := Vector3.ZERO
	var cloud_observer_position := Vector3.ZERO
	if camera != null:
		cloud_observer_position = (camera.global_position - global_position) * 0.001
		if flash > 0.0:
			flash_from_camera = (_flash_world_position - camera.global_position) * 0.001
	_set_sky_parameter(&"cloud_observer_position_km", cloud_observer_position)
	_set_sky_parameter(&"lightning_direction", flash_from_camera.normalized())
	_set_sky_parameter(&"lightning_position_km", flash_from_camera)
	if _modifiers != null and not stylized:
		_modifiers.apply_outputs(time_of_day, _sky_material, _environment, _sun, _moon)
	_apply_horizon_fog(horizon_fog_strength)
	var moonlit_sky := maxf(moonlit_dust, 0.0)
	if moonlit_sky > 0.0:
		var radiance := _environment.fog_light_color.srgb_to_linear() * _environment.fog_light_energy
		_set_sky_parameter(&"moonlit_dust_fog_radiance", Vector3(radiance.r, radiance.g, radiance.b))
	_set_sky_parameter(&"moonlit_dust_fog_weight", moonlit_sky)
	if stylized:
		_set_sky_parameter(&"rainbow_enabled", false)
	else:
		_apply_rainbow(camera)


func _apply_stylized_palette(solar_elevation: float) -> void:
	var daylight := smoothstep(-0.12, 0.20, solar_elevation)
	var day_fog: Color = _view_weather[&"day_fog_tint"]
	var night_fog: Color = _view_weather[&"night_fog_tint"]
	_environment.fog_light_color = night_fog.lerp(day_fog, daylight)
	_environment.fog_aerial_perspective = 0.0
	_environment.fog_sky_affect = lerpf(0.04, 0.86, smoothstep(0.10, 1.0, float(_view_weather[&"fog_amount"])))
	var sunlight: Color = _view_weather[&"sunlight_tint"]
	var twilight: Color = _view_weather[&"twilight_tint"]
	_sun.light_color = twilight.lerp(sunlight, smoothstep(0.0, 0.30, solar_elevation))
	_sun.light_energy *= float(_view_weather[&"sunlight_strength"])
	_moon.light_color = _view_weather[&"moonlight_tint"]
	_set_sky_parameter(&"stylized_day_zenith", _linear_rgb(_view_weather[&"sky_zenith_tint"]))
	_set_sky_parameter(&"stylized_day_horizon", _linear_rgb(_view_weather[&"sky_horizon_tint"]))
	_set_sky_parameter(&"stylized_night_zenith", _linear_rgb(_view_weather[&"night_sky_tint"]))
	_set_sky_parameter(&"stylized_night_horizon", _linear_rgb(night_fog))
	_set_sky_parameter(&"stylized_twilight", _linear_rgb(twilight))
	_set_sky_parameter(&"stylized_cloud_shade", _linear_rgb(_view_weather[&"cloud_shade_tint"]))
	_set_sky_parameter(&"stylized_cloud_light", _linear_rgb(_view_weather[&"cloud_light_tint"]))
	_set_sky_parameter(&"stylized_aurora_strength", _view_weather[&"aurora_strength"])
	_set_sky_parameter(&"stylized_aurora_azimuth", deg_to_rad(north_rotation))
	_set_sky_parameter(&"stylized_aurora_scroll", _wind_phase * 0.03)


func _linear_rgb(color: Color) -> Vector3:
	var linear := color.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)


func _get_effective_wind_fog_settings() -> DynamicSkyWindFogSettings:
	if wind_fog_settings == null and _airborne != null:
		return _airborne.wind_fog_settings
	return wind_fog_settings


func _daylight_dust_weight(dust: float, elevation: float) -> float:
	var fog_settings := _get_effective_wind_fog_settings()
	if (
		fog_settings == null
		or fog_settings.mode != DynamicSkyWindFogSettings.Mode.SOURCE_SNOW_AND_DUST
		or not fog_settings.calibrate_daylight_dust
		or get_color_mode() != ColorMode.SKY_ATMOSPHERE
		or float(_view_weather[&"fog_density"]) <= 0.0
	):
		return 0.0
	return smoothstep(0.30, 0.70, dust) * smoothstep(0.08, 0.32, elevation)


func _moonlit_dust_weight(dust: float, sun_elevation: float) -> float:
	if dust <= 0.30 or sun_elevation >= -0.15:
		return 0.0
	var fog_settings := _get_effective_wind_fog_settings()
	if (
		fog_settings == null or fog_settings.mode != DynamicSkyWindFogSettings.Mode.SOURCE_SNOW_AND_DUST
		or get_color_mode() != ColorMode.SKY_ATMOSPHERE or float(_view_weather[&"fog_density"]) <= 0.0
	):
		return 0.0
	var moon_elevation := get_moon_direction().y
	var phase: float = _astronomy_state.get(&"moon_phase", 0.5)
	var illumination := 0.5 * (1.0 - cos(TAU * phase))
	# Approximate the source's rapid onset above the horizon and slower rise overhead.
	var scatter := sqrt(clampf(moon_elevation, 0.0, 1.0)) * smoothstep(0.0, 0.18, moon_elevation) * illumination
	var response := clampf((scatter - 0.72) / 0.206, -1.0, 1.0)
	var night := 1.0 - smoothstep(-0.38, -0.15, sun_elevation)
	return response * night * smoothstep(0.30, 0.70, dust)


func _apply_distance_fog(
	space_mode: bool, cloud_coverage: float, dust: float, elevation: float, daylight_dust: float, moonlit_dust: float,
) -> float:
	var fog_density: float = _view_weather[&"fog_density"]
	_environment.fog_enabled = not space_mode and fog_density > 0.0
	_environment.fog_density = fog_density
	_apply_weather_height_fog()

	var storm := 0.0
	var blizzard := 0.0
	if _environment.fog_enabled and weather_style == WeatherStyle.REALISTIC:
		var fog_amount: float = _view_weather[&"fog_amount"]
		var heavy_overcast := smoothstep(0.85, 1.0, cloud_coverage) * (1.0 - dust)
		blizzard = smoothstep(0.65, 1.0, fog_amount) * float(_view_weather[&"snow"]) * heavy_overcast
		storm = smoothstep(0.32, 0.65, fog_amount) * float(_view_weather[&"rain"]) * heavy_overcast
		storm *= 1.0 - blizzard

	var daylight := smoothstep(-0.15, 0.27, elevation)
	var overcast := smoothstep(0.55, 1.0, cloud_coverage)
	var fog_daylight := day_fog_color.lerp(overcast_fog_color, overcast)
	var fog_color := night_fog_color.lerp(fog_daylight, daylight)
	var dust_illumination := lerpf(0.16, 1.0, daylight)
	fog_color = fog_color.lerp(dust_fog_color * dust_illumination, dust)
	var fog_settings := _get_effective_wind_fog_settings()
	if fog_settings != null and fog_settings.mode == DynamicSkyWindFogSettings.Mode.SOURCE_SNOW_AND_DUST:
		var night_dust := smoothstep(0.30, 0.70, dust) * (1.0 - daylight)
		if night_dust > 0.0:
			# Use the source night hue and scale the rig's fog luminance by lunar illumination.
			var linear := fog_color.srgb_to_linear()
			var chroma := SOURCE_NIGHT_DUST_FOG_CHROMA * linear.get_luminance()
			chroma *= 1.0 + 0.16 * moonlit_dust
			var night_color := Color(chroma.x, chroma.y, chroma.z, linear.a)
			fog_color = linear.lerp(night_color, night_dust).linear_to_srgb()
	var storm_daylight := smoothstep(-0.08, 0.32, elevation)
	var storm_dimming := storm * storm_daylight
	if storm_dimming > 0.0:
		# Scale the resolved distance fog in linear light, retaining the authored Environment energy.
		var fog_alpha := fog_color.a
		fog_color = (fog_color.srgb_to_linear() * lerpf(1.0, 0.62, storm_dimming)).linear_to_srgb()
		fog_color.a = fog_alpha
	if daylight_dust > 0.0:
		# Account for the terrain renderer's fog response in linear light.
		var linear := fog_color.srgb_to_linear()
		fog_color = linear.lerp(linear * SOURCE_DAY_DUST_FOG_SCALE, daylight_dust).linear_to_srgb()
	_environment.fog_light_color = fog_color

	var weather_veil := (1.0 - exp(-fog_density * 125.0)) * 0.93
	var sky_affect := maxf(weather_veil, dust * 0.91)
	sky_affect = lerpf(sky_affect, 0.35, daylight_dust)
	_environment.fog_sky_affect = lerpf(sky_affect, maxf(sky_affect, 0.76), blizzard)
	var aerial_mix := lerpf(0.58, 0.06, smoothstep(0.003, 0.016, fog_density))
	aerial_mix = lerpf(aerial_mix, minf(aerial_mix, 0.28), storm)
	aerial_mix = lerpf(aerial_mix, minf(aerial_mix, 0.12), blizzard)
	_environment.fog_aerial_perspective = (
		(1.0 - dust) * aerial_mix if get_color_mode() == ColorMode.SKY_ATMOSPHERE else 0.0
	)

	var horizon_strength := lerpf(0.83, 0.94, storm_daylight) * storm + 0.90 * blizzard
	horizon_strength = lerpf(horizon_strength, 0.94, daylight_dust)
	if horizon_strength > 0.0:
		var altitude_limits := Vector2(0.13, 0.54).lerp(Vector2(0.19, 0.58), storm_dimming)
		if daylight_dust > 0.0:
			# Bring shallow sky rays toward the same fog radiance as distant surfaces.
			altitude_limits = altitude_limits.lerp(Vector2(-0.025, 0.030), daylight_dust)
		_set_sky_parameter(&"horizon_fog_direction_y_range", altitude_limits)
	return horizon_strength


func _apply_weather_height_fog() -> void:
	if not drive_height_fog_from_weather or _environment.fog_mode != Environment.FOG_MODE_EXPONENTIAL:
		_restore_authored_height_fog()
		return
	if (
		not RenderingServer.has_method(NATIVE_HEIGHT_FOG_SETTER)
		or RenderingServer.get_current_rendering_method() != "forward_plus"
	):
		return

	# The RID override keeps the Environment's authored resource values available for editing and saving.
	RenderingServer.call(
		NATIVE_HEIGHT_FOG_SETTER, _environment.get_rid(), true,
		_view_weather[&"fog_height_falloff"], _view_weather[&"fog_start_distance"]
	)
	_weather_height_fog_environment = _environment


func _restore_authored_height_fog() -> void:
	var previous := _weather_height_fog_environment
	_weather_height_fog_environment = null
	if previous == null:
		return

	RenderingServer.call(
		NATIVE_HEIGHT_FOG_SETTER, previous.get_rid(), previous.get(&"fog_height_integrated"),
		previous.get(&"fog_height_falloff"), previous.get(&"fog_start_distance")
	)


func _apply_horizon_fog(strength: float) -> void:
	var active := strength > 0.0 and _environment.fog_enabled and _environment.fog_density > 0.0
	if active:
		# Match the effective native fog, including any authored modifier outputs.
		var radiance := _environment.fog_light_color.srgb_to_linear() * _environment.fog_light_energy
		radiance /= maxf(_environment.background_energy_multiplier, 0.001)
		_set_sky_parameter(&"horizon_fog_radiance", Vector3(radiance.r, radiance.g, radiance.b))
	_set_sky_parameter(&"horizon_fog_strength", strength if active else 0.0)


func _rainbow_settings_changed() -> void:
	if not is_node_ready():
		return
	if rainbow_settings == null or not rainbow_settings.enabled:
		_rainbow_moisture = 0.0
	_apply_sky()


func _rainbow_target() -> float:
	if rainbow_settings == null or _weather.view.is_empty():
		return 0.0
	return rainbow_settings.weather_target(
		float(_weather.view.get(&"rain", 0.0)), float(_weather.view.get(&"fog_amount", 0.0))
	)


func _advance_rainbow(delta: float) -> void:
	if rainbow_settings == null:
		_rainbow_moisture = 0.0
		return
	_rainbow_moisture = rainbow_settings.advance_strength(_rainbow_moisture, _rainbow_target(), delta)


func _apply_rainbow(camera: Camera3D) -> void:
	if rainbow_settings == null:
		_set_sky_parameter(&"rainbow_enabled", false)
		_set_sky_parameter(&"rainbow_strength", 0.0)
		return
	if Engine.is_editor_hint():
		_rainbow_moisture = _rainbow_target()
	var mode := get_cloud_mode()
	var cloud_visibility := 1.0
	if mode != CloudMode.CLEAR:
		cloud_visibility = rainbow_settings.cloud_transmission(
			float(_weather.view[&"cloud_coverage"]), mode == CloudMode.VOLUMETRIC
		)
	var above_clouds := 0.0
	if _exposure != null and camera != null:
		above_clouds = _exposure.get_above_cloud_suppression(
			camera.global_position, global_position, _get_cloud_layer_value(&"cloud_base_km", 0.60),
			_get_cloud_layer_value(&"cloud_thickness_km", 0.70), mode, is_space_mode()
		)
	rainbow_settings.apply_to(
		_sky_material, _rainbow_moisture, _sun.light_energy / maxf(sun_energy, 0.0001),
		cloud_visibility, above_clouds, float(_observer_underwater), is_space_mode()
	)


func _night_storm_weight(rain: float, elevation: float) -> float:
	return _exposure.get_night_storm_weight(rain, elevation) if _exposure != null else 0.0


func _apply_weather_effects(delta: float) -> void:
	if Engine.is_editor_hint() or _weather.current.is_empty():
		return

	var space_mode := is_space_mode()
	var stylized := weather_style == WeatherStyle.STYLIZED
	var rain: float = 0.0 if space_mode else _view_weather[&"rain"]
	var snow: float = 0.0 if space_mode else _view_weather[&"snow"]
	var dust: float = 0.0 if space_mode else _view_weather[&"dust"]
	var wind_sample := _get_view_wind_sample()
	var wind := Vector2(wind_sample.x, wind_sample.z)
	var sun_elevation := get_sun_direction().y
	if _precipitation != null:
		_precipitation.set_observer_active(not stylized and not space_mode and not _observer_underwater)
		_precipitation.apply_weather(0.0 if stylized else rain, 0.0 if stylized else snow, wind, 0.0 if stylized else dust, sun_elevation)
	if _stylized_precipitation != null:
		var effect_camera: Camera3D = _precipitation.get_effect_camera() if _precipitation != null else get_viewport().get_camera_3d()
		var particle_look := Vector2(_view_weather.get(&"particle_scale", 1.0), _view_weather.get(&"particle_opacity_scale", 1.0))
		_stylized_precipitation.apply_weather(
			stylized and not space_mode and not _observer_underwater, effect_camera, rain, snow, wind,
			_airborne_exposure, sun_elevation, particle_look,
		)
	if _audio != null:
		var muffle := _observer_underwater and exposure_settings != null and exposure_settings.force_underwater_audio_occlusion
		_audio.set_underwater(muffle)
		var base_wind: Vector2 = Vector2.ZERO if space_mode else _view_weather[&"wind"]
		_audio.apply_weather(rain, snow, dust, wind, WeatherState.source_wind_strength(base_wind), wind_sample.w)
	if _airborne != null:
		var effect_camera: Camera3D = _precipitation.get_effect_camera() if _precipitation != null else null
		var collision_enabled: bool = _precipitation != null and _precipitation.surface_collision_enabled
		var local_dust_scattering := lerpf(1.0, 1.0 / 1.65, _daylight_dust_weight(dust, sun_elevation))
		# The visible lunar glow comes from the distant haze. Keep the nearby dust veil subdued.
		local_dust_scattering *= lerpf(1.0, 0.42, maxf(_moonlit_dust_weight(dust, sun_elevation), 0.0))
		_airborne.apply_weather(
			rain, snow, dust, wind, delta, sun_elevation, effect_camera, collision_enabled,
			0.0 if stylized else _airborne_exposure,
			_view_weather[&"fog_amount"], (_view_weather[&"wind"] as Vector2).length(),
			local_dust_scattering,
		)
	_apply_underwater_fog_mask(_observer_underwater, _airborne != null)
	if space_mode and _environment != null:
		_environment.volumetric_fog_enabled = false
	var night_grade := Vector2.ZERO
	if _exposure != null:
		var camera := get_viewport().get_camera_3d()
		var night_storm_weight := _night_storm_weight(rain, sun_elevation) if not _observer_underwater and not stylized else 0.0
		_exposure.update_camera_exposure(camera, dust, sun_elevation, night_storm_weight, delta)
		night_grade = _exposure.get_night_storm_grade(camera, night_storm_weight)
		_exposure.update_cloud_interior(
			camera, _sky_material, _environment, global_position,
			not space_mode and not _observer_underwater and get_cloud_mode() == CloudMode.VOLUMETRIC,
		)
	if _wind_debris != null:
		_wind_debris.apply_weather(wind, _view_weather[&"gustiness"], delta, 0.0 if stylized else _airborne_exposure)
	if _screen_weather != null:
		var temperature := _get_clear_temperature() + float(_view_weather[&"temperature_offset"])
		var screen_active := not stylized and not space_mode and not (
			_observer_underwater and exposure_settings != null and exposure_settings.suppress_screen_underwater
		)
		if _wet_on_emerge_pending and screen_active:
			_screen_weather.wet_on_emerge()
		_screen_weather.apply_weather(rain, snow, dust, wind, temperature, delta, screen_active, night_grade)
	_wet_on_emerge_pending = false
	var preserve_radial_cloud_coverage := _uses_radial_cloud_field()
	_material_weather.apply(
		_weather, delta, _get_clear_temperature(), material_weather_settings, not space_mode, preserve_radial_cloud_coverage,
	)
	if _precipitation != null and rain_settings != null and rain_settings.contact_normal_strength > 0.0:
		var receivers: Array[MeshInstance3D] = []
		if rain > 0.0 and not stylized and not _observer_underwater:
			receivers = _material_weather.get_rain_contact_receivers()
		_precipitation.set_rain_contact_receivers(receivers)
	if space_mode:
		return

	var world := get_world_3d()
	var temperature := _get_clear_temperature()
	for surface: DynamicSkySurface in get_tree().get_nodes_in_group(DynamicSkySurface.GROUP):
		if surface.get_surface_world() == world:
			var position := surface.get_surface_position()
			var weather_here := _weather.sample_at(position, preserve_radial_cloud_coverage, true)
			var accumulation := weather_here
			var precipitation: Vector2 = weather_here.get(
				&"surface_precipitation", DynamicSkySurface.USE_AIRBORNE_PRECIPITATION,
			)
			if _material_weather.uses_radial_coating(surface.get_surface_geometry()):
				accumulation = _weather.sample_at(position, preserve_radial_cloud_coverage, true, true)
				precipitation = accumulation.get(
					&"surface_precipitation", Vector2(accumulation[&"rain"], accumulation[&"snow"]),
				)
			surface.apply_weather(
				weather_here[&"rain"], accumulation[&"snow"], accumulation[&"dust"],
				delta, temperature + float(accumulation[&"temperature_offset"]),
				accumulation[&"snow_coverage_limit"], precipitation,
			)


func _apply_underwater_fog_mask(underwater: bool, fog_updated: bool = false) -> void:
	var previous: Environment = null if _underwater_fog_environment == null else _underwater_fog_environment.get_ref()
	if _underwater_fog_environment != null and (previous == null or not underwater or previous != _environment):
		if previous != null and (previous != _environment or not fog_updated):
			previous.volumetric_fog_enabled = _underwater_fog_enabled
		_underwater_fog_environment = null
	if underwater and _environment != null:
		if _underwater_fog_environment == null:
			_underwater_fog_environment = weakref(_environment)
			_underwater_fog_enabled = (
				_airborne.get_authored_volumetric_fog_enabled() if _airborne != null
				else _environment.volumetric_fog_enabled
			)
		_environment.volumetric_fog_enabled = false


func _get_clear_temperature() -> float:
	var daylight := smoothstep(-0.15, 0.72, get_sun_direction().y)
	return lerpf(night_temperature, day_temperature, daylight)


func _point_light(light: DirectionalLight3D, direction: Vector3) -> void:
	var up := Vector3.FORWARD if absf(direction.y) > 0.99 else Vector3.UP
	var light_basis := Basis.looking_at(-direction, up)
	if not light.global_basis.is_equal_approx(light_basis):
		light.global_basis = light_basis


func _set_sky_parameter(parameter: StringName, value: Variant) -> void:
	if _sky_material.get_shader_parameter(parameter) != value:
		_sky_material.set_shader_parameter(parameter, value)
