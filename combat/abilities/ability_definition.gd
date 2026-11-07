@tool
class_name AbilityDefinition
extends Resource
## Authored ability configuration, shared by player input and AI activation requests.

## Stable identifier used to grant, activate, and track this ability's cooldown.
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
@export_group("Gameplay Events")
## An incoming gameplay event with this tag or a child tag starts this grant. Empty allows direct requests.
@export var activation_event_tag: StringName = &""
@export_group("Activation Cost", "cost_")
## Current resource charged once when this ability activates. None skips that upfront charge.
@export var cost_attribute: CombatAttributes.Id = CombatAttributes.Id.MANA
## Flat amount of the activation resource charged at the start. Ongoing costs belong to execution.
@export_range(0.0, 10000.0, 0.1, "or_greater") var cost_amount: float = 0.0
@export_group("")
## Base cooldown in seconds, started when activation commits successfully.
@export_range(0.0, 600.0, 0.01, "or_greater") var cooldown: float = 0.0
## Inline reusable execution behavior and its Inspector configuration; not a scene.
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
	if not is_finite(cost_amount) or cost_amount < 0.0:
		return &"invalid_cost_amount"
	if cost_attribute != CombatAttributes.Id.NONE and not CombatAttributes.is_current_resource(cost_attribute):
		return &"invalid_cost_attribute"
	if not is_finite(cooldown) or cooldown < 0.0:
		return &"invalid_cooldown"
	return &""


func _validate_property(property: Dictionary) -> void:
	if property.name == &"cost_attribute":
		var choices := PackedStringArray(["None:%d" % CombatAttributes.Id.NONE])
		for id: int in [CombatAttributes.Id.HEALTH, CombatAttributes.Id.STAMINA, CombatAttributes.Id.MANA]:
			choices.append("%s:%d" % [CombatAttributes.display_name(id), id])
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(choices)
