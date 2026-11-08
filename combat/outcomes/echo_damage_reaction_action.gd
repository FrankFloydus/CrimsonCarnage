@tool
class_name EchoDamageReactionAction
extends CombatReactionAction
## Echoes the source-scaled damage packet and resolves the recipient's current defenses.

## Determines whether a damage copy inherits the original packet's critical result.
enum CriticalRule {
	## Copies the original critical multiplier and its attribution when the packet was critical.
	REUSE,
	## Resolves the copied packet as a normal hit with a multiplier of one.
	REMOVE,
}

## Effectiveness of the echoed damage. Empty copies the source packet at full value.
@export var copy_policy: CombatCopyPolicy
## Reuses the original critical or treats the echoed packet as noncritical.
@export var critical_rule: CriticalRule = CriticalRule.REUSE
## Optional defense profile for the new packet. Empty uses the live default defense stages.
@export var secondary_damage_profile: DamageProfile


func get_validation_error(trigger: int) -> StringName:
	if trigger != ReactionDefinition.Trigger.ON_DAMAGE_RESOLVED \
			and trigger != ReactionDefinition.Trigger.ON_HEALTH_DAMAGED:
		return &"echo_requires_damage_outcome"
	if not CriticalRule.values().has(critical_rule):
		return &"invalid_echo_critical_rule"
	if secondary_damage_profile != null:
		var error := secondary_damage_profile.get_validation_error()
		if not error.is_empty():
			return error
	return copy_policy.get_validation_error() if copy_policy != null else &""


func execute(outcome: CombatOutcome, context: CombatOutcomeContext, recipient: ActorAttributes) -> void:
	if (context.provenance & CombatOutcomeContext.Provenance.COPIED) != 0:
		return
	var recipient_system := CombatOutcomeContext.resolve_system(recipient)
	if recipient_system == null:
		return
	var raw := outcome.get_amount(&"raw_magnitude")
	var magnitude := copy_policy.scale_amount(raw) if copy_policy != null else raw
	if not is_finite(magnitude) or magnitude <= 0.0:
		return
	var event := outcome.get_event()
	var definition := GameplayEffectDefinition.new()
	definition.effect_id = int(event.get("effect_id", 0))
	definition.display_name = str(event.get("effect_name", ""))
	definition.damage_type = int(event.get("damage_type", GameplayEffectDefinition.DamageType.PHYSICAL)) \
			as GameplayEffectDefinition.DamageType
	if definition.damage_type == GameplayEffectDefinition.DamageType.MAGIC:
		definition.magic_school = int(event.get("magic_school", GameplayEffectDefinition.MagicSchool.FIRE)) \
				as GameplayEffectDefinition.MagicSchool
	definition.damage_profile = secondary_damage_profile
	var damage := GameplayEffectDamageExecution.new()
	damage.amount = AmountDefinition.fixed(magnitude)
	definition.executions = [damage]

	var source := context.actor(CombatOutcomeContext.Role.EXECUTING_ACTOR)
	var source_system := CombatOutcomeContext.resolve_system(source)
	var tags: PackedStringArray = event.get("ability_tags", PackedStringArray())
	var payload := source_system.create_effect_context(tags) if source_system != null \
			else GameplayEffectContext.capture(source, null, tags)
	payload.outcome_context = context.with_provenance(CombatOutcomeContext.Provenance.COPIED).for_contact(recipient)
	payload.source_id = context.actor_id(CombatOutcomeContext.Role.ORIGINAL_SOURCE)
	payload.ability_id = int(event.get("ability_id", 0))
	payload.ability_name = str(event.get("ability_name", ""))
	if bool(event.get("is_critical", false)) and critical_rule == CriticalRule.REUSE:
		payload = payload.with_critical_result(true, float(event.get("critical_multiplier", 1.0)),
				float(event.get("critical_damage_percent", 0.0)))
	var spec := recipient_system.make_outgoing_spec(definition, payload)
	recipient_system.apply_effect_spec_to_self(spec)
