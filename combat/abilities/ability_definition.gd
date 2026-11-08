@tool
class_name AbilityDefinition
extends Resource
## Authored ability configuration, shared by player input and AI activation requests.

## How a player action assigned to this ability responds to a button.
enum InputGesture {
	## Use Hold + release for older Hold Release casts and Press for other saved abilities.
	AUTOMATIC,
	## Activate when the player presses the button.
	PRESS,
	## Start on button-down and end sustained or channeled behavior on button-up.
	HOLD,
	## Arm on button-down and attempt activation on button-up.
	RELEASE,
	## Start on button-down and begin the configured release timing on button-up.
	HOLD_RELEASE,
}

## Stable positive integer used to grant and activate this ability. Keep it unique across abilities and effects.
## Zero leaves the ID unassigned.
@export var ability_id: int = 0
## Human-readable name shown by interfaces and debugging tools.
@export var display_name: String = "Ability"
## Optional texture that represents this ability in the Ability Editor and other interfaces.
@export var icon: Texture2D
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
## Button gesture for player actions assigned to this ability. Cast timing controls when delivery follows.
@export var input_gesture: InputGesture = InputGesture.AUTOMATIC
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
@export_group("Presentation")
## Optional Gameplay Cue shown from cast start until payload release or cancellation.
## The actor binds the cue to its own visual.
@export var casting_cue: StringName = &""
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


## Resolves the gesture of both explicitly configured abilities and older authored casts.
func get_input_gesture() -> InputGesture:
	if input_gesture != InputGesture.AUTOMATIC:
		return input_gesture
	var phased := execution as PhasedAbilityExecution
	if phased != null and phased.cast_mode == PhasedAbilityExecution.CastMode.HOLD_RELEASE:
		return InputGesture.HOLD_RELEASE
	return InputGesture.PRESS


func get_validation_error() -> StringName:
	if execution == null:
		return &"missing_execution"
	if input_gesture < InputGesture.AUTOMATIC or input_gesture > InputGesture.HOLD_RELEASE:
		return &"invalid_input_gesture"
	var phased := execution as PhasedAbilityExecution
	if phased != null:
		var gesture := get_input_gesture()
		var is_ongoing := phased.cast_mode in [PhasedAbilityExecution.CastMode.CHANNEL,
				PhasedAbilityExecution.CastMode.SUSTAINED]
		if gesture == InputGesture.HOLD and not is_ongoing:
			return &"hold_requires_sustained_or_channel"
		if gesture == InputGesture.HOLD_RELEASE and is_ongoing:
			return &"hold_release_requires_delivery_timing"
		if phased.cast_mode == PhasedAbilityExecution.CastMode.HOLD_RELEASE \
				and gesture != InputGesture.HOLD_RELEASE:
			return &"legacy_cast_timing_requires_hold_release"
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
