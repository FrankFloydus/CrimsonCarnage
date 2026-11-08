@tool
class_name ReactionDefinition
extends Resource
## An authored follow-up to one class of committed outcome within its attachment.

## Selects the committed event that can start the follow-up.
enum Trigger {
	## A confirmed contact, including a hit whose damage was fully absorbed.
	ON_HIT,
	## A damage transaction that removed a positive number of Health points.
	ON_HEALTH_DAMAGED,
	## A successful status application.
	ON_STATUS_APPLIED,
	## A damage transaction that killed its target.
	ON_KILL,
	## A proc-eligible heal with a positive scaled amount, including fully overhealed results.
	ON_HEAL,
	## A published transaction that restored a positive number of Mana or Stamina points.
	ON_RESOURCE_RESTORED,
	## A completed target batch with its final unique-target count.
	ON_BATCH_COMPLETE,
	## A retained effect ending for the configured removal reason.
	ON_EFFECT_REMOVED,
	## A retained effect publishing its accumulated amount on a threshold or expiry.
	ON_EFFECT_THRESHOLD,
	## A resolved positive damage packet accepted by the recipient, even if defenses prevented all Health loss.
	ON_DAMAGE_RESOLVED,
}

## Determines which identity a reaction can claim only once.
enum OncePolicy {
	## Each distinct committed outcome can trigger this reaction once.
	PER_EVENT,
	## Each target of the originating execution can trigger this reaction once.
	PER_EXECUTION_TARGET,
	## All packets and contacts of one attack share one trigger.
	PER_ATTACK,
	## Every outcome sharing the root execution competes for a single trigger.
	PER_EXECUTION,
}

## Selects the actor or actors that receive the follow-up actions.
enum Recipient {
	## Uses the actor credited with the triggering outcome.
	CREDITED_OWNER,
	## Uses the actor against whom the outcome resolved.
	TARGET,
	## Uses the actor who executed the original action.
	EXECUTING_ACTOR,
	## Uses the actor who requested the original action.
	REQUESTER,
	## Uses the actor whose resources paid for the original activation.
	RESOURCE_PAYER,
	## Uses the original source, preserving this identity through reflection or transfer.
	ORIGINAL_SOURCE,
	## Uses the owner of the triggering payload's delivery.
	DELIVERY_OWNER,
	## Uses the recorded actor who dispelled the effect.
	REMOVAL_INSTIGATOR,
	## Uses the actor occupying the credited owner's selected retained-effect slot.
	LINKED_ACTOR,
	## Uses the actors returned by the configured area query after excluding the triggering target.
	NEARBY_TARGETS,
}

## Filters when the triggering payload was produced, independently of its delivery.
enum TimingFilter {
	## Accepts direct outcomes, periodic ticks, and channel pulses.
	ANY,
	## Accepts outcomes from immediate actions or impacts.
	DIRECT,
	## Accepts outcomes produced by retained effects' scheduled ticks.
	PERIODIC,
	## Accepts outcomes produced by a channel pulse.
	CHANNEL_PULSE,
}

## Selects the removal reason to match for an effect-removal reaction.
enum RemovalFilter {
	## Accepts every recorded removal reason.
	ANY = -1,
	## The effect was removed explicitly.
	MANUAL = 0,
	## The effect reached its configured expiration time.
	EXPIRED = 1,
	## An authored dispel removed the effect.
	DISPELLED = 2,
	## The effect ended during death cleanup.
	DEATH = 3,
	## The effect ended when its scene was unloaded.
	SCENE_UNLOAD = 4,
	## A replacement effect took its place.
	REPLACED = 5,
	## The effect's budget or a one-shot behavior was exhausted.
	DEPLETED = 6,
	## The effect moved to another recipient.
	TRANSFERRED = 7,
	## An authored break condition ended the effect.
	BROKEN = 8,
	## Loading saved actor state invalidated the session-only effect.
	SAVE_INVALIDATED = 9,
}

const ORIGINAL_PROVENANCE: int = CombatOutcomeContext.Provenance.ORIGINAL

## Committed event that may trigger the follow-up. Hit includes fully absorbed contact.
@export var trigger: Trigger = Trigger.ON_HIT:
	set(value):
		trigger = value
		notify_property_list_changed()
## Actor who receives the follow-up actions, independently of the triggering event's target.
@export var recipient: Recipient = Recipient.CREDITED_OWNER:
	set(value):
		recipient = value
		notify_property_list_changed()
## Identity at which this reaction may fire only once, even if several outcomes qualify.
@export var once_policy: OncePolicy = OncePolicy.PER_EVENT:
	set(value):
		once_policy = value
		notify_property_list_changed()
## Select direct damage, periodic ticks, or channel pulses independently of delivery.
@export var timing_filter: TimingFilter = TimingFilter.ANY
## Optional delivery identity to match, such as projectile or area_burst. Empty accepts any delivery.
@export var required_delivery: StringName
## Every selected provenance flag must be present.
@export_flags("Copied:2", "Reflected:4", "Transferred:8", "Retaliation:16", "Pet:32")
var required_provenance: int = 0
## Any selected flag suppresses this reaction. Secondary payloads are excluded by default.
@export_flags("Copied:2", "Reflected:4", "Transferred:8", "Retaliation:16", "Pet:32")
var excluded_provenance: int = CombatOutcomeContext.Provenance.COPIED \
		| CombatOutcomeContext.Provenance.REFLECTED | CombatOutcomeContext.Provenance.TRANSFERRED \
		| CombatOutcomeContext.Provenance.RETALIATION
## All listed tags must match the outcome's ability context, using hierarchical tag matching.
@export var required_ability_tags: PackedStringArray = PackedStringArray()
## Any listed ability tag suppresses the reaction, using hierarchical tag matching.
@export var blocked_ability_tags: PackedStringArray = PackedStringArray()
## An effect removal reason to match. Any accepts every reason. Removal Instigator only uses dispels.
@export var removal_reason: RemovalFilter = RemovalFilter.ANY
## Exclusive retained-effect slot on the credited owner when Recipient is Linked Actor.
@export var link_slot: StringName
## Maximum distance in meters from the credited owner to the linked actor. Zero has no range limit.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var link_range: float = 0.0
## Suppresses a linked follow-up if the linked actor already received the triggering outcome.
@export var link_exclude_trigger_target: bool = true
## Area query selecting nearby recipients. The triggering target is excluded before any target cap.
@export var nearby_targeting: AbilityTargetingDefinition
## Maximum fires for this attachment within one execution. Zero uses only the once policy.
@export_range(0, 4096, 1, "or_greater") var fire_limit: int = 0
## Ordered, reusable follow-up actions run with this outcome and the selected recipient.
@export var actions: Array[CombatReactionAction] = []


func _validate_property(property: Dictionary) -> void:
	var visible := true
	match property.name:
		&"removal_reason":
			visible = trigger == Trigger.ON_EFFECT_REMOVED and recipient != Recipient.REMOVAL_INSTIGATOR
		&"link_slot", &"link_range":
			visible = recipient == Recipient.LINKED_ACTOR
		&"link_exclude_trigger_target":
			visible = recipient == Recipient.LINKED_ACTOR and trigger != Trigger.ON_BATCH_COMPLETE
		&"nearby_targeting":
			visible = recipient == Recipient.NEARBY_TARGETS
		&"fire_limit":
			visible = once_policy != OncePolicy.PER_EXECUTION
	if not visible:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if not Trigger.values().has(trigger) or not Recipient.values().has(recipient) \
			or not OncePolicy.values().has(once_policy) or not TimingFilter.values().has(timing_filter):
		return &"invalid_reaction_selector"
	if actions.is_empty() or (once_policy != OncePolicy.PER_EXECUTION and fire_limit < 0) \
			or (required_provenance & excluded_provenance & ~ORIGINAL_PROVENANCE):
		return &"invalid_reaction_configuration"
	if trigger != Trigger.ON_EFFECT_REMOVED and recipient == Recipient.REMOVAL_INSTIGATOR:
		return &"requires_effect_removal"
	if trigger == Trigger.ON_EFFECT_REMOVED and recipient != Recipient.REMOVAL_INSTIGATOR \
			and not RemovalFilter.values().has(removal_reason):
		return &"invalid_reaction_removal_reason"
	if trigger == Trigger.ON_BATCH_COMPLETE \
			and (once_policy == OncePolicy.PER_EXECUTION_TARGET or recipient == Recipient.TARGET):
		return &"batch_has_no_single_target"
	if recipient == Recipient.LINKED_ACTOR and (link_slot.is_empty() \
			or not is_finite(link_range) or link_range < 0.0):
		return &"invalid_reaction_link"
	if recipient == Recipient.NEARBY_TARGETS and (nearby_targeting == null \
			or nearby_targeting.shape < AbilityTargetingDefinition.Shape.SPHERE \
			or nearby_targeting.require_line_of_sight \
			or not nearby_targeting.get_validation_error().is_empty()):
		return &"reaction_requires_registry_area_query"
	for action in actions:
		if action == null:
			return &"missing_reaction_action"
		if once_policy == OncePolicy.PER_EVENT and fire_limit == 0 \
				and ((trigger == Trigger.ON_HEAL and action is HealReactionAction) \
				or (trigger == Trigger.ON_RESOURCE_RESTORED and action is RestoreResourceReactionAction)):
			return &"requires_reaction_loop_limit"
		var error := action.get_validation_error(trigger)
		if not error.is_empty():
			return error
	return &""


func matches(outcome: CombatOutcome) -> bool:
	var context := outcome.context
	var required_flags := required_provenance & ~ORIGINAL_PROVENANCE
	var excluded_flags := excluded_provenance & ~ORIGINAL_PROVENANCE
	if (context.provenance & required_flags) != required_flags or context.provenance & excluded_flags:
		return false
	if timing_filter != TimingFilter.ANY and int(context.timing) != int(timing_filter) - 1:
		return false
	if not required_delivery.is_empty() and context.delivery != required_delivery:
		return false
	var event := outcome.get_event()
	var tags: PackedStringArray = event.get("ability_tags", PackedStringArray())
	for tag in required_ability_tags:
		if not _has_tag(tags, StringName(tag)):
			return false
	for tag in blocked_ability_tags:
		if _has_tag(tags, StringName(tag)):
			return false
	match trigger:
		Trigger.ON_HIT:
			return outcome.is_confirmed_hit()
		Trigger.ON_HEALTH_DAMAGED:
			return outcome.kind == CombatOutcome.Kind.DAMAGE and outcome.get_amount(&"health_damage") > 0.0
		Trigger.ON_STATUS_APPLIED:
			return outcome.kind == CombatOutcome.Kind.STATUS and event["type"] == &"status_applied"
		Trigger.ON_KILL:
			return outcome.kind == CombatOutcome.Kind.KILL
		Trigger.ON_HEAL:
			return outcome.kind == CombatOutcome.Kind.HEALING and bool(event.get("proc_eligible", true)) \
					and outcome.get_amount(&"scaled_healing") > 0.0
		Trigger.ON_RESOURCE_RESTORED:
			return outcome.kind == CombatOutcome.Kind.RESOURCE and bool(event.get("publish_outcome", true)) \
					and outcome.get_amount(&"actual_delta") > 0.0
		Trigger.ON_BATCH_COMPLETE:
			return outcome.kind == CombatOutcome.Kind.BATCH_COMPLETE
		Trigger.ON_EFFECT_REMOVED:
			var reason := RemovalFilter.DISPELLED if recipient == Recipient.REMOVAL_INSTIGATOR else removal_reason
			return outcome.kind == CombatOutcome.Kind.EFFECT_REMOVED \
					and (reason == RemovalFilter.ANY or int(event.get("removal_reason", -1)) == reason)
		Trigger.ON_EFFECT_THRESHOLD:
			return outcome.kind == CombatOutcome.Kind.EFFECT_THRESHOLD
		Trigger.ON_DAMAGE_RESOLVED:
			return outcome.kind == CombatOutcome.Kind.DAMAGE and event.get("outcome") != &"immune" \
					and outcome.get_amount(&"raw_magnitude") > 0.0
	return false


func resolve_recipient(outcome: CombatOutcome) -> ActorAttributes:
	var context := outcome.context
	match recipient:
		Recipient.CREDITED_OWNER:
			return context.actor(CombatOutcomeContext.Role.CREDITED_OWNER)
		Recipient.TARGET:
			return CombatOutcomeContext.resolve_actor(outcome.target_id)
		Recipient.EXECUTING_ACTOR:
			return context.actor(CombatOutcomeContext.Role.EXECUTING_ACTOR)
		Recipient.REQUESTER:
			return context.actor(CombatOutcomeContext.Role.REQUESTER)
		Recipient.RESOURCE_PAYER:
			return context.actor(CombatOutcomeContext.Role.RESOURCE_PAYER)
		Recipient.ORIGINAL_SOURCE:
			return context.actor(CombatOutcomeContext.Role.ORIGINAL_SOURCE)
		Recipient.DELIVERY_OWNER:
			return context.actor(CombatOutcomeContext.Role.DELIVERY_OWNER)
		Recipient.REMOVAL_INSTIGATOR:
			return CombatOutcomeContext.resolve_actor(int(outcome.get_event().get("dispeller_id", 0)))
		Recipient.LINKED_ACTOR:
			return _resolve_link(outcome)
	return null


func resolve_recipients(outcome: CombatOutcome) -> Array[ActorAttributes]:
	var actors: Array[ActorAttributes] = []
	if recipient != Recipient.NEARBY_TARGETS:
		var actor := resolve_recipient(outcome)
		if actor != null:
			actors.append(actor)
		return actors
	var source := CombatOutcomeContext.resolve_system(
			outcome.context.actor(CombatOutcomeContext.Role.CREDITED_OWNER))
	if source == null:
		return actors
	var target := CombatOutcomeContext.resolve_system(CombatOutcomeContext.resolve_actor(outcome.target_id))
	var incoming: AbilityTargetSet
	if nearby_targeting.origin == AbilityTargetingDefinition.Origin.CONTACT:
		var event := outcome.get_event()
		var body := AbilityTargetingDefinition.actor_spatial(target)
		if not event.has("hit_position") and (body == null or not body.is_inside_tree()):
			return actors
		incoming = AbilityTargetSet.new()
		incoming.transform.origin = event["hit_position"] if event.has("hit_position") else body.global_position
	var result: AbilityTargetSet = nearby_targeting.select_from(source, incoming, null,
			target.get_instance_id() if target != null else 0)
	for contact in result.contacts:
		var system := contact.get_target()
		if system != null and is_instance_valid(system.attributes):
			actors.append(system.attributes)
	return actors


func _resolve_link(outcome: CombatOutcome) -> ActorAttributes:
	var owner := outcome.context.actor(CombatOutcomeContext.Role.CREDITED_OWNER)
	var system := CombatOutcomeContext.resolve_system(owner)
	if system == null or system.effects == null:
		return null
	var target: ActorAttributes = system.effects.get_exclusive_slot_target(link_slot)
	if not is_instance_valid(target) or (link_exclude_trigger_target and target.get_instance_id() == outcome.target_id):
		return null
	if link_range > 0.0:
		var owner_body := owner.get_parent() as Node3D
		var target_body := target.get_parent() as Node3D
		if owner_body == null or target_body == null or not owner_body.is_inside_tree() \
				or not target_body.is_inside_tree() or owner_body.get_world_3d() != target_body.get_world_3d() \
				or owner_body.global_position.distance_squared_to(target_body.global_position) > link_range * link_range:
			return null
	return target


func claim(outcome: CombatOutcome, attachment_key: String, attack_use: Callable) -> StringName:
	var scope := outcome.context._execution
	var max_fires := 0 if once_policy == OncePolicy.PER_EXECUTION else fire_limit
	var fire_count: int = scope.reaction_fires.get(attachment_key, 0)
	if max_fires > 0 and fire_count >= max_fires:
		return &"fire_limit"
	var identity: int
	match once_policy:
		OncePolicy.PER_EVENT:
			identity = outcome.id
		OncePolicy.PER_EXECUTION_TARGET:
			identity = outcome.target_id
			if identity == 0:
				return &"missing_target"
		OncePolicy.PER_ATTACK:
			identity = outcome.context.attack_execution_id
		OncePolicy.PER_EXECUTION:
			identity = outcome.context.root_execution_id
	var claim_key := "%s:%d" % [attachment_key, identity]
	if scope.reaction_claims.has(claim_key):
		return &"once_policy"
	if not attack_use.is_null() and (not attack_use.is_valid() or not bool(attack_use.call(outcome))):
		return &"attack_use_budget"
	# The dispatcher delivers each event once. Keep only cross-event claims on the execution.
	if once_policy != OncePolicy.PER_EVENT:
		scope.reaction_claims[claim_key] = true
	if max_fires > 0:
		scope.reaction_fires[attachment_key] = fire_count + 1
	return &""


static func _has_tag(tags: PackedStringArray, query: StringName) -> bool:
	for tag in tags:
		if GameplayTagSet.matches(StringName(tag), query):
			return true
	return false
