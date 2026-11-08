@tool
class_name GameplayEffectDamageExecution
extends GameplayEffectExecution
## Resolves instant or periodic Health damage using the combat formula and the effect spec.

## Semantic base damage in Health points. Empty contributes zero before Power and weapon scaling.
@export var amount: AmountDefinition
## Includes the bound physical weapon roll and base-cycle Power contribution.
@export var use_weapon_damage: bool = false:
	set(value):
		use_weapon_damage = value
		notify_property_list_changed()
## Damage points added per point of applicable Power for damage without a weapon roll.
@export_range(0.0, 100.0, 0.01, "or_greater") var power_coefficient: float = 0.0
## Fraction of the complete weapon contribution assigned to this damage component.
@export_range(0.0, 100.0, 0.01, "or_greater") var weapon_power_share: float = 1.0


func is_damage_execution() -> bool:
	return true


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if not use_weapon_damage and (not is_finite(power_coefficient) or power_coefficient < 0.0):
		return &"Effect.InvalidPowerCoefficient"
	if use_weapon_damage and (not is_finite(weapon_power_share) or weapon_power_share < 0.0):
		return &"Effect.InvalidWeaponShare"
	if use_weapon_damage and (definition.damage_type != GameplayEffectDefinition.DamageType.PHYSICAL \
			or definition.timing != GameplayEffectDefinition.Timing.INSTANT):
		return &"Effect.WeaponDamageRequiresPhysicalHit"
	if amount == null:
		return &""
	if amount.source in [AmountDefinition.Source.OUTCOME_PERCENT, AmountDefinition.Source.UNIQUE_TARGET_COUNT]:
		return &"damage_amount_requires_outcome"
	if amount.source == AmountDefinition.Source.FIXED and amount.evaluate() < 0.0:
		return &"negative_damage_amount"
	return amount.get_validation_error(AmountDefinition.Unit.POINTS)


func _validate_property(property: Dictionary) -> void:
	if (property.name == &"power_coefficient" and use_weapon_damage) \
			or (property.name == &"weapon_power_share" and not use_weapon_damage):
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func calculate_damage(spec: GameplayEffectSpec, target: ActorAttributes) -> Dictionary:
	return CombatMath.resolve_effect_result(spec.settings, spec.context, target, spec)


static func capture_amount_inputs(spec: GameplayEffectSpec, target: ActorAttributes) -> void:
	if spec == null or spec.settings == null or spec.context == null:
		return
	var execution := spec.settings.get_damage_execution()
	if execution != null and execution.amount != null \
			and execution.amount.timing == AmountDefinition.Timing.SNAPSHOT:
		spec.amount_snapshot = _amount_context(spec.settings, spec.context, target, spec).capture()


func evaluate_base_amount(
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		target: ActorAttributes,
		spec: GameplayEffectSpec
) -> float:
	if amount == null:
		return 0.0
	if amount.source == AmountDefinition.Source.FIXED:
		return amount.evaluate()
	var evaluation := _amount_context(definition, context, target, spec)
	if amount.timing == AmountDefinition.Timing.SNAPSHOT and evaluation.snapshot == null:
		evaluation.snapshot = evaluation.capture()
	return amount.evaluate(evaluation)


static func _amount_context(
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		target: ActorAttributes,
		spec: GameplayEffectSpec
) -> AmountEvaluationContext:
	var evaluation := context.outcome_context.make_payload_amount_context(target) \
			if context.outcome_context != null else AmountEvaluationContext.new()
	evaluation.effect_context = context
	evaluation.target = target
	evaluation.recipient = target
	evaluation.scope_tags = definition.get_payload_context_tags(context)
	if spec != null:
		evaluation.snapshot = spec.amount_snapshot
		evaluation.stack_count = spec.stack_count
		evaluation.accumulator = spec.accumulated_amount
	return evaluation
