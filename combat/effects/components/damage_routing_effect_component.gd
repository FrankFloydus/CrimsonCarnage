@tool
class_name DamageRoutingEffectComponent
extends GameplayEffectComponent
## Redirects part of the owner's mitigated damage to the effect's original source.

## Any matching canonical damage/context tag or descendant. Empty matches all damage.
@export var damage_tags: PackedStringArray = PackedStringArray()
## Lower priorities get the first eligible routing decision.
@export var priority: int = 0
## Fraction transferred after local block and absorption, before the destination's defenses.
@export_range(0.0, 1.0, 0.01) var fraction: float = 0.3
## Total points this instance can redirect. Zero permits an unlimited total.
@export_range(0.0, 100000.0, 0.1, "or_greater") var capacity: float = 0.0
## Maximum source-to-target distance in world units. Zero allows any distance in the same world.
@export_range(0.0, 1000.0, 0.1, "or_greater") var max_range: float = 0.0
## Leave at least one Health on the source. Unroutable damage remains on the original target.
@export var preserve_source_health: bool = false


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT or not is_finite(fraction) \
			or fraction <= 0.0 or fraction > 1.0 or not is_finite(capacity) or capacity < 0.0 \
			or not is_finite(max_range) or max_range < 0.0:
		return &"Effect.InvalidDamageRouting"
	return &""


func matches(spec: GameplayEffectSpec) -> bool:
	var tags := spec.settings.get_payload_context_tags(spec.context)
	for query in damage_tags:
		if AttributeModifier._has_match(tags, query):
			return true
	return damage_tags.is_empty()
