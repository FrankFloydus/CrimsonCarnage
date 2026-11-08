class_name HealingRequest
extends RefCounted
## Validated healing or a signed Health restoration request from an owned snapshot.

## Selects whether the request goes through ordinary healing rules or restores recorded Health.
enum Mode {
	## Applies nonnegative healing through profile scaling, incoming modifiers, and absorption.
	HEAL,
	## Applies a signed Health change without healing modifiers, keeping the recipient alive.
	SNAPSHOT_RESTORE,
}

var recipient: ActorAttributes
var requested_amount: float
var profile: HealingProfile
var mode: Mode = Mode.HEAL
## Snapshot restorations can explicitly publish as eligible for healing reactions.
var snapshot_triggers_reactions: bool = false


func _init(
		recipient_attributes: ActorAttributes,
		amount: float,
		healing_profile: HealingProfile = null
) -> void:
	recipient = recipient_attributes
	requested_amount = amount
	profile = healing_profile
