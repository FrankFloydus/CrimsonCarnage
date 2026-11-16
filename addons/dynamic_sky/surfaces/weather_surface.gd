@tool
class_name DynamicSkySurface
extends Node
## Accumulates water, snow, and dust on a weather-responsive mesh.

## Emitted when this surface's settled snow fraction changes.
signal snow_coverage_changed(coverage: float)

const GROUP := &"dynamic_sky_surfaces"
const USE_AIRBORNE_PRECIPITATION := Vector2(-1.0, -1.0)

## Mesh using a weather-responsive shader. Empty uses the GeometryInstance3D parent.
@export var geometry: GeometryInstance3D:
	set(value):
		geometry = value
		if is_node_ready():
			if is_instance_valid(_surface):
				_surface.set_instance_shader_parameter(&"weather_surface", Vector4.ZERO)
			_surface = _get_surface()
		update_configuration_warnings()

## Fraction of precipitation that reaches this surface. Use zero beneath a solid roof.
@export_range(0.0, 1.0, 0.01) var exposure: float = 1.0

@export_group("Response Times")
## Real seconds for full-strength rain to saturate a dry surface.
@export_range(0.1, 600.0, 0.1, "or_greater", "suffix:s") var wetting_seconds: float = 12.0

## Real seconds for a saturated surface to dry in clear conditions.
@export_range(0.1, 1200.0, 0.1, "or_greater", "suffix:s") var drying_seconds: float = 65.0

## Real seconds for full-strength snowfall to cover the surface.
@export_range(0.1, 600.0, 0.1, "or_greater", "suffix:s") var snow_seconds: float = 22.0

## Real seconds for a full cover of snow to melt at 8°C with no rain.
@export_range(0.1, 1200.0, 0.1, "or_greater", "suffix:s") var thaw_seconds: float = 120.0

## Real seconds for full-strength dust to coat the surface.
@export_range(0.1, 600.0, 0.1, "or_greater", "suffix:s") var dust_seconds: float = 19.0

## Real seconds for full-strength rain to remove a heavy dust coating.
@export_range(0.1, 1200.0, 0.1, "or_greater", "suffix:s") var wash_seconds: float = 16.0

var _wetness: float = 0.0
var _snow_cover: float = 0.0:
	set(value):
		if value != _snow_cover:
			_snow_cover = value
			snow_coverage_changed.emit(value)
var _dust_cover: float = 0.0
var _surface: GeometryInstance3D


func _ready() -> void:
	_surface = _get_surface()
	if not Engine.is_editor_hint():
		add_to_group(GROUP)


func _get_configuration_warnings() -> PackedStringArray:
	if _get_surface() == null:
		return PackedStringArray(["Assign a geometry target or add this node under a MeshInstance3D."])
	return PackedStringArray()


## Advances the surface state by real seconds and updates its per-instance shader uniform.
func apply_weather(
	rain: float, snow: float, dust: float, delta: float, temperature: float = 0.0,
	snow_coverage_limit: float = 1.0, surface_precipitation: Vector2 = USE_AIRBORNE_PRECIPITATION,
) -> void:
	var state := calculate_weather_state(
		get_accumulation(), rain, snow, dust, delta, temperature, self, snow_coverage_limit, surface_precipitation,
	)
	_wetness = state.x
	_snow_cover = state.y
	_dust_cover = state.z
	if is_instance_valid(_surface) and _surface.get_instance_shader_parameter(&"weather_surface") != state:
		_surface.set_instance_shader_parameter(&"weather_surface", state)


## Shared accumulation for explicit surface components and root-managed custom shaders.
## Response supplies the exposure and response-time properties documented on this component.
## Surface precipitation can supply separate wetting and settling rates for local weather overrides.
static func calculate_weather_state(
	accumulation: Vector3, rain: float, snow: float, dust: float, delta: float,
	temperature: float, response: Object, snow_coverage_limit: float = 1.0,
	surface_precipitation: Vector2 = USE_AIRBORNE_PRECIPITATION,
) -> Vector4:
	var exposure_value := float(response.get(&"exposure"))
	var rain_here := clampf(rain * exposure_value, 0.0, 1.0)
	var accumulation_precipitation := Vector2(rain, snow) if surface_precipitation.x < 0.0 else surface_precipitation
	var wetting_rain := clampf(accumulation_precipitation.x * exposure_value, 0.0, 1.0)
	var snow_here := clampf(accumulation_precipitation.y * exposure_value, 0.0, 1.0)
	var dust_here := clampf(dust * exposure_value, 0.0, 1.0)
	var wetness := accumulation.x
	var snow_cover := accumulation.y
	var dust_cover := accumulation.z
	var previous_snow := snow_cover
	var settles := 1.0 - smoothstep(0.5, 5.0, temperature)
	var snow_gain := snow_here * settles * delta / maxf(float(response.get(&"snow_seconds")), 0.1)
	snow_gain = minf(snow_gain, maxf(snow_coverage_limit - snow_cover, 0.0))
	var thaw_strength := clampf(temperature / 8.0, 0.0, 4.0) + 3.0 * wetting_rain
	var snow_loss := thaw_strength / maxf(float(response.get(&"thaw_seconds")), 0.1)
	snow_cover = clampf(snow_cover + snow_gain - snow_loss * delta, 0.0, 1.0)

	var melted_snow := maxf(previous_snow - snow_cover, 0.0)
	if wetting_rain > 0.0:
		wetness = move_toward(wetness, 1.0, wetting_rain * delta / maxf(float(response.get(&"wetting_seconds")), 0.1))
	else:
		var evaporation := lerpf(0.36, 1.82, smoothstep(-8.0, 38.0, temperature))
		wetness = move_toward(wetness, 0.0, delta * evaporation / maxf(float(response.get(&"drying_seconds")), 0.1))
	wetness = minf(wetness + melted_snow, 1.0)

	dust_cover = clampf(
		dust_cover + delta * (
			dust_here / maxf(float(response.get(&"dust_seconds")), 0.1)
			- wetting_rain / maxf(float(response.get(&"wash_seconds")), 0.1)
		),
		0.0, 1.0
	)
	return Vector4(wetness, snow_cover, dust_cover, rain_here)


## Returns water, snow, and dust coverage as independent fractions.
func get_accumulation() -> Vector3:
	return Vector3(_wetness, _snow_cover, _dust_cover)


## Returns the geometry this accumulation component writes to.
func get_surface_geometry() -> GeometryInstance3D:
	return _surface


func get_surface_world() -> World3D:
	if is_instance_valid(_surface) and _surface.is_inside_tree():
		return _surface.get_world_3d()
	return null


func get_surface_position() -> Vector3:
	return _surface.global_position


func _get_surface() -> GeometryInstance3D:
	if geometry != null:
		return geometry
	return get_parent() as GeometryInstance3D
