class_name GameplayAbilitySpec
extends RefCounted
## One grant of an authored ability on an actor. Activations own their own state.

static var _next_handle: int = 1

var handle: int:
	get:
		return _handle
var definition: AbilityDefinition:
	get:
		return _definition
var level: int:
	get:
		return _level
var source_object: Object:
	get:
		return _source_object if is_instance_valid(_source_object) else null
var granting_effect_handle: int:
	get:
		return _granting_effect_handle
var remove_on_end: bool = false

var _handle: int
var _definition: AbilityDefinition
var _level: int
var _source_object: Object
var _granting_effect_handle: int
var _set_by_caller: Dictionary[StringName, float]


func _init(
		ability: AbilityDefinition, grant_level: int, source: Object,
		effect_handle: int, set_by_caller: Dictionary[StringName, float]
) -> void:
	_handle = _next_handle
	_next_handle += 1
	_definition = ability
	_level = grant_level
	_source_object = source
	_granting_effect_handle = effect_handle
	_set_by_caller = set_by_caller.duplicate()


## The prototype's physical calculations optionally use a runtime weapon profile.
func get_weapon_source() -> WeaponDefinition:
	return source_object as WeaponDefinition


func copy_set_by_caller_to(effect_spec: GameplayEffectSpec) -> void:
	for tag in _set_by_caller:
		effect_spec.set_by_caller_magnitude(tag, _set_by_caller[tag])
