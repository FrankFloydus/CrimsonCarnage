class_name CombatMath
extends RefCounted
## Combat 2.0 source damage, Armor/Penetration, matching-school Resistance and shared Accuracy.
## Level changes success probability, never the magnitude of a successful hit.


## Pure probability in the range 0..1; inspection never consumes a random roll.
static func get_hit_chance(attacker_level: int, target_level: int, accuracy: float) -> float:
	return float(get_hit_chance_details(attacker_level, target_level, accuracy)["hit_chance"])


## Returns fractional base/maximum/final chances and the total rating reaching the ceiling.
## Accuracy is action-scoped; the same curve is used for attacks and spells.
static func get_hit_chance_details(
		attacker_level: int, target_level: int, accuracy: float
) -> Dictionary:
	var gap := maxi(1, target_level) - maxi(1, attacker_level)
	var curve_end := maxi(0, int(CombatRules.get_number("accuracy_curve_max_gap")))
	var curve_index := clampi(gap, 0, curve_end)
	var base := CombatRules.get_number_at("accuracy_base_chance_by_gap", curve_index)
	var maximum := CombatRules.get_number_at("accuracy_max_chance_by_gap", curve_index)
	if gap < 0:
		base = minf(1.0, base - CombatRules.get_number("accuracy_lower_level_bonus") * gap)
		maximum = 1.0
	elif gap > curve_end:
		var decay := pow(CombatRules.get_number("accuracy_higher_level_decay"), gap - curve_end)
		base *= decay
		maximum *= decay
	maximum = clampf(maximum, 0.0, 1.0)
	base = clampf(base, 0.0, maximum)
	var baseline := CombatRules.get_number("accuracy_baseline_rating")
	var scale := CombatRules.get_number("accuracy_rating_scale_base") \
			+ CombatRules.get_number("accuracy_rating_scale_per_level") * (maxi(1, attacker_level) - 1) \
			+ CombatRules.get_number("accuracy_rating_scale_per_gap") * maxi(0, gap)
	var chance := 0.0
	if is_finite(accuracy) and scale > 0.0:
		var progress := clampf((maxf(0.0, accuracy) - baseline) / scale, -1.0, 1.0)
		chance = clampf(base + (maximum - base) * progress, 0.0, maximum)
	return {
		"level_gap": gap,
		"base_chance": base,
		"max_chance": maximum,
		"hit_chance": chance,
		"rating_scale": scale,
		"required_accuracy": 0.0 if base == maximum else baseline + scale,
	}


## Physical damage reduction from a nonnegative rating, independent of hit size and level.
## The rating stays uncapped; only mitigation caps at the configured rating/reduction pair.
static func get_armor_reduction(armor: float) -> float:
	if not is_finite(armor) or armor <= 0.0:
		return 0.0
	var cap := CombatRules.get_number("armor_max_reduction")
	var rating_at_cap := CombatRules.get_number("armor_rating_at_cap")
	if cap <= 0.0 or cap >= 1.0 or rating_at_cap <= 0.0:
		return 0.0
	if armor >= rating_at_cap:
		return cap
	var curve_scale := rating_at_cap * (1.0 - cap) / cap
	return clampf(armor / (armor + curve_scale), 0.0, cap)


## Armor rating used by one Physical component after its source's percentage penetration.
## The full target rating is reduced before the mitigation curve; neither actor is mutated.
static func get_effective_armor(armor: float, penetration: float) -> float:
	if not is_finite(armor) or armor <= 0.0:
		return 0.0
	return armor * (1.0 - _bounded_armor_penetration(penetration) / 100.0)


## Total critical multiplier from nonnegative, uncapped bonus percentage points.
## Zero bonus retains the configured base (1.5); this pure calculation never rolls.
static func get_critical_multiplier(critical_damage: float) -> float:
	var bonus := maxf(0.0, critical_damage) if is_finite(critical_damage) else 0.0
	return CombatRules.get_number("base_critical_multiplier") + bonus / 100.0


## Damage type selects the applicable flat Power; the action context selects its primary.
static func get_source_power(
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		tags: PackedStringArray
) -> float:
	var attribute := CombatAttributes.Id.PHYSICAL_POWER \
			if definition.damage_type == GameplayEffectDefinition.DamageType.PHYSICAL \
			else CombatAttributes.Id.MAGIC_POWER
	return maxf(0.0, context.get_source_value(attribute, tags))


## Resolves one stable weapon roll and Power contribution before actual Health loss.
static func raw_effect_magnitude(
		definition: GameplayEffectDefinition, context: GameplayEffectContext
) -> float:
	if definition == null or context == null or not definition.is_damage_effect() \
			or not definition.get_validation_error().is_empty():
		return 0.0
	var tags := definition.get_context_tags(context.ability_tags)
	var power := get_source_power(definition, context, tags)
	if definition.use_weapon_damage:
		if not context.has_physical_weapon() or GameplayEffectContext.is_spell_delivery(tags):
			return 0.0
		return maxf(0.0, definition.base_magnitude + (context.get_weapon_base_damage() \
				+ power * context.weapon_power_coefficient) * definition.weapon_power_share)
	return maxf(0.0, definition.base_magnitude + power * definition.power_coefficient)


## Returns resolved damage after Armor or matching school Resistance, independently of Accuracy.
static func resolve_effect(
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		target: ActorAttributes
) -> float:
	return float(resolve_effect_result(definition, context, target)["magnitude"])


## Physical components reduce full Armor by source penetration before the mitigation curve.
## Magic uses only its matching school Resistance and ignores Armor/Penetration.
## Target Health limits actual resource loss later, never the source or mitigated magnitude.
static func resolve_effect_result(
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		target: ActorAttributes
) -> Dictionary:
	var raw := raw_effect_magnitude(definition, context) if is_instance_valid(target) else 0.0
	var resistance_attribute := CombatAttributes.Id.NONE
	var resistance := 0.0
	var school := -1
	var armor := 0.0
	var effective_armor := 0.0
	var penetration := 0.0
	var armor_reduction := 0.0
	var critical := false
	var critical_multiplier := 1.0
	var critical_damage := 0.0
	if is_instance_valid(target) and definition != null and context != null \
			and definition.is_damage_effect() \
			and definition.get_validation_error().is_empty():
		critical = context.is_critical
		if critical:
			critical_multiplier = context.critical_multiplier
			critical_damage = context.critical_damage_percent
		if definition.damage_type == GameplayEffectDefinition.DamageType.PHYSICAL:
			var tags := definition.get_context_tags(context.ability_tags)
			armor = target.get_value(CombatAttributes.Id.ARMOR, tags)
			if not is_finite(armor):
				armor = 0.0
			penetration = _bounded_armor_penetration(context.get_source_value(
					CombatAttributes.Id.ARMOR_PENETRATION, tags))
			effective_armor = get_effective_armor(armor, penetration)
			armor_reduction = get_armor_reduction(effective_armor)
		else:
			resistance_attribute = definition.get_resistance_attribute()
			if resistance_attribute != CombatAttributes.Id.NONE:
				school = definition.magic_school
				var tags := definition.get_context_tags(context.ability_tags)
				resistance = clampf(target.get_value(resistance_attribute, tags),
						CombatRules.get_number("resistance_min_percent"),
						CombatRules.get_number("resistance_max_percent"))
	var multiplier := 1.0 - resistance / 100.0
	var critical_magnitude := raw * critical_multiplier
	return {
		"magnitude": critical_magnitude * (1.0 - armor_reduction) * multiplier,
		"raw_magnitude": raw,
		"critical_magnitude": critical_magnitude,
		"is_critical": critical,
		"critical_multiplier": critical_multiplier,
		"critical_damage_percent": critical_damage,
		"armor": armor,
		"effective_armor": effective_armor,
		"armor_penetration_percent": penetration,
		"armor_reduction": armor_reduction,
		"magic_school": school,
		"resistance_attribute": resistance_attribute,
		"resistance_percent": resistance,
		"resistance_multiplier": multiplier,
	}


static func _bounded_armor_penetration(penetration: float) -> float:
	if not is_finite(penetration):
		return 0.0
	return clampf(penetration, CombatRules.get_number("armor_penetration_min_percent"),
			CombatRules.get_number("armor_penetration_max_percent"))
