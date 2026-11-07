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
## Counted owner tags granted for this cast and removed on completion or interruption.
@export var activation_tags: PackedStringArray = PackedStringArray()
## Matching asset tags on other active abilities cancel those activations when this ability starts.
@export var cancel_ability_tags: PackedStringArray = PackedStringArray()
## Blocks other abilities with matching asset tags while this ability is active.
@export var block_ability_tags: PackedStringArray = PackedStringArray()
@export_group("Gameplay Events")
## An incoming gameplay event with this tag or a child tag starts this grant. Empty allows direct requests.
@export var activation_event_tag: StringName = &""
## Outcome-driven responses scoped to this activation, including detached deliveries.
@export var reactions: Array[ReactionDefinition] = []
@export_group("Interruption")
## Cast school, interruptible phases, action channels and commitment timing.
@export var interruption_policy: AbilityInterruptionPolicy
@export_group("Commitment")
## Fixed or variable current-pool costs reserved at activation and paid at the commitment phase.
@export var resource_costs: Array[AbilityResourceCost] = []
## Optional actor-owned charge pool. Use a single charge for a standard cooldown.
@export var charge_pool: AbilityChargeDefinition
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
	var resources: Dictionary[int, bool] = {}
	for cost: AbilityResourceCost in resource_costs:
		if cost == null or not cost.get_validation_error().is_empty():
			return &"invalid_resource_cost"
		if resources.has(cost.pool):
			return &"duplicate_resource_cost"
		resources[cost.pool] = true
	if charge_pool != null and not charge_pool.get_validation_error().is_empty():
		return &"invalid_charge_pool"
	if interruption_policy != null and not interruption_policy.get_validation_error().is_empty():
		return &"invalid_interruption_policy"
	for reaction: ReactionDefinition in reactions:
		if reaction == null or not reaction.get_validation_error().is_empty():
			return &"invalid_ability_reaction"
	return &""
