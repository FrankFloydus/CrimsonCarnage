class_name GameplayEffectSpec
extends RefCounted
## Per-application copy of effect data, source context and caller-supplied magnitudes.

var definition: GameplayEffectDefinition
var context: GameplayEffectContext
var settings: GameplayEffectDefinition
var level: float = 1.0
## Requested stack count on an outgoing spec and the aggregate count on an active copy.
var stack_count: int = 1
## Per-application capture for semantic effect magnitudes.
var amount_snapshot: AmountEvaluationContext
## Optional amount supplied by the effect-owned behavior that accumulated it.
var accumulated_amount: float = NAN
## Per-target resistance changes this application's lifetime without changing shared settings.
var duration_scale: float = 1.0
## Per-target resistance changes this application's authored modifier magnitude only.
var modifier_scale: float = 1.0
var duration: float:
	get:
		return settings.duration * duration_scale if settings != null \
				and settings.timing == GameplayEffectDefinition.Timing.DURATION else 0.0
var period: float:
	get:
		return settings.get_effective_period() if settings != null else 0.0
var modifiers: Array[AttributeModifier]:
	get:
		return settings.modifiers if settings != null else []
var executions: Array[GameplayEffectExecution]:
	get:
		return settings.executions if settings != null and settings.executes_calculations() else []

var _set_by_caller: Dictionary[StringName, float] = {}


func _init(effect: GameplayEffectDefinition = null, source: GameplayEffectContext = null) -> void:
	definition = effect
	if effect != null:
		settings = effect.duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as GameplayEffectDefinition
	if source != null:
		context = source.with_critical_result(source.is_critical, source.critical_multiplier,
				source.critical_damage_percent)


## Supplies a finite magnitude for a tagged value consumed by this application only.
func set_by_caller_magnitude(tag: StringName, value: float) -> void:
	if not tag.is_empty() and is_finite(value):
		_set_by_caller[tag] = value


func get_set_by_caller_magnitude(tag: StringName, fallback: float = 0.0) -> float:
	return _set_by_caller.get(tag, fallback)


## Provides a detached copy for an ability granted by this effect.
func get_set_by_caller_magnitudes() -> Dictionary[StringName, float]:
	return _set_by_caller.duplicate()


## A retained application owns a separate copy so callers can reuse or edit their outgoing spec.
func copy_for_application() -> GameplayEffectSpec:
	var result := GameplayEffectSpec.new(settings, context)
	result.definition = definition
	result.level = level
	result.stack_count = stack_count
	result.amount_snapshot = amount_snapshot
	result.accumulated_amount = accumulated_amount
	result.duration_scale = duration_scale
	result.modifier_scale = modifier_scale
	result._set_by_caller = _set_by_caller.duplicate()
	return result


## Executes using the active instance's frozen settings with an independent timing context.
func copy_for_execution() -> GameplayEffectSpec:
	var result := GameplayEffectSpec.new(null, context)
	result.definition = definition
	result.settings = settings
	result.level = level
	result.stack_count = stack_count
	result.amount_snapshot = amount_snapshot
	result.accumulated_amount = accumulated_amount
	result.duration_scale = duration_scale
	result.modifier_scale = modifier_scale
	result._set_by_caller = _set_by_caller.duplicate()
	return result
