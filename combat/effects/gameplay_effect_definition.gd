@tool
class_name GameplayEffectDefinition
extends Resource
## Authored Gameplay Effect modifiers, execution calculations, and lifetime rules.

## Direct Health damage or a set of owned stat adjustments.
enum Kind {
	## Applies the explicitly authored direct damage to Health once.
	DAMAGE = 0,
	## Retains an independently owned set of stat modifiers and optional tags.
	MODIFIERS = 2,
}
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
enum StackingType { INDEPENDENT, AGGREGATE_BY_SOURCE, AGGREGATE_BY_TARGET }
## Controls the active lifetime on an accepted reapplication.
enum StackDurationPolicy { REFRESH, NEVER_REFRESH, EXTEND }
## Controls the execution cadence on an accepted reapplication.
enum StackPeriodPolicy { RESET, NEVER_RESET }
## Controls what expiration removes from an aggregate stack.
enum StackExpirationPolicy { CLEAR_ALL, REMOVE_ONE_AND_REFRESH, REFRESH }
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
	"base_magnitude", "power_coefficient", "use_weapon_damage", "weapon_power_share",
	"damage_type", "magic_school", "damage_tags",
]

## Stable identity for telemetry and locating authored modifier effects.
@export var effect_id: StringName = &""
## Human-readable name used in combat feedback and the log.
@export var display_name: String = ""
## Optional icon for this effect while it is retained on the player.
## Assign a HUD category to display it.
@export var icon: Texture2D
## Display group for the retained icon. This choice affects presentation only.
@export var hud_category: HudCategory = HudCategory.NONE
## Old effect assets can retain their serialized damage and modifier classification.
@export_storage var kind: Kind = Kind.MODIFIERS
## Instant executes once. Duration expires after its lifetime. Infinite requires handle removal.
@export var timing: Timing = Timing.INSTANT
## Tags identifying the effect asset itself. These do not grant actor state.
@export var asset_tags: PackedStringArray = PackedStringArray()
## Presentation cues dispatched by the target's cue router when this effect executes or changes state.
@export var gameplay_cue_tags: PackedStringArray = PackedStringArray()
## Flat direct damage before adding the applicable Power contribution, in Health units.
@export_range(0.0, 100000.0, 0.1, "or_greater") var base_magnitude: float = 0.0
## Damage added per point of applicable Power. Weapon payloads use their base-cycle coefficient.
## Authored per effect; this is not a universal spell-damage conversion rate.
@export_range(0.0, 100.0, 0.01, "or_greater") var power_coefficient: float = 0.0
## Adds the bound physical weapon's rolled damage and Physical Power contribution.
## Requires an instant Physical damage payload on a physical weapon Attack.
@export var use_weapon_damage: bool = false
## Share of the entire weapon contribution assigned to this component. An ordinary hit uses 1.0.
## Split this value between components when authoring a multi-component weapon hit.
@export_range(0.0, 100.0, 0.01, "or_greater") var weapon_power_share: float = 1.0
## Physical uses Physical Power; Magic uses Magic Power and its matching school Resistance.
## Neither damage type applies a hidden status or changes the attack/spell Accuracy check.
@export var damage_type: DamageType = DamageType.PHYSICAL
## School used only by Magic damage, selecting Fire/Cold/Lightning/Void/Necrotic Resistance.
## Physical damage and retained modifiers ignore this field. Fire is the default for existing spells.
@export var magic_school: MagicSchool = MagicSchool.FIRE
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
@export_range(0.0, 3600.0, 0.01, "or_greater") var period: float = 0.0
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
@export var stacking_type: StackingType = StackingType.INDEPENDENT
## Maximum count per aggregate handle. Zero allows any number of stacks.
@export_range(0, 100, 1, "or_greater") var stack_limit_count: int = 0
## Rejects applications that exceed the stack limit. Otherwise the capped stack can still refresh.
@export var deny_overflow_application: bool = false
## Removes the existing stack when an overflowing application is denied.
@export var clear_stack_on_overflow: bool = false
## Refreshes, preserves, or extends the remaining duration on accepted reapplication.
@export var stack_duration_policy: StackDurationPolicy = StackDurationPolicy.REFRESH
## Resets or preserves the next periodic deadline on accepted reapplication.
@export var stack_period_policy: StackPeriodPolicy = StackPeriodPolicy.RESET
## On expiry, remove the stack, remove one stack and refresh, or refresh without removing stacks.
@export var stack_expiration_policy: StackExpirationPolicy = StackExpirationPolicy.CLEAR_ALL
## Optional reusable effect behaviors such as granting abilities or removing matching active effects.
@export var components: Array[GameplayEffectComponent] = []


func get_validation_error() -> StringName:
	var damage := is_damage_effect()
	for tag in damage_tags:
		if AttributeModifier._has_match(PackedStringArray([tag]), "Ability") \
				or AttributeModifier._has_match(PackedStringArray([tag]), "Weapon"):
			return &"Effect.ReservedContextTag"
		if damage:
			var identity := _damage_identity(tag)
			var type_tag := "Damage.Physical" if damage_type == DamageType.PHYSICAL else "Damage.Magic"
			if not identity.is_empty() and identity != type_tag and identity != get_magic_school_tag() \
					and identity != get_damage_timing_tag():
				return &"Effect.ConflictingDamageTag"
	if kind not in [Kind.DAMAGE, Kind.MODIFIERS]:
		return &"Effect.InvalidKind"
	if damage_type not in [DamageType.PHYSICAL, DamageType.MAGIC]:
		return &"Effect.InvalidDamageType"
	if not is_finite(base_magnitude) or base_magnitude < 0.0:
		return &"Effect.InvalidMagnitude"
	if not is_finite(power_coefficient) or power_coefficient < 0.0:
		return &"Effect.InvalidPowerCoefficient"
	if not is_finite(weapon_power_share) or weapon_power_share < 0.0:
		return &"Effect.InvalidWeaponShare"
	if not is_finite(duration) or duration < 0.0:
		return &"Effect.InvalidDuration"
	if timing not in Timing.values() or not is_finite(period) or period < 0.0 \
			or period_inhibition_policy not in PeriodInhibitionPolicy.values():
		return &"Effect.InvalidTiming"
	if stacking_type not in StackingType.values() or stack_limit_count < 0 \
			or stack_duration_policy not in StackDurationPolicy.values() \
			or stack_period_policy not in StackPeriodPolicy.values() \
			or stack_expiration_policy not in StackExpirationPolicy.values() \
			or (timing == Timing.INSTANT and stacking_type != StackingType.INDEPENDENT):
		return &"Effect.InvalidStacking"
	if timing == Timing.INSTANT and (period > 0.0 or not granted_tags.is_empty() \
			or not ongoing_required_target_tags.is_empty() or not ongoing_blocked_target_tags.is_empty()):
		return &"Effect.InstantCannotRetainState"
	for grant in granted_tags:
		for block in ongoing_blocked_target_tags:
			if GameplayTagSet.matches(StringName(grant), StringName(block)):
				return &"Effect.SelfInhibitingTagGrant"
	var instantaneous := timing == Timing.INSTANT or period > 0.0
	var damage_executions := 0
	for execution in executions:
		if execution == null or not instantaneous:
			return &"Effect.InvalidExecution"
		if _is_damage_execution(execution):
			damage_executions += 1
	if damage_executions > 1:
		return &"Effect.MultipleDamageExecutions"
	if damage:
		if timing != Timing.INSTANT and (period <= 0.0 or damage_executions == 0):
			return &"Effect.DamageRequiresInstantOrPeriodicExecution"
		if damage_type == DamageType.MAGIC and magic_school not in MagicSchool.values():
			return &"Effect.InvalidMagicSchool"
		if use_weapon_damage and (damage_type != DamageType.PHYSICAL or timing != Timing.INSTANT):
			return &"Effect.WeaponDamageRequiresPhysicalHit"
		if damage_executions == 0 and not modifiers.is_empty():
			return &"Effect.DamageCannotRetainModifiers"
	elif use_weapon_damage:
		return &"Effect.WeaponDamageRequiresPhysicalHit"
	for modifier in modifiers:
		if not is_valid_modifier(modifier, instantaneous):
			return &"Effect.InvalidModifier"
	for component in components:
		if component == null:
			return &"Effect.InvalidComponent"
		var failure := component.get_validation_error(self)
		if not failure.is_empty():
			return failure
	return &""


## Legacy damage definitions remain valid until their assets are migrated to explicit executions.
func is_damage_effect() -> bool:
	for execution in executions:
		if _is_damage_execution(execution):
			return true
	if not executions.is_empty():
		return false
	return kind == Kind.DAMAGE or (modifiers.is_empty() and granted_tags.is_empty() \
			and (base_magnitude != 0.0 or power_coefficient != 0.0 or use_weapon_damage \
				or damage_type == DamageType.MAGIC))


func _validate_property(property: Dictionary) -> void:
	if DAMAGE_EDITOR_FIELDS.has(String(property.name)) and not is_damage_effect():
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


static func _is_damage_execution(execution: GameplayEffectExecution) -> bool:
	return execution is GameplayEffectDamageExecution \
			or (not Engine.is_editor_hint() and execution != null and execution.is_damage_execution())


static func is_valid_modifier(modifier: AttributeModifier, instantaneous: bool) -> bool:
	if modifier == null or not CombatAttributes.is_active(modifier.attribute) \
			or not is_finite(modifier.value) or modifier.operation not in AttributeModifier.Operation.values():
		return false
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
	return "Damage.Periodic" if period > 0.0 else "Damage.Direct"


## Copies delivery tags and adds this effect's damage type, Magic school and timing.
func get_context_tags(ability_tags: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var result := ability_tags.duplicate()
	if is_damage_effect():
		# Each component owns its identity; a hybrid action cannot label every component as one school.
		for index in range(result.size() - 1, -1, -1):
			if not _damage_identity(result[index]).is_empty():
				result.remove_at(index)
	for tag in damage_tags:
		if not result.has(tag):
			result.append(tag)
	if is_damage_effect():
		var type_tag := "Damage.Physical" if damage_type == DamageType.PHYSICAL else "Damage.Magic"
		for tag in [type_tag, get_damage_timing_tag()]:
			if not result.has(tag):
				result.append(tag)
		var school_tag := get_magic_school_tag()
		if not school_tag.is_empty() and not result.has(school_tag):
			result.append(school_tag)
	return result


static func _damage_identity(tag: String) -> String:
	for identity: String in DAMAGE_IDENTITY_TAGS:
		if tag == identity or tag.begins_with(identity + "."):
			return identity
	return ""
