@tool
class_name DynamicSkyRainLayerSettings
extends Resource
## Emitter and optical controls for one authored rain distance layer.

@export_group("Emission")
## Maximum particles in this distance layer. Emission scales with normalized rain raised to 1.7.
@export_range(1, 100000, 1, "or_greater") var amount: int = 8900:
	set(value):
		if amount == value:
			return
		amount = value
		emit_changed()

## Particle lifetime in seconds. Use a lifetime long enough to cross the authored vertical volume.
@export_range(0.05, 10.0, 0.01, "suffix:s") var lifetime: float = 1.53:
	set(value):
		if lifetime == value:
			return
		lifetime = value
		emit_changed()

## Local height above the followed camera; middle and far offsets are relative to the near emitter.
@export_range(-20.0, 40.0, 0.01, "suffix:m") var vertical_offset: float = 4.1:
	set(value):
		if vertical_offset == value:
			return
		vertical_offset = value
		emit_changed()

## Inner and outer radii of the horizontal spawn annulus, in meters.
@export var spawn_radii: Vector2 = Vector2(0.0, 13.6):
	set(value):
		if spawn_radii == value:
			return
		spawn_radii = value
		emit_changed()

## Half the vertical spawn volume, in meters.
@export_range(0.1, 30.0, 0.1, "suffix:m") var spawn_half_height: float = 3.8:
	set(value):
		if spawn_half_height == value:
			return
		spawn_half_height = value
		emit_changed()

## Minimum and maximum downward speed in meters per second.
@export var fall_speed_range: Vector2 = Vector2(4.875, 9.0):
	set(value):
		if fall_speed_range == value:
			return
		fall_speed_range = value
		emit_changed()

## Minimum and maximum random sprite scale before velocity and exposure stretching.
@export var drop_scale_range: Vector2 = Vector2(0.833, 1.167):
	set(value):
		if drop_scale_range == value:
			return
		drop_scale_range = value
		emit_changed()

## Local particle bounds in meters. Enlarge these when extending the spawn volume or travel.
@export var visibility_aabb: AABB = AABB(Vector3(-31, -20, -31), Vector3(62, 31, 62)):
	set(value):
		if visibility_aabb == value:
			return
		visibility_aabb = value
		emit_changed()

@export_group("Appearance")
## Unscaled streak width in meters; the shader preserves subpixel opacity as it expands coverage.
@export_range(0.001, 0.1, 0.001, "suffix:m") var sprite_width: float = 0.009:
	set(value):
		if sprite_width == value:
			return
		sprite_width = value
		emit_changed()

## Scattered rain color. Opacity is authored separately.
@export_color_no_alpha var tint: Color = Color(0.69, 0.75, 0.79, 1.0):
	set(value):
		if tint == value:
			return
		tint = value
		emit_changed()

## Base optical alpha before the streak profile, depth fades, transmission, and storm boost.
@export_range(0.0, 1.0, 0.01) var opacity: float = 0.34:
	set(value):
		if opacity == value:
			return
		opacity = value
		emit_changed()

## Near fade start/end and far fade start/end, in view-space meters (X/Y/Z/W).
@export var view_depth_range: Vector4 = Vector4(0.40, 0.85, 8.9, 14.5):
	set(value):
		if view_depth_range == value:
			return
		view_depth_range = value
		emit_changed()

## Distance over which streaks soften against opaque scene depth.
@export_range(0.01, 2.0, 0.01, "suffix:m") var surface_fade_distance: float = 0.01:
	set(value):
		if surface_fade_distance == value:
			return
		surface_fade_distance = value
		emit_changed()

## Exposure time used to stretch streaks along their projected velocity.
@export_range(0.001, 0.1, 0.001, "suffix:s") var shutter_seconds: float = 0.024:
	set(value):
		if shutter_seconds == value:
			return
		shutter_seconds = value
		emit_changed()

## Minimum raster coverage before opacity compensation; affects distant thin streaks.
@export_range(0.5, 2.0, 0.01, "suffix:px") var minimum_pixel_width: float = 1.25:
	set(value):
		if minimum_pixel_width == value:
			return
		minimum_pixel_width = value
		emit_changed()

## Screen-color displacement across the streak in pixels.
@export_range(0.0, 2.0, 0.01, "suffix:px") var refraction_pixels: float = 0.82:
	set(value):
		if refraction_pixels == value:
			return
		refraction_pixels = value
		emit_changed()

## Strength of the sampled opaque backdrop in the drop's transmitted light.
@export_range(0.0, 1.0, 0.01) var transmission_weight: float = 0.67:
	set(value):
		if transmission_weight == value:
			return
		transmission_weight = value
		emit_changed()

## Additional opacity multiplier at full storm deflection.
@export_range(0.0, 2.0, 0.01) var storm_opacity_boost: float = 0.0:
	set(value):
		if storm_opacity_boost == value:
			return
		storm_opacity_boost = value
		emit_changed()

## Additional exposure-time multiplier at full storm deflection.
@export_range(0.0, 1.0, 0.01) var storm_shutter_boost: float = 0.0:
	set(value):
		if storm_shutter_boost == value:
			return
		storm_shutter_boost = value
		emit_changed()

@export_group("Contacts")
## Chance that a valid hit shows a contact. Near controls the surface sampler; middle controls spray.
@export_range(0.0, 1.0, 0.01) var contact_chance: float = 0.92:
	set(value):
		if contact_chance == value:
			return
		contact_chance = value
		emit_changed()

## Lift along the surface normal from the reconstructed contact point, in meters.
@export_range(-0.05, 0.05, 0.001, "suffix:m") var contact_surface_offset: float = 0.004:
	set(value):
		if contact_surface_offset == value:
			return
		contact_surface_offset = value
		emit_changed()

## Multiplies contact chance by storm strength for this layer's spray sub-emitter.
@export var storm_spray_contact: bool = false:
	set(value):
		if storm_spray_contact == value:
			return
		storm_spray_contact = value
		emit_changed()
