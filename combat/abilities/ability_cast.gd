class_name AbilityCast
extends RefCounted
## One activation's runtime state, independent of the shared ability and execution resources.

## Current execution phase used by interruption and movement policies.
enum Phase {
	## The cast is preparing its first release or beginning sustained work.
	WINDUP,
	## Release conditions are being resolved and release-based payment can commit.
	RELEASE,
	## The activation is producing or waiting between channel pulses.
	CHANNEL,
	## The payload has been released and the cast is completing recovery.
	RECOVERY,
}

var grant_spec: GameplayAbilitySpec
var definition: AbilityDefinition:
	get:
		return grant_spec.definition
var context: GameplayEffectContext
var trigger_event_tag: StringName
var trigger_event_payload: Dictionary = {}
var target_request: AbilitySystem:
	get:
		return _target.get_ref() as AbilitySystem if _target != null else null
var phase: Phase = Phase.WINDUP
var spend_receipt: ResourceSpendReceipt
var data: Dictionary = {}
var elapsed: float = 0.0
var released: bool = false:
	set(value):
		released = value
		if released:
			_stop_casting_cue()
var finished: bool = false
var committed: bool = false
var granted_tags: PackedStringArray = PackedStringArray()
var blocked_ability_tags: PackedStringArray = PackedStringArray()
var _committing: bool = false
var _cancelled: bool = false
var _cost_committed: bool = false
var _cooldown_committed: bool = false
var _charge_receipt: int = 0
var _charge_pool: AbilityChargePool
var _reserved_costs: Dictionary[int, float] = {}
var _target: WeakRef
var _system: WeakRef
var _animation_speed_multiplier: float = 1.0
var _tasks: Array[AbilityTask] = []
var _active_casting_cue: StringName


func _init(
		system: AbilitySystem, grant: GameplayAbilitySpec, target: AbilitySystem = null
) -> void:
	_system = weakref(system)
	if is_instance_valid(target):
		_target = weakref(target)
	grant_spec = grant
	context = capture_context(system, grant.definition, grant.get_weapon_source())
	context.source_object = grant.source_object
	context.outcome_context.set_execution_identity(grant.definition.ability_id, grant.definition.display_name)
	context.outcome_context.set_execution_reactions(grant.definition.reactions)
	context.outcome_context.capture_amount_basis(context.ability_tags, grant.level)
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


## Rechecks and pays this cast's release-based costs and charge at most once.
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


func _start_casting_cue() -> void:
	var cue := definition.casting_cue
	var system := get_system()
	if cue.is_empty() or system == null or system.effects == null:
		return
	_active_casting_cue = cue
	system.effects.cues.dispatch_cast(true, system.attributes, context, cue, get_instance_id())


func _stop_casting_cue() -> void:
	var cue := _active_casting_cue
	if cue.is_empty():
		return
	_active_casting_cue = &""
	var system := get_system()
	if system != null and system.effects != null:
		system.effects.cues.dispatch_cast(false, system.attributes, context, cue, get_instance_id())


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
