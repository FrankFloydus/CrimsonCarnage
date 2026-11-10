class_name BloodImpact3D
extends Node3D
## Presents blood hits and owns the internal world droplet and decal pool.

const PRESENTER_SCENE := "res://scenes/effects/blood_impact.tscn"
const WORLD_SCENE := preload("res://scenes/effects/blood_world.tscn")
const BloodWorld := preload("res://scripts/effects/blood_world.gd")

## Blood profile used when the hit receiver has no preset assigned.
@export var default_profile: BloodProfile

var _world: BloodWorld
var _spray_variants: Array[int] = []
var _last_spray_variant := -1


## Finds or creates the shared presenter in the target's level branch of its viewport.
static func for_target(target: Node) -> BloodImpact3D:
	var viewport := target.get_viewport()
	var scope := target.get_parent()
	while scope != viewport and scope.get_parent() != viewport:
		scope = scope.get_parent()
	for child in scope.get_children(true):
		if child is BloodImpact3D:
			return child as BloodImpact3D

	var scene := load(PRESENTER_SCENE) as PackedScene
	var presenter := scene.instantiate() as BloodImpact3D
	scope.add_child(presenter, false, Node.INTERNAL_MODE_BACK)
	return presenter


func _ready() -> void:
	_world = WORLD_SCENE.instantiate() as BloodWorld
	add_child(_world, false, Node.INTERNAL_MODE_BACK)


## Starts the airborne burst and shared world deposits for a receiver's accepted hit.
func play_hit(
		profile: BloodProfile, point: Vector3, origin: Vector3, normal: Vector3,
		direction: Vector3, excluded: Array[RID]
) -> void:
	if profile != null and profile.burst_scene != null:
		_spawn_burst(profile, origin, normal, direction)
	_world.spawn_droplet(point, direction, excluded, true, profile)


func _spawn_burst(profile: BloodProfile, origin: Vector3, normal: Vector3, direction: Vector3) -> void:
	var instance := profile.burst_scene.instantiate()
	var burst := instance as BloodBurst3D
	if burst == null:
		instance.free()
		push_warning("The blood burst scene needs a BloodBurst3D root.")
		return
	add_child(burst)
	burst.play(origin, normal, direction, _next_spray_variant(), profile)


func _next_spray_variant() -> int:
	if _spray_variants.is_empty():
		for index in BloodBurst3D.VARIATION_COUNT:
			_spray_variants.append(index)
		_spray_variants.shuffle()
		if _spray_variants.back() == _last_spray_variant:
			_spray_variants.push_front(_spray_variants.pop_back())
	_last_spray_variant = _spray_variants.pop_back()
	return _last_spray_variant
