@tool
class_name AbilityDeliveryDefinition
extends Resource
## Describes how an activation produces contacts and how long delivery remains owned.

## Determines when and how the selected contacts reach delivery phases.
enum Kind {
	## Send the selected contacts to the impact phase without travel.
	DIRECT,
	## Send the result of a physics ray to the impact phase without travel.
	HITSCAN,
	## Launch the saved carrier and use its first swept collision as the impact.
	PROJECTILE,
	## Send one complete spatial selection to the impact phase and report its confirmed count.
	AREA_BURST,
	## Place a timed area on terrain and report occupancy changes and periodic ticks.
	FIELD,
	## Attach a timed area to the casting actor and update occupants as it moves.
	AURA,
	## Place a timed area on terrain and detonate once when an eligible actor is present after arming.
	TRAP,
	## Requery a physics ray for each channel pulse and stop when it has no contact.
	BEAM,
	## Run ability phases without creating a delivery or emitting an impact.
	NONE,
	## Deliver an initial impact and hop to the nearest eligible actor that the chain has yet to visit.
	CHAIN,
}

## Direct sends selected contacts immediately. Hitscan traces a ray. Projectile uses a flight scene.
## Area Burst resolves one area. Field stays on terrain. Aura follows the caster.
## Trap detonates after arming. Beam repeats a ray each pulse. Chain hops to new contacts.
## None runs the ability's own phases without a delivery.
@export var kind: Kind = Kind.DIRECT:
	set(value):
		kind = value
		notify_property_list_changed()
## Saved scene with an AbilityProjectile root. Its scene owns speed, lifetime and collision.
@export var projectile_scene: PackedScene
## Projectile spawn offset in the casting socket's local coordinates, in meters.
@export var spawn_offset: Vector3 = Vector3.ZERO
## A launched projectile or area continues independently if the caster is interrupted.
@export var detach_on_cancel: bool = true
## Occupant query used by Field, Aura and Trap. Its origin must be Contact.
@export var area_targeting: AbilityTargetingDefinition
## Lifetime of a placed field, aura or trap in seconds.
@export_range(0.01, 120.0, 0.01, "or_greater") var lifetime: float = 1.0
## Time between Field/Aura ticks, in seconds. Zero emits only enter, exit and expiration.
@export_range(0.0, 60.0, 0.01, "or_greater") var period: float = 0.0
## Delay before a trap detects its first eligible actor, in seconds.
@export_range(0.0, 60.0, 0.01, "or_greater") var arm_delay: float = 0.0
## Steepest terrain surface on which a field or trap can be placed, measured from world up.
@export_range(0.0, 180.0, 0.1) var maximum_surface_slope: float = 90.0
## Contact-centered sphere used to select each chain hop.
@export var chain_targeting: AbilityTargetingDefinition
## Maximum number of new contacts after the initial chain target.
@export_range(0, 31, 1) var chain_hops: int = 2:
	set(value):
		chain_hops = value
		notify_property_list_changed()
## End the chain when a selected contact does not confirm a hit.
@export var stop_chain_on_failed_hit: bool = false


func _validate_property(property: Dictionary) -> void:
	var visible := true
	match property.name:
		&"projectile_scene", &"spawn_offset":
			visible = kind == Kind.PROJECTILE
		&"detach_on_cancel":
			visible = kind == Kind.PROJECTILE or is_persistent()
		&"area_targeting", &"lifetime":
			visible = is_persistent()
		&"period":
			visible = _uses_period()
		&"arm_delay":
			visible = kind == Kind.TRAP
		&"maximum_surface_slope":
			visible = _uses_placement_surface()
		&"chain_hops":
			visible = kind == Kind.CHAIN
		&"chain_targeting", &"stop_chain_on_failed_hit":
			visible = kind == Kind.CHAIN and chain_hops > 0
	if not visible:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if kind < Kind.DIRECT or kind > Kind.CHAIN:
		return &"invalid_delivery_kind"
	if kind == Kind.PROJECTILE:
		if not spawn_offset.is_finite():
			return &"invalid_projectile_offset"
		if projectile_scene == null or not projectile_scene.can_instantiate():
			return &"missing_projectile"
		var node := projectile_scene.instantiate()
		var projectile := node as AbilityProjectile
		var error := &"invalid_projectile_root"
		if projectile != null:
			# Read the saved exports directly so validation also works on an editor placeholder.
			var speed := float(projectile.get(&"speed"))
			var flight_lifetime := float(projectile.get(&"lifetime"))
			error = &"" if is_finite(speed) and speed > 0.0 \
					and is_finite(flight_lifetime) and flight_lifetime > 0.0 else &"invalid_projectile_flight"
		if node != null:
			node.free()
		return error
	if is_persistent():
		if area_targeting == null or area_targeting.origin != AbilityTargetingDefinition.Origin.CONTACT \
				or area_targeting.shape < AbilityTargetingDefinition.Shape.SPHERE:
			return &"missing_delivery_area"
		if not is_finite(lifetime) or lifetime <= 0.0:
			return &"invalid_delivery_timing"
		if _uses_period() and (not is_finite(period) or period < 0.0 \
				or (period > 0.0 and (period < 0.001 or lifetime / period > 10000.0))):
			return &"invalid_delivery_timing"
		if kind == Kind.TRAP and (not is_finite(arm_delay) or arm_delay < 0.0 or arm_delay >= lifetime):
			return &"invalid_delivery_timing"
		if _uses_placement_surface() and (not is_finite(maximum_surface_slope) \
				or maximum_surface_slope < 0.0 or maximum_surface_slope > 180.0):
			return &"invalid_placement_slope"
		return area_targeting.get_validation_error()
	if kind == Kind.CHAIN:
		if chain_hops < 0 or chain_hops > 31:
			return &"invalid_chain_hop_count"
		if chain_hops > 0:
			if chain_targeting == null or chain_targeting.origin != AbilityTargetingDefinition.Origin.CONTACT \
					or chain_targeting.shape != AbilityTargetingDefinition.Shape.SPHERE:
				return &"chain_requires_contact_sphere"
			return chain_targeting.get_validation_error()
	return &""


func is_persistent() -> bool:
	return kind == Kind.FIELD or kind == Kind.AURA or kind == Kind.TRAP


func _uses_period() -> bool:
	return kind == Kind.FIELD or kind == Kind.AURA


func _uses_placement_surface() -> bool:
	return kind == Kind.FIELD or kind == Kind.TRAP


## Checks the selected geometry before release can commit a placed field or trap.
func get_placement_error(targets: AbilityTargetSet) -> StringName:
	if not _uses_placement_surface():
		return &""
	if targets.contacts.is_empty() or not targets.contacts[0].has_geometry:
		return &"placement_surface_missing"
	var contact := targets.contacts[0]
	if contact.actor_id != 0 or contact.normal.is_zero_approx():
		return &"invalid_placement_surface"
	return &"" if rad_to_deg(contact.normal.angle_to(Vector3.UP)) <= maximum_surface_slope \
			else &"placement_surface_too_steep"


func get_outcome_kind() -> StringName:
	match kind:
		Kind.DIRECT: return &"direct"
		Kind.HITSCAN: return &"hitscan"
		Kind.PROJECTILE: return &"projectile"
		Kind.AREA_BURST: return &"area_burst"
		Kind.FIELD: return &"field"
		Kind.AURA: return &"aura"
		Kind.TRAP: return &"trap"
		Kind.BEAM: return &"beam"
		Kind.CHAIN: return &"chain"
	return &"none"
