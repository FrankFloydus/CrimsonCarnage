@tool
class_name AbilityDefinition
extends Resource
## Authored ability configuration, shared by player input and AI activation requests.

## Stable identifier used to grant and activate this ability.
@export var ability_id: StringName = &""
## Human-readable name shown by interfaces and debugging tools.
@export var display_name: String = "Ability"
## Hierarchical action categories supplied to effect and attribute-modifier queries.
## Weapon tags come from the grant's source profile.
@export var ability_tags: PackedStringArray = PackedStringArray()
## All of these owner tags must be present before activation.
@export var required_tags: PackedStringArray = PackedStringArray()
## Activation fails while the owner has any matching tag, including descendants.
@export var blocked_tags: PackedStringArray = PackedStringArray(["State.Dead"])
## Counted owner tags granted for this cast and removed on completion or interruption.
@export var activation_tags: PackedStringArray = PackedStringArray()
## A matching tag gained during execution interrupts the cast; excludes its own action tag.
@export var interruption_tags: PackedStringArray = PackedStringArray([
	"State.Dead"
])
## Matching asset tags on other active abilities cancel those activations when this ability starts.
@export var cancel_ability_tags: PackedStringArray = PackedStringArray()
## Blocks other abilities with matching asset tags while this ability is active.
@export var block_ability_tags: PackedStringArray = PackedStringArray()
@export_group("Gameplay Events")
## An incoming gameplay event with this tag or a child tag starts this grant. Empty allows direct requests.
@export var activation_event_tag: StringName = &""
@export_group("Commit Effects")
## Optional instant effect with additive current-pool debits, applied once at commit.
@export var cost_effect: GameplayEffectDefinition
## Optional finite effect that grants cooldown tags. Abilities sharing those tags share the cooldown.
@export var cooldown_effect: GameplayEffectDefinition
@export_group("")
## Reusable GDScript behavior with its own Inspector configuration.
@export var execution: AbilityExecution


## Returns the action's authored tags. Weapon classification comes from the granted source.
func get_context_tags() -> PackedStringArray:
	var result := PackedStringArray()
	for tag in ability_tags:
		if tag == "Weapon" or tag.begins_with("Weapon."):
			continue
		if not result.has(tag):
			result.append(tag)
	return result


func get_validation_error() -> StringName:
	if execution == null:
		return &"missing_execution"
	if cost_effect != null and not _has_valid_cost_effect():
		return &"invalid_cost_effect"
	if cooldown_effect != null and not _has_valid_cooldown_effect():
		return &"invalid_cooldown_effect"
	return &""


func _has_valid_cost_effect() -> bool:
	if cost_effect.is_damage_effect() \
			or cost_effect.timing != GameplayEffectDefinition.Timing.INSTANT \
			or not cost_effect.executions.is_empty() or cost_effect.modifiers.is_empty() \
			or not cost_effect.get_validation_error().is_empty():
		return false
	for modifier in cost_effect.modifiers:
		if not CombatAttributes.is_current_resource(modifier.attribute) \
				or modifier.operation != AttributeModifier.Operation.ADD:
			return false
		if modifier.value > 0.0 and modifier.capture_attribute == CombatAttributes.Id.NONE \
				and modifier.set_by_caller_tag.is_empty():
			return false
	return true


func _has_valid_cooldown_effect() -> bool:
	if cooldown_effect.timing != GameplayEffectDefinition.Timing.DURATION \
			or cooldown_effect.duration <= 0.0 or cooldown_effect.period > 0.0 \
			or cooldown_effect.granted_tags.is_empty() \
			or not cooldown_effect.get_validation_error().is_empty():
		return false
	for tag in cooldown_effect.granted_tags:
		if tag.is_empty():
			return false
	return true
