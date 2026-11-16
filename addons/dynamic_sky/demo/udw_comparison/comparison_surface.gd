extends DynamicSkySurface
## Applies the DemoMap's independently authored material state to a comparison surface.

var _use_source_state := false
var _airborne_rain: float = 0.0


## Sets the source material's wetness, snow cover, and dust cover.
func set_source_state(state: Vector3) -> void:
	_use_source_state = true
	_wetness = state.x
	_snow_cover = state.y
	_dust_cover = state.z
	_update_source_uniform()


## Resumes normal surface simulation for weather without a source material state.
func clear_source_state() -> void:
	_use_source_state = false


func apply_weather(
	rain: float, snow: float, dust: float, delta: float, temperature: float = 0.0,
	snow_coverage_limit: float = 1.0, surface_precipitation: Vector2 = USE_AIRBORNE_PRECIPITATION,
) -> void:
	_airborne_rain = clampf(rain * exposure, 0.0, 1.0)
	if _use_source_state:
		_update_source_uniform()
	else:
		super(rain, snow, dust, delta, temperature, snow_coverage_limit, surface_precipitation)


func _update_source_uniform() -> void:
	var state := Vector4(_wetness, _snow_cover, _dust_cover, _airborne_rain)
	if is_instance_valid(_surface) and _surface.get_instance_shader_parameter(&"weather_surface") != state:
		_surface.set_instance_shader_parameter(&"weather_surface", state)
