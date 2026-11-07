class_name AbilityTransferEffectAction
extends AbilityActionDefinition
## Moves one eligible retained effect per selected actor to the executing actor.

## Optional exact effect ID. When both selectors are set, both must match.
@export var effect_id: StringName = &""
## Every tag or a descendant must identify the effect asset, such as Effect.Beneficial and Effect.Magical.
@export var required_asset_tags: PackedStringArray = PackedStringArray()
## Upper limit on the remaining lifetime carried over, in seconds. Zero preserves remaining time.
@export_range(0.0, 3600.0, 0.1, "or_greater") var duration_cap: float = 0.0
## Upper limit on the stacks carried over. Zero preserves the current stack count.
@export_range(0, 100, 1, "or_greater") var stack_cap: int = 0


func get_validation_error() -> StringName:
	if (effect_id.is_empty() and required_asset_tags.is_empty()) or required_asset_tags.has(""):
		return &"invalid_transfer_selector"
	if not is_finite(duration_cap) or duration_cap < 0.0 or stack_cap < 0:
		return &"invalid_transfer_limits"
	return &""


func execute(context: AbilityPhaseContext, targets: AbilityTargetSet) -> int:
	if context == null or context.cast == null or targets == null or not get_validation_error().is_empty():
		return -1
	var recipient := context.cast.get_system()
	if not is_instance_valid(recipient) or recipient.effects == null:
		return -1
	var count := 0
	var seen: Dictionary[int, bool] = {}
	for contact: AbilityTargetContact in targets.contacts:
		var source := contact.get_target()
		if source == null or source == recipient or source.effects == null or seen.has(source.get_instance_id()):
			continue
		seen[source.get_instance_id()] = true
		if _transfer_one(source.effects, recipient.effects):
			count += 1
		if not is_instance_valid(recipient):
			break
	return count


func _transfer_one(source: GameplayEffectRuntime, recipient: GameplayEffectRuntime) -> bool:
	var retained := source.get_retained_effects()
	var handles := retained.keys()
	handles.sort()
	for handle: int in handles:
		var definition := retained[handle]
		if not _matches(definition) or source.is_effect_inhibited(handle):
			continue
		var time_limit := duration_cap if duration_cap > 0.0 else INF
		var stack_limit := stack_cap if stack_cap > 0 else GameplayEffectRuntime.MAX_STACK_COUNT
		if source.transfer_effect(handle, recipient, time_limit, stack_limit) > 0:
			return true
	return false


func _matches(definition: GameplayEffectDefinition) -> bool:
	if not definition.is_transferable() or (not effect_id.is_empty() and effect_id != definition.effect_id):
		return false
	for query: String in required_asset_tags:
		if not AttributeModifier._has_match(definition.asset_tags, query):
			return false
	return true
