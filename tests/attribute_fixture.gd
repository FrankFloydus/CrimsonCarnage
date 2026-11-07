extends RefCounted
## Test-owned startup values and effect definitions for exact numerical assertions.

const REGENERATION_EXECUTION = preload("res://combat/effects/calculations/resource_regeneration_execution.gd")
const REGENERATION_PERIOD: float = 0.1

const STARTUP_BASES: Dictionary[int, float] = {
	CombatAttributes.Id.STRENGTH: 10.0,
	CombatAttributes.Id.DEXTERITY: 10.0,
	CombatAttributes.Id.INTELLECT: 10.0,
	CombatAttributes.Id.VITALITY: 10.0,
	CombatAttributes.Id.MAX_HEALTH: 100.0,
	CombatAttributes.Id.MAX_STAMINA: 50.0,
	CombatAttributes.Id.MAX_MANA: 50.0,
	CombatAttributes.Id.CARRY_CAPACITY: 80.0,
	CombatAttributes.Id.STAMINA_REGEN: 10.0,
	CombatAttributes.Id.MANA_REGEN: 5.0,
}


## Builds an isolated set for tests that do not need an actor or an ASC.
static func new_attributes() -> ActorAttributes:
	var attributes := ActorAttributes.new()
	attributes.initialize()
	for id: int in STARTUP_BASES:
		attributes.set_numeric_base_value(id, STARTUP_BASES[id])
	attributes.set_modifiers(&"fixture.attribute_derivations", _derivations())
	attributes.restore_resources()
	return attributes


## Overrides an actor's startup effect assets for this test. Call before it enters the tree.
static func configure(system: AbilitySystem, regen_period: float = REGENERATION_PERIOD) -> void:
	var defaults := GameplayEffectDefinition.new()
	defaults.effect_id = &"Effect.DefaultAttributes"
	for id: int in STARTUP_BASES:
		var modifier := AttributeModifier.new()
		modifier.attribute = id
		modifier.operation = AttributeModifier.Operation.SET_BASE
		modifier.value = STARTUP_BASES[id]
		defaults.modifiers.append(modifier)
	var derivations := GameplayEffectDefinition.new()
	derivations.effect_id = &"Effect.AttributeDerivations"
	derivations.timing = GameplayEffectDefinition.Timing.INFINITE
	derivations.modifiers = _derivations()
	system.startup_effects = [defaults, derivations, regeneration_effect(regen_period)]


static func regeneration_effect(period: float = REGENERATION_PERIOD) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = &"Effect.ResourceRegeneration"
	effect.timing = GameplayEffectDefinition.Timing.INFINITE
	effect.period = period
	effect.execute_periodic_on_application = false
	effect.ongoing_blocked_target_tags = PackedStringArray(["State.Dead"])
	effect.executions.append(REGENERATION_EXECUTION.new())
	return effect


## Uses the same runtime execution path as the ASC with an independently controlled clock.
static func attach_regeneration(runtime: GameplayEffectRuntime, attributes: ActorAttributes,
		period: float = REGENERATION_PERIOD) -> int:
	return runtime.apply_effect(regeneration_effect(period), GameplayEffectContext.capture(attributes, null))


static func _derivations() -> Array[AttributeModifier]:
	return [
		_capture(CombatAttributes.Id.MAX_HEALTH, CombatAttributes.Id.VITALITY, 10.0),
		_capture(CombatAttributes.Id.MAX_STAMINA, CombatAttributes.Id.VITALITY, 5.0),
		_capture(CombatAttributes.Id.MAX_MANA, CombatAttributes.Id.INTELLECT, 5.0),
		_capture(CombatAttributes.Id.MAGIC_POWER, CombatAttributes.Id.INTELLECT, 2.0),
		_capture(CombatAttributes.Id.CARRY_CAPACITY, CombatAttributes.Id.STRENGTH, 2.0),
	]


static func _capture(attribute: int, source: int, coefficient: float) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = attribute
	modifier.operation = AttributeModifier.Operation.ADD_TO_FOUNDATION
	modifier.capture_attribute = source
	modifier.capture_coefficient = coefficient
	return modifier
