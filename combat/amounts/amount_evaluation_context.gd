class_name AmountEvaluationContext
extends RefCounted
## Per-evaluation inputs. Captures hold numeric values and never retain actor nodes.

var source: ActorAttributes
var target: ActorAttributes
var recipient: ActorAttributes
var payer: ActorAttributes
var scope_tags := PackedStringArray()
var effect_context: GameplayEffectContext
var outcome: CombatOutcome
var spend_receipt: ResourceSpendReceipt
var accumulator: float = NAN
var stack_count: int = 0
var rank: int = 0
var snapshot: AmountEvaluationContext

var _captured_stats: Dictionary[int, Dictionary] = {}
var _captured_levels: Dictionary[int, int] = {}
var _captured_actor_ids: Dictionary[int, int] = {}


## Capture the actor inputs available at the requested activation, batch, or application boundary.
func capture() -> AmountEvaluationContext:
	var captured := AmountEvaluationContext.new()
	for role: AmountDefinition.ActorRole in AmountDefinition.ActorRole.values():
		var actor := _get_actor(role)
		var level := read_level(role, AmountDefinition.Timing.LIVE)
		if not is_instance_valid(actor) and not is_finite(level):
			continue
		var values: Dictionary[int, float] = {}
		for attribute: int in CombatAttributes.all_ids():
			values[attribute] = read_stat(role, attribute, AmountDefinition.Timing.LIVE)
		values.make_read_only()
		captured._captured_stats[role] = values
		captured._captured_levels[role] = int(level)
		captured._captured_actor_ids[role] = _get_actor_id(role)
	captured._captured_stats.make_read_only()
	captured._captured_levels.make_read_only()
	captured._captured_actor_ids.make_read_only()
	return captured


func read_stat(role: AmountDefinition.ActorRole, attribute: int, timing: AmountDefinition.Timing) -> float:
	if timing == AmountDefinition.Timing.SNAPSHOT:
		if not _matches_snapshot(role):
			return NAN
		return snapshot._captured_stats[role].get(attribute, NAN)
	if role == AmountDefinition.ActorRole.SOURCE and effect_context != null:
		return effect_context.get_source_value(attribute, scope_tags) if effect_context.source_id != 0 else NAN
	var actor := _get_actor(role)
	return actor.get_value(attribute, scope_tags) if is_instance_valid(actor) else NAN


func read_level(role: AmountDefinition.ActorRole, timing: AmountDefinition.Timing) -> float:
	if timing == AmountDefinition.Timing.SNAPSHOT:
		if not _matches_snapshot(role):
			return NAN
		return float(snapshot._captured_levels[role])
	if role == AmountDefinition.ActorRole.SOURCE and effect_context != null:
		return float(effect_context.source_level) if effect_context.source_id != 0 else NAN
	var actor := _get_actor(role)
	return float(actor.level) if is_instance_valid(actor) else NAN


func _matches_snapshot(role: AmountDefinition.ActorRole) -> bool:
	if snapshot == null or not snapshot._captured_actor_ids.has(role):
		return false
	var live_id := _get_actor_id(role)
	# A detached source or payer may still contribute its captured values after it leaves play.
	if live_id == 0:
		return role == AmountDefinition.ActorRole.SOURCE or role == AmountDefinition.ActorRole.PAYER
	return live_id == snapshot._captured_actor_ids[role]


func _get_actor_id(role: AmountDefinition.ActorRole) -> int:
	if role == AmountDefinition.ActorRole.SOURCE and effect_context != null:
		return effect_context.source_id
	var actor := _get_actor(role)
	return actor.get_instance_id() if is_instance_valid(actor) else 0


func _get_actor(role: AmountDefinition.ActorRole) -> ActorAttributes:
	match role:
		AmountDefinition.ActorRole.SOURCE:
			return source
		AmountDefinition.ActorRole.TARGET:
			return target
		AmountDefinition.ActorRole.RECIPIENT:
			return recipient
		AmountDefinition.ActorRole.PAYER:
			return payer
	return null
