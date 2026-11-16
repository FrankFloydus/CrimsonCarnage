@tool
class_name DynamicSkyConfiguration
extends Resource
## Saved Inspector configuration for supported sky, weather, and environmental controls.
## Native rendering controls remain on the actual Environment, Sky, and ShaderMaterial resources.

const RadialStormSpawning = preload("res://addons/dynamic_sky/weather/radial_storm_spawning.gd")
const DEFAULT_WEATHER_LIBRARY = preload("res://addons/dynamic_sky/presets/weather_library.tres")

@export_group("Clock and Location")
## Authored starting time in hours. The controller's runtime clock advances independently.
@export_range(0.0, 24.0, 0.01, "suffix:h") var time_of_day: float = 14.0:
	set(value):
		time_of_day = fposmod(value, 24.0)
		emit_changed()

## Real seconds per complete simulated day. Zero stops automatic time progression.
@export_range(0.0, 3600.0, 1.0, "or_greater", "suffix:s") var day_length_seconds: float = 0.0:
	set(value):
		day_length_seconds = maxf(value, 0.0)
		emit_changed()

## Follows the computer clock in the editor and at runtime. Astronomy selects its UTC offset.
## With no Astronomy resource, the operating system's local time zone is used.
@export var use_system_time: bool = false:
	set(value):
		use_system_time = value
		emit_changed()

## Geographic latitude in degrees. Positive values are north of the equator.
@export_range(-89.0, 89.0, 0.1, "degrees") var latitude: float = 35.0:
	set(value):
		latitude = clampf(value, -89.0, 89.0)
		emit_changed()

## Rotation of geographic north around world up. Zero uses world negative Z as north.
@export_range(-180.0, 180.0, 0.1, "degrees") var north_rotation: float = 0.0:
	set(value):
		north_rotation = value
		emit_changed()

## Optional civil date, longitude, time zone, and celestial calculation settings.
@export var astronomy: DynamicSkyAstronomy:
	set(value):
		_watch_resource(astronomy, value)
		astronomy = value
		emit_changed()

@export_group("Weather and Climate")
## Startup and editor-preview weather targets. Empty uses the controller's Clear fallback.
@export var start_weather: DynamicSkyWeather:
	set(value):
		_watch_resource(start_weather, value)
		start_weather = value
		emit_changed()

## Reusable weather choices exposed by this sky rig to gameplay and preview controls.
@export var weather_presets: Array[DynamicSkyWeather] = DEFAULT_WEATHER_LIBRARY.presets.duplicate():
	set(value):
		weather_presets = value
		emit_changed()

## Optional seasonal probability table and automatic weather-change schedule.
@export var climate: DynamicSkyClimate:
	set(value):
		_watch_resource(climate, value)
		climate = value
		emit_changed()

## Optional source-style schedule for spatial storms passing over the active observer.
@export var radial_storm_spawning: RadialStormSpawning:
	set(value):
		radial_storm_spawning = value
		emit_changed()

## Cloud texture UV displacement per meter of horizontal wind travel.
@export_range(0.0, 0.01, 0.0001, "or_greater") var cloud_drift_scale: float = 0.001:
	set(value):
		cloud_drift_scale = maxf(value, 0.0)
		emit_changed()

## Shared direction-source and gust settings consumed by the wind resolver.
@export var wind_settings: DynamicSkyWindSettings:
	set(value):
		_watch_resource(wind_settings, value)
		wind_settings = value
		emit_changed()

## Shared wind-driven mist settings for volumetric, post-process, or disabled presentation.
@export var wind_fog_settings: DynamicSkyWindFogSettings:
	set(value):
		_watch_resource(wind_fog_settings, value)
		wind_fog_settings = value
		emit_changed()

## Shared response and translation limits for the optional wind camera-shake component.
## The DynamicSky root owns its separate enable switch and explicit camera override.
@export var wind_shake_settings: DynamicSkyWindShakeSettings:
	set(value):
		_watch_resource(wind_shake_settings, value)
		wind_shake_settings = value
		emit_changed()

@export_group("Weather Effects")
## Snow spawn volume, cached trajectories, physical wind scale, and flake size.
@export var snow_settings: DynamicSkySnowSettings:
	set(value):
		_watch_resource(snow_settings, value)
		snow_settings = value
		emit_changed()

## Local rain/snow/dust haze densities, colors, and shelter probes.
@export var airborne_settings: DynamicSkyAirborneSettings:
	set(value):
		_watch_resource(airborne_settings, value)
		airborne_settings = value
		emit_changed()

## Flying debris enablement, wind thresholds, collision, and shelter tuning.
@export var wind_debris_settings: DynamicSkyWindDebrisSettings:
	set(value):
		_watch_resource(wind_debris_settings, value)
		wind_debris_settings = value
		emit_changed()

## Audio shelter probes, smoothing, sound speed, and thunder range.
@export var weather_audio_settings: DynamicSkyWeatherAudioSettings:
	set(value):
		_watch_resource(weather_audio_settings, value)
		weather_audio_settings = value
		emit_changed()

## Distant strike position, channel shape, branch count, and stroke timing.
@export var lightning_settings: DynamicSkyLightningSettings:
	set(value):
		_watch_resource(lightning_settings, value)
		lightning_settings = value
		emit_changed()

## Enables heightfield rain collision and geometry-clipped snow trajectories.
@export var precipitation_surface_collision: bool = true:
	set(value):
		precipitation_surface_collision = value
		emit_changed()

## Enables snow contact effects when precipitation surface collision is enabled.
@export var snow_contact_enabled: bool = true:
	set(value):
		snow_contact_enabled = value
		emit_changed()

## Opts the viewing camera into reversible offsets from strong wind.
@export var wind_shake_enabled: bool = false:
	set(value):
		wind_shake_enabled = value
		emit_changed()

@export_group("Material Weather")
## Wetness, snow, and dust on compatible existing shaders, including the prototype grid.
## Shader code and material assignments remain authored on the geometry.
@export var material_weather_settings: DynamicSkyMaterialWeatherSettings:
	set(value):
		_watch_resource(material_weather_settings, value)
		material_weather_settings = value
		emit_changed()


@export_group("Rain and Cloud Shadows")
## Visible rain layers and contacts. Weather-driven wetness, sky, and audio remain independent.
@export var rain_settings: DynamicSkyRainSettings:
	set(value):
		_watch_resource(rain_settings, value)
		rain_settings = value
		emit_changed()

## Directional cloud-shadow map projection, sampling, strength, and refresh controls.
@export var cloud_shadow_settings: DynamicSkyCloudShadowSettings:
	set(value):
		_watch_resource(cloud_shadow_settings, value)
		cloud_shadow_settings = value
		emit_changed()

## Explicit root cloud mode, or Material Default to retain the actual native material's mode.
@export_enum("Material Default:-1", "Volumetric:0", "Static:1", "Clear:2", "Dynamic 2D:3", "Space:4") var cloud_mode: int = -1:
	set(value):
		cloud_mode = clampi(value, -1, 4)
		emit_changed()

## Independent root color mode, or Material Default to retain native material authoring.
@export_enum("Material Default:-1", "Sky Atmosphere:0", "Simplified Color:1") var color_mode: int = -1:
	set(value):
		color_mode = clampi(value, -1, 1)
		emit_changed()

@export_group("Temperature")
## Clear-weather air temperature during the warmest part of the day, in degrees Celsius.
@export_range(-60.0, 60.0, 0.1, "suffix:°C") var day_temperature: float = 18.0:
	set(value):
		day_temperature = value
		emit_changed()

## Clear-weather air temperature at night, in degrees Celsius.
@export_range(-80.0, 60.0, 0.1, "suffix:°C") var night_temperature: float = 7.0:
	set(value):
		night_temperature = value
		emit_changed()

@export_group("Directional Lighting")
## Peak sunlight energy before calculated sun elevation and weather attenuation.
@export_range(0.0, 8.0, 0.01, "or_greater") var sun_energy: float = 1.25:
	set(value):
		sun_energy = maxf(value, 0.0)
		emit_changed()

## Peak moonlight energy before calculated moon elevation, phase, and weather attenuation.
@export_range(0.0, 2.0, 0.01, "or_greater") var moon_energy: float = 0.18:
	set(value):
		moon_energy = maxf(value, 0.0)
		emit_changed()

## Direct sunlight tint when the sun is high in the sky.
@export var daylight_color: Color = Color(1.0, 0.94, 0.85):
	set(value):
		daylight_color = value
		emit_changed()

## Authored sRGB moonlight tint; lunar phase, altitude and weather control energy separately.
@export var moon_light_color: Color = Color(0.69846177, 0.77201432, 0.93793751):
	set(value):
		moon_light_color = value
		emit_changed()

## Direct sunlight tint as the sun passes through the horizon.
@export var sunset_light_color: Color = Color(1.0, 0.48, 0.23):
	set(value):
		sunset_light_color = value
		emit_changed()

@export_group("Weather Fog")
## Applies the active weather profile's height falloff and start distance in supported Forward+ builds.
## The active Environment still owns the fog reference height and the authored settings used on opt-out.
@export var drive_height_fog_from_weather: bool = false:
	set(value):
		drive_height_fog_from_weather = value
		emit_changed()

## Distance-fog tint at noon, before overcast and dust contributions.
@export var day_fog_color: Color = Color(0.59, 0.67, 0.76):
	set(value):
		day_fog_color = value
		emit_changed()

## Distance-fog tint at night.
@export var night_fog_color: Color = Color(0.10, 0.15, 0.24):
	set(value):
		night_fog_color = value
		emit_changed()

## Daytime distance-fog tint under a dense cloud layer.
@export var overcast_fog_color: Color = Color(0.48, 0.54, 0.63):
	set(value):
		overcast_fog_color = value
		emit_changed()

## Distance-fog tint in airborne dust, attenuated by calculated daylight.
@export var dust_fog_color: Color = Color(0.62, 0.53, 0.43):
	set(value):
		dust_fog_color = value
		emit_changed()

@export_group("Lightning Illumination")
## Peak directional fill from sheet flashes. Zero also disables lightning glow in the sky.
@export_range(0.0, 5.0, 0.01, "or_greater") var lightning_energy: float = 1.45:
	set(value):
		lightning_energy = maxf(value, 0.0)
		emit_changed()

## Real seconds for the sheet light and sky glow to decay.
@export_range(0.05, 1.0, 0.01, "suffix:s") var lightning_duration: float = 0.26:
	set(value):
		lightning_duration = maxf(value, 0.05)
		emit_changed()

@export_group("Rendering and Camera Weather")
## Sun-opposed rainbow optics and lingering rain/fog moisture. Disabled in the default resource.
@export var rainbow_settings: DynamicSkyRainbowSettings:
	set(value):
		_watch_resource(rainbow_settings, value)
		rainbow_settings = value
		emit_changed()

## Shared above-cloud height ramp and authored global or regional water exposure controls.
@export var exposure_settings: DynamicSkyExposureSettings:
	set(value):
		_watch_resource(exposure_settings, value)
		exposure_settings = value
		emit_changed()

## Volumetric cloud quality. Use Material preserves the quality authored on the sky ShaderMaterial.
@export_enum("Use Material:-1", "Balanced:0", "High:1") var volumetric_quality: int = -1:
	set(value):
		volumetric_quality = clampi(value, -1, 1)
		emit_changed()

## Actual Environment used by the rig, including its Sky and ShaderMaterial controls.
## Keep this resource local to the scene. Native edits affect that environment directly.
@export var environment: Environment:
	set(value):
		environment = value
		emit_changed()

## Shared droplet, frost, heat-distortion, and roof-exposure settings for the camera effect.
@export var screen_settings: DynamicSkyScreenSettings:
	set(value):
		_watch_resource(screen_settings, value)
		screen_settings = value
		emit_changed()


## Returns authored controller scalars. Cache this dictionary when applying a configuration so
## unrelated Resource edits do not reset a running clock or a value changed through runtime APIs.
func get_scalar_values() -> Dictionary[StringName, Variant]:
	return {
		&"time_of_day": time_of_day,
		&"day_length_seconds": day_length_seconds,
		&"use_system_time": use_system_time,
		&"latitude": latitude,
		&"north_rotation": north_rotation,
		&"cloud_drift_scale": cloud_drift_scale,
		&"volumetric_quality": volumetric_quality,
		&"cloud_mode": cloud_mode,
		&"color_mode": color_mode,
		&"day_temperature": day_temperature,
		&"night_temperature": night_temperature,
		&"sun_energy": sun_energy,
		&"moon_energy": moon_energy,
		&"daylight_color": daylight_color,
		&"moon_light_color": moon_light_color,
		&"sunset_light_color": sunset_light_color,
		&"drive_height_fog_from_weather": drive_height_fog_from_weather,
		&"day_fog_color": day_fog_color,
		&"night_fog_color": night_fog_color,
		&"overcast_fog_color": overcast_fog_color,
		&"dust_fog_color": dust_fog_color,
		&"lightning_energy": lightning_energy,
		&"lightning_duration": lightning_duration,
		&"precipitation_surface_collision": precipitation_surface_collision,
		&"snow_contact_enabled": snow_contact_enabled,
		&"wind_shake_enabled": wind_shake_enabled,
	}


func _watch_resource(previous: Resource, next: Resource) -> void:
	if previous != null and previous.changed.is_connected(_child_changed):
		previous.changed.disconnect(_child_changed)
	if next != null and not next.changed.is_connected(_child_changed):
		next.changed.connect(_child_changed)


func _child_changed() -> void:
	emit_changed()
