@tool
class_name GameplayEffectDefinition
extends Resource
## Authored Gameplay Effect modifiers, execution calculations, and lifetime rules.

## When the effect executes and how long it remains on its target.
enum Timing {
	## Executes once and leaves no active effect.
	INSTANT = 0,
	## Retains the effect for the authored duration.
	DURATION = 1,
	## Retains the effect until its handle is removed.
	INFINITE = 2,
}
## Period behavior when an inhibited effect becomes active again.
enum PeriodInhibitionPolicy {
	## Keeps the original tick cadence and skips ticks while inhibited.
	NEVER_RESET = 0,
	## Schedules the next tick one period after inhibition ends.
	RESET_PERIOD = 1,
	## Executes as inhibition ends and starts a fresh period.
	EXECUTE_AND_RESET_PERIOD = 2,
}
## Determines which retained applications share an active handle and stack count.
enum StackingType {
	## Each accepted application owns a separate handle and timer.
	INDEPENDENT,
	## Reapplications of this asset from the same original source share one handle.
	AGGREGATE_BY_SOURCE,
	## Reapplications of this asset from any source share one target-owned handle.
	AGGREGATE_BY_TARGET,
}
## Controls the active lifetime on an accepted reapplication.
enum StackDurationPolicy {
	## Replaces the remaining lifetime with the new application's full duration.
	REFRESH,
	## Preserves the current expiration deadline.
	NEVER_REFRESH,
	## Adds the new application's duration to the current deadline.
	EXTEND,
}
## Controls the execution cadence on an accepted reapplication.
enum StackPeriodPolicy {
	## Schedules the next tick one period after reapplication.
	RESET,
	## Keeps the current periodic schedule.
	NEVER_RESET,
}
## Controls what expiration removes from an aggregate stack.
enum StackExpirationPolicy {
	## Removes the handle and all its stacks at expiry.
	CLEAR_ALL,
	## Removes one stack and refreshes the remaining lifetime while stacks remain.
	REMOVE_ONE_AND_REFRESH,
	## Refreshes duration without removing a stack.
	REFRESH,
}
## Selects Physical Power or Magic Power independently of the action's delivery.
enum DamageType {
	## Uses the action's applicable Physical Power contribution.
	PHYSICAL = 0,
	## Uses Magic Power from Intellect and other applicable bonuses.
	MAGIC = 1,
}
## The school of a Magic damage component, selecting its matching target Resistance.
enum MagicSchool {
	## Fire damage is reduced by Fire Resistance.
	FIRE = 0,
	## Cold damage is reduced by Cold Resistance.
	COLD = 1,
	## Lightning damage is reduced by Lightning Resistance.
	LIGHTNING = 2,
	## Void damage is reduced by Void Resistance.
	VOID = 3,
	## Necrotic damage is reduced by Necrotic Resistance.
	NECROTIC = 4,
}
## Chooses which player HUD strip shows a retained effect.
enum HudCategory {
	## Hides this effect from the HUD.
	NONE = 0,
	## Shows its icon in the left-to-right buff strip.
	BUFF = 1,
	## Shows its icon in the right-to-left debuff strip.
	DEBUFF = 2,
}

const DAMAGE_IDENTITY_TAGS: Array[String] = [
	"Damage.Physical", "Damage.Magic", "Damage.Fire", "Damage.Cold",
	"Damage.Lightning", "Damage.Void", "Damage.Necrotic", "Damage.Direct", "Damage.Periodic",
]
const DAMAGE_EDITOR_FIELDS: PackedStringArray = [
	"damage_type", "magic_school", "damage_tags", "damage_profile",
]
const RETAINED_EDITOR_FIELDS: PackedStringArray = [
	"hud_category", "period", "granted_tags", "ongoing_required_target_tags",
	"ongoing_blocked_target_tags", "stacking_type",
]
const PERIODIC_EDITOR_FIELDS: PackedStringArray = [
	"execute_periodic_on_application", "period_inhibition_policy", "snapshot_source",
]

## Stable positive integer used to find and report this effect. Keep it unique across abilities and effects.
## Zero leaves the ID unassigned.
@export var effect_id: int = 0
## Human-readable name used in combat feedback and the log.
@export var display_name: String = ""
## Optional texture that represents this effect in the Ability Editor.
## A retained effect also uses it on the player HUD when a HUD category is set.
@export var icon: Texture2D
## Display group for the retained icon. This choice affects presentation only.
@export var hud_category: HudCategory = HudCategory.NONE:
	set(value):
		hud_category = value
		notify_property_list_changed()
## Instant executes once. Duration expires after its lifetime. Infinite requires handle removal.
@export var timing: Timing = Timing.INSTANT:
	set(value):
		timing = value
		notify_property_list_changed()
## Tags identifying the effect asset itself. These do not grant actor state.
@export var asset_tags: PackedStringArray = PackedStringArray()
## Presentation cues dispatched by the target's cue router when this effect executes or changes state.
@export var gameplay_cue_tags: PackedStringArray = PackedStringArray()
## Physical uses Physical Power; Magic uses Magic Power and its matching school Resistance.
## Neither damage type applies a hidden status or changes the attack/spell Accuracy check.
@export var damage_type: DamageType = DamageType.PHYSICAL:
	set(value):
		damage_type = value
		notify_property_list_changed()
## School used only by Magic damage, selecting Fire/Cold/Lightning/Void/Necrotic Resistance.
## Physical damage and retained modifiers ignore this field. Fire is the default for existing spells.
@export var magic_school: MagicSchool = MagicSchool.FIRE
## Optional defense-stage and nonlethal policy. Empty keeps the live Combat 2.0 defaults.
@export var damage_profile: DamageProfile
## Additional effect/damage tags used to select applicable stat modifiers for this payload.
## Ability/Weapon hierarchies are reserved; damage identity tags must match the type/school fields.
@export var damage_tags: PackedStringArray = PackedStringArray()
## Counted actor tags owned by the effect while retained and uninhibited.
@export var granted_tags: PackedStringArray = PackedStringArray()
## All listed tags must be present on the target before application.
@export var required_target_tags: PackedStringArray = PackedStringArray()
## Any matching target tag prevents application; parent tags match descendants.
@export var blocked_target_tags: PackedStringArray = PackedStringArray(["State.Dead"])
## Lifetime in seconds for Duration policy. Use Infinite for new indefinite effects.
@export_range(0.0, 3600.0, 0.1, "or_greater") var duration: float = 0.0
## Seconds between executions on a retained effect. Zero retains continuous modifiers instead.
@export_range(0.0, 3600.0, 0.01, "or_greater") var period: float = 0.0:
	set(value):
		period = value
		notify_property_list_changed()
## Executes a periodic effect as soon as it is successfully applied and uninhibited.
@export var execute_periodic_on_application: bool = true
## Controls the tick cadence when a retained effect becomes uninhibited.
@export var period_inhibition_policy: PeriodInhibitionPolicy = PeriodInhibitionPolicy.NEVER_RESET
## All listed tags must stay present for the effect's modifiers, executions and grants to be active.
@export var ongoing_required_target_tags: PackedStringArray = PackedStringArray()
## Any matching tag inhibits the retained effect without removing its handle or stopping expiration.
@export var ongoing_blocked_target_tags: PackedStringArray = PackedStringArray()
## Modifiers applied once by Instant or once per Period. Nonperiodic retained effects own the
## adjustments for their active lifetime and cannot retain modifiers on current pools.
@export var modifiers: Array[AttributeModifier] = []
## Calculations run on Instant application or each Period. Use modifiers for persistent adjustments.
@export var executions: Array[GameplayEffectExecution] = []:
	set(value):
		executions = value
		notify_property_list_changed()
@export_group("Stacking")
## Aggregate only repeated applications of this same effect resource. Independent uses separate handles.
@export var stacking_type: StackingType = StackingType.INDEPENDENT:
	set(value):
		stacking_type = value
		notify_property_list_changed()
## Maximum count per aggregate handle. Zero allows any number of stacks.
@export_range(0, 100, 1, "or_greater") var stack_limit_count: int = 0:
	set(value):
		stack_limit_count = value
		notify_property_list_changed()
## Rejects applications that exceed the stack limit. Otherwise the capped stack can still refresh.
@export var deny_overflow_application: bool = false:
	set(value):
		deny_overflow_application = value
		notify_property_list_changed()
## Removes the existing stack when an overflowing application is denied.
@export var clear_stack_on_overflow: bool = false
## Refreshes, preserves, or extends the remaining duration on accepted reapplication.
@export var stack_duration_policy: StackDurationPolicy = StackDurationPolicy.REFRESH
## Resets or preserves the next periodic deadline on accepted reapplication.
@export var stack_period_policy: StackPeriodPolicy = StackPeriodPolicy.RESET
## On expiry, remove the stack, remove one stack and refresh, or refresh without removing stacks.
@export var stack_expiration_policy: StackExpirationPolicy = StackExpirationPolicy.CLEAR_ALL
@export_group("")
## Optional reusable effect behaviors such as granting abilities or removing matching active effects.
@export var components: Array[GameplayEffectComponent] = []
## Optional independent status profile. A damaging payload applies a separate status effect.
@export var status_profile: StatusProfile
## Captures source stat inputs at application so later ticks retain the same source basis.
@export var snapshot_source: bool = false
## Includes a scheduled tick exactly on the expiration deadline. Existing effects include it.
@export var tick_at_end: bool = true
## Optional slot shared by this source's retained effects. A successful application replaces its occupant.
@export var exclusive_owner_slot: StringName:
	set(value):
		exclusive_owner_slot = value
		notify_property_list_changed()
## Allows explicit transfer of remaining time, cadence, stacks and supported owned state.
@export var transferable: bool = false
## Reactions scoped to outcomes emitted by this effect, including its retained periodic execution.
@export var reactions: Array[ReactionDefinition] = []


func get_validation_error() -> StringName:
	var damage := is_damage_effect()
	if damage:
		if damage_type not in DamageType.values():
			return &"Effect.InvalidDamageType"
		for tag in damage_tags:
			if AttributeModifier._has_match(PackedStringArray([tag]), "Ability") \
					or AttributeModifier._has_match(PackedStringArray([tag]), "Weapon"):
				return &"Effect.ReservedContextTag"
			var identity := _damage_identity(tag)
			var type_tag := "Damage.Physical" if damage_type == DamageType.PHYSICAL else "Damage.Magic"
			if not identity.is_empty() and identity != type_tag and identity != get_magic_school_tag() \
					and identity != get_damage_timing_tag():
				return &"Effect.ConflictingDamageTag"
	if timing == Timing.DURATION and (not is_finite(duration) or duration < 0.0):
		return &"Effect.InvalidDuration"
	if timing not in Timing.values():
		return &"Effect.InvalidTiming"
	if timing != Timing.INSTANT:
		var retained_failure := _get_retained_validation_error()
		if not retained_failure.is_empty():
			return retained_failure
	var instantaneous := executes_calculations()
	var damage_executions := 0
	if instantaneous:
		for execution in executions:
			if execution == null:
				return &"Effect.InvalidExecution"
			if execution is GameplayEffectDamageExecution:
				damage_executions += 1
				var amount_failure: StringName = execution.get_validation_error(self)
				if not amount_failure.is_empty():
					return amount_failure
	if damage_executions > 1:
		return &"Effect.MultipleDamageExecutions"
	if damage:
		if damage_type == DamageType.MAGIC and magic_school not in MagicSchool.values():
			return &"Effect.InvalidMagicSchool"
	if damage and damage_profile != null:
		var profile_failure := damage_profile.get_validation_error()
		if not profile_failure.is_empty():
			return profile_failure
	for modifier in modifiers:
		if not is_valid_modifier(modifier, instantaneous):
			return &"Effect.InvalidModifier"
	for component in components:
		if component == null:
			return &"Effect.InvalidComponent"
		var failure := component.get_validation_error(self)
		if not failure.is_empty():
			return failure
	var status := get_status_profile()
	if status != null:
		var status_failure := status.get_validation_error()
		if not status_failure.is_empty():
			return status_failure
		if status.resistance_effect == StatusProfile.ResistanceEffect.DURATION \
				and (timing != Timing.DURATION or duration <= 0.0):
			return &"Effect.InvalidStatusLifetime"
	for reaction in reactions:
		if reaction == null:
			return &"Effect.InvalidReaction"
	return &""


func _get_retained_validation_error() -> StringName:
	if not is_finite(period) or period < 0.0 \
			or (period > 0.0 and period_inhibition_policy not in PeriodInhibitionPolicy.values()):
		return &"Effect.InvalidTiming"
	if stacking_type not in StackingType.values():
		return &"Effect.InvalidStacking"
	if stacking_type != StackingType.INDEPENDENT:
		if stack_limit_count < 0 or (period > 0.0 and stack_period_policy not in StackPeriodPolicy.values()):
			return &"Effect.InvalidStacking"
		if timing == Timing.DURATION and (stack_duration_policy not in StackDurationPolicy.values() \
				or stack_expiration_policy not in StackExpirationPolicy.values()):
			return &"Effect.InvalidStacking"
	for grant in granted_tags:
		for block in ongoing_blocked_target_tags:
			if GameplayTagSet.matches(StringName(grant), StringName(block)):
				return &"Effect.SelfInhibitingTagGrant"
	return &""


func is_damage_effect() -> bool:
	return get_damage_execution() != null


func get_damage_execution() -> GameplayEffectDamageExecution:
	if not executes_calculations():
		return null
	for execution in executions:
		if execution is GameplayEffectDamageExecution:
			return execution
	return null


## Instant effects have no periodic schedule, even if their saved period is later reused.
func get_effective_period() -> float:
	return period if timing != Timing.INSTANT else 0.0


## Calculations execute immediately or on a retained periodic schedule.
func executes_calculations() -> bool:
	return timing == Timing.INSTANT or period > 0.0


## Returns the status policy active in this effect's current mode.
func get_status_profile() -> StatusProfile:
	return status_profile if timing != Timing.INSTANT and not is_damage_effect() else null


## Returns the active slot for retained effects with unambiguous source ownership.
func get_exclusive_owner_slot() -> StringName:
	if timing == Timing.INSTANT or stacking_type == StackingType.AGGREGATE_BY_TARGET:
		return &""
	return exclusive_owner_slot


## Transfers are available only on retained effects without an exclusive source slot.
func is_transferable() -> bool:
	return transferable and timing != Timing.INSTANT and get_exclusive_owner_slot().is_empty()


func _validate_property(property: Dictionary) -> void:
	if not _is_property_applicable(String(property.name)):
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func _is_property_applicable(name: String) -> bool:
	var retained := timing != Timing.INSTANT
	var duration_mode := timing == Timing.DURATION
	var periodic := get_effective_period() > 0.0
	var aggregate := retained and stacking_type != StackingType.INDEPENDENT
	if DAMAGE_EDITOR_FIELDS.has(name):
		return is_damage_effect() and (name != "magic_school" or damage_type == DamageType.MAGIC)
	if RETAINED_EDITOR_FIELDS.has(name):
		return retained
	if PERIODIC_EDITOR_FIELDS.has(name):
		return periodic
	match name:
		"duration":
			return duration_mode
		"executions":
			return executes_calculations()
		"stack_limit_count":
			return aggregate
		"deny_overflow_application":
			return aggregate and stack_limit_count > 0
		"clear_stack_on_overflow":
			return aggregate and stack_limit_count > 0 and deny_overflow_application
		"stack_duration_policy", "stack_expiration_policy":
			return aggregate and duration_mode
		"stack_period_policy":
			return aggregate and periodic
		"tick_at_end":
			return duration_mode and periodic
		"status_profile":
			return retained and not is_damage_effect()
		"exclusive_owner_slot":
			return retained and stacking_type != StackingType.AGGREGATE_BY_TARGET
		"transferable":
			return retained and get_exclusive_owner_slot().is_empty()
	return true


static func is_valid_modifier(modifier: AttributeModifier, instantaneous: bool) -> bool:
	if modifier == null or not CombatAttributes.is_active(modifier.attribute) \
			or not is_finite(modifier.value) or modifier.operation not in AttributeModifier.Operation.values():
		return false
	if modifier.operation == AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT:
		return not instantaneous and modifier.is_valid_final_movement_percent()
	if modifier.capture_attribute != CombatAttributes.Id.NONE \
			and (not CombatAttributes.is_active(modifier.capture_attribute) \
				or modifier.capture_attribute == modifier.attribute \
				or not is_finite(modifier.capture_coefficient)):
		return false
	if instantaneous:
		return modifier.operation != AttributeModifier.Operation.ADD_TO_FOUNDATION
	return not CombatAttributes.is_current_resource(modifier.attribute) \
			and not CombatAttributes.is_current_resource(modifier.capture_attribute)


## Maps this component's authored school to one Resistance; Physical/modifier effects select none.
func get_resistance_attribute() -> int:
	if not is_damage_effect() or damage_type != DamageType.MAGIC:
		return CombatAttributes.Id.NONE
	match magic_school:
		MagicSchool.FIRE:
			return CombatAttributes.Id.FIRE_RESISTANCE
		MagicSchool.COLD:
			return CombatAttributes.Id.COLD_RESISTANCE
		MagicSchool.LIGHTNING:
			return CombatAttributes.Id.LIGHTNING_RESISTANCE
		MagicSchool.VOID:
			return CombatAttributes.Id.VOID_RESISTANCE
		MagicSchool.NECROTIC:
			return CombatAttributes.Id.NECROTIC_RESISTANCE
	return CombatAttributes.Id.NONE


## Canonical school tag for this Magic damage component; other effect kinds/types have none.
func get_magic_school_tag() -> String:
	if get_resistance_attribute() == CombatAttributes.Id.NONE:
		return ""
	match magic_school:
		MagicSchool.FIRE:
			return "Damage.Fire"
		MagicSchool.COLD:
			return "Damage.Cold"
		MagicSchool.LIGHTNING:
			return "Damage.Lightning"
		MagicSchool.VOID:
			return "Damage.Void"
		MagicSchool.NECROTIC:
			return "Damage.Necrotic"
	return ""


## Canonical timing tag for damage. Retained damage executes through a periodic calculation.
func get_damage_timing_tag() -> String:
	return "Damage.Periodic" if get_effective_period() > 0.0 else "Damage.Direct"


## Copies delivery tags and adds this effect's damage type, Magic school and timing.
func get_context_tags(
		ability_tags: PackedStringArray = PackedStringArray(), force_periodic: bool = false
) -> PackedStringArray:
	var result := ability_tags.duplicate()
	var damage := is_damage_effect()
	if damage:
		# Each component owns its identity; a hybrid action cannot label every component as one school.
		for index in range(result.size() - 1, -1, -1):
			if not _damage_identity(result[index]).is_empty():
				result.remove_at(index)
	if damage:
		for tag in damage_tags:
			if force_periodic and _damage_identity(tag) == "Damage.Direct":
				continue
			if not result.has(tag):
				result.append(tag)
		var type_tag := "Damage.Physical" if damage_type == DamageType.PHYSICAL else "Damage.Magic"
		var timing_tag := "Damage.Periodic" if force_periodic else get_damage_timing_tag()
		for tag in [type_tag, timing_tag]:
			if not result.has(tag):
				result.append(tag)
		var school_tag := get_magic_school_tag()
		if not school_tag.is_empty() and not result.has(school_tag):
			result.append(school_tag)
	return result


## A copied periodic packet can use an instant carrier while keeping its original timing identity.
func get_payload_context_tags(context: GameplayEffectContext) -> PackedStringArray:
	var periodic := context.outcome_context != null \
			and context.outcome_context.timing == CombatOutcomeContext.Timing.PERIODIC
	return get_context_tags(context.ability_tags, periodic)


static func _damage_identity(tag: String) -> String:
	for identity: String in DAMAGE_IDENTITY_TAGS:
		if tag == identity or tag.begins_with(identity + "."):
			return identity
	return ""
