class_name CombatMath
extends RefCounted
## Combat 2.0 source damage, Armor/Penetration, matching-school Resistance and shared Accuracy.
## Level changes success probability, never the magnitude of a successful hit.


## Pure probability in the range 0..1; inspection never consumes a random roll.
static func get_hit_chance(attacker_level: int, target_level: int, accuracy: float) -> float:
	return float(get_hit_chance_details(attacker_level, target_level, accuracy)["hit_chance"])


## Returns fractional base/maximum/final chances and the total rating reaching the ceiling.
## Accuracy is action-scoped; the same curve is used for attacks and spells.
## An authoring preview can supply validated fractional base and ceiling arrays.
static func get_hit_chance_details(
		attacker_level: int, target_level: int, accuracy: float, draft_curve: Dictionary = {}
) -> Dictionary:
	var gap := maxi(1, target_level) - maxi(1, attacker_level)
	var curve_end := maxi(0, int(CombatRules.get_number("accuracy_curve_max_gap")))
	var curve_index := clampi(gap, 0, curve_end)
	var base: float
	var maximum: float
	if draft_curve.is_empty():
		base = CombatRules.get_number_at("accuracy_base_chance_by_gap", curve_index)
		maximum = CombatRules.get_number_at("accuracy_max_chance_by_gap", curve_index)
	else:
		base = draft_curve["base"][curve_index]
		maximum = draft_curve["ceiling"][curve_index]
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
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		target: ActorAttributes = null,
		spec: GameplayEffectSpec = null
) -> float:
	if definition == null or context == null or not definition.is_damage_effect() \
			or not definition.get_validation_error().is_empty():
		return 0.0
	var damage := definition.get_damage_execution()
	var base_amount := damage.evaluate_base_amount(definition, context, target, spec)
	if not is_finite(base_amount) or base_amount < 0.0:
		return 0.0
	var tags := definition.get_payload_context_tags(context)
	var power := get_source_power(definition, context, tags)
	if damage.use_weapon_damage:
		if not context.has_physical_weapon() or GameplayEffectContext.is_spell_delivery(tags):
			return 0.0
		return maxf(0.0, base_amount + (context.get_weapon_base_damage() \
				+ power * context.weapon_power_coefficient) * damage.weapon_power_share)
	return maxf(0.0, base_amount + power * damage.power_coefficient)


## Returns resolved damage after Armor or matching school Resistance, independently of Accuracy.
static func resolve_effect(
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		target: ActorAttributes
) -> float:
	return float(resolve_effect_result(definition, context, target)["magnitude"])


## Physical components reduce full Armor by source penetration before the mitigation curve.
## Magic uses its matching school Resistance. Spell hits subtract source Spell Penetration.
## Target Health limits actual resource loss later, never the source or mitigated magnitude.
static func resolve_effect_result(
		definition: GameplayEffectDefinition,
		context: GameplayEffectContext,
		target: ActorAttributes,
		spec: GameplayEffectSpec = null
) -> Dictionary:
	var raw := raw_effect_magnitude(definition, context, target, spec) if is_instance_valid(target) else 0.0
	var resistance_attribute := CombatAttributes.Id.NONE
	var resistance := 0.0
	var effective_resistance := 0.0
	var spell_penetration := 0.0
	var resistance_stages: Array[Dictionary] = []
	var resistance_multiplier := 1.0
	var school := -1
	var armor := 0.0
	var effective_armor := 0.0
	var penetration := 0.0
	var flat_penetration := 0.0
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
		var tags := definition.get_payload_context_tags(context)
		var physical := definition.damage_type == GameplayEffectDefinition.DamageType.PHYSICAL
		var profile := definition.damage_profile
		var explicit := profile != null and profile.defense_selection == DamageProfile.DefenseSelection.EXPLICIT
		var use_armor := profile.use_armor if explicit else physical
		if use_armor:
			armor = target.get_value(CombatAttributes.Id.ARMOR, tags)
			if not is_finite(armor):
				armor = 0.0
			penetration = _bounded_armor_penetration(context.get_source_value(
					CombatAttributes.Id.ARMOR_PENETRATION, tags))
			flat_penetration = profile.flat_armor_penetration if explicit else 0.0
			effective_armor = maxf(0.0, get_effective_armor(armor, penetration) - flat_penetration)
			armor_reduction = get_armor_reduction(effective_armor)
		if not physical:
			school = definition.magic_school
		var source_spell_penetration := _direct_spell_penetration(definition, context, tags)
		if explicit:
			for stage: DamageResistanceStage in profile.resistance_stages:
				var stage_penetration := source_spell_penetration if stage.apply_spell_penetration else 0.0
				resistance_stages.append(_resolve_resistance_stage(target, tags, stage.attribute,
						stage_penetration, stage.minimum_percent, stage.maximum_percent))
		elif not physical:
			resistance_stages.append(_resolve_resistance_stage(target, tags, definition.get_resistance_attribute(),
					source_spell_penetration, CombatRules.get_number("resistance_min_percent"),
					CombatRules.get_number("resistance_max_percent")))
		if not resistance_stages.is_empty():
			var primary := resistance_stages[0]
			resistance_attribute = primary.attribute
			resistance = primary.resistance_percent
			effective_resistance = primary.effective_resistance_percent
			spell_penetration = primary.spell_penetration
			for stage: Dictionary in resistance_stages:
				resistance_multiplier *= stage.multiplier
	var critical_magnitude := raw * critical_multiplier
	return {
		"magnitude": critical_magnitude * (1.0 - armor_reduction) * resistance_multiplier,
		"raw_magnitude": raw,
		"critical_magnitude": critical_magnitude,
		"is_critical": critical,
		"critical_multiplier": critical_multiplier,
		"critical_damage_percent": critical_damage,
		"armor": armor,
		"effective_armor": effective_armor,
		"armor_penetration_percent": penetration,
		"flat_armor_penetration": flat_penetration,
		"armor_reduction": armor_reduction,
		"magic_school": school,
		"resistance_attribute": resistance_attribute,
		"resistance_percent": resistance,
		"effective_resistance_percent": effective_resistance,
		"spell_penetration": spell_penetration,
		"resistance_multiplier": resistance_multiplier,
		"resistance_stages": resistance_stages,
	}


static func _direct_spell_penetration(
		definition: GameplayEffectDefinition, context: GameplayEffectContext, tags: PackedStringArray
) -> float:
	if definition.damage_type != GameplayEffectDefinition.DamageType.MAGIC \
			or definition.get_effective_period() != 0.0 or not GameplayEffectContext.is_spell_delivery(tags):
		return 0.0
	if context.outcome_context != null and context.outcome_context.timing != CombatOutcomeContext.Timing.DIRECT:
		return 0.0
	var source_value := context.get_source_value(CombatAttributes.Id.SPELL_PENETRATION, tags)
	return maxf(0.0, source_value) if is_finite(source_value) else 0.0


static func _resolve_resistance_stage(
		target: ActorAttributes, tags: PackedStringArray, attribute: int,
		penetration: float, minimum_percent: float, maximum_percent: float
) -> Dictionary:
	var resistance := target.get_value(attribute, tags)
	var effective := clampf(resistance - penetration, minimum_percent, maximum_percent)
	return {
		"attribute": attribute,
		"resistance_percent": resistance,
		"effective_resistance_percent": effective,
		"spell_penetration": penetration,
		"multiplier": 1.0 - effective / 100.0,
	}


static func _bounded_armor_penetration(penetration: float) -> float:
	if not is_finite(penetration):
		return 0.0
	return clampf(penetration, CombatRules.get_number("armor_penetration_min_percent"),
			CombatRules.get_number("armor_penetration_max_percent"))
