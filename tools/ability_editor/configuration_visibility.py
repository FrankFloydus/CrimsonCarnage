"""Apply the project Inspector's mode-dependent field visibility to JSON drafts."""

RESOURCE_PERCENT_SOURCE = 2


def is_applicable(resource_type: str, key: str, values: dict, resources: dict, lifecycle_events) -> bool:
    def get(name: str, default=0):
        return values.get(name, default)

    if resource_type == "AbilityTargetingDefinition":
        shape = get("shape")
        area = 4 <= shape <= 9
        return {
            "max_range": shape in (1, 2, 3),
            "radius": area and shape != 8,
            "half_height": shape in (5, 6, 9),
            "up_axis": shape in (5, 6, 9),
            "half_extents": shape == 8,
            "angle_degrees": shape == 7,
            "max_targets": area,
            "collision_mask": shape != 0,
            "include_caster": shape != 0,
            "require_line_of_sight": shape == 1 or area,
            "allow_world_surfaces": shape == 2,
        }.get(key, True)
    if resource_type == "AbilityDeliveryDefinition":
        kind = get("kind")
        persistent = kind in (4, 5, 6)
        return {
            "projectile_scene": kind == 2,
            "spawn_offset": kind == 2,
            "detach_on_cancel": kind == 2 or persistent,
            "area_targeting": persistent,
            "lifetime": persistent,
            "period": kind in (4, 5),
            "arm_delay": kind == 6,
            "maximum_surface_slope": kind in (4, 6),
            "chain_hops": kind == 9,
            "chain_targeting": kind == 9 and get("chain_hops") > 0,
            "stop_chain_on_failed_hit": kind == 9 and get("chain_hops") > 0,
        }.get(key, True)
    if resource_type == "PhasedAbilityExecution":
        mode = get("cast_mode")
        return {
            "cast_duration": mode in (1, 4),
            "channel_period": mode == 4,
            "animation_name": mode == 2,
            "release_event": mode == 2,
            "animation_fallback_seconds": mode == 2,
            "delivery": mode != 5,
        }.get(key, True)
    if resource_type == "AbilityConditionDefinition":
        if key == "tag":
            return get("kind") in (0, 1)
        if key in ("resource", "threshold", "fraction_of_maximum"):
            return get("kind") in (2, 3)
    if resource_type == "AmountDefinition":
        source = get("source")
        actor = source in (1, 2) or (source == 3 and get("curve_input") == 0)
        return {
            "fixed_amount": source == 0,
            "percentage": source not in (0, 8),
            "actor": actor,
            "timing": actor,
            "stat": source == 1,
            "resource": source in (2, 5),
            "resource_basis": source == 2,
            "outcome_basis": source == 4,
            "curve_input": source == 3,
            "curve": source in (3, 5, 7),
            "amount_per_target": source == 8,
            "minimum": get("clamp_enabled"),
            "maximum": get("clamp_enabled"),
        }.get(key, True)
    if resource_type == "GameplayEffectDefinition":
        return _effect_field(key, values, resources)
    if resource_type == "ReactionDefinition":
        recipient = get("recipient")
        return {
            "removal_reason": get("trigger") == 7 and recipient != 7,
            "link_slot": recipient == 8,
            "link_range": recipient == 8,
            "link_exclude_trigger_target": recipient == 8 and get("trigger") != 6,
            "nearby_targeting": recipient == 9,
            "fire_limit": get("once_policy") != 3,
        }.get(key, True)
    if resource_type == "AbilityPhaseDefinition":
        if key == "max_fires":
            return not get("run_once_per_execution")
        if key == "synchronous_gameplay_event":
            return get("event_key", "") not in lifecycle_events
    if resource_type == "AbilityInterruptionPolicy":
        return {
            "activation_exceptions": bool(get("activation_blockers")),
            "compatible_channels": bool(get("occupied_channels")),
            "cancel_on_tags": get("interrupt_windup") or get("interrupt_channel"),
            "interruptible_by_action": get("interrupt_windup") or get("interrupt_channel"),
        }.get(key, True)
    if resource_type == "DamageDefenseEffectComponent":
        mode = get("mode")
        return {
            "priority": mode != 0,
            "fraction": mode in (3, 4),
            "capacity": mode == 4,
            "recast_capacity": mode == 4,
            "remove_when_depleted": mode == 4,
            "reflect_attached_statuses": mode == 2,
            "contact_uses": mode in (1, 2),
        }.get(key, True)
    if resource_type == "GameplayEffectDamageExecution":
        return {
            "power_coefficient": not get("use_weapon_damage"),
            "weapon_power_share": get("use_weapon_damage"),
        }.get(key, True)
    if resource_type == "AttributeModifier":
        dynamic = get("operation") != 5
        return {
            "capture_attribute": dynamic,
            "capture_coefficient": dynamic and get("capture_attribute") != -1,
            "set_by_caller_tag": dynamic,
        }.get(key, True)
    if resource_type == "DamageProfile":
        explicit = get("defense_selection") == 1
        return {
            "use_armor": explicit,
            "resistance_stages": explicit,
            "flat_armor_penetration": explicit and get("use_armor"),
        }.get(key, True)
    if resource_type == "SelectiveResourceSnapshotEffectComponent":
        return {
            "maximum_restore_distance": get("restore_transform"),
            "healing_reactions": 0 in get("pools", []),
        }.get(key, True)
    if resource_type == "HealingProfile" and key in ("apply_incoming_modifiers", "apply_absorption"):
        return get("source_percent") != 0
    if resource_type == "WeaponDefinition" and key in ("physical_damage_min", "physical_damage_max", "base_attack_cycle"):
        return 0 <= get("kind") <= 7
    controls = {
        ("AbilityChargeDefinition", "parallel_recharge"): ("capacity", 1),
        ("DamageAccumulatorEffectComponent", "remove_on_threshold"): ("threshold", 0),
        ("ObserveOutcomeEffectComponent", "reset_attack_uses_on_reapply"): ("attack_uses", 0),
        ("ThreatTauntProfile", "priority"): ("override_seconds", 0),
        ("ThreatGenerationProfile", "transaction_tag"): ("multiplier", 0),
        ("StatusProfile", "resistance_attribute"): ("resistance_effect", 0),
    }
    if (resource_type, key) in controls:
        dependency, minimum = controls[resource_type, key]
        return get(dependency) > minimum
    if (resource_type, key) == ("AbilityApplyEffectsAction", "owned_until_cast_ends"):
        return get("application") == 1
    if (resource_type, key) == ("AbilityRestoreResourceAction", "healing_profile"):
        return get("resource") == 0
    if resource_type == "AbilityResourceCost":
        if key == "maximum":
            return bool(get("spend_up_to_maximum"))
        if key == "use_payment_pool":
            amount = get("amount")
            if not isinstance(amount, dict):
                return False
            properties = resources.get(amount.get("$resource"), {}).get("properties", {})
            return properties.get("source") == RESOURCE_PERCENT_SOURCE
    if (resource_type, key) == ("ApplyEffectReactionAction", "amount"):
        return bool(get("magnitude_tag"))
    return True


def _effect_field(key: str, values: dict, resources: dict) -> bool:
    retained = values.get("timing", 0) != 0
    duration = values.get("timing") == 1
    periodic = retained and values.get("period", 0) > 0
    aggregate = retained and values.get("stacking_type", 0) != 0
    bounded = aggregate and values.get("stack_limit_count", 0) > 0
    damage = (not retained or periodic) and any(
        resources.get(execution.get("$resource"), {}).get("type") == "GameplayEffectDamageExecution"
        for execution in values.get("executions", []) if isinstance(execution, dict)
    )
    if key in {"damage_type", "damage_tags", "damage_profile", "magic_school"}:
        return damage and (key != "magic_school" or values.get("damage_type") == 1)
    if key in {"hud_category", "period", "granted_tags", "ongoing_required_target_tags",
               "ongoing_blocked_target_tags", "stacking_type"}:
        return retained
    if key in {"execute_periodic_on_application", "period_inhibition_policy", "snapshot_source"}:
        return periodic
    return {
        "duration": duration,
        "executions": not retained or periodic,
        "stack_limit_count": aggregate,
        "deny_overflow_application": bounded,
        "clear_stack_on_overflow": bounded and values.get("deny_overflow_application", False),
        "stack_duration_policy": aggregate and duration,
        "stack_expiration_policy": aggregate and duration,
        "stack_period_policy": aggregate and periodic,
        "tick_at_end": duration and periodic,
        "status_profile": retained and not damage,
        "exclusive_owner_slot": retained and values.get("stacking_type", 0) != 2,
        "transferable": retained and (
            values.get("stacking_type") == 2 or not values.get("exclusive_owner_slot")
        ),
    }.get(key, True)
