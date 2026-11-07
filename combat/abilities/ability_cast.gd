class_name AbilityCast
extends RefCounted
## One activation's runtime state, independent of the shared ability and execution resources.

var definition: AbilityDefinition
var context: GameplayEffectContext
var trigger_event_tag: StringName
var trigger_event_payload: Dictionary = {}
var data: Dictionary = {}
var elapsed: float = 0.0
var released: bool = false
var finished: bool = false
var granted_tags: PackedStringArray = PackedStringArray()
var _system: WeakRef
var _animation_speed_multiplier: float = 1.0


func _init(system: AbilitySystem, ability: AbilityDefinition, source: WeaponDefinition = null) -> void:
	_system = weakref(system)
	definition = ability
	context = capture_context(system, ability, source)
	var speed_attribute := CombatAttributes.Id.NONE
	if GameplayEffectContext.is_spell_delivery(context.ability_tags):
		speed_attribute = CombatAttributes.Id.CAST_SPEED
	else:
		for tag: String in context.ability_tags:
			if GameplayTagSet.matches(StringName(tag), &"Ability.Attack"):
				speed_attribute = CombatAttributes.Id.ATTACK_SPEED
				break
	if speed_attribute != CombatAttributes.Id.NONE:
		_animation_speed_multiplier += context.get_source_value(
				speed_attribute, context.ability_tags) / 100.0


## Uses the same weapon and action snapshot for activation and preview.
static func capture_context(
		system: AbilitySystem, ability: AbilityDefinition, source: WeaponDefinition
) -> GameplayEffectContext:
	var result := system.create_effect_context(ability.get_context_tags())
	result.bind_weapon(source)
	result.ability_id = ability.ability_id
	result.ability_name = ability.display_name
	return result


func get_system() -> AbilitySystem:
	return _system.get_ref() as AbilitySystem


## Applies the speed sampled at activation to the authored animation or weapon cycle.
func get_animation_playback_rate(animation_length: float) -> float:
	if context.has_physical_weapon() \
			and not GameplayEffectContext.is_spell_delivery(context.ability_tags):
		return animation_length / context.weapon_power_coefficient * _animation_speed_multiplier
	return _animation_speed_multiplier


func finish() -> void:
	var system := get_system()
	if system != null:
		system.complete_cast(self, false)


func cancel() -> void:
	var system := get_system()
	if system != null:
		system.complete_cast(self, true)
