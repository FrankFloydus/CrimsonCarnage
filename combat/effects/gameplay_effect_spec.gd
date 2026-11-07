class_name GameplayEffectSpec
extends RefCounted
## Per-application copy of effect data, source context and caller-supplied magnitudes.

var definition: GameplayEffectDefinition
var context: GameplayEffectContext
var settings: GameplayEffectDefinition
var level: float = 1.0
## Requested stack count on an outgoing spec and the aggregate count on an active copy.
var stack_count: int = 1
var duration: float:
	get:
		return settings.duration if settings != null else 0.0
var period: float:
	get:
		return settings.period if settings != null else 0.0
var modifiers: Array[AttributeModifier]:
	get:
		return settings.modifiers if settings != null else []
var executions: Array[GameplayEffectExecution]:
	get:
		return settings.executions if settings != null else []

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
	result._set_by_caller = _set_by_caller.duplicate()
	return result
