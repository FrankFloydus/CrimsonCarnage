class_name AbilityCast
extends RefCounted
## One activation's runtime state, independent of the shared ability and execution resources.

var grant_spec: GameplayAbilitySpec
var definition: AbilityDefinition:
	get:
		return grant_spec.definition
var context: GameplayEffectContext
var trigger_event_tag: StringName
var trigger_event_payload: Dictionary = {}
var data: Dictionary = {}
var elapsed: float = 0.0
var released: bool = false
var finished: bool = false
var committed: bool = false
var granted_tags: PackedStringArray = PackedStringArray()
var blocked_ability_tags: PackedStringArray = PackedStringArray()
var _committing: bool = false
var _system: WeakRef
var _animation_speed_multiplier: float = 1.0
var _tasks: Array[AbilityTask] = []


func _init(system: AbilitySystem, grant: GameplayAbilitySpec) -> void:
	_system = weakref(system)
	grant_spec = grant
	context = capture_context(system, grant.definition, grant.get_weapon_source())
	context.source_object = grant.source_object
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


## Rechecks and applies this cast's cost and cooldown effects at most once.
func commit() -> bool:
	var system := get_system()
	return system != null and system.commit_ability(self)


## Creates an outgoing effect spec at this ability grant's level.
func make_effect_spec(effect: GameplayEffectDefinition) -> GameplayEffectSpec:
	var system := get_system()
	if system == null or system.effects == null:
		return null
	var spec := system.effects.make_effect_spec(effect, context)
	if spec != null:
		spec.level = grant_spec.level
		grant_spec.copy_set_by_caller_to(spec)
	return spec


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


## Registers one task before starting it so immediate callbacks can safely end the cast.
func start_task(task: AbilityTask) -> bool:
	if task == null or not task._attach(self):
		return false
	_tasks.append(task)
	task._start()
	return true


func _remove_task(task: AbilityTask) -> void:
	_tasks.erase(task)


func _advance_tasks(delta: float) -> void:
	for task: AbilityTask in _tasks.duplicate():
		if task.is_active():
			task._advance(delta)


func _dispatch_task_gameplay_event(tag: StringName, payload: Dictionary) -> void:
	for task: AbilityTask in _tasks.duplicate():
		if task.is_active():
			task._receive_gameplay_event(tag, payload)


func _dispatch_task_input_release() -> void:
	for task: AbilityTask in _tasks.duplicate():
		if task.is_active():
			task._input_released()


func _complete_animation_task(was_interrupted: bool) -> bool:
	for task: AbilityTask in _tasks.duplicate():
		if task is AbilityTaskPlayAnimationAndWait and task._started:
			task._finish_playback(was_interrupted)
			return true
	return false


func _stop_tasks(was_cancelled: bool) -> void:
	for task: AbilityTask in _tasks.duplicate():
		if task.is_active():
			task._end_from_cast(was_cancelled)
