@tool
class_name AmountDefinition
extends Resource
## Inspector-authored magnitude using a typed basis and explicit evaluation timing.

## Selects which value supplies the magnitude before optional clamping.
enum Source {
	## Uses the authored Fixed Amount directly.
	FIXED,
	## Takes a percentage of the selected actor's effective attribute.
	STAT_PERCENT,
	## Takes a percentage of the selected actor's current, maximum, or missing pool points.
	RESOURCE_PERCENT,
	## Samples the authored curve at the selected actor level or ability rank.
	LEVEL_CURVE,
	## Takes a percentage of the selected numeric field on the triggering combat outcome.
	OUTCOME_PERCENT,
	## Takes a percentage of the actual committed spend, optionally mapped through a curve.
	SPEND_PERCENT,
	## Takes a percentage of a running total supplied by the owning effect.
	ACCUMULATOR_PERCENT,
	## Samples the authored curve at the current effect stack count.
	STACK_PROGRESSION,
	## Multiplies Amount per Target by the unique count reported by the completed batch.
	UNIQUE_TARGET_COUNT,
}

## Selects whose stat, pool, or level supplies the magnitude.
enum ActorRole {
	## Uses the actor supplying the outgoing action or effect.
	SOURCE,
	## Uses the target of the delivery or triggering outcome.
	TARGET,
	## Uses the actor receiving the action currently being evaluated.
	RECIPIENT,
	## Uses the actor who pays the activation's resource cost.
	PAYER,
}

## Identifies the current pool used to read resource points or committed spend.
enum Pool {
	## Uses Health, the pool changed by damage and healing.
	HEALTH,
	## Uses Mana, the pool available for spell costs.
	MANA,
	## Uses Stamina, the pool available for exertion costs.
	STAMINA,
}

## Selects the quantity read from a resource pool for Resource Percent.
enum ResourceBasis {
	## Reads the amount currently available in the pool.
	CURRENT,
	## Reads the pool's effective maximum capacity.
	MAXIMUM,
	## Reads how many points would fill the pool to capacity.
	MISSING,
}

## Selects the measured field of the triggering combat outcome.
enum OutcomeBasis {
	## Uses committed Health loss, capped by the Health the target had left.
	ACTUAL_HEALTH_DAMAGE,
	## Uses damage after source scaling and before criticals and target defenses.
	RAW_DAMAGE,
	## Uses damage after defenses and prevention, before the available Health cap.
	RESOLVED_DAMAGE,
	## Uses the Health actually restored after incoming rules and the capacity cap.
	ACTUAL_HEALING,
	## Uses healing after source and recipient scaling, before healing absorption.
	SCALED_HEALING,
	## Uses healing left over after absorption and available Health capacity.
	OVERHEAL,
	## Uses the committed signed change in Mana or Stamina.
	ACTUAL_RESOURCE_DELTA,
}

## Declares the result's unit so consumers can check that they accept it.
enum Unit {
	## Returns flat damage, healing, resource, or other native points.
	POINTS,
	## Returns a duration measured in seconds.
	SECONDS,
	## Returns a count, such as the number of unique targets.
	COUNT,
	## Returns a scale factor, where 1.0 leaves the input unchanged.
	MULTIPLIER,
	## Returns percentage points, where 10.0 represents ten percentage points.
	PERCENTAGE_POINTS,
}

## Chooses when actor inputs are read for stat, resource, and actor-level sources.
enum Timing {
	## Reads the actor's effective values when the amount is evaluated.
	LIVE,
	## Reads values captured at the activation, batch, or effect application boundary.
	SNAPSHOT,
}

## Selects the horizontal input of a level or rank curve.
enum CurveInput {
	## Samples at the selected actor's current or captured character level.
	ACTOR_LEVEL,
	## Samples at the active ability grant's rank.
	ABILITY_RANK,
}

## Selects a fixed, actor, curve, outcome, spend, accumulator, stack, or batch input.
## The Inspector shows the fields used by the selected input.
@export var source: Source = Source.FIXED:
	set(value):
		if source == value:
			return
		source = value
		notify_property_list_changed()
## Units returned after scaling and optional clamping. The consuming action validates this field.
@export var unit: Unit = Unit.POINTS
## Constant value in the selected output unit when Source is Fixed.
@export var fixed_amount: float = 0.0
## Percentage of the chosen basis. A value of 10 means 10%, serialized as 10.0.
@export_range(0.0, 100.0, 0.01, "or_greater", "suffix:%") var percentage: float = 100.0
## Actor whose attribute, level or resource provides the selected basis.
@export var actor: ActorRole = ActorRole.SOURCE
## Native attribute for Stat Percent, using the active Combat 2.0 catalogue.
@export var stat: CombatAttributes.Id = CombatAttributes.Id.MAGIC_POWER
## Pool for Resource Percent or Spend Percent.
@export var resource: Pool = Pool.MANA
## Selects current, maximum, or missing points for Resource Percent.
@export var resource_basis: ResourceBasis = ResourceBasis.MAXIMUM
## Numeric field of the current typed outcome. An incompatible outcome is an evaluation failure.
@export var outcome_basis: OutcomeBasis = OutcomeBasis.ACTUAL_HEALTH_DAMAGE
## Reads actor inputs live or from the capture supplied at the authoring boundary.
@export var timing: Timing = Timing.LIVE
## Samples the curve by actor level or by the active ability grant's rank.
@export var curve_input: CurveInput = CurveInput.ACTOR_LEVEL:
	set(value):
		if curve_input == value:
			return
		curve_input = value
		notify_property_list_changed()
## Maps actual level, rank, or stack count to an amount. For Spend Percent, an optional
## curve maps actual spent points to a replacement basis before applying Percentage.
@export var curve: Curve
## Output units per unique target reported by a completed batch. One returns the unchanged count.
@export_range(0.0, 10000.0, 0.01, "or_greater") var amount_per_target: float = 1.0
## Enables lower and upper bounds in the selected output unit.
@export var clamp_enabled: bool = false:
	set(value):
		if clamp_enabled == value:
			return
		clamp_enabled = value
		notify_property_list_changed()
## Inclusive lower bound when Clamp Enabled is active.
@export var minimum: float = 0.0
## Inclusive upper bound when Clamp Enabled is active.
@export var maximum: float = 100.0


static func fixed(points: float) -> AmountDefinition:
	var amount := AmountDefinition.new()
	amount.fixed_amount = points
	return amount


func _validate_property(property: Dictionary) -> void:
	var visible := true
	match property.name:
		&"fixed_amount":
			visible = source == Source.FIXED
		&"percentage":
			visible = source != Source.FIXED and source != Source.UNIQUE_TARGET_COUNT
		&"actor", &"timing":
			visible = _uses_actor_input()
		&"stat":
			property.hint = PROPERTY_HINT_ENUM
			property.hint_string = CombatAttributes.inspector_hint(false)
			visible = source == Source.STAT_PERCENT
		&"resource":
			visible = source == Source.RESOURCE_PERCENT or source == Source.SPEND_PERCENT
		&"resource_basis":
			visible = source == Source.RESOURCE_PERCENT
		&"outcome_basis":
			visible = source == Source.OUTCOME_PERCENT
		&"curve_input":
			visible = source == Source.LEVEL_CURVE
		&"curve":
			visible = source in [Source.LEVEL_CURVE, Source.SPEND_PERCENT, Source.STACK_PROGRESSION]
		&"amount_per_target":
			visible = source == Source.UNIQUE_TARGET_COUNT
		&"minimum", &"maximum":
			visible = clamp_enabled
	if not visible:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func _uses_actor_input() -> bool:
	return source == Source.STAT_PERCENT or source == Source.RESOURCE_PERCENT \
			or (source == Source.LEVEL_CURVE and curve_input == CurveInput.ACTOR_LEVEL)


func get_validation_error(expected_unit: int = -1) -> StringName:
	if not source in Source.values() or not unit in Unit.values():
		return &"invalid_amount_source_or_unit"
	if expected_unit >= 0 and unit != expected_unit:
		return &"incompatible_amount_unit"
	if clamp_enabled and (not is_finite(minimum) or not is_finite(maximum) or minimum > maximum):
		return &"invalid_amount_bounds"
	if source == Source.FIXED:
		return &"" if is_finite(fixed_amount) else &"invalid_fixed_amount"
	if source == Source.UNIQUE_TARGET_COUNT:
		return &"" if is_finite(amount_per_target) and amount_per_target >= 0.0 else &"invalid_amount_per_target"
	if not is_finite(percentage) or percentage < 0.0:
		return &"invalid_amount_percentage"
	if _uses_actor_input() and (not actor in ActorRole.values() or not timing in Timing.values()):
		return &"invalid_amount_actor_or_timing"
	match source:
		Source.STAT_PERCENT:
			if not CombatAttributes.is_active(stat):
				return &"invalid_amount_stat"
		Source.RESOURCE_PERCENT, Source.SPEND_PERCENT:
			if not resource in Pool.values() or (
					source == Source.RESOURCE_PERCENT and not resource_basis in ResourceBasis.values()):
				return &"invalid_amount_resource"
		Source.OUTCOME_PERCENT:
			if not outcome_basis in OutcomeBasis.values():
				return &"invalid_amount_outcome_basis"
		Source.LEVEL_CURVE:
			if not curve_input in CurveInput.values() or not _has_curve():
				return &"invalid_amount_level_curve"
		Source.STACK_PROGRESSION:
			if not _has_curve():
				return &"invalid_amount_stack_curve"
	return &""


## Returns NAN when the authoring or inputs are invalid; zero is a valid evaluated amount.
func evaluate(context: AmountEvaluationContext = null) -> float:
	if not get_validation_error().is_empty():
		return NAN
	var value := fixed_amount
	if source != Source.FIXED:
		if context == null:
			return NAN
		var factor := amount_per_target if source == Source.UNIQUE_TARGET_COUNT else percentage / 100.0
		value = _evaluate_basis(context) * factor
	if not is_finite(value):
		return NAN
	return clampf(value, minimum, maximum) if clamp_enabled else value


func _evaluate_basis(context: AmountEvaluationContext) -> float:
	match source:
		Source.STAT_PERCENT:
			return context.read_stat(actor, stat, timing)
		Source.RESOURCE_PERCENT:
			return _resource_value(context)
		Source.LEVEL_CURVE:
			if curve_input == CurveInput.ABILITY_RANK:
				return _sample_curve(float(context.rank)) if context.rank > 0 else NAN
			return _sample_curve(context.read_level(actor, timing))
		Source.OUTCOME_PERCENT:
			return _outcome_value(context.outcome)
		Source.SPEND_PERCENT:
			if context.spend_receipt == null:
				return NAN
			var spent := context.spend_receipt.get_spent(pool_attribute(resource))
			return _sample_curve(spent) if curve != null else spent
		Source.ACCUMULATOR_PERCENT:
			return context.accumulator
		Source.STACK_PROGRESSION:
			return _sample_curve(float(context.stack_count)) if context.stack_count > 0 else NAN
		Source.UNIQUE_TARGET_COUNT:
			if context.outcome != null and context.outcome.kind == CombatOutcome.Kind.BATCH_COMPLETE:
				return context.outcome.get_amount(&"unique_target_count")
	return NAN


func _resource_value(context: AmountEvaluationContext) -> float:
	var current_id := pool_attribute(resource)
	if resource_basis == ResourceBasis.CURRENT:
		return context.read_stat(actor, current_id, timing)
	var capacity := context.read_stat(actor, CombatAttributes.maximum_for(current_id), timing)
	if resource_basis == ResourceBasis.MAXIMUM:
		return capacity
	var current := context.read_stat(actor, current_id, timing)
	return maxf(0.0, capacity - current) if is_finite(current) and is_finite(capacity) else NAN


func _outcome_value(outcome: CombatOutcome) -> float:
	if outcome == null:
		return NAN
	match outcome.kind:
		CombatOutcome.Kind.DAMAGE:
			match outcome_basis:
				OutcomeBasis.ACTUAL_HEALTH_DAMAGE:
					return outcome.get_amount(&"health_damage")
				OutcomeBasis.RAW_DAMAGE:
					return outcome.get_amount(&"raw_magnitude")
				OutcomeBasis.RESOLVED_DAMAGE:
					return outcome.get_amount(&"resolved_amount")
		CombatOutcome.Kind.HEALING:
			match outcome_basis:
				OutcomeBasis.ACTUAL_HEALING:
					return outcome.get_amount(&"actual_restoration")
				OutcomeBasis.SCALED_HEALING:
					return outcome.get_amount(&"scaled_healing")
				OutcomeBasis.OVERHEAL:
					return outcome.get_amount(&"overheal")
		CombatOutcome.Kind.RESOURCE:
			if outcome_basis == OutcomeBasis.ACTUAL_RESOURCE_DELTA:
				return outcome.get_amount(&"actual_delta")
	return NAN


func _has_curve() -> bool:
	return curve != null and curve.point_count > 0


func _sample_curve(input: float) -> float:
	if not _has_curve() or not is_finite(input):
		return NAN
	return curve.sample(clampf(input, curve.min_domain, curve.max_domain))


static func pool_attribute(pool: Pool) -> int:
	match pool:
		Pool.HEALTH:
			return CombatAttributes.Id.HEALTH
		Pool.MANA:
			return CombatAttributes.Id.MANA
		Pool.STAMINA:
			return CombatAttributes.Id.STAMINA
	return CombatAttributes.Id.NONE
