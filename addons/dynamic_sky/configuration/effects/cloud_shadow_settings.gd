@tool
class_name DynamicSkyCloudShadowSettings
extends Resource
## Authored directional cloud-shadow projection, sampling, and refresh settings.

## Projects cloud shadows in Forward+ on Godot builds with directional projectors.
@export var enabled: bool = false:
	set(value):
		if enabled == value:
			return
		enabled = value
		emit_changed()

## Width of the square shadow map measured perpendicular to sunlight, in meters.
@export_range(250.0, 20000.0, 50.0, "suffix:m") var map_size_meters: float = 6000.0:
	set(value):
		if map_size_meters == value:
			return
		map_size_meters = value
		emit_changed()

## Number of texels per map side. Higher resolutions retain finer cloud-shadow edges.
@export_range(64, 512, 32) var resolution: int = 192:
	set(value):
		if resolution == value:
			return
		resolution = value
		emit_changed()

## Maximum regular shadow-map refreshes per real second. Large camera or sun jumps refresh immediately.
@export_range(1.0, 30.0, 1.0, "suffix:Hz") var updates_per_second: float = 10.0:
	set(value):
		if updates_per_second == value:
			return
		updates_per_second = value
		emit_changed()

## Density samples along each light ray through volumetric clouds.
@export_range(4, 24, 1) var samples_per_ray: int = 12:
	set(value):
		if samples_per_ray == value:
			return
		samples_per_ray = value
		emit_changed()

## Amount of direct-light extinction to apply. One uses the full physical transmission.
@export_range(0.0, 1.0, 0.01) var shadow_strength: float = 1.0:
	set(value):
		if shadow_strength == value:
			return
		shadow_strength = value
		emit_changed()


func _init() -> void:
	resource_local_to_scene = true
