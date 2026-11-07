@tool
class_name AbilityInterruptionPolicy
extends Resource
## Controls when a cast can start, be interrupted, or commit its costs and cooldown.

## Boundary at which the ability spends a reserved resource or charge.
enum CommitTiming {
	## Spend when activation starts, before windup.
	ON_START,
	## Spend at the first valid release, after rechecking the reservation.
	ON_RELEASE,
}

## Response to movement intent during an active cast phase.
enum MovementRule {
	## Movement input leaves the cast active and reaches the movement controller.
	ALLOW,
	## The cast stays active and the movement controller suppresses movement.
	LOCK,
	## A movement request cancels the cast through its normal cleanup path.
	CANCEL_ON_REQUEST,
}

## School reported by successful interrupts and checked against active school lockouts.
@export var school: StringName
## Actor tags that prevent new activations of this ability.
@export var activation_blockers: PackedStringArray = []:
	set(value):
		activation_blockers = value
		notify_property_list_changed()
## Exact queries in Activation Blockers that this ability may bypass.
@export var activation_exceptions: PackedStringArray = []
## Actor tags that interrupt this ability during its interruptible phases.
@export var cancel_on_tags: PackedStringArray = []
## Allows interruption while waiting to release.
@export var interrupt_windup: bool = true:
	set(value):
		interrupt_windup = value
		notify_property_list_changed()
## Allows interruption while a channel is producing pulses.
@export var interrupt_channel: bool = true:
	set(value):
		interrupt_channel = value
		notify_property_list_changed()
## Allows an explicit interrupt action to interrupt this ability during an eligible phase.
@export var interruptible_by_action: bool = true
## Channels occupied while the cast is active. Two occupants need mutual compatibility to overlap.
@export var occupied_channels: PackedStringArray = []:
	set(value):
		occupied_channels = value
		notify_property_list_changed()
## Occupied channels on other casts that may overlap this ability.
@export var compatible_channels: PackedStringArray = []
## During windup, allow movement, lock movement, or cancel the cast when movement is requested.
@export var windup_movement: MovementRule = MovementRule.ALLOW
## While channeling, allow movement, lock movement, or cancel when movement is requested.
@export var channel_movement: MovementRule = MovementRule.ALLOW
## Spend reserved resources at activation start or when a valid release occurs.
@export var cost_timing: CommitTiming = CommitTiming.ON_START
## Start the reserved charge's recharge at activation start or at a valid release.
@export var cooldown_timing: CommitTiming = CommitTiming.ON_START
## Restores resource amounts this cast actually paid if it is interrupted or cancelled.
@export var refund_cost_on_cancel: bool = false
## Refunds this cast's spent charge if it is interrupted or cancelled before that charge recharges.
@export var refund_cooldown_on_cancel: bool = false


func _validate_property(property: Dictionary) -> void:
	if property.name == &"activation_exceptions" and activation_blockers.is_empty():
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name == &"compatible_channels" and occupied_channels.is_empty():
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name in [&"cancel_on_tags", &"interruptible_by_action"] \
			and not interrupt_windup and not interrupt_channel:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if not cost_timing in CommitTiming.values() or not cooldown_timing in CommitTiming.values():
		return &"invalid_commit_timing"
	if not windup_movement in MovementRule.values() or not channel_movement in MovementRule.values():
		return &"invalid_cast_movement_rule"
	for values in [activation_blockers, occupied_channels]:
		if values.has(""):
			return &"empty_interruption_policy_query"
	if not activation_blockers.is_empty() and activation_exceptions.has(""):
		return &"empty_interruption_policy_query"
	if not occupied_channels.is_empty() and compatible_channels.has(""):
		return &"empty_interruption_policy_query"
	if (interrupt_windup or interrupt_channel) and cancel_on_tags.has(""):
		return &"empty_interruption_policy_query"
	return &""


func blocks_activation(tags: GameplayTagSet) -> bool:
	for query in activation_blockers:
		if not activation_exceptions.has(query) and tags.has_tag(StringName(query)):
			return true
	return false


func permits_interruption(phase: int) -> bool:
	return (phase == AbilityCast.Phase.WINDUP and interrupt_windup
			or phase == AbilityCast.Phase.CHANNEL and interrupt_channel)


func get_movement_rule(phase: int) -> MovementRule:
	match phase:
		AbilityCast.Phase.WINDUP:
			return windup_movement
		AbilityCast.Phase.CHANNEL:
			return channel_movement
	return MovementRule.ALLOW


func conflicts_with(other: AbilityInterruptionPolicy) -> bool:
	if other == null:
		return false
	for channel in occupied_channels:
		if other.occupied_channels.has(channel) and (
				not compatible_channels.has(channel) or not other.compatible_channels.has(channel)):
			return true
	return false
