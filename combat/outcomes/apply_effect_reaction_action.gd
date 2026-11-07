@tool
class_name ApplyEffectReactionAction
extends CombatReactionAction
## Applies a configured effect directly to a committed outcome's chosen recipient.

## Effect spec to apply. This is direct effect application and performs no new hostile hit roll.
@export var effect: GameplayEffectDefinition
## Optional magnitude key read by the effect's Set by Caller configuration.
@export var magnitude_tag: StringName:
	set(value):
		magnitude_tag = value
		notify_property_list_changed()
## Amount supplied to the configured magnitude key, in points.
@export var amount: AmountDefinition
## Marks the child as retaliation, which ordinary reactions exclude by default.
@export var retaliation: bool = false


func _validate_property(property: Dictionary) -> void:
	if property.name == &"amount" and magnitude_tag.is_empty():
		property.usage &= ~PROPERTY_USAGE_EDITOR


func get_validation_error(trigger: int) -> StringName:
	if effect == null:
		return &"missing_reaction_effect"
	if magnitude_tag.is_empty():
		return &""
	return amount_validation_error(amount, trigger)


func execute(outcome: CombatOutcome, context: CombatOutcomeContext, recipient: ActorAttributes) -> void:
	var system := CombatOutcomeContext.resolve_system(recipient)
	if system == null:
		return
	var source := context.actor(CombatOutcomeContext.Role.EXECUTING_ACTOR)
	var source_system := CombatOutcomeContext.resolve_system(source)
	var parent_event := outcome.get_event()
	var tags: PackedStringArray = parent_event.get("ability_tags", PackedStringArray())
	var effect_context := source_system.create_effect_context(tags) if source_system != null \
			else GameplayEffectContext.capture(source, null, tags)
	effect_context.outcome_context = context.with_provenance(CombatOutcomeContext.Provenance.RETALIATION) \
			if retaliation else context
	effect_context.source_id = context.actor_id(CombatOutcomeContext.Role.ORIGINAL_SOURCE)
	effect_context.ability_id = StringName(parent_event.get("ability_id", &""))
	effect_context.ability_name = str(parent_event.get("ability_name", ""))
	var spec := system.make_outgoing_spec(effect, effect_context)
	if spec == null:
		return
	if not magnitude_tag.is_empty() and amount != null:
		var value := amount.evaluate(context.make_amount_context(outcome, recipient))
		if not is_finite(value):
			return
		spec.set_by_caller_magnitude(magnitude_tag, value)
	system.apply_effect_spec_to_self(spec)
