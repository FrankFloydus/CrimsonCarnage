@tool
class_name DynamicSkyWeatherZone
extends Node3D
## Spatial weather override with an editable region and a continuous falloff outside it.

## Geometry used to calculate local weather influence.
enum RegionMode {
	## Uses the assigned local BoxShape3D or SphereShape3D.
	SHAPE,
	## Extrudes a closed Path3D footprint between local floor and ceiling heights.
	SPLINE,
}

const GROUP := &"dynamic_sky_weather_zones"
const POINT_EPSILON_SQUARED: float = 0.00000001

## Weather sampled inside the region. Assign a preset or a custom weather resource.
@export var weather: DynamicSkyWeather

## Choose a primitive shape or an editable closed spline footprint for the full-weight region.
@export var region_mode: RegionMode = RegionMode.SHAPE:
	set(value):
		region_mode = value
		notify_property_list_changed()
		update_configuration_warnings()

## Local-space BoxShape3D or SphereShape3D that receives the full weather override.
@export var region: Shape3D:
	set(value):
		region = value
		update_configuration_warnings()

## Path3D whose closed curve defines the footprint in the zone's local X/Z plane.
@export var spline_path: Path3D:
	set(value):
		if is_instance_valid(spline_path):
			spline_path.curve_changed.disconnect(_invalidate_footprint)
			spline_path.tree_entered.disconnect(_invalidate_footprint)
		spline_path = value
		if is_instance_valid(spline_path):
			spline_path.curve_changed.connect(_invalidate_footprint)
			spline_path.tree_entered.connect(_invalidate_footprint)
		_invalidate_footprint()

## Floor and ceiling heights in the zone's local meters. The ceiling must be above the floor.
@export var spline_height_range: Vector2 = Vector2(-6.0, 6.0):
	set(value):
		spline_height_range = value
		update_configuration_warnings()

## Width in meters of the smooth falloff beyond the region boundary.
@export_range(0.0, 500.0, 0.1, "or_greater", "suffix:m") var falloff: float = 20.0

## Higher priorities are applied later and override lower-priority zones where they overlap.
@export var priority: int = 0

## Enable the zone for local weather sampling.
@export var enabled: bool = true

var _footprint_dirty: bool = true
var _footprint_transform: Transform3D
var _footprint: PackedVector2Array
var _footprint_bounds: Rect2


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		add_to_group(GROUP)


func _validate_property(property: Dictionary) -> void:
	match property.name:
		&"region":
			if region_mode == RegionMode.SPLINE:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		&"spline_path", &"spline_height_range":
			if region_mode != RegionMode.SPLINE:
				property.usage &= ~PROPERTY_USAGE_EDITOR


func _get_configuration_warnings() -> PackedStringArray:
	if region_mode == RegionMode.SPLINE:
		var warnings := PackedStringArray()
		if not _update_footprint():
			warnings.append("Assign a closed Path3D with at least three points and a simple X/Z footprint.")
		if not _has_valid_height_range():
			warnings.append("Set the spline ceiling height above the floor height.")
		return warnings
	if not region is BoxShape3D and not region is SphereShape3D:
		return PackedStringArray(["Assign a BoxShape3D or SphereShape3D to Region."])
	return PackedStringArray()


## Returns the weight of this zone at a world position.
func get_weather_weight(world_position: Vector3) -> float:
	if not enabled or weather == null:
		return 0.0

	var position_in_region := to_local(world_position)
	var distance_outside: float
	if region_mode == RegionMode.SPLINE:
		distance_outside = _distance_outside_spline(position_in_region)
	elif region is BoxShape3D:
		var half_size: Vector3 = region.size * 0.5
		var outside_box := position_in_region.abs() - half_size
		distance_outside = outside_box.max(Vector3.ZERO).length()
	elif region is SphereShape3D:
		distance_outside = maxf(position_in_region.length() - region.radius, 0.0)
	else:
		return 0.0

	if distance_outside == 0.0:
		return 1.0
	if falloff <= 0.0 or distance_outside >= falloff:
		return 0.0
	return 1.0 - smoothstep(0.0, falloff, distance_outside)


func _distance_outside_spline(local_position: Vector3) -> float:
	if not _has_valid_height_range() or not _update_footprint():
		return INF
	var point := Vector2(local_position.x, local_position.z)
	var basis := global_transform.basis
	var horizontal_scale := Vector2(basis.x.length(), basis.z.length())
	var outside_height := maxf(
		maxf(spline_height_range.x - local_position.y, local_position.y - spline_height_range.y),
		0.0,
	) * basis.y.length()
	var nearest_in_bounds := point.clamp(_footprint_bounds.position, _footprint_bounds.end)
	var bounds_offset := (point - nearest_in_bounds) * horizontal_scale
	if bounds_offset.length_squared() + outside_height * outside_height > maxf(falloff, 0.0) ** 2:
		return INF
	if Geometry2D.is_point_in_polygon(point, _footprint):
		return outside_height

	var point_in_meters := point * horizontal_scale
	var nearest_squared: float = INF
	var previous := _footprint[-1] * horizontal_scale
	for vertex in _footprint:
		var current := vertex * horizontal_scale
		var nearest := Geometry2D.get_closest_point_to_segment(point_in_meters, previous, current)
		nearest_squared = minf(nearest_squared, point_in_meters.distance_squared_to(nearest))
		previous = current
	return sqrt(nearest_squared + outside_height * outside_height)


func _has_valid_height_range() -> bool:
	return spline_height_range.is_finite() and spline_height_range.y > spline_height_range.x


func _invalidate_footprint() -> void:
	_footprint_dirty = true
	update_configuration_warnings()


func _update_footprint() -> bool:
	if not is_instance_valid(spline_path) or not spline_path.is_inside_tree() or not is_inside_tree():
		return false
	var curve := spline_path.curve
	if curve == null or not curve.closed or curve.point_count < 3:
		return false
	var relative_transform := spline_path.transform
	if spline_path.get_parent() != self or spline_path.top_level:
		relative_transform = global_transform.affine_inverse() * spline_path.global_transform
	if _footprint_dirty or not relative_transform.is_equal_approx(_footprint_transform):
		_footprint_dirty = false
		_footprint_transform = relative_transform
		_bake_footprint(curve, relative_transform)
	return not _footprint.is_empty()


func _bake_footprint(curve: Curve3D, relative_transform: Transform3D) -> void:
	_footprint.clear()
	for point in curve.tessellate():
		var local_point := relative_transform * point
		var projected := Vector2(local_point.x, local_point.z)
		if not projected.is_finite():
			_footprint.clear()
			return
		if (
			_footprint.is_empty()
			or projected.distance_squared_to(_footprint[-1]) > POINT_EPSILON_SQUARED
		):
			_footprint.append(projected)
	if (
		_footprint.size() >= 2
		and _footprint[0].distance_squared_to(_footprint[-1]) <= POINT_EPSILON_SQUARED
	):
		_footprint.remove_at(_footprint.size() - 1)
	if (
		_footprint.size() < 3
		or Geometry2D.triangulate_polygon(_footprint).is_empty()
		or _has_crossing_edges()
	):
		_footprint.clear()
		return
	_footprint_bounds = Rect2(_footprint[0], Vector2.ZERO)
	for vertex in _footprint:
		_footprint_bounds = _footprint_bounds.expand(vertex)


func _has_crossing_edges() -> bool:
	var count := _footprint.size()
	for first_edge in count:
		var a := _footprint[first_edge]
		var b := _footprint[(first_edge + 1) % count]
		# Adjacent edges share a vertex. Check only pairs that should be disjoint.
		var last_edge := count - 1 if first_edge == 0 else count
		for second_edge in range(first_edge + 2, last_edge):
			var c := _footprint[second_edge]
			var d := _footprint[(second_edge + 1) % count]
			if not Rect2(a, Vector2.ZERO).expand(b).intersects(Rect2(c, Vector2.ZERO).expand(d), true):
				continue
			if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
				return true
			# Segment intersection excludes collinear overlaps.
			if (
				Geometry2D.get_closest_point_to_segment(a, c, d).distance_squared_to(a) <= POINT_EPSILON_SQUARED
				or Geometry2D.get_closest_point_to_segment(b, c, d).distance_squared_to(b) <= POINT_EPSILON_SQUARED
				or Geometry2D.get_closest_point_to_segment(c, a, b).distance_squared_to(c) <= POINT_EPSILON_SQUARED
				or Geometry2D.get_closest_point_to_segment(d, a, b).distance_squared_to(d) <= POINT_EPSILON_SQUARED
			):
				return true
	return false
