@tool
class_name DynamicSkyRigidBodyWind
extends Marker3D
## Attach to a RigidBody3D and move the marker to the point where wind should push it.

const WindSource = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")
const AIR_DENSITY: float = 1.225

## Optional source for local gusts. Empty uses the first DynamicSky in this World3D.
@export var sky_rig: DynamicSky

## Approximate area facing the wind in square meters. Zero disables the receiver.
@export_range(0.0, 40.0, 0.01, "or_greater", "suffix:m²") var exposed_area: float = 0.24

## Aerodynamic shape factor. About 1 is suitable for a blunt body.
@export_range(0.0, 3.0, 0.01, "or_greater") var drag_coefficient: float = 1.05

## Fraction of the area exposed to the airflow. Zero disables force.
@export_range(0.0, 1.0, 0.01) var exposure: float = 1.0

@export_group("Shelter")
## Collision layers that shield the marker from upwind airflow. Zero skips shelter queries.
@export_flags_3d_physics var shelter_mask: int = 0

## Distance to check for shelter in the upwind direction, in meters.
@export_range(0.1, 40.0, 0.1, "or_greater", "suffix:m") var shelter_distance: float = 12.0

var _sky: DynamicSky


func _ready() -> void:
	set_physics_process(not Engine.is_editor_hint())


func _get_configuration_warnings() -> PackedStringArray:
	if not get_parent() is RigidBody3D:
		return ["Place Wind Receiver directly under the RigidBody3D it should move."]
	return []


func _physics_process(delta: float) -> void:
	var body := get_parent() as RigidBody3D
	var drag_area := maxf(drag_coefficient, 0.0) * maxf(exposed_area, 0.0) * clampf(exposure, 0.0, 1.0)
	if body == null or body.freeze or drag_area <= 0.0:
		return
	_sky = WindSource.resolve(self, sky_rig, _sky)
	if _sky == null:
		return

	var wind := _sky.get_wind_at(global_position)
	if shelter_mask != 0 and not wind.is_zero_approx() and _is_sheltered(wind, body.get_rid()):
		wind = Vector3.ZERO
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	if state == null:
		return
	var offset := global_position - state.transform.origin
	var relative_air := wind - state.get_velocity_at_local_position(offset)
	var speed := relative_air.length()
	if speed < 0.001:
		return

	# Average quadratic drag over this tick to avoid reversing the air-relative velocity.
	# The inverse mass at the marker includes rotation around the body's center of mass.
	var force_per_speed := 0.5 * AIR_DENSITY * drag_area * speed
	var leverage := (offset - state.center_of_mass).cross(relative_air / speed)
	var inverse_mass_at_point := (
		state.inverse_mass + leverage.dot(state.inverse_inertia_tensor * leverage)
	)
	var effective_drag := force_per_speed / (1.0 + force_per_speed * inverse_mass_at_point * delta)
	var force := relative_air * effective_drag
	body.apply_force(force, offset)


func _is_sheltered(wind: Vector3, body_rid: RID) -> bool:
	var upwind := global_position - wind.normalized() * shelter_distance
	var ray := PhysicsRayQueryParameters3D.create(global_position, upwind, shelter_mask, [body_rid])
	return not get_world_3d().direct_space_state.intersect_ray(ray).is_empty()
