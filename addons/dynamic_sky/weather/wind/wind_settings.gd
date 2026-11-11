@tool
class_name DynamicSkyWindSettings
extends Resource
## Resolves horizontal wind direction and spatially coherent gusts for all wind receivers.

## Where the direction of airflow comes from. Local weather still supplies its speed.
enum DirectionSource {
	## Uses the X/Z vector in the weather profile, including local weather zones.
	WEATHER,
	## Uses the authored compass angle while retaining the local weather's wind speed.
	ANGLE,
	## Uses the negative Z axis of a Node3D relative to the sky rig.
	NODE,
}

@export_group("Direction")
## Selects the profile vector, a compass angle, or an authored direction node.
@export var direction_source: DirectionSource = DirectionSource.WEATHER:
	set(value):
		direction_source = value
		notify_property_list_changed()
		emit_changed()

## Airflow heading clockwise from world negative Z, in degrees. Ninety flows along positive X.
@export_range(0.0, 360.0, 0.1, "degrees") var direction_degrees: float = 0.0:
	set(value):
		direction_degrees = fposmod(value, 360.0)
		emit_changed()

## Node3D path relative to DynamicSky. Its world negative Z axis gives the direction of airflow.
@export_node_path("Node3D") var direction_node: NodePath:
	set(value):
		direction_node = value
		emit_changed()

@export_group("Gusts")
## Real seconds between random gust targets. This clock continues while the solar clock is paused.
@export_range(0.1, 120.0, 0.1, "suffix:s") var gust_period_seconds: float = 2.0:
	set(value):
		gust_period_seconds = maxf(value, 0.1)
		emit_changed()

## Symmetric random speed variation, multiplied by local Gustiness. A value of 0.45 gives up to 45%.
@export_range(0.0, 0.95, 0.01) var gust_intensity: float = 0.45:
	set(value):
		gust_intensity = clampf(value, 0.0, 0.95)
		emit_changed()

## Sideways direction variation as a fraction of wind speed and local Gustiness.
@export_range(0.0, 0.75, 0.01) var lateral_variation: float = 0.13:
	set(value):
		lateral_variation = clampf(value, 0.0, 0.75)
		emit_changed()

## Distance between coherent gust fronts measured along the wind direction, in meters.
@export_range(4.0, 500.0, 1.0, "suffix:m") var gust_wavelength_meters: float = 72.0:
	set(value):
		gust_wavelength_meters = maxf(value, 4.0)
		emit_changed()

## Stable random gust sequence. Changing the seed creates a different sequence for this wind field.
@export var gust_seed: int = 8179:
	set(value):
		gust_seed = value
		emit_changed()


func _validate_property(property: Dictionary) -> void:
	if (
		(property.name == &"direction_degrees" and direction_source != DirectionSource.ANGLE)
		or (property.name == &"direction_node" and direction_source != DirectionSource.NODE)
	):
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Gust segments per real second. The rig saves the unbounded segment coordinate.
func phase_speed() -> float:
	return 1.0 / maxf(gust_period_seconds, 0.1)


## Samples wind in world meters per second. Phase is an unbounded count of gust segments.
func sample_wind(
	base_wind: Vector2, gustiness: float, position: Vector3, phase: float, rig: Node3D
) -> Vector3:
	var speed := base_wind.length()
	if speed <= 0.00001:
		return Vector3.ZERO
	var direction := _resolve_direction(base_wind / speed, rig)
	var point := Vector2(position.x, position.z)
	var front := point.dot(direction) / maxf(gust_wavelength_meters, 4.0)
	var lateral := direction.orthogonal()
	var eddy := point.dot(lateral) * TAU / maxf(gust_wavelength_meters * 0.73, 4.0)
	var coordinate := phase - front + sin(eddy * 0.47) * 0.15
	var segment := floori(coordinate)
	var progress := coordinate - float(segment)
	var gust := lerpf(_gust_target(segment), _gust_target(segment + 1), progress)
	var variation := clampf(gustiness, 0.0, 1.0)
	var multiplier := 1.0 + variation * gust_intensity * gust
	var sideways := variation * lateral_variation * lerpf(
		_gust_target(segment + 271), _gust_target(segment + 272), progress
	)
	var velocity := (direction * maxf(multiplier, 0.0) + lateral * sideways) * speed
	return Vector3(velocity.x, 0.0, velocity.y)


func _gust_target(segment: int) -> float:
	var state := (segment + gust_seed) & 0xffffffff
	state = (state * 1664525 + 1013904223) & 0xffffffff
	state ^= state >> 13
	state = (state * 1664525 + 1013904223) & 0xffffffff
	state ^= state >> 16
	return float(state) / 4294967295.0 * 2.0 - 1.0


func _resolve_direction(weather_direction: Vector2, rig: Node3D) -> Vector2:
	if direction_source == DirectionSource.ANGLE:
		var angle := deg_to_rad(direction_degrees)
		return Vector2(sin(angle), -cos(angle))
	if direction_source == DirectionSource.NODE and is_instance_valid(rig) and rig.is_inside_tree():
		var source := rig.get_node_or_null(direction_node) as Node3D
		if source != null and source.is_inside_tree() and source.get_world_3d() == rig.get_world_3d():
			var forward := -source.global_basis.z
			var horizontal := Vector2(forward.x, forward.z)
			if not horizontal.is_zero_approx():
				return horizontal.normalized()
	return weather_direction
