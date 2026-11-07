extends RefCounted
## Constructs test-owned cost and cooldown effects without depending on authored assets.


static func make_cost(attribute: int, amount: float) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.kind = GameplayEffectDefinition.Kind.MODIFIERS
	var modifier := AttributeModifier.new()
	modifier.attribute = attribute
	modifier.value = -amount
	effect.modifiers = [modifier]
	return effect


static func make_cooldown(tag: String, duration: float) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.kind = GameplayEffectDefinition.Kind.MODIFIERS
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = duration
	effect.granted_tags = PackedStringArray([tag])
	return effect
