@tool
class_name DynamicSkyModifierProperty
extends Resource
## One editable float or color adjustment in a sky modifier.

## Output whose final computed value receives this adjustment.
enum Target {
	## A float or color uniform on the sky ShaderMaterial.
	SKY_SHADER,
	## A float or color property on the sky's Environment.
	ENVIRONMENT,
	## A float or color property on the sun DirectionalLight3D.
	SUN_LIGHT,
	## A float or color property on the moon DirectionalLight3D.
	MOON_LIGHT,
}

## Data type of the property and its authored adjustment.
enum ValueType {
	## A continuous scalar value.
	FLOAT,
	## An RGB color, with alpha when supported by the target.
	COLOR,
}

const SKY_FLOATS := [
	"atmosphere_exposure", "simple_sky_exposure", "simple_moon_strength", "star_brightness",
	"sun_angular_radius", "moon_angular_radius", "cloud_coverage", "cloud_base_km",
	"cloud_thickness_km", "cloud_extinction", "low_cloud_scale", "high_cloud_amount",
	"high_cloud_scale", "static_cloud_opacity", "dynamic_2d_opacity", "aurora_intensity",
]
const SKY_COLORS := [
	"sky_zenith", "sky_horizon", "sky_ground", "cloud_light", "cloud_shadow",
	"simple_day_sky_tint", "simple_twilight_sky_tint", "simple_night_sky_tint",
	"simple_dust_tint", "simple_cloud_day_tint", "simple_cloud_twilight_tint",
	"simple_cloud_night_tint", "simple_cloud_day_ambient", "simple_cloud_twilight_ambient",
	"simple_cloud_night_ambient", "aurora_green", "aurora_red", "aurora_violet", "planet_color",
]
const ENVIRONMENT_FLOATS := [
	"tonemap_exposure", "tonemap_white", "ambient_light_energy", "ambient_light_sky_contribution",
	"background_energy_multiplier", "fog_density", "fog_light_energy", "fog_sky_affect",
	"fog_aerial_perspective", "glow_intensity", "glow_strength", "glow_bloom",
	"adjustment_brightness", "adjustment_contrast", "adjustment_saturation",
]
const ENVIRONMENT_COLORS := ["fog_light_color", "ambient_light_color", "background_color"]
const LIGHT_FLOATS := ["light_energy", "light_indirect_energy", "light_volumetric_fog_energy", "light_angular_distance"]
const LIGHT_COLORS := ["light_color"]

## Final sky, environment, or directional light output to adjust.
@export var target: Target = Target.SKY_SHADER:
	set(value):
		target = value
		_select_valid_property()
		notify_property_list_changed()
		emit_changed()

## Selects a scalar or color property and the corresponding editable value.
@export var value_type: ValueType = ValueType.FLOAT:
	set(value):
		value_type = value
		_select_valid_property()
		notify_property_list_changed()
		emit_changed()

## Property or shader uniform selected from the supported fields for this target and type.
@export var property_name: StringName = &"atmosphere_exposure":
	set(value):
		property_name = value
		emit_changed()

## Scalar target in the selected property's native units, blended with the preceding layer result.
@export var float_value: float = 1.0:
	set(value):
		float_value = value
		emit_changed()

## Color target blended with the preceding layer result.
@export var color_value: Color = Color.WHITE:
	set(value):
		color_value = value
		emit_changed()


func _validate_property(property: Dictionary) -> void:
	if property.name == &"property_name":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(get_supported_properties())
	if property.name == &"float_value" and value_type != ValueType.FLOAT:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if property.name == &"color_value" and value_type != ValueType.COLOR:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Returns the allowed property names for the selected output and data type.
func get_supported_properties() -> PackedStringArray:
	match target:
		Target.SKY_SHADER:
			return PackedStringArray(SKY_FLOATS if value_type == ValueType.FLOAT else SKY_COLORS)
		Target.ENVIRONMENT:
			return PackedStringArray(ENVIRONMENT_FLOATS if value_type == ValueType.FLOAT else ENVIRONMENT_COLORS)
		_:
			return PackedStringArray(LIGHT_FLOATS if value_type == ValueType.FLOAT else LIGHT_COLORS)


## Interpolates from the preceding layer result to this property's authored target.
func blend(current: Variant, weight: float) -> Variant:
	if value_type == ValueType.FLOAT:
		return lerpf(float(current), float_value, weight)
	var color: Color = current
	return color.lerp(color_value, weight)


func _select_valid_property() -> void:
	var properties := get_supported_properties()
	if not properties.has(String(property_name)):
		property_name = StringName(properties[0])
