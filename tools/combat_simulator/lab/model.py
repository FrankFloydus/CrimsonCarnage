"""Serializable inputs and attribute evaluation for the pre-2.0 combat model.

No gameplay files are changed. Attribute IDs and bounds come from the headless
bundled legacy Godot export. Empty matrix selections mean all profiles; empty level lists retain
the selected profiles' own levels.
"""
from __future__ import annotations

import copy
import itertools
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from functools import lru_cache

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parents[2]
SNAPSHOT_PATH = HERE / "game_snapshot.json"
RULES_PATH = HERE.parent / "legacy_combat_rules_v1.json"
LIVE_RULES_PATH = PROJECT_ROOT / "combat" / "combat_rules.json"
LEGACY_NOTICE = ("Legacy pre-2.0 combat model: these experiments do not simulate "
                 "the current Godot Physical Power, governing attributes or more modifiers.")
PRIMARY_KEYS = ("strength", "dexterity", "intellect", "vitality")


def _read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def require_legacy_rules(rules):
    """Reject unsupported live rules before reading profiles or changing snapshots."""
    if rules.get("schema_version") != 2 or str(rules.get("combat_model", "")).startswith("2.0"):
        raise ValueError("Combat 2.0 is not supported by the legacy Combat Lab. "
                         "The bundled pre-2.0 snapshot remains available for legacy experiments; "
                         "importing the current Godot project requires a simulator migration.")


@lru_cache(maxsize=1)
def _snapshot():
    if not SNAPSHOT_PATH.exists():
        raise ValueError("Game snapshot missing. Import saved game with a headless Godot executable.")
    result = _read_json(SNAPSHOT_PATH)
    if result.get("version") != 1 or result.get("combat_schema_version") != 2 or not result.get("catalogue"):
        raise ValueError("This game snapshot predates unified power, automatic ailments, Absorption, and consumables-only Health restoration. Reimport saved game data.")
    require_legacy_rules(result.get("rules", {}))
    catalogue = {entry["key"]: int(entry["id"]) for entry in result["catalogue"]}
    if catalogue.get("RESOLVE") != 24 or {28, 29} & set(catalogue.values()):
        raise ValueError("This game snapshot predates Resolve and the retirement of Mana/Stamina Efficiency. Reimport saved game data.")
    return result


def attribute_catalogue():
    """Return active Godot attributes, stable IDs, and native-unit bounds."""
    return copy.deepcopy(_snapshot()["catalogue"])


def attribute_ids():
    """Name lookup generated from the exported Godot catalogue."""
    return {entry["key"]: int(entry["id"]) for entry in _snapshot()["catalogue"]}


def tags_match(tags, query):
    """A hierarchical query matches itself and any descendant tag."""
    return bool(query) and any(tag == query or tag.startswith(query + ".") for tag in tags)


def modifier_matches(modifier, context_tags):
    return (all(tags_match(context_tags, tag) for tag in modifier.get("required_context_tags", []))
            and not any(tags_match(context_tags, tag)
                        for tag in modifier.get("excluded_context_tags", [])))


def _evaluate_actor(actor, rules, context_tags=(), bases_only=False):
    catalogue = _snapshot()["catalogue"]
    ids = {entry["key"]: int(entry["id"]) for entry in catalogue}
    entries = {int(entry["id"]): entry for entry in catalogue}
    level = max(1, min(int(rules["max_level"]), int(actor.get("level", 1))))
    allocations = actor.get("allocations", {})
    overrides = {int(key): float(value) for key, value in actor.get("base_values", {}).items()}
    modifiers = actor.get("modifiers", [])
    context_tags = tuple(context_tags)
    cache, base_cache = {}, {}
    unscoped_values = None
    primary = float(rules["base_primary"])

    def unscoped(id_):
        nonlocal unscoped_values
        if not context_tags:
            return evaluate(id_)
        if unscoped_values is None:
            unscoped_values = _evaluate_actor(actor, rules)
        return unscoped_values[id_]

    def evaluate(id_):
        if id_ in cache:
            return cache[id_]
        entry, key = entries[id_], entries[id_]["key"]
        if entry["current"]:
            # Godot pools are actor state, not a separate pool for each query scope.
            if context_tags:
                result = unscoped(id_)
            else:
                maximum = evaluate(int(entry["maximum_attribute"]))
                result = min(maximum, max(0.0, overrides.get(id_, maximum)))
            cache[id_] = base_cache[id_] = result
            return result
        value = 0.0
        if key in ("MAX_HEALTH", "MAX_STAMINA", "MAX_MANA"):
            suffix = key[4:].lower()
            value = rules["base_" + suffix] + rules[suffix + "_per_level"] * (level - 1)
        elif key.lower() in PRIMARY_KEYS:
            value = primary + allocations.get(key.lower(), 0)
        elif key == "CARRY_CAPACITY":
            value = rules["base_carry_capacity"]
        elif key in ("STAMINA_REGEN", "MANA_REGEN"):
            suffix = key.split("_")[0].lower()
            value = rules[suffix + "_regen_base"] + rules[suffix + "_regen_per_level"] * (level - 1)
        elif key == "CRITICAL_CHANCE":
            value = rules["critical_chance_base"]
        elif key == "CRITICAL_DAMAGE":
            value = rules["critical_damage_base"]
        elif key in ("BURN_CHANCE", "CHILL_CHANCE", "ZAPPED_CHANCE",
                     "BLEED_CHANCE", "POISON_CHANCE", "HOLLOWED_CHANCE"):
            value = rules["ailment_chance_base"]
        contributions = {
            "MAX_STAMINA": ("STRENGTH", "strength_stamina_per_point"),
            "MAX_MANA": ("INTELLECT", "intellect_mana_per_point"),
            "MAGIC_POWER": ("INTELLECT", "intellect_magic_power_per_point"),
            "EVASION": ("DEXTERITY", "dexterity_evasion_per_point"),
            "CARRY_CAPACITY": ("VITALITY", "vitality_capacity_per_point"),
            "HIT_RATING": ("DEXTERITY", "dexterity_hit_rating_per_point"),
        }
        if key in contributions:
            dependency, coefficient = contributions[key]
            # Godot capacities derive from unscoped primaries; Power/Evasion use context.
            primary_value = (unscoped(ids[dependency])
                             if key in ("MAX_STAMINA", "MAX_MANA", "CARRY_CAPACITY")
                             else evaluate(ids[dependency]))
            value += (primary_value - primary) * rules[coefficient]
        additive, percentage = 0.0, 0.0
        for modifier in modifiers:
            if int(modifier.get("attribute", -1)) != id_ or not modifier_matches(modifier, context_tags):
                continue
            if key == "BLOCK_CHANCE" and modifier.get("source", 0) not in (1, 2):
                continue
            operation, amount = int(modifier.get("operation", 0)), float(modifier.get("value", 0))
            if operation == 2:
                value = amount
            elif operation == 0:
                additive += amount
            elif operation == 1:
                percentage += amount / 100.0
        if id_ in overrides:
            value = overrides[id_]
        base_cache[id_] = float(value)
        vitality = (rules["vitality_health_per_point"] * (unscoped(ids["VITALITY"]) - primary)
                    if key == "MAX_HEALTH" else 0.0)
        result = value * (1.0 + percentage + vitality) + additive
        minimum = rules[entry["minimum_rule"]] if entry.get("minimum_rule") else entry["minimum"]
        maximum = rules[entry["maximum_rule"]] if entry.get("maximum_rule") else entry["maximum"]
        if minimum is not None:
            result = max(float(minimum), result)
        if maximum is not None:
            result = min(float(maximum), result)
        if not math.isfinite(result):
            raise ValueError(f"{actor.get('name', 'Actor')}: {entry['name']} overflowed; reduce the inputs.")
        cache[id_] = float(result)
        return cache[id_]

    result = {int(entry["id"]): evaluate(int(entry["id"])) for entry in catalogue}
    return base_cache if bases_only else result


def resolve_actor(actor, rules, context_tags=()):
    """Evaluate legacy attributes, scopes, primary contributions, and owned Set Base.

    base_values are final owned test bases, like F3. Authored ADD and ADD_PERCENT
    still apply. Current resources instead specify initial amount (default full).
    A manual Block base uses Shield origin; General-source Block grants are ignored.
    """
    require_legacy_rules(rules)
    return _evaluate_actor(actor, rules, context_tags)


def resolve_actor_bases(actor, rules, context_tags=()):
    """Bases after authored/test Set Base, before ADD/PERCENT; currents are initial values."""
    require_legacy_rules(rules)
    return _evaluate_actor(actor, rules, context_tags, bases_only=True)


def _neutral_actor(id_, name, level=1):
    return {"id": id_, "name": name, "level": level,
            "allocations": {key: 0 for key in PRIMARY_KEYS},
            "base_values": {}, "modifiers": [], "tags": []}


def _session_from_snapshot(snapshot):
    rules = copy.deepcopy(snapshot["rules"])
    ids = {entry["key"]: str(int(entry["id"])) for entry in snapshot["catalogue"]}
    enemies = copy.deepcopy(snapshot["enemies"])
    player_level = int(snapshot["players"][0]["level"]) if snapshot["players"] else 1
    # Editable examples illustrate varied matchups, not approved enemy/item budgets.
    # The actual saved dummy above is preserved verbatim.
    for id_, name, level_offset, overrides in [
        ("neutral", "Neutral target", 0, {"MAX_HEALTH": 300}),
        ("armored", "Armored target", 2, {"MAX_HEALTH": 500, "ARMOR": 300}),
        ("elemental", "Elemental resistant target", 4, {"MAX_HEALTH": 500, "FIRE_RESISTANCE": 40,
                                                       "COLD_RESISTANCE": 40, "LIGHTNING_RESISTANCE": 40}),
        ("evasive", "Evasive / blocking target", 5, {"MAX_HEALTH": 400, "EVASION": 250,
                                                    "BLOCK_CHANCE": 20}),
    ]:
        level = max(1, min(int(rules["max_level"]), player_level + level_offset))
        actor = _neutral_actor(id_, name, level)
        actor["base_values"] = {ids[key]: float(value) for key, value in overrides.items()}
        enemies.append(actor)
    curve = copy.deepcopy(rules["accuracy_chance_by_level_gap"])
    return {
        "version": 1, "name": "Saved game combat experiments",
        "rules": rules, "curves": {"melee": curve, "spell": copy.deepcopy(curve)},
        "players": copy.deepcopy(snapshot["players"]), "enemies": enemies,
        "abilities": copy.deepcopy(snapshot["abilities"]),
        "matrix": {"player_ids": [], "enemy_ids": [], "ability_ids": [],
                   "player_levels": [], "enemy_levels": [], "sweeps": []},
        "run": {"trials": 10000, "horizon": 120.0, "seed": 12345,
                "batch_size": 4096, "workers": 1},
        "import_notes": copy.deepcopy(snapshot.get("notes", [])),
    }


def default_session():
    """Create independent inputs from the frozen pre-2.0 snapshot and rules."""
    snapshot = copy.deepcopy(_snapshot())
    snapshot["rules"] = _read_json(RULES_PATH)
    session = _session_from_snapshot(snapshot)
    session["name"] = "Legacy pre-2.0 combat experiments"
    session["import_notes"].insert(0, LEGACY_NOTICE)
    validate_session(session)
    return session


def _number(value, path, *, minimum=None, maximum=None, integer=False):
    try:
        finite = not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)
    except (OverflowError, TypeError):
        finite = False
    if not finite:
        raise ValueError(f"{path} must be a finite number.")
    if integer and int(value) != value:
        raise ValueError(f"{path} must be an integer.")
    if minimum is not None and value < minimum:
        raise ValueError(f"{path} must be at least {minimum}.")
    if maximum is not None and value > maximum:
        raise ValueError(f"{path} must be at most {maximum}.")
    return value


def _tags(value, path):
    if not isinstance(value, list) or any(not isinstance(tag, str) or not tag for tag in value):
        raise ValueError(f"{path} must be a list of nonempty tag strings.")


def _object(value, path):
    if not isinstance(value, dict):
        raise ValueError(f"{path} must be a JSON object.")


def _list(value, path, *, nonempty=False):
    if not isinstance(value, list) or (nonempty and not value):
        raise ValueError(f"{path} must be a {'nonempty ' if nonempty else ''}list.")


def _boolean(value, path):
    if not isinstance(value, bool):
        raise ValueError(f"{path} must be true or false.")


def _identity(item, path):
    _object(item, path)
    for field in ("id", "name"):
        if not isinstance(item.get(field), str) or not item[field].strip():
            raise ValueError(f"{path}.{field} must be a nonempty string.")


def _attribute_id(value, path, *, allow_none=False):
    _number(value, path, integer=True)
    valid = {int(entry["id"]) for entry in _snapshot()["catalogue"]}
    if int(value) not in valid and not (allow_none and value == -1):
        raise ValueError(f"{path} references an unknown or retired combat attribute.")


def validate_actor(actor, rules):
    """Validate one editor actor before preview; return None or a descriptive ValueError."""
    return _validate_actor(actor, rules, "actor")


def _validate_actor(actor, rules, path):
    _identity(actor, path)
    _number(actor.get("level"), path + ".level", integer=True, minimum=1, maximum=rules["max_level"])
    allocations = actor.get("allocations", {})
    _object(allocations, path + ".allocations")
    for key, value in allocations.items():
        if key not in PRIMARY_KEYS:
            raise ValueError(f"{path}.allocations has unknown primary '{key}'.")
        _number(value, f"{path}.allocations.{key}", integer=True, minimum=0)
    overrides = actor.get("base_values", {})
    _object(overrides, path + ".base_values")
    for key, value in overrides.items():
        try:
            id_ = int(key)
        except (ValueError, TypeError):
            raise ValueError(f"{path}.base_values keys must be attribute ID strings.") from None
        if str(id_) != str(key):
            raise ValueError(f"{path}.base_values key '{key}' is not a canonical attribute ID.")
        _attribute_id(id_, path + ".base_values." + str(key))
        _number(value, path + ".base_values." + str(key))
    modifiers = actor.get("modifiers", [])
    _list(modifiers, path + ".modifiers")
    current_ids = {entry["id"] for entry in _snapshot()["catalogue"] if entry["current"]}
    for index, modifier in enumerate(modifiers):
        prefix = f"{path}.modifiers[{index}]"
        _object(modifier, prefix)
        _attribute_id(modifier.get("attribute"), prefix + ".attribute")
        if modifier["attribute"] in current_ids:
            raise ValueError(prefix + ": persistent modifiers cannot target current pools; use base_values.")
        _number(modifier.get("operation"), prefix + ".operation", integer=True, minimum=0, maximum=2)
        _number(modifier.get("source", 0), prefix + ".source", integer=True, minimum=0, maximum=2)
        _number(modifier.get("value"), prefix + ".value")
        for key in ("required_context_tags", "excluded_context_tags"):
            _tags(modifier.get(key, []), prefix + "." + key)
    _tags(actor.get("tags", []), path + ".tags")
    for flag in ("automatic_regeneration", "pause_stamina_regeneration"):
        if flag in actor:
            _boolean(actor[flag], path + "." + flag)
    resolve_actor(actor, rules)


def _validate_ability(ability, path):
    _identity(ability, path)
    if ability.get("kind") not in ("melee", "spell"):
        raise ValueError(path + ".kind must be 'melee' or 'spell'.")
    if ability.get("delivery") is not None:
        expected = "projectile" if ability["kind"] == "spell" else "melee_trace"
        if ability["delivery"] != expected:
            raise ValueError(path + ": delivery and kind must use the same spell/melee execution clock.")
    for key in ("tags", "required_tags", "blocked_tags"):
        _tags(ability.get(key, []), path + "." + key)
    if tags_match(ability.get("tags", []), "Ability.Spell") != (ability["kind"] == "spell"):
        raise ValueError(path + ": kind must agree with hierarchical Ability.Spell tags; "
                         "damage_type is independent of spell/melee delivery.")
    base = _number(ability.get("base_duration"), path + ".base_duration", minimum=1e-9)
    if "weapon_attacks_per_second" in ability:
        if ability["kind"] != "melee":
            raise ValueError(path + ".weapon_attacks_per_second only applies to melee Attacks.")
        attacks_per_second = _number(ability["weapon_attacks_per_second"], path + ".weapon_attacks_per_second", minimum=1e-9)
        base = 1.0 / attacks_per_second
    _number(ability.get("minimum_duration"), path + ".minimum_duration", minimum=1e-9, maximum=base)
    _number(ability.get("release_fraction", 1.0), path + ".release_fraction", minimum=0, maximum=1)
    for key in ("travel_time", "cooldown", "cost_amount"):
        _number(ability.get(key, 0), path + "." + key, minimum=0)
    cost_id = ability.get("cost_attribute", -1)
    _attribute_id(cost_id, path + ".cost_attribute", allow_none=True)
    ids = attribute_ids()
    cost_resources = {ids[key] for key in ("HEALTH", "STAMINA", "MANA")}
    if cost_id != -1 and cost_id not in cost_resources:
        raise ValueError(path + ".cost_attribute must be Health, Stamina, Mana, or -1 (free); Absorption costs are not part of the combat rules.")
    for flag in ("dodgeable", "blockable"):
        if flag in ability:
            _boolean(ability[flag], path + "." + flag)
    if "automatic_ailments" in ability:
        _boolean(ability["automatic_ailments"], path + ".automatic_ailments")
        if not ability["automatic_ailments"]:
            raise ValueError(path + ": automatic ailments are a shared combat rule and cannot be disabled per ability in this lab.")
    effects = ability.get("effects")
    _list(effects, path + ".effects", nonempty=True)
    for index, effect in enumerate(effects):
        prefix = f"{path}.effects[{index}]"
        _object(effect, prefix)
        if not isinstance(effect.get("id"), str) or not effect["id"]:
            raise ValueError(prefix + ".id must be a nonempty string.")
        if not isinstance(effect.get("name", ""), str):
            raise ValueError(prefix + ".name must be a string.")
        for key in ("base_damage", "power_coefficient", "duration", "period"):
            _number(effect.get(key, 0), prefix + "." + key, minimum=0)
        damage_min = _number(effect.get("base_damage_min", effect.get("base_damage", 0)),
                             prefix + ".base_damage_min", minimum=0)
        damage_max = _number(effect.get("base_damage_max", effect.get("base_damage", 0)),
                             prefix + ".base_damage_max", minimum=0)
        if damage_min > damage_max:
            raise ValueError(prefix + ".base_damage_min cannot exceed base_damage_max.")
        _attribute_id(effect.get("scaling_attribute", -1), prefix + ".scaling_attribute", allow_none=True)
        if effect.get("scaling_attribute", -1) not in (-1, attribute_ids()["MAGIC_POWER"]):
            raise ValueError(prefix + ".scaling_attribute must be automatic (-1) or Magic Power; Physical damage uses Strength automatically.")
        _number(effect.get("application_chance", 100), prefix + ".application_chance", minimum=0, maximum=100)
        for key in ("critical", "periodic", "scale_with_level", "execute_on_application",
                    "strongest_wins"):
            _boolean(effect.get(key, False), prefix + "." + key)
        if effect.get("damage_type") not in ("physical", "fire", "cold", "lightning", "necrotic", "void"):
            raise ValueError(prefix + ".damage_type must be physical, fire, cold, lightning, necrotic, or void; reimport legacy Frost/Poison definitions.")
        if effect.get("periodic") and (effect.get("duration", 0) <= 0 or effect.get("period", 0) <= 0):
            raise ValueError(prefix + ": periodic damage requires positive duration and period.")
        if effect.get("reapplication", "refresh") not in ("refresh", "replace", "stack"):
            raise ValueError(prefix + ".reapplication must be refresh, replace, or stack.")
        _number(effect.get("maximum_stacks", 1), prefix + ".maximum_stacks", integer=True, minimum=0)
        if str(effect.get("ailment_family", "")).lower() not in ("", "burn", "bleed", "poison", "chill", "zapped", "hollowed"):
            raise ValueError(prefix + ".ailment_family is unsupported.")
        for key in ("damage_tags", "required_target_tags", "blocked_target_tags", "granted_tags"):
            _tags(effect.get(key, []), prefix + "." + key)
        if effect.get("kind", "damage") != "damage" or effect.get("target_attribute", "health") not in (
                "health", attribute_ids()["HEALTH"]):
            raise ValueError(prefix + ": only Health-damage effects are supported by this lab.")
        if effect.get("modifiers") or effect.get("control_effect"):
            raise ValueError(prefix + ": modifier/control effects are not supported by this lab.")
    retained_ids = {}
    for index, effect in enumerate(effects):
        if not effect.get("periodic", False):
            continue
        identity = effect["id"]
        if identity in retained_ids:
            raise ValueError(
                f"{path}.effects[{index}].id: duplicate periodic effect ID '{identity}' "
                f"also used by effects[{retained_ids[identity]}]; shared retained groups "
                "within one ability are not supported by this lab.")
        retained_ids[identity] = index
    # Retained tags are counted runtime state in Godot. This lab supports static
    # target immunities, but does not reproduce changing conditions between payload
    # components/reapplications. Include self-grants: they can gate later refreshes.
    retained_grants = [(index, tag)
                       for index, effect in enumerate(effects) if effect.get("periodic", False)
                       for tag in effect.get("granted_tags", [])]
    for index, effect in enumerate(effects):
        for key in ("required_target_tags", "blocked_target_tags"):
            for query in effect.get(key, []):
                for grant_index, grant in retained_grants:
                    if tags_match((grant,), query):
                        raise ValueError(
                            f"{path}.effects[{index}].{key}: query '{query}' can match retained "
                            f"tag '{grant}' granted by effects[{grant_index}]; dynamic counted-tag "
                            "conditions are not supported. Static target immunities remain valid.")


def validate_session(session):
    """Return None or raise a path-specific ValueError for unsupported/invalid inputs."""
    _object(session, "session")
    if session.get("version") != 1:
        raise ValueError("session.version must be 1.")
    if not isinstance(session.get("name"), str):
        raise ValueError("session.name must be a string.")
    rules = session.get("rules")
    _object(rules, "rules")
    require_legacy_rules(rules)
    expected_rules = _read_json(RULES_PATH)
    for key, expected in expected_rules.items():
        if key not in rules:
            raise ValueError(f"rules.{key} is required.")
        if isinstance(expected, list) != isinstance(rules[key], list):
            raise ValueError(f"rules.{key} must be a {'numeric array' if isinstance(expected, list) else 'number'}.")
    for key, value in rules.items():
        if isinstance(value, list):
            _list(value, "rules." + key, nonempty=True)
            for index, number in enumerate(value):
                _number(number, f"rules.{key}[{index}]")
        else:
            _number(value, "rules." + key)
    _number(rules["max_level"], "rules.max_level", integer=True, minimum=1, maximum=60)
    for key in ("creation_points", "points_per_level"):
        _number(rules[key], "rules." + key, integer=True, minimum=0)
    for key in ("defense_curve_denominator_base", "defense_curve_denominator_per_rating",
                "speed_rating_scale", "level_gap_width", "hit_rating_base_requirement",
                "control_level_duration_width", "minimum_capacity"):
        if rules[key] <= 0:
            raise ValueError(f"rules.{key} must be positive.")
    if rules["speed_rating_min"] <= -rules["speed_rating_scale"]:
        raise ValueError("rules.speed_rating_min must exceed negative speed_rating_scale.")
    for key in ("armor_damage_reduction_max", "evasion_chance_max", "encumbrance_multiplier_min"):
        _number(rules[key], "rules." + key, minimum=0, maximum=1)
    for key in ("critical_chance_max", "block_chance_max", "armor_penetration_max",
                "resolve_max", "resistance_max"):
        _number(rules[key], "rules." + key, minimum=0, maximum=100)
    if rules["resistance_min"] > rules["resistance_max"]:
        raise ValueError("rules.resistance_min cannot exceed resistance_max.")
    if rules["movement_speed_bonus_min"] > rules["movement_speed_bonus_max"]:
        raise ValueError("rules.movement_speed_bonus_min cannot exceed movement_speed_bonus_max.")
    for key in ("level_gap_advantage_max", "accuracy_rating_growth_per_level"):
        _number(rules[key], "rules." + key, minimum=1)
    for key in ("strength_physical_damage_per_point", "intellect_magic_power_per_point",
                "dexterity_hit_rating_per_point", "vitality_capacity_per_point",
                "absorption_recovery_delay", "absorption_recovery_fraction",
                "utility_threshold_per_level"):
        _number(rules[key], "rules." + key, minimum=0)
    _number(rules["utility_threshold_base"], "rules.utility_threshold_base", minimum=1e-12)
    _number(rules["critical_base_multiplier"], "rules.critical_base_multiplier", minimum=1)
    _number(rules["ailment_chance_base"], "rules.ailment_chance_base", minimum=0, maximum=100)
    for family in ("burn", "bleed", "poison"):
        duration = _number(rules[family + "_duration"], "rules." + family + "_duration", minimum=1e-12)
        _number(rules[family + "_period"], "rules." + family + "_period", minimum=1e-12, maximum=duration)
        _number(rules[family + "_damage_per_second_fraction"],
                "rules." + family + "_damage_per_second_fraction", minimum=0)
    for family in ("chill", "zapped", "hollowed"):
        _number(rules[family + "_duration"], "rules." + family + "_duration", minimum=1e-12)
    _number(rules["chill_slow_max"], "rules.chill_slow_max", minimum=0, maximum=1)
    if rules["chill_slow_max"] == 1:
        raise ValueError("rules.chill_slow_max must be below 1; Chill cannot stop the action clock.")
    _number(rules["zapped_critical_bonus"], "rules.zapped_critical_bonus", minimum=0, maximum=100)
    _number(rules["hollowed_recovery_reduction_max"], "rules.hollowed_recovery_reduction_max", minimum=0, maximum=1)
    shared_curve = rules["accuracy_chance_by_level_gap"]
    for index, value in enumerate(shared_curve):
        _number(value, f"rules.accuracy_chance_by_level_gap[{index}]", minimum=0, maximum=1)
    curves = session.get("curves")
    _object(curves, "curves")
    for kind in ("melee", "spell"):
        values = curves.get(kind)
        _list(values, "curves." + kind, nonempty=True)
        if len(values) > 60:
            raise ValueError("curves." + kind + " supports at most 60 integer-gap entries.")
        for index, value in enumerate(values):
            _number(value, f"curves.{kind}[{index}]", minimum=0, maximum=1)
    if curves["melee"] != curves["spell"]:
        raise ValueError("Attack and Spell delivery now share Hit Rating and one accuracy curve; both curve copies must match.")
    for collection in ("players", "enemies", "abilities"):
        items = session.get(collection)
        _list(items, collection, nonempty=True)
        seen = set()
        for index, item in enumerate(items):
            path = f"{collection}[{index}]"
            if collection == "abilities":
                _validate_ability(item, path)
            else:
                _validate_actor(item, rules, path)
            if item["id"] in seen:
                raise ValueError(collection + " contains duplicate ID '" + item["id"] + "'.")
            seen.add(item["id"])
    matrix = session.get("matrix")
    _object(matrix, "matrix")
    for side, collection in (("player", "players"), ("enemy", "enemies"), ("ability", "abilities")):
        values = matrix.get(side + "_ids", [])
        _list(values, "matrix." + side + "_ids")
        known = {item["id"] for item in session[collection]}
        if any(not isinstance(value, str) for value in values):
            raise ValueError("matrix." + side + "_ids must contain ID strings.")
        if len(values) != len(set(values)) or any(value not in known for value in values):
            raise ValueError("matrix." + side + "_ids contains unknown or duplicate IDs.")
    for key in ("player_levels", "enemy_levels"):
        values = matrix.get(key, [])
        _list(values, "matrix." + key)
        for index, value in enumerate(values):
            _number(value, f"matrix.{key}[{index}]", integer=True, minimum=1, maximum=rules["max_level"])
        if len(values) != len(set(values)):
            raise ValueError("matrix." + key + " contains duplicate levels.")
    sweeps = matrix.get("sweeps", [])
    _list(sweeps, "matrix.sweeps")
    seen = set()
    for index, sweep in enumerate(sweeps):
        prefix = f"matrix.sweeps[{index}]"
        _object(sweep, prefix)
        if sweep.get("side") not in ("player", "enemy"):
            raise ValueError(prefix + ".side must be player or enemy.")
        _attribute_id(sweep.get("attribute"), prefix + ".attribute")
        identity = (sweep["side"], sweep["attribute"])
        if identity in seen:
            raise ValueError(prefix + " duplicates a side/attribute sweep.")
        seen.add(identity)
        _list(sweep.get("values"), prefix + ".values", nonempty=True)
        for value in sweep["values"]:
            _number(value, prefix + ".values")
    run = session.get("run")
    _object(run, "run")
    for key in ("trials", "batch_size", "workers"):
        _number(run.get(key), "run." + key, integer=True, minimum=1)
    _number(run.get("seed"), "run.seed", integer=True, minimum=0)
    _number(run.get("horizon"), "run.horizon", minimum=1e-9)


def _selected(session, collection, key):
    selected = session["matrix"].get(key, [])
    lookup = {item["id"]: item for item in session[collection]}
    return [lookup[id_] for id_ in selected] if selected else list(session[collection])


def estimate_matrix_size(session):
    validate_session(session)
    matrix = session["matrix"]
    result = (len(_selected(session, "players", "player_ids"))
              * len(_selected(session, "enemies", "enemy_ids"))
              * len(_selected(session, "abilities", "ability_ids"))
              * max(1, len(matrix.get("player_levels", [])))
              * max(1, len(matrix.get("enemy_levels", []))))
    for sweep in matrix.get("sweeps", []):
        result *= len(sweep["values"])
    return result


def build_matrix(session):
    """Materialize matrix cells; use iter_matrix for large background runs."""
    return list(iter_matrix(session))


def iter_matrix(session):
    """Stream selected profiles, levels, abilities, and independent attribute sweeps."""
    validate_session(session)
    matrix = session["matrix"]
    dimensions = [_selected(session, "players", "player_ids"),
                  _selected(session, "enemies", "enemy_ids"),
                  _selected(session, "abilities", "ability_ids"),
                  matrix.get("player_levels") or [None],
                  matrix.get("enemy_levels") or [None]]
    sweeps = matrix.get("sweeps", [])
    dimensions.extend(sweep["values"] for sweep in sweeps)
    entries = {int(entry["id"]): entry for entry in _snapshot()["catalogue"]}
    # Cells share one immutable tuning snapshot, detached from the editable UI session.
    experiment_rules = copy.deepcopy(session["rules"])
    experiment_curves = copy.deepcopy(session["curves"])
    for index, combination in enumerate(itertools.product(*dimensions)):
        player, enemy, ability, player_level, enemy_level, *values = combination
        player, enemy = copy.deepcopy(player), copy.deepcopy(enemy)
        if player_level is not None:
            player["level"] = int(player_level)
        if enemy_level is not None:
            enemy["level"] = int(enemy_level)
        variants = [f"{player['name']} L{player['level']}", f"{enemy['name']} L{enemy['level']}"]
        for sweep, value in zip(sweeps, values):
            actor = player if sweep["side"] == "player" else enemy
            actor.setdefault("base_values", {})[str(int(sweep["attribute"]))] = float(value)
            variants.append(f"{sweep['side']} {entries[int(sweep['attribute'])]['name']}={value:g}")
        yield {"index": index, "id": f"cell-{index + 1:06d}",
               "player": player, "enemy": enemy, "ability": copy.deepcopy(ability),
               "rules": experiment_rules, "curves": experiment_curves,
               "variants": " | ".join(variants)}


def _godot_executable(godot_path):
    if godot_path:
        candidate = Path(godot_path).expanduser()
        if candidate.is_file():
            return str(candidate)
        found = shutil.which(str(godot_path))
        if found:
            return found
        raise ValueError("Godot executable does not exist: " + str(godot_path))
    environment = os.environ.get("GODOT_PATH")
    if environment:
        return _godot_executable(environment)
    for name in ("godot", "godot4", "godot_console"):
        found = shutil.which(name)
        if found:
            return found
    candidates = sorted((Path.home() / "Desktop" / "GODOT").glob("Godot*_console.exe"))
    if candidates:
        return str(candidates[-1])
    raise ValueError("Godot not found. Select its console executable or set GODOT_PATH.")


def import_game(godot_path=None):
    """Read saved content using an explicitly headless, off-tree Godot subprocess."""
    require_legacy_rules(_read_json(LIVE_RULES_PATH))
    executable = _godot_executable(godot_path)
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    if not (PROJECT_ROOT / ".godot" / "global_script_class_cache.cfg").exists():
        # A fresh checkout needs Godot's generated class registry before --script
        # can resolve class_name types. This import remains entirely headless.
        try:
            prepared = subprocess.run(
                [executable, "--headless", "--path", str(PROJECT_ROOT),
                 "--editor", "--import", "--quit"], cwd=PROJECT_ROOT,
                capture_output=True, text=True, encoding="utf-8", errors="replace",
                timeout=120, creationflags=flags, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError("Headless Godot project import failed: " + str(error)) from error
        if prepared.returncode:
            raise ValueError("Headless Godot project import failed:\n" + prepared.stderr[-10000:])
    with tempfile.TemporaryDirectory(prefix="combat_lab_import_") as temporary:
        output = Path(temporary) / "game_snapshot.json"
        command = [executable, "--headless", "--path", str(PROJECT_ROOT), "--script",
                   "res://tools/combat_simulator/lab/export_game.gd", "--", "--output", str(output)]
        try:
            process = subprocess.run(command, cwd=PROJECT_ROOT, capture_output=True, text=True,
                                     encoding="utf-8", errors="replace", timeout=120,
                                     creationflags=flags, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError("Headless Godot import failed: " + str(error)) from error
        if process.returncode != 0 or not output.is_file() or "COMBAT_LAB_EXPORT_OK" not in process.stdout:
            detail = (process.stderr + "\n" + process.stdout).strip()
            raise ValueError("Headless Godot import failed:\n" + detail[-10000:])
        snapshot = _read_json(output)
    old = SNAPSHOT_PATH.read_text(encoding="utf-8") if SNAPSHOT_PATH.exists() else None
    SNAPSHOT_PATH.write_text(json.dumps(snapshot, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    _snapshot.cache_clear()
    try:
        session = _session_from_snapshot(snapshot)
        validate_session(session)
    except (ValueError, KeyError, TypeError) as error:
        if old is not None:
            SNAPSHOT_PATH.write_text(old, encoding="utf-8")
        elif SNAPSHOT_PATH.exists():
            SNAPSHOT_PATH.unlink()
        _snapshot.cache_clear()
        raise ValueError("Imported game data is unsupported: " + str(error)) from error
    return session
