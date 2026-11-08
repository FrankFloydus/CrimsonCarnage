@tool
class_name AbilityTargetingDefinition
extends Resource
## Selects actors and world points independently of effects and delivery.

## Geometry or actor selection used by the target query.
enum Shape {
	## Select the casting actor.
	SELF,
	## Select the explicitly requested actor when it meets range and target filters.
	SINGLE,
	## Trace forward and return an eligible actor or permitted world surface on first contact.
	RAY,
	## Trace forward for geometry and fall back to the aim endpoint when unobstructed.
	POINT,
	## Select actor origins within a three-dimensional radius.
	SPHERE,
	## Select actor origins within a planar radius and the configured vertical tolerance.
	DISK,
	## Select actor origins within a cylinder defined by its radius, up axis and half-height.
	CYLINDER,
	## Select actor origins within the forward aperture and radial distance.
	CONE,
	## Select actor origins inside the query transform's oriented box.
	BOX,
	## Select actor origins within a radius of a segment along the configured up axis.
	CAPSULE,
}

## Transform used as the query's position and orientation.
enum Origin {
	## Use the casting actor's physics body or spatial parent.
	CASTER,
	## Use the actor's aim transform, falling back to its cast socket.
	AIM,
	## Use the scene transform assigned as the actor's cast origin.
	SOCKET,
	## Use the incoming delivery contact's position and orientation.
	CONTACT,
}

## Relationship filter applied alongside the other target requirements.
enum Allegiance {
	## Accept any relationship that passes the rest of the query.
	ANY,
	## Require a target faction in the caster's explicit hostile list.
	HOSTILE,
	## Require the caster or an actor in the same nonempty faction.
	FRIENDLY,
	## Require a target outside the caster's friendly and hostile relationships.
	NEUTRAL,
}

## Self selects the caster. Single uses the requested actor. Ray selects its first permitted contact.
## Point uses geometry or the aim endpoint. Sphere, Disk, Cylinder, Cone, Box, and Capsule select
## actor origins inside their configured volumes.
@export var shape: Shape = Shape.SELF:
	set(value):
		shape = value
		notify_property_list_changed()
## Caster uses the actor origin. Aim uses the aim transform. Socket uses the cast origin.
## Contact uses the incoming delivery's position and orientation.
@export var origin: Origin = Origin.CASTER
## Maximum distance in meters for Single, Ray or Point. Zero Point uses the forward axis.
@export_range(0.0, 500.0, 0.1, "or_greater") var max_range: float = 100.0
## Horizontal radius in meters for a disk or cylinder, or radial size for sphere, cone and capsule.
@export_range(0.0, 100.0, 0.1, "or_greater") var radius: float = 1.0
## Vertical tolerance in meters above and below the center of a disk or cylinder.
## Capsule uses this as the half-length of its cylindrical segment.
@export_range(0.0, 100.0, 0.1, "or_greater") var half_height: float = 2.0
## World-space vertical direction for ground shapes and capsules.
@export var up_axis: Vector3 = Vector3.UP
## Box half extents in meters along the query transform's local axes.
@export var half_extents: Vector3 = Vector3.ONE
## Full cone aperture in degrees. The cone points along the origin's local forward axis.
@export_range(0.0, 360.0, 0.1) var angle_degrees: float = 90.0
## Applies an explicit nearest-first target cap. Zero includes every eligible actor.
@export_range(0, 1024, 1, "or_greater") var max_targets: int = 0
## Layers used by ray/LOS queries and by filters for actors with a registered physics body.
@export_flags_3d_physics var collision_mask: int = 1
## Requires an unobstructed ray from the query origin to each candidate.
@export var require_line_of_sight: bool = false
## Any leaves relationships unrestricted. Hostile uses the caster's Hostile Factions list.
## Friendly accepts the caster or the same faction. Neutral accepts actors outside both relationships.
@export var allegiance: Allegiance = Allegiance.ANY
## Permits a Ray to expose world geometry as a contact without a target actor.
@export var allow_world_surfaces: bool = false
## Includes the casting actor among non-Self selections.
@export var include_caster: bool = false
## Includes actors with no remaining Health.
@export var include_dead: bool = false
## Includes actors with positive Health.
@export var include_living: bool = true
## All these hierarchical tags must be present on an eligible target.
@export var required_target_tags: PackedStringArray = PackedStringArray()
## An eligible target cannot own any of these hierarchical tags.
@export var blocked_target_tags: PackedStringArray = PackedStringArray()


func _validate_property(property: Dictionary) -> void:
	var visible := true
	match property.name:
		&"max_range":
			visible = _uses_range()
		&"radius":
			visible = _uses_radius()
		&"half_height", &"up_axis":
			visible = _uses_axial_height()
		&"half_extents":
			visible = shape == Shape.BOX
		&"angle_degrees":
			visible = shape == Shape.CONE
		&"max_targets":
			visible = _uses_area()
		&"collision_mask", &"include_caster":
			visible = shape != Shape.SELF
		&"require_line_of_sight":
			visible = shape == Shape.SINGLE or _uses_area()
		&"allow_world_surfaces":
			visible = shape == Shape.RAY
	if not visible:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if shape < Shape.SELF or shape > Shape.CAPSULE or origin < Origin.CASTER \
			or origin > Origin.CONTACT or allegiance < Allegiance.ANY \
			or allegiance > Allegiance.NEUTRAL:
		return &"invalid_targeting_mode"
	if (_uses_range() and (not is_finite(max_range) or max_range < 0.0)) \
			or (_uses_radius() and (not is_finite(radius) or radius < 0.0)) \
			or (_uses_axial_height() and (not is_finite(half_height) or half_height < 0.0)) \
			or (_uses_area() and max_targets < 0):
		return &"invalid_targeting_distance"
	if (_uses_axial_height() and (not up_axis.is_finite() or up_axis.is_zero_approx())) \
			or (shape == Shape.BOX and (not half_extents.is_finite() \
			or half_extents.x < 0.0 or half_extents.y < 0.0 or half_extents.z < 0.0)):
		return &"invalid_targeting_axes"
	if shape == Shape.CONE and (not is_finite(angle_degrees) or angle_degrees < 0.0 \
			or angle_degrees > 360.0):
		return &"invalid_targeting_angle"
	return &""


func _uses_range() -> bool:
	return shape == Shape.SINGLE or shape == Shape.RAY or shape == Shape.POINT


func _uses_area() -> bool:
	return shape >= Shape.SPHERE and shape <= Shape.CAPSULE


func _uses_radius() -> bool:
	return _uses_area() and shape != Shape.BOX


func _uses_axial_height() -> bool:
	return shape == Shape.DISK or shape == Shape.CYLINDER or shape == Shape.CAPSULE


## Checks actor eligibility without doing a physics query or consuming random values.
func accepts(
		source: AbilitySystem, target: AbilitySystem, attribution: AbilityTargetSet = null
) -> bool:
	if not is_instance_valid(target) or not target.is_inside_tree() \
			or not is_instance_valid(target.attributes):
		return false
	var self_target := target == source or (attribution != null \
			and attribution.source_id == target.get_instance_id())
	if self_target and not include_caster and shape != Shape.SELF:
		return false
	var body := actor_body(target)
	if body != null and (body.collision_layer & collision_mask) == 0 and shape != Shape.SELF:
		return false
	var is_living := target.attributes.get_value(CombatAttributes.Id.HEALTH) > 0.0
	if (is_living and not include_living) or (not is_living and not include_dead):
		return false
	if not target.tags.has_all(required_target_tags) or target.tags.has_any(blocked_target_tags):
		return false
	return allegiance == Allegiance.ANY \
			or _get_allegiance(source, target, attribution, self_target) == allegiance


## Resolves the authoring query in a physics callback when it needs space state.
func select(
		cast: AbilityCast, incoming: AbilityTargetSet = null
) -> AbilityTargetSet:
	return select_from(cast.get_system(), incoming, cast.target_request)


## Queries from an actor or detached contact. Exclusions are applied before the target cap.
func select_from(
		source: AbilitySystem, incoming: AbilityTargetSet = null,
		explicit_target: AbilitySystem = null, excluded_target_id: int = 0,
		visited_actor_ids: Dictionary[int, bool] = {}
) -> AbilityTargetSet:
	var result := AbilityTargetSet.new()
	var error := get_validation_error()
	if not error.is_empty():
		result.failure = error
		return result
	var has_source := is_instance_valid(source) and source.is_inside_tree()
	if not has_source and (origin != Origin.CONTACT or incoming == null):
		result.failure = &"missing_query_source"
		return result
	var spatial: Node3D
	if has_source:
		result.source_id = source.get_instance_id()
		result.source_faction = source.faction_id
		result.hostile_factions.assign(source.hostile_factions)
		spatial = actor_spatial(source)
		match origin:
			Origin.AIM:
				spatial = source.aim_origin if is_instance_valid(source.aim_origin) else source.cast_origin
			Origin.SOCKET:
				spatial = source.cast_origin
	if origin == Origin.CONTACT:
		if incoming == null:
			result.failure = &"missing_query_contact"
			return result
		result.copy_origin(incoming)
		if incoming.query_space != null:
			var carrier := incoming.query_space.get_ref() as Node3D
			if is_instance_valid(carrier) and carrier.is_inside_tree():
				spatial = carrier
	elif is_instance_valid(spatial) and spatial.is_inside_tree():
		result.transform = spatial.global_transform.orthonormalized()
	elif shape != Shape.SELF:
		result.failure = &"missing_query_origin"
		return result
	if is_instance_valid(spatial):
		result.query_space = weakref(spatial)
	match shape:
		Shape.SELF:
			if accepts(source, source):
				result.contacts.append(AbilityTargetContact.new(result.transform.origin, source))
		Shape.SINGLE:
			_add_single(result, source, explicit_target, max_range, spatial)
		Shape.RAY, Shape.POINT:
			_select_ray(result, source, spatial)
		_:
			_select_area(result, source, spatial, excluded_target_id, visited_actor_ids)
	return result


## Resolves a scene position through the actor's explicit body or spatial parent.
static func actor_spatial(system: AbilitySystem) -> Node3D:
	if not is_instance_valid(system):
		return null
	return system.actor_body if is_instance_valid(system.actor_body) \
			else system.get_parent() as Node3D


## Finds an actor's collision body for exclusion and layer filtering.
static func actor_body(system: AbilitySystem) -> CollisionObject3D:
	return actor_spatial(system) as CollisionObject3D


func _get_allegiance(
		source: AbilitySystem, target: AbilitySystem, attribution: AbilityTargetSet,
		self_target: bool
) -> Allegiance:
	if self_target:
		return Allegiance.FRIENDLY
	if target.faction_id.is_empty():
		return Allegiance.NEUTRAL
	var faction := source.faction_id if is_instance_valid(source) else &""
	var hostilities: Array[StringName] = []
	if is_instance_valid(source):
		hostilities = source.hostile_factions
	if attribution != null and attribution.source_id != 0:
		faction = attribution.source_faction
		hostilities = attribution.hostile_factions
	if faction == target.faction_id:
		return Allegiance.FRIENDLY
	if hostilities.has(target.faction_id):
		return Allegiance.HOSTILE
	return Allegiance.NEUTRAL


func _add_single(
		result: AbilityTargetSet, source: AbilitySystem, target: AbilitySystem,
		limit: float, spatial: Node3D
) -> void:
	var actor := actor_spatial(target)
	if not accepts(source, target, result) or not is_instance_valid(actor) or not actor.is_inside_tree():
		return
	var point := actor.global_position
	if point.distance_squared_to(result.transform.origin) > limit * limit:
		return
	if require_line_of_sight and not _has_sight(result.transform.origin, point, source, target, spatial):
		return
	result.contacts.append(AbilityTargetContact.new(point, target))


func _select_ray(result: AbilityTargetSet, source: AbilitySystem, spatial: Node3D) -> void:
	var start := result.transform.origin
	var end := start - result.transform.basis.z * max_range
	if max_range <= 0.0:
		if shape == Shape.POINT:
			result.contacts.append(AbilityTargetContact.new(start - result.transform.basis.z))
		return
	if not is_instance_valid(spatial) or spatial.get_world_3d() == null:
		result.failure = &"missing_query_space"
		return
	var hit := _ray(start, end, source, spatial)
	if hit.is_empty():
		if shape == Shape.POINT:
			result.contacts.append(AbilityTargetContact.new(end))
		return
	var target := AbilitySystem.find_for(hit["collider"] as Node)
	var accepted := target if accepts(source, target, result) else null
	if accepted != null or shape == Shape.POINT or allow_world_surfaces:
		result.contacts.append(AbilityTargetContact.new(hit["position"], accepted, hit["normal"], true))


func _select_area(
		result: AbilityTargetSet, source: AbilitySystem, spatial: Node3D,
		excluded_target_id: int, visited_actor_ids: Dictionary[int, bool]
) -> void:
	if not is_instance_valid(spatial) or not spatial.is_inside_tree():
		result.failure = &"missing_query_space"
		return
	var world := spatial.get_world_3d()
	var center := result.transform.origin
	for node: Node in spatial.get_tree().get_nodes_in_group(&"ability_actors"):
		var target := node as AbilitySystem
		if not accepts(source, target, result):
			continue
		var target_id := target.get_instance_id()
		if target_id == excluded_target_id or visited_actor_ids.has(target_id):
			continue
		var actor := actor_spatial(target)
		if not is_instance_valid(actor) or not actor.is_inside_tree() or actor.get_world_3d() != world:
			continue
		var point := actor.global_position
		if not _contains(point - center, result.transform.basis):
			continue
		if require_line_of_sight and not _has_sight(center, point, source, target, spatial):
			continue
		result.contacts.append(AbilityTargetContact.new(point, target))
	result.contacts.sort_custom(_is_nearer.bind(center))
	if max_targets > 0 and result.contacts.size() > max_targets:
		result.contacts.resize(max_targets)


func _contains(offset: Vector3, axes: Basis) -> bool:
	var distance_squared := offset.length_squared()
	match shape:
		Shape.DISK, Shape.CYLINDER, Shape.CAPSULE:
			var up := up_axis.normalized()
			var height := offset.dot(up)
			if shape == Shape.CAPSULE:
				return (offset - up * clampf(height, -half_height, half_height)).length_squared() \
						<= radius * radius
			return absf(height) <= half_height and (offset - up * height).length_squared() \
					<= radius * radius
		Shape.CONE:
			return distance_squared <= radius * radius and (offset.is_zero_approx() \
					or offset.normalized().dot(-axes.z) >= cos(deg_to_rad(angle_degrees * 0.5)))
		Shape.BOX:
			var local := axes.transposed() * offset
			return absf(local.x) <= half_extents.x and absf(local.y) <= half_extents.y \
					and absf(local.z) <= half_extents.z
	return distance_squared <= radius * radius


func _has_sight(
		from: Vector3, to: Vector3, source: AbilitySystem,
		target: AbilitySystem, spatial: Node3D
) -> bool:
	if from.is_equal_approx(to):
		return true
	if not is_instance_valid(spatial) or spatial.get_world_3d() == null:
		return false
	var hit := _ray(from, to, source, spatial)
	return hit.is_empty() or AbilitySystem.find_for(hit["collider"] as Node) == target


func _ray(from: Vector3, to: Vector3, source: AbilitySystem, spatial: Node3D) -> Dictionary:
	var excluded: Array[RID] = []
	var body := actor_body(source)
	if body != null:
		excluded.append(body.get_rid())
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, excluded)
	return spatial.get_world_3d().direct_space_state.intersect_ray(query)


func _is_nearer(
		left: AbilityTargetContact, right: AbilityTargetContact, center: Vector3
) -> bool:
	var left_distance := left.position.distance_squared_to(center)
	var right_distance := right.position.distance_squared_to(center)
	return left.actor_id < right.actor_id if left_distance == right_distance \
			else left_distance < right_distance
