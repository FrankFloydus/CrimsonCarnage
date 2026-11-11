@tool
class_name DynamicSkyScreenSettings
extends Resource
## Authored lens response to local weather and temperature.

## Enables the screen weather component that uses this resource.
@export var enabled: bool = true:
	set(value):
		if enabled == value:
			return
		enabled = value
		emit_changed()

@export_group("Droplets")
## Accumulates refractive water beads when the lens is exposed to rain.
@export var droplets_enabled: bool = true:
	set(value):
		if droplets_enabled == value:
			return
		droplets_enabled = value
		emit_changed()
## Maximum lens wetness during sustained exposed rain, from zero to one.
@export_range(0.0, 1.0, 0.01) var maximum_wetness: float = 0.76:
	set(value):
		if maximum_wetness == value:
			return
		maximum_wetness = value
		emit_changed()
## Seconds of full rain required to reach the maximum wetness.
@export_range(0.1, 120.0, 0.1, "suffix:s") var wetting_seconds: float = 3.8:
	set(value):
		if wetting_seconds == value:
			return
		wetting_seconds = value
		emit_changed()
## Seconds for a fully wet lens to dry in temperate clear conditions.
@export_range(0.1, 300.0, 0.1, "suffix:s") var drying_seconds: float = 17.0:
	set(value):
		if drying_seconds == value:
			return
		drying_seconds = value
		emit_changed()
## Size of water beads relative to the reference lens. Larger beads are fewer.
@export_range(0.25, 3.0, 0.05) var droplet_scale: float = 1.0:
	set(value):
		if droplet_scale == value:
			return
		droplet_scale = value
		emit_changed()
## Peak droplet refraction measured in equivalent pixels at a 1080-pixel viewport height.
@export_range(0.0, 30.0, 0.1) var droplet_refraction_pixels: float = 9.0:
	set(value):
		if droplet_refraction_pixels == value:
			return
		droplet_refraction_pixels = value
		emit_changed()

@export_group("Frost")
## Builds crystalline frost on the lens in freezing conditions.
@export var frost_enabled: bool = true:
	set(value):
		if frost_enabled == value:
			return
		frost_enabled = value
		emit_changed()
## Air temperature at which frost can begin to form, in degrees Celsius.
@export_range(-30.0, 10.0, 0.1, "suffix:°C") var frost_start_temperature: float = -1.0:
	set(value):
		if frost_start_temperature == value:
			return
		frost_start_temperature = value
		emit_changed()
## Temperature producing full freezing response. Must be below the starting temperature.
@export_range(-70.0, 0.0, 0.1, "suffix:°C") var frost_full_temperature: float = -20.0:
	set(value):
		if frost_full_temperature == value:
			return
		frost_full_temperature = value
		emit_changed()
## Seconds for freezing moisture to reach full frost coverage.
@export_range(0.1, 600.0, 0.1, "suffix:s") var freezing_seconds: float = 35.0:
	set(value):
		if freezing_seconds == value:
			return
		freezing_seconds = value
		emit_changed()
## Seconds for warm air to thaw full frost coverage.
@export_range(0.1, 600.0, 0.1, "suffix:s") var thawing_seconds: float = 22.0:
	set(value):
		if thawing_seconds == value:
			return
		thawing_seconds = value
		emit_changed()
## Maximum opacity of the ice crystals. The center stays readable at the default value.
@export_range(0.0, 1.0, 0.01) var frost_opacity: float = 0.67:
	set(value):
		if frost_opacity == value:
			return
		frost_opacity = value
		emit_changed()
## Size of the frost crystals relative to the viewport height.
@export_range(0.25, 4.0, 0.05) var frost_scale: float = 1.2:
	set(value):
		if frost_scale == value:
			return
		frost_scale = value
		emit_changed()
## Crystal refraction measured in equivalent pixels at a 1080-pixel viewport height.
@export_range(0.0, 12.0, 0.1) var frost_refraction_pixels: float = 2.1:
	set(value):
		if frost_refraction_pixels == value:
			return
		frost_refraction_pixels = value
		emit_changed()
## Neutral daylight tint for the ice, multiplied by the scene's local brightness.
@export var frost_tint: Color = Color(0.79, 0.86, 0.92):
	set(value):
		if frost_tint == value:
			return
		frost_tint = value
		emit_changed()
## Original grayscale crystalline density used for frosting and its refractive slopes.
@export var frost_texture: Texture2D:
	set(value):
		if frost_texture == value:
			return
		frost_texture = value
		emit_changed()

@export_group("Heat")
## Enables refractive heat shimmer around the distant horizon in hot exposed conditions.
@export var heat_enabled: bool = true:
	set(value):
		if heat_enabled == value:
			return
		heat_enabled = value
		emit_changed()
## Air temperature where heat shimmer begins, in degrees Celsius.
@export_range(0.0, 70.0, 0.1, "suffix:°C") var heat_start_temperature: float = 29.0:
	set(value):
		if heat_start_temperature == value:
			return
		heat_start_temperature = value
		emit_changed()
## Air temperature producing the full heat response, above the starting temperature.
@export_range(1.0, 90.0, 0.1, "suffix:°C") var heat_full_temperature: float = 43.0:
	set(value):
		if heat_full_temperature == value:
			return
		heat_full_temperature = value
		emit_changed()
## Peak heat refraction measured in equivalent pixels at a 1080-pixel viewport height.
@export_range(0.0, 12.0, 0.1) var heat_refraction_pixels: float = 2.6:
	set(value):
		if heat_refraction_pixels == value:
			return
		heat_refraction_pixels = value
		emit_changed()
## Vertical thickness of the heat layer as a fraction of viewport height.
@export_range(0.04, 0.5, 0.01) var heat_horizon_width: float = 0.24:
	set(value):
		if heat_horizon_width == value:
			return
		heat_horizon_width = value
		emit_changed()

@export_group("Shelter")
## Physics surfaces that shelter the lens from precipitation and direct heat.
@export_flags_3d_physics var shelter_mask: int = 1:
	set(value):
		if shelter_mask == value:
			return
		shelter_mask = value
		emit_changed()
## Distance above the camera checked for a roof, in meters. Zero disables shelter checks.
@export_range(0.0, 40.0, 0.1, "suffix:m") var roof_probe_height: float = 12.0:
	set(value):
		if roof_probe_height == value:
			return
		roof_probe_height = value
		emit_changed()
