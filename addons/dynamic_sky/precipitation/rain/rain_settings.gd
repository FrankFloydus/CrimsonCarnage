@tool
class_name DynamicSkyRainSettings
extends Resource
## Visible rain layers and contact optics, independent of the global rain weather channel.

enum FallDistribution { DISTANCE_LAYERS, CAMERA_BIASED_VOLUME }
enum SplashCollision { HEIGHTFIELD, TRAJECTORY_CACHE, FALLING_DROP_CONTACT }

@export_group("Visibility")
## Enables rain particles and their contacts without changing weather, sky, wetness, or audio.
@export var enabled: bool = true:
	set(value):
		if enabled == value:
			return
		enabled = value
		emit_changed()

## Distance Layers uses all three authored bands. Camera-Biased Volume uses the near band's optics and concentrates births ahead of the camera.
@export var fall_distribution: FallDistribution = FallDistribution.DISTANCE_LAYERS:
	set(value):
		if fall_distribution == value:
			return
		fall_distribution = value
		emit_changed()

## Near distance layer. Empty preserves that emitter's authored native values.
@export var near_layer: DynamicSkyRainLayerSettings = preload("res://addons/dynamic_sky/precipitation/rain/rain_near.tres"):
	set(value):
		_watch_layer(near_layer, value)
		near_layer = value
		emit_changed()

## Middle distance layer. Empty preserves that emitter's authored native values.
@export var middle_layer: DynamicSkyRainLayerSettings = preload("res://addons/dynamic_sky/precipitation/rain/rain_middle.tres"):
	set(value):
		_watch_layer(middle_layer, value)
		middle_layer = value
		emit_changed()

## Distant distance layer. Empty preserves that emitter's authored native values.
@export var distant_layer: DynamicSkyRainLayerSettings = preload("res://addons/dynamic_sky/precipitation/rain/rain_distant.tres"):
	set(value):
		_watch_layer(distant_layer, value)
		distant_layer = value
		emit_changed()


@export_group("Camera-Biased Fall Volume")
## Full-intensity births per second. The normalized rain amount still scales the rate to the power of 1.7.
@export_range(1, 100000, 1, "suffix:/s") var fall_volume_maximum_rate: int = 20000:
	set(value):
		if fall_volume_maximum_rate == value:
			return
		fall_volume_maximum_rate = value
		emit_changed()

## Maximum lifetime of a falling drop in seconds. Opaque collisions can end a drop earlier.
@export_range(0.05, 4.0, 0.01, "suffix:s") var fall_volume_lifetime: float = 1.0:
	set(value):
		if fall_volume_lifetime == value:
			return
		fall_volume_lifetime = value
		emit_changed()

## Horizontal spawn radius and particle retention distance from the camera or its offset spawn origin.
@export_range(1.0, 60.0, 0.1, "suffix:m") var fall_volume_radius: float = 20.0:
	set(value):
		if fall_volume_radius == value:
			return
		fall_volume_radius = value
		emit_changed()

## Vertical span of drop births. One quarter of the span sits below the spawn origin.
@export_range(0.1, 30.0, 0.1, "suffix:m") var fall_volume_height: float = 6.0:
	set(value):
		if fall_volume_height == value:
			return
		fall_volume_height = value
		emit_changed()

## Moves the center of the fall volume along the current camera forward axis.
@export_range(0.0, 10.0, 0.01, "suffix:m") var fall_volume_forward_offset: float = 0.5:
	set(value):
		if fall_volume_forward_offset == value:
			return
		fall_volume_forward_offset = value
		emit_changed()

## Biases drop births toward the forward view. Overhead and downward views blend toward a full circle.
@export_range(0.0, 4.0, 0.01) var fall_volume_forward_bias: float = 0.9:
	set(value):
		if fall_volume_forward_bias == value:
			return
		fall_volume_forward_bias = value
		emit_changed()

## Larger values concentrate drop births closer to the spawn origin inside the same radius.
@export_range(0.1, 5.0, 0.01) var fall_volume_radial_distribution: float = 1.0:
	set(value):
		if fall_volume_radial_distribution == value:
			return
		fall_volume_radial_distribution = value
		emit_changed()

## Starts the near-view fade at this distance in meters, reducing clipped streaks next to the camera.
@export_range(0.05, 2.0, 0.01, "suffix:m") var fall_volume_minimum_view_distance: float = 0.45:
	set(value):
		if fall_volume_minimum_view_distance == value:
			return
		fall_volume_minimum_view_distance = value
		emit_changed()

## Unscaled width of a drop in the camera-biased volume. The near layer's random size range still applies.
@export_range(0.001, 0.1, 0.001, "suffix:m") var fall_volume_sprite_width: float = 0.006:
	set(value):
		if fall_volume_sprite_width == value:
			return
		fall_volume_sprite_width = value
		emit_changed()


@export_group("Contact Splashes")
## Shows independently sampled opaque-surface contacts without changing falling rain.
@export var splashes_enabled: bool = true:
	set(value):
		if splashes_enabled == value:
			return
		splashes_enabled = value
		emit_changed()

## Strength of real impact normals on nearby weather materials in Forward+ Falling Drop Contact mode. Zero disables the field.
@export_range(0.0, 1.0, 0.01) var contact_normal_strength: float = 0.0:
	set(value):
		var next_strength := clampf(value, 0.0, 1.0)
		if contact_normal_strength == next_strength:
			return
		contact_normal_strength = next_strength
		emit_changed()

## Heightfield uses GPU surface probes. Trajectory Cache samples physics hits along camera-biased rain paths. Falling Drop Contact uses visible falling drops and visual collision in Camera-Biased Volume on Forward+ or Mobile, and uses Heightfield otherwise.
@export var splash_collision: SplashCollision = SplashCollision.HEIGHTFIELD:
	set(value):
		if splash_collision == value:
			return
		splash_collision = value
		emit_changed()

## Simultaneous splash slots. Heightfield also uses these slots during its surface search.
@export_range(1, 20000, 1, "or_greater") var splash_amount: int = 2400:
	set(value):
		if splash_amount == value:
			return
		splash_amount = value
		emit_changed()

## Number of sampled impact paths retained for Trajectory Cache.
@export_range(64, 16384, 1) var splash_cached_paths: int = 2000:
	set(value):
		if splash_cached_paths == value:
			return
		splash_cached_paths = value
		emit_changed()

## Baseline physics paths sampled per second for Trajectory Cache. Camera motion can raise the replacement rate.
@export_range(100, 8000, 1, "suffix:/s") var splash_paths_per_second: int = 2000:
	set(value):
		if splash_paths_per_second == value:
			return
		splash_paths_per_second = value
		emit_changed()

## Physics layers that can stop trajectory-cache rain and supply splash receivers.
@export_flags_3d_physics var splash_collision_mask: int = 1:
	set(value):
		if splash_collision_mask == value:
			return
		splash_collision_mask = value
		emit_changed()

## Distance to check upstream of a trajectory start for roofs or other rain-blocking geometry.
@export_range(0.0, 160.0, 0.5, "suffix:m") var splash_ceiling_check: float = 80.0:
	set(value):
		if splash_ceiling_check == value:
			return
		splash_ceiling_check = value
		emit_changed()

## Minimum alignment between a receiver normal and incoming rain for a cached hit to produce a splash.
@export_range(0.0, 1.0, 0.01) var splash_minimum_facing_normal: float = 0.02:
	set(value):
		if splash_minimum_facing_normal == value:
			return
		splash_minimum_facing_normal = value
		emit_changed()

## Base radial offset for repeated samples around a cached hit. The spread grows with view distance.
@export_range(0.0, 1.0, 0.01, "suffix:m") var splash_duplicate_radius: float = 0.22:
	set(value):
		if splash_duplicate_radius == value:
			return
		splash_duplicate_radius = value
		emit_changed()

## Visual duration scale for ripples, crowns, and rebounds. Surface search time is separate.
@export_range(0.01, 2.0, 0.01, "suffix:s") var splash_lifetime: float = 0.34:
	set(value):
		if splash_lifetime == value:
			return
		splash_lifetime = value
		emit_changed()

## Unscaled surface ripple width and depth in meters.
@export var ripple_size: Vector2 = Vector2(0.14, 0.14):
	set(value):
		if ripple_size == value:
			return
		ripple_size = value
		emit_changed()

## Color and peak alpha of the quiet ripple and wet flecks around a hit.
@export var ripple_tint: Color = Color(0.70, 0.75, 0.78, 0.36):
	set(value):
		if ripple_tint == value:
			return
		ripple_tint = value
		emit_changed()

## Dark contact-center color and alpha inside the ripple.
@export var contact_tint: Color = Color(0.18, 0.23, 0.28, 0.18):
	set(value):
		if contact_tint == value:
			return
		contact_tint = value
		emit_changed()

## Unscaled crown sprite dimensions in meters.
@export var crown_size: Vector2 = Vector2(0.075, 0.034):
	set(value):
		if crown_size == value:
			return
		crown_size = value
		emit_changed()

## Crown sprite color and peak alpha through its existing atlas.
@export var crown_tint: Color = Color(0.77, 0.82, 0.88, 0.38):
	set(value):
		if crown_tint == value:
			return
		crown_tint = value
		emit_changed()

## Fraction of surface contacts that display an animated crown.
@export_range(0.0, 1.0, 0.01) var crown_visible_fraction: float = 0.86:
	set(value):
		if crown_visible_fraction == value:
			return
		crown_visible_fraction = value
		emit_changed()

## Unscaled bounce-droplet dimensions in meters.
@export var bounce_size: Vector2 = Vector2(0.0065, 0.010):
	set(value):
		if bounce_size == value:
			return
		bounce_size = value
		emit_changed()

## Bounce-droplet color and peak alpha.
@export var bounce_tint: Color = Color(0.72, 0.80, 0.89, 0.45):
	set(value):
		if bounce_tint == value:
			return
		bounce_tint = value
		emit_changed()

## Fraction of surface contacts that launch a rebound droplet.
@export_range(0.0, 1.0, 0.01) var bounce_visible_fraction: float = 0.86:
	set(value):
		if bounce_visible_fraction == value:
			return
		bounce_visible_fraction = value
		emit_changed()

## Minimum and maximum vertical launch speeds in meters per second.
@export var bounce_launch_speed_range: Vector2 = Vector2(0.48, 0.99):
	set(value):
		if bounce_launch_speed_range == value:
			return
		bounce_launch_speed_range = value
		emit_changed()

## Minimum and maximum horizontal bounce speeds in meters per second.
@export var bounce_outward_speed_range: Vector2 = Vector2(0.14, 0.48):
	set(value):
		if bounce_outward_speed_range == value:
			return
		bounce_outward_speed_range = value
		emit_changed()

@export_group("Storm Spray")
## Shows storm-contact spray independently of falling rain and its near splashes.
@export var spray_enabled: bool = true:
	set(value):
		if spray_enabled == value:
			return
		spray_enabled = value
		emit_changed()

## Maximum simultaneous storm spray contacts.
@export_range(1, 20000, 1, "or_greater") var spray_amount: int = 650:
	set(value):
		if spray_amount == value:
			return
		spray_amount = value
		emit_changed()

## Lifetime of storm spray and its ballistic droplets.
@export_range(0.01, 2.0, 0.01, "suffix:s") var spray_lifetime: float = 0.26:
	set(value):
		if spray_lifetime == value:
			return
		spray_lifetime = value
		emit_changed()

## Unscaled storm spray plume dimensions in meters.
@export var spray_size: Vector2 = Vector2(0.12, 0.052):
	set(value):
		if spray_size == value:
			return
		spray_size = value
		emit_changed()

## Storm spray plume color and peak alpha.
@export var spray_tint: Color = Color(0.68, 0.72, 0.75, 0.065):
	set(value):
		if spray_tint == value:
			return
		spray_tint = value
		emit_changed()

## Color and peak alpha shared by the three ballistic storm droplets.
@export var spray_droplet_tint: Color = Color(0.77, 0.82, 0.86, 0.57):
	set(value):
		if spray_droplet_tint == value:
			return
		spray_droplet_tint = value
		emit_changed()

## Side lengths in meters of the first, second, and third storm-droplet draw passes.
@export var spray_droplet_sizes: Vector3 = Vector3(0.005, 0.004, 0.0045):
	set(value):
		if spray_droplet_sizes == value:
			return
		spray_droplet_sizes = value
		emit_changed()


func _init() -> void:
	for layer in [near_layer, middle_layer, distant_layer]:
		_watch_layer(null, layer)


func _watch_layer(previous: Resource, next: Resource) -> void:
	if previous != null and previous.changed.is_connected(_layer_changed):
		previous.changed.disconnect(_layer_changed)
	if next != null and not next.changed.is_connected(_layer_changed):
		next.changed.connect(_layer_changed)


func _layer_changed() -> void:
	emit_changed()
