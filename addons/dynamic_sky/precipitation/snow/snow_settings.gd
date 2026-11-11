@tool
class_name DynamicSkySnowSettings
extends Resource
## Authored snow emitter and cached trajectory settings recovered from the source weather actor.

## Falling particles emitted per second at full snow intensity before camera-motion compensation.
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:particles/s") var spawn_rate: float = 20000.0:
	set(value):
		if spawn_rate == value:
			return
		spawn_rate = value
		emit_changed()

## Longest lifetime of a cached falling trajectory before geometry clips its endpoint.
@export_range(0.1, 10.0, 0.1, "suffix:s") var maximum_lifetime_seconds: float = 3.0:
	set(value):
		if maximum_lifetime_seconds == value:
			return
		maximum_lifetime_seconds = value
		emit_changed()

## Radius of the horizontal spawn disc and the camera/spawn-origin particle culling spheres.
@export_range(0.1, 100.0, 0.1, "suffix:m") var spawn_radius_meters: float = 20.0:
	set(value):
		if spawn_radius_meters == value:
			return
		spawn_radius_meters = value
		emit_changed()

## Vertical span of the disc. One quarter lies below its origin and three quarters above it.
@export_range(0.1, 100.0, 0.1, "suffix:m") var spawn_height_meters: float = 6.0:
	set(value):
		if spawn_height_meters == value:
			return
		spawn_height_meters = value
		emit_changed()

## Distance the disc origin leads the camera along its forward direction.
@export_range(0.0, 20.0, 0.1, "suffix:m") var camera_forward_offset_meters: float = 0.5:
	set(value):
		if camera_forward_offset_meters == value:
			return
		camera_forward_offset_meters = value
		emit_changed()

## Exponent controlling how the source angular distribution favors the horizontal camera forward.
@export_range(0.0, 10.0, 0.05) var forward_bias: float = 0.9:
	set(value):
		if forward_bias == value:
			return
		forward_bias = value
		emit_changed()

## Exponent controlling the source distribution between the inner and outer spawn radii.
@export_range(0.1, 10.0, 0.05) var spawn_distribution: float = 1.0:
	set(value):
		if spawn_distribution == value:
			return
		spawn_distribution = value
		emit_changed()

## Number of reusable world-space trajectories available to the visible snow emitter.
@export_range(1, 8192, 1) var cached_path_count: int = 2000:
	set(value):
		if cached_path_count == value:
			return
		cached_path_count = value
		emit_changed()

## Cached trajectories refreshed per second before camera-motion compensation.
@export_range(1.0, 10000.0, 1.0, "suffix:paths/s") var cached_paths_per_second: float = 2000.0:
	set(value):
		if cached_paths_per_second == value:
			return
		cached_paths_per_second = value
		emit_changed()

## Distance traced backward along a trajectory to reject spawn points sheltered by upstream geometry.
@export_range(0.0, 200.0, 0.1, "suffix:m") var ceiling_check_meters: float = 80.0:
	set(value):
		if ceiling_check_meters == value:
			return
		ceiling_check_meters = value
		emit_changed()

## Static world physics layers used to clip cached paths and reject covered spawn points.
@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		if collision_mask == value:
			return
		collision_mask = value
		emit_changed()

## Horizontal wind speed corresponding to full normalized source wind intensity.
@export_range(0.1, 100.0, 0.1, "suffix:m/s") var wind_velocity_scale: float = 15.0:
	set(value):
		if wind_velocity_scale == value:
			return
		wind_velocity_scale = value
		emit_changed()

## Unstretched sprite side length before the source random size multiplier from one to 2.4.
@export_range(0.001, 0.2, 0.001, "suffix:m") var sprite_size_meters: float = 0.01:
	set(value):
		if sprite_size_meters == value:
			return
		sprite_size_meters = value
		emit_changed()
