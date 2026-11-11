@tool
class_name DynamicSkyLightningSettings
extends Resource
## Authored distant lightning placement, channel shape, and stroke timing.

@export_group("Placement")
## Physics layers that can receive distant ground strikes. Zero uses cloud channels only.
@export_flags_3d_physics var ground_mask: int = 1:
	set(value):
		ground_mask = value
		emit_changed()

## Closest automatic strike distance along the ground, in meters from the observer.
@export_range(500.0, 6000.0, 10.0, "or_greater", "suffix:m") var near_distance: float = 1400.0:
	set(value):
		near_distance = value
		emit_changed()

## Farthest automatic strike distance, in meters. Values below Near Distance use Near Distance.
@export_range(500.0, 6000.0, 10.0, "or_greater", "suffix:m") var far_distance: float = 3000.0:
	set(value):
		far_distance = value
		emit_changed()

## Maximum angular deviation to either side of the observer's horizontal view.
@export_range(0.0, 180.0, 1.0, "degrees") var strike_angle: float = 16.0:
	set(value):
		strike_angle = value
		emit_changed()

## How far below the observer to search for ground, in meters.
@export_range(1.0, 3000.0, 1.0, "or_greater", "suffix:m") var ground_search_depth: float = 1600.0:
	set(value):
		ground_search_depth = value
		emit_changed()

## Fraction of automatic strikes that stay in the storm deck. Missed ground rays also stay in clouds.
@export_range(0.0, 1.0, 0.01) var cloud_to_cloud_fraction: float = 0.66:
	set(value):
		cloud_to_cloud_fraction = value
		emit_changed()

@export_group("Bolt")
## Height of the lower storm deck above this node's origin, in meters.
@export_range(250.0, 4000.0, 10.0, "or_greater", "suffix:m") var cloud_base_height: float = 650.0:
	set(value):
		cloud_base_height = value
		emit_changed()

## Average depth inside the cloud where the first leader point forms, in meters.
@export_range(30.0, 650.0, 5.0, "or_greater", "suffix:m") var channel_depth: float = 190.0:
	set(value):
		channel_depth = value
		emit_changed()

## Halo half-width in meters. The narrow bright filament uses only the center of this width.
@export_range(0.1, 15.0, 0.05, "or_greater", "suffix:m") var bolt_radius: float = 6.5:
	set(value):
		bolt_radius = value
		emit_changed()

## Number of main branches before the generator adds smaller forks.
@export_range(0, 8) var branch_count: int = 3:
	set(value):
		branch_count = value
		emit_changed()

## Peak return-stroke multiplier for the bolt and the emitted impact intensity.
@export_range(0.1, 3.0, 0.05) var intensity: float = 1.0:
	set(value):
		intensity = value
		emit_changed()

## Peak energy of the local OmniLight3D. Zero disables ground illumination.
@export_range(0.0, 32.0, 0.1, "or_greater") var impact_light_energy: float = 3.8:
	set(value):
		impact_light_energy = value
		emit_changed()

@export_group("Timing")
## Seconds for the faint leader to travel from cloud to ground. Zero starts on impact.
@export_range(0.0, 0.2, 0.005, "suffix:s") var leader_duration: float = 0.045:
	set(value):
		leader_duration = value
		emit_changed()

## Seconds from impact until the last return stroke fades away.
@export_range(0.05, 1.0, 0.01, "suffix:s") var return_duration: float = 0.24:
	set(value):
		return_duration = value
		emit_changed()


func _init() -> void:
	resource_local_to_scene = true
