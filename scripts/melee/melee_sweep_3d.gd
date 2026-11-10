@tool
class_name MeleeSweep3D
extends Node3D
## Sweeps a weapon's editable damage volume between evaluated poses and reports contacts.

## Emitted once per contacted physics body during the current swing.
signal world_contact(collider: Node3D)
## Emits the surface point, outward normal, and sampled swing direction for a contact.
signal surface_contact(collider: CollisionObject3D, point: Vector3, normal: Vector3, direction: Vector3)

const CROSS_SECTION_DEPTH := 0.0002
const MAX_QUERY_RESULTS := 32
const CONTACT_MARGIN := 0.001
const SWEEP_COLOR := Color(0.18, 0.73, 0.88)
const CONTACT_COLOR := Color(1.0, 0.38, 0.16)
const BOX_EDGES := [
	Vector2i(0, 1), Vector2i(0, 2), Vector2i(0, 4),
	Vector2i(1, 3), Vector2i(1, 5), Vector2i(2, 3), Vector2i(2, 6),
	Vector2i(3, 7), Vector2i(4, 5), Vector2i(4, 6), Vector2i(5, 7), Vector2i(6, 7),
]

## Full width of the sweep box in meters, along SweepStart's projected local Y axis.
@export_range(0.001, 2.0, 0.001, "or_greater", "suffix:m") var width: float = 0.10
## Full height of the sweep box in meters, perpendicular to the blade and width axes.
@export_range(0.001, 2.0, 0.001, "or_greater", "suffix:m") var height: float = 0.05
## Physics body layers queried for world contacts.
@export_flags_3d_physics var collision_mask: int = 1

@export_group("Debug")
## Draws the blade volume in the 3D editor, with any attack reach applied while posing or scrubbing.
@export var show_editor_preview: bool = true
## Draws the boxes queried in play. Orange marks a box pose that contacted a body.
@export var show_sweeps: bool = true
## Seconds each queried box stays visible in play. Zero disables the runtime overlay.
@export_range(0.0, 30.0, 0.1, "suffix:s") var debug_draw_duration: float = 3.0

## Attack reach supplied by the scene that previews this weapon in the editor.
var preview_reach: MeleeAttackReach

var _contacted: Dictionary[int, bool] = {}
var _hit_receivers: Dictionary[int, bool] = {}
var _box := BoxShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()
var _cast := PhysicsCastMotionResult3D.new()
var _surface_query := PhysicsShapeQueryParameters3D.new()
var _surface := PhysicsGetRestInfoResult3D.new()
var _draw_mesh := ImmediateMesh.new()
var _draw_material := StandardMaterial3D.new()
var _draw_passes: Array[DrawPass] = []
var _draw_dirty := false
var _preview_pose := Transform3D.IDENTITY
var _preview_size := Vector3.ZERO

@onready var _start := get_node_or_null(^"SweepStart") as Marker3D
@onready var _end := get_node_or_null(^"SweepEnd") as Marker3D
@onready var _blood_motion := get_node_or_null(^"BloodMotion") as Marker3D


func _ready() -> void:
	var drawing := MeshInstance3D.new()
	drawing.mesh = _draw_mesh
	drawing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	drawing.top_level = true
	if Engine.is_editor_hint():
		add_child(drawing, false, Node.INTERNAL_MODE_BACK)
	else:
		# A plain Node keeps world traces visible when this weapon is hidden on a swap.
		var draw_root := Node.new()
		add_child(draw_root, false, Node.INTERNAL_MODE_BACK)
		draw_root.add_child(drawing, false, Node.INTERNAL_MODE_BACK)
	drawing.global_transform = Transform3D.IDENTITY
	_draw_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_draw_material.vertex_color_use_as_albedo = true
	_draw_material.no_depth_test = true
	_query.shape = _box
	_surface_query.shape = _box
	set_process(Engine.is_editor_hint())


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		_update_preview()
		return

	var now := Time.get_ticks_msec()
	for index in range(_draw_passes.size() - 1, -1, -1):
		if not show_sweeps or debug_draw_duration <= 0.0 or _draw_passes[index].expires_at <= now:
			_draw_passes.remove_at(index)
			_draw_dirty = true
	if _draw_dirty:
		_redraw()
		_draw_dirty = false
	set_process(not _draw_passes.is_empty())


## Resets the contacted bodies and hit receivers before a new swing.
func begin_swing() -> void:
	_contacted.clear()
	_hit_receivers.clear()


## Returns the current world-space sweep origin and basis, with local X pointing toward SweepEnd.
func sample_pose() -> Transform3D:
	if _start == null or _end == null:
		return global_transform.orthonormalized()

	var span := _end.global_position - _start.global_position
	if span.is_zero_approx():
		return _start.global_transform.orthonormalized()

	var blade_axis := span.normalized()
	var width_hint := _start.global_basis.y.normalized()
	if absf(blade_axis.dot(width_hint)) > 0.999:
		width_hint = _start.global_basis.z.normalized()
	var height_axis := blade_axis.cross(width_hint).normalized()
	var width_axis := height_axis.cross(blade_axis)
	return Transform3D(Basis(blade_axis, width_axis, height_axis), _start.global_position)


## Returns the authored blade point used to estimate the visible swing direction.
func sample_motion_point() -> Vector3:
	if _blood_motion != null:
		return _blood_motion.global_position
	if _start != null and _end != null:
		return _start.global_position.lerp(_end.global_position, 0.5)
	return global_position


## Queries one pair of marker poses with the optional attack reach. Call during physics processing.
func trace_segment(
		previous: Transform3D,
		current: Transform3D,
		excluded: Array[RID],
		reach: MeleeAttackReach = null,
		direction: Vector3 = Vector3.ZERO
) -> void:
	var size := _blade_size(reach)
	if size.x <= 0.0:
		return

	previous = _place_blade(previous, reach)
	current = _place_blade(current, reach)
	var space := get_world_3d().direct_space_state
	_query.collision_mask = collision_mask
	var previous_span := previous.basis.x * size.x
	var current_span := current.basis.x * size.x

	if previous.is_equal_approx(current):
		_trace_pass(space, _at_offset(current, current_span * 0.5), size, Vector3.ZERO, excluded, direction)
		return

	# Follow the previous blade span, approximate rotation, then translate the blade base.
	var section := Vector3(CROSS_SECTION_DEPTH, size.y, size.z)
	_trace_pass(space, previous, section, previous_span, excluded, direction)
	_trace_pass(space, _at_offset(previous, previous_span * 0.5), size,
			current_span - previous_span, excluded, direction)
	_trace_pass(space, Transform3D(current.basis, previous.origin + current_span * 0.5), size,
			current.origin - previous.origin, excluded, direction)


func _trace_pass(
		space: PhysicsDirectSpaceState3D,
		pose: Transform3D,
		size: Vector3,
		motion: Vector3,
		excluded: Array[RID],
		direction: Vector3
) -> void:
	_box.size = size
	_query.transform = pose
	_query.exclude = excluded
	_query.margin = 0.0
	var pass_exclusions: Array[RID] = excluded.duplicate()
	var contact_fractions := PackedFloat32Array()
	if _collect_overlaps(space, pass_exclusions, excluded, direction):
		contact_fractions.append(0.0)

	# A Jolt cast reports travel fractions. Find bodies at the impact pose and exclude them
	# before recasting so another body farther along the same pass can also be reported.
	if not motion.is_zero_approx():
		_query.motion = motion
		for index in MAX_QUERY_RESULTS:
			_query.transform = pose
			_query.margin = 0.0
			_query.exclude = pass_exclusions
			if not space.cast_motion_into(_query, _cast):
				break
			var impact_fraction := _cast.unsafe_fraction
			_query.transform = _at_offset(pose, motion * impact_fraction)
			_query.margin = CONTACT_MARGIN
			if not _collect_overlaps(space, pass_exclusions, excluded, direction):
				break
			contact_fractions.append(impact_fraction)

	if show_sweeps and debug_draw_duration > 0.0:
		var draw_pass := DrawPass.new()
		draw_pass.pose = pose
		draw_pass.size = size
		draw_pass.motion = motion
		draw_pass.contacts = contact_fractions
		draw_pass.expires_at = Time.get_ticks_msec() + roundi(debug_draw_duration * 1000.0)
		_draw_passes.append(draw_pass)
		_draw_dirty = true
		set_process(true)


func _collect_overlaps(
		space: PhysicsDirectSpaceState3D,
		exclusions: Array[RID],
		source_exclusions: Array[RID],
		direction: Vector3
) -> bool:
	var overlaps := space.intersect_shape(_query, MAX_QUERY_RESULTS)
	for overlap in overlaps:
		var rid: RID = overlap["rid"]
		if not exclusions.has(rid):
			exclusions.append(rid)
	for overlap in overlaps:
		var collider := overlap["collider"] as Node3D
		if not is_instance_valid(collider):
			continue
		var collider_id := collider.get_instance_id()
		if _contacted.has(collider_id):
			continue
		_contacted[collider_id] = true
		world_contact.emit(collider)
		if not is_instance_valid(collider) or direction.is_zero_approx():
			continue
		var body := collider as CollisionObject3D
		if body == null:
			continue
		var receivers := _find_hit_receivers(body)
		if not receivers.is_empty() or surface_contact.has_connections():
			_report_surface_contact(space, body, overlap["rid"], exclusions, source_exclusions, direction, receivers)
	return not overlaps.is_empty()


func _report_surface_contact(
		space: PhysicsDirectSpaceState3D,
		body: CollisionObject3D,
		rid: RID,
		exclusions: Array[RID],
		source_exclusions: Array[RID],
		direction: Vector3,
		receivers: Array[Node]
) -> void:
	# Query this body alone so a closer overlapping wall cannot supply the target's point.
	var other_bodies := exclusions.duplicate()
	other_bodies.erase(rid)
	_surface_query.exclude = other_bodies
	_surface_query.collision_mask = collision_mask
	_surface_query.transform = _query.transform
	_surface_query.margin = CONTACT_MARGIN
	if not space.get_rest_info_into(_surface_query, _surface):
		return
	if _surface.collider_rid != rid or _surface.normal.is_zero_approx():
		return
	var point := _surface.point
	var normal := _surface.normal.normalized()
	surface_contact.emit(body, point, normal, direction)
	for receiver in receivers:
		if not is_instance_valid(body):
			break
		if not is_instance_valid(receiver):
			continue
		var receiver_id := receiver.get_instance_id()
		if not _hit_receivers.has(receiver_id):
			_hit_receivers[receiver_id] = true
			receiver.call(&"receive_hit", body, point, normal, direction, source_exclusions.duplicate())


func _find_hit_receivers(body: CollisionObject3D) -> Array[Node]:
	var receiver: Node
	var blood: BloodComponent
	var node: Node = body
	while node != null and (receiver == null or blood == null):
		if receiver == null and node.has_method(&"receive_hit"):
			receiver = node
		if blood == null:
			for child in node.get_children():
				if child is BloodComponent:
					blood = child
					break
		node = node.get_parent()

	var receivers: Array[Node] = []
	if receiver != null and not _hit_receivers.has(receiver.get_instance_id()):
		receivers.append(receiver)
	if blood != null and not _hit_receivers.has(blood.get_instance_id()):
		receivers.append(blood)
	return receivers


func _blade_size(reach: MeleeAttackReach = null) -> Vector3:
	if _start == null or _end == null:
		return Vector3.ZERO
	var span := _end.global_position - _start.global_position
	if span.is_zero_approx():
		return Vector3.ZERO
	var base_length := span.length()
	var length := reach.resolve_length(base_length) if reach != null else base_length
	return Vector3(length, maxf(width, 0.001), maxf(height, 0.001))


func _update_preview() -> void:
	var size := _blade_size(preview_reach) if show_editor_preview else Vector3.ZERO
	if size.x <= 0.0:
		if not _preview_size.is_zero_approx():
			_draw_mesh.clear_surfaces()
			_preview_size = Vector3.ZERO
		return

	var blade := _place_blade(sample_pose(), preview_reach)
	var center := _at_offset(blade, blade.basis.x * size.x * 0.5)
	if _preview_pose.is_equal_approx(center) and _preview_size.is_equal_approx(size):
		return

	_preview_pose = center
	_preview_size = size
	_draw_mesh.clear_surfaces()
	_draw_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _draw_material)
	_draw_mesh.surface_set_color(SWEEP_COLOR)
	_add_edges(_box_corners(center, size))
	_draw_mesh.surface_end()


func _redraw() -> void:
	_draw_mesh.clear_surfaces()
	if _draw_passes.is_empty():
		return
	_draw_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _draw_material)
	for draw_pass in _draw_passes:
		_draw_mesh.surface_set_color(SWEEP_COLOR)
		var corners := _box_corners(draw_pass.pose, draw_pass.size)
		_add_edges(corners)
		if not draw_pass.motion.is_zero_approx():
			_add_edges(corners, draw_pass.motion)
			for corner in corners:
				_draw_mesh.surface_add_vertex(corner)
				_draw_mesh.surface_add_vertex(corner + draw_pass.motion)

		_draw_mesh.surface_set_color(CONTACT_COLOR)
		for fraction in draw_pass.contacts:
			_add_edges(corners, draw_pass.motion * fraction)
	_draw_mesh.surface_end()


func _add_edges(corners: PackedVector3Array, offset := Vector3.ZERO) -> void:
	for edge: Vector2i in BOX_EDGES:
		_draw_mesh.surface_add_vertex(corners[edge.x] + offset)
		_draw_mesh.surface_add_vertex(corners[edge.y] + offset)


static func _box_corners(pose: Transform3D, size: Vector3) -> PackedVector3Array:
	var half := size * 0.5
	var corners := PackedVector3Array()
	for index in 8:
		var x := half.x if index & 1 else -half.x
		var y := half.y if index & 2 else -half.y
		var z := half.z if index & 4 else -half.z
		corners.append(pose * Vector3(x, y, z))
	return corners


static func _at_offset(pose: Transform3D, offset: Vector3) -> Transform3D:
	return Transform3D(pose.basis, pose.origin + offset)


static func _place_blade(pose: Transform3D, reach: MeleeAttackReach) -> Transform3D:
	if reach == null:
		return pose
	return _at_offset(pose, pose.basis.x * reach.blade_offset)


class DrawPass:
	var pose: Transform3D
	var size: Vector3
	var motion: Vector3
	var contacts: PackedFloat32Array
	var expires_at: int
