extends Node3D
## Replays the reference's rolling contact on an editable receiving patch.

## Radius of the sphere's world-space circular path, in meters.
@export_range(0.5, 2.4, 0.05, "suffix:m") var orbit_radius_meters: float = 2.0

## Rate at which the sphere travels around the receiver, in degrees per real second.
@export_range(10.0, 180.0, 1.0, "suffix:°/s") var orbit_speed_degrees: float = 85.0

var _phase: float

@onready var _receiver: DynamicSkySnowTrackReceiver = $SnowTrackReceiver
@onready var _sphere: Node3D = $RollingSphere
@onready var _sphere_mesh: MeshInstance3D = $RollingSphere/Mesh
@onready var _stamp: DynamicSkySnowTrackStamp = $RollingSphere/SnowTrackStamp


func _ready() -> void:
	_receiver.accumulation.apply_weather(0.0, 1.0, 0.0, 30.0, -12.0)
	_update_sphere(0.0)


func _physics_process(delta: float) -> void:
	var angle_step := deg_to_rad(orbit_speed_degrees) * delta
	_phase = fposmod(_phase + angle_step, TAU)
	_update_sphere(angle_step)


func _update_sphere(angle_step: float) -> void:
	var radius := _stamp.diameter_meters * 0.5
	var compressed_depth := _receiver.get_snow_depth_meters() * (1.0 - _receiver.settings.compression)
	_sphere.position = Vector3(cos(_phase) * orbit_radius_meters, radius + compressed_depth, sin(_phase) * orbit_radius_meters)
	var axle := Vector3(cos(_phase), 0.0, sin(_phase))
	_sphere_mesh.rotate(axle, -angle_step * orbit_radius_meters / maxf(radius, 0.001))
