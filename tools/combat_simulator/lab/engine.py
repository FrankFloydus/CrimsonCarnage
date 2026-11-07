"""Repeated, event-timed encounters for the offline combat lab.

One trial repeatedly uses one ability against a stationary, non-attacking target.
Only health damage payloads are supported.  Actor evaluation belongs to model;
the shared simulator supplies the game's numeric formula helpers.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import threading
import time
from array import array
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass
from typing import Any, Callable

import numpy as np

from .. import simulator as sim
from . import model


Progress = Callable[[dict[str, Any]], None]
_MASK64 = (1 << 64) - 1
_RANDOM_STREAMS = {
    "entropy": 0x243F6A8885A308D3,
    "block": 0x13198A2E03707344,
    "accuracy": 0xA4093822299F31D0,
    "application": 0x082EFA98EC4E6C89,
    "critical": 0x452821E638D01377,
    "damage": 0xBE5466CF34E90C6C,
}
_METRICS = (
    "attempts", "hits", "missed", "resisted", "evaded", "blocked",
    "critical_events", "damage_events", "damage_direct", "damage_periodic", "damage_absorbed", "health_remaining", "absorption_remaining",
)


def _cancelled(cancel: Any) -> bool:
    if cancel is None:
        return False
    if hasattr(cancel, "is_set"):
        return bool(cancel.is_set())
    return bool(cancel()) if callable(cancel) else bool(cancel)


def _notify(progress: Progress | None, event: dict[str, Any]) -> None:
    if progress is not None:
        progress(event)


def _time_tolerance(value: float) -> float:
    # Use representational precision, not an absolute simulation tick.  A fixed
    # epsilon could turn a very short release into a fabricated time-zero hit.
    return math.ulp(value) * 16.0


def _matches(tags: tuple[str, ...] | list[str], required: str) -> bool:
    return any(tag == required or tag.startswith(required + ".") for tag in tags)


def _cell_seed(cell: dict[str, Any], seed: int) -> int:
    # Matrix ordering and worker scheduling must not change a matchup's samples.
    semantic = {key: cell.get(key) for key in
                ("player", "enemy", "ability", "rules", "curves", "variants")}
    encoded = json.dumps(semantic, sort_keys=True, separators=(",", ":"),
                         ensure_ascii=True, allow_nan=False).encode("utf-8")
    digest = int.from_bytes(hashlib.blake2b(encoded, digest_size=8).digest(), "little")
    return (digest ^ int(seed)) & _MASK64


class _TrialRandom:
    """Independent per-trial SplitMix64 streams, invariant to batch partitioning.

    These are reproducible independent samples, not a replay of Godot's RNG.
    A draw advances only participating trials in the selected random stream.
    """

    def __init__(self, seed: int, offset: int, count: int) -> None:
        ids = np.arange(offset, offset + count, dtype=np.uint64)
        identity = (ids + np.uint64(1)) * np.uint64(0xD2B74407B1CE6E93)
        self._states = {
            name: identity ^ np.uint64(seed) ^ np.uint64(salt)
            for name, salt in _RANDOM_STREAMS.items()
        }

    def draw(self, stream: str, selected: np.ndarray) -> np.ndarray:
        state = self._states[stream]
        value = state[selected] + np.uint64(0x9E3779B97F4A7C15)
        state[selected] = value
        value = (value ^ (value >> np.uint64(30))) * np.uint64(0xBF58476D1CE4E5B9)
        value = (value ^ (value >> np.uint64(27))) * np.uint64(0x94D049BB133111EB)
        value ^= value >> np.uint64(31)
        return (value >> np.uint64(11)).astype(np.float64) * (1.0 / (1 << 53))


@dataclass
class _Effect:
    definition: dict[str, Any]
    identity: str
    magnitude: float
    critical_chance: float
    critical_multiplier: float
    application_chance: float
    periodic: bool
    duration: float
    period: float
    execute_on_application: bool
    reapplication: str
    maximum_stacks: int
    school: str = "physical"
    ordinary_raw: float = 0.0
    bleed: bool = False
    raw_minimum: float = 0.0
    raw_maximum: float = 0.0


@dataclass
class _Schedule:
    deliveries: np.ndarray
    wait_starts: np.ndarray
    wait_ends: np.ndarray
    terminal_resource_time: float
    cancelled: bool = False
    unavailable_reason: str = ""

    def wait_time(self, exposures: np.ndarray) -> np.ndarray:
        result = np.zeros(exposures.size, dtype=np.float64)
        # Normally there are only a few waits.  Work in intervals, not a large
        # trials x actions matrix, so memory remains bounded by batch_size.
        for start, end in zip(self.wait_starts, self.wait_ends):
            result += np.maximum(0.0, np.minimum(exposures, end) - start)
        return result


@dataclass
class _Prepared:
    cell: dict[str, Any]
    ids: dict[str, int]
    source: dict[int, float]
    target: dict[int, float]
    effects: list[_Effect]
    dodge_chance: float
    block_chance: float
    accuracy: float
    analytic: dict[str, Any]
    schedule: _Schedule
    critical_chance: float
    critical_multiplier: float
    ailment_chances: dict[str, float]


class _PeriodicGroup:
    def __init__(self, slots: int, count: int) -> None:
        shape = (slots, count)
        self.active = np.zeros(shape, dtype=bool)
        self.next_tick = np.full(shape, np.inf)
        self.expires = np.full(shape, np.inf)
        self.period = np.ones(shape)
        self.magnitude = np.zeros(shape)
        self.critical = np.zeros(shape, dtype=bool)

    def clear(self, selected: np.ndarray) -> None:
        self.active[:, selected] = False
        self.next_tick[:, selected] = np.inf
        self.expires[:, selected] = np.inf


def _effect_tags(ability: dict[str, Any], effect: dict[str, Any]) -> tuple[str, ...]:
    tags = list(dict.fromkeys(ability.get("tags", []) + effect.get("damage_tags", [])))
    school = sim.canonical_school(effect.get("damage_type", "physical"))
    tags.append("Damage." + school.capitalize())
    if school in ("fire", "cold", "lightning"):
        tags.append("Damage.Elemental")
    tags.append("Damage.Periodic" if effect.get("periodic", False) else "Damage.Direct")
    return tuple(dict.fromkeys(tags))


def _finite_or_none(value: float) -> float | None:
    return float(value) if math.isfinite(value) else None


def _make_schedule(
    source: dict[int, float], ids: dict[str, int], ability: dict[str, Any],
    duration: float, cooldown: float, cost: float, horizon: float,
    cancel: Any,
) -> _Schedule:
    deliveries, wait_starts, wait_ends = array("d"), array("d"), array("d")
    terminal = math.inf
    cost_id = int(ability.get("cost_attribute", -1))
    health_id = ids["HEALTH"]
    if source[health_id] <= 0:
        return _Schedule(np.asarray(deliveries), np.asarray(wait_starts),
                         np.asarray(wait_ends), terminal, unavailable_reason="source_dead")
    blocked = ability.get("blocked_tags", ["State.Dead", "State.Stunned",
                                            "State.Silenced", "State.PerformingAction"])
    # The caller handles actor tags; no runtime tag-granting payloads are supported.
    actor_tags = ability.get("_source_tags", [])
    blocked_matches = [tag for tag in blocked if _matches(actor_tags, tag)]
    missing = [tag for tag in ability.get("required_tags", []) if not _matches(actor_tags, tag)]
    if blocked_matches or missing:
        reason = "blocked_by_tags: " + ", ".join(blocked_matches) if blocked_matches \
            else "missing_required_tags: " + ", ".join(missing)
        return _Schedule(np.asarray(deliveries), np.asarray(wait_starts),
                         np.asarray(wait_ends), terminal, unavailable_reason=reason)
    capacity_id = {ids["HEALTH"]: ids["MAX_HEALTH"],
                   ids["STAMINA"]: ids["MAX_STAMINA"],
                   ids["MANA"]: ids["MAX_MANA"]}.get(cost_id)
    regen_id = {ids["STAMINA"]: ids["STAMINA_REGEN"],
                ids["MANA"]: ids["MANA_REGEN"]}.get(cost_id)
    capacity = source[capacity_id] if capacity_id is not None else math.inf
    pool = source.get(cost_id, math.inf)
    regen = source[regen_id] if regen_id is not None else 0.0
    if not ability.get("_automatic_regeneration", True) or (
            cost_id == ids["STAMINA"] and ability.get("_pause_stamina_regeneration", False)):
        regen = 0.0
    cycle = max(duration, cooldown)
    release_delay = duration * float(ability.get("release_fraction", 0.0)) \
        + float(ability.get("travel_time", 0.0))
    start = last_update = 0.0
    tolerance = _time_tolerance(horizon)
    while start <= horizon + tolerance:
        if _cancelled(cancel):
            return _Schedule(np.asarray(deliveries), np.asarray(wait_starts),
                             np.asarray(wait_ends), terminal, True)
        pool = min(capacity, pool + regen * max(0.0, start - last_update))
        last_update = start
        if cost_id != -1 and cost > 0.0 and pool < cost:
            wait_starts.append(min(start, horizon))
            if cost > capacity or regen <= 0.0:
                wait_ends.append(horizon)
                terminal = start
                break
            delay = (cost - pool) / regen
            wait_ends.append(min(horizon, start + delay))
            start += delay
            if start > horizon + tolerance or not math.isfinite(start):
                break
            pool = cost
            last_update = start
        if cost_id != -1:
            pool = max(0.0, pool - cost)
        # Spending the last Health cancels the cast through State.Dead in Godot.
        # Earlier released projectiles remain in deliveries and may still kill.
        if cost_id == health_id and pool <= 0.0:
            terminal = start
            break
        delivery = start + release_delay
        if delivery <= horizon + tolerance:
            deliveries.append(min(delivery, horizon))
        next_start = start + cycle
        if next_start <= start:
            raise ValueError("Action interval is too small for the encounter time precision")
        start = next_start
    return _Schedule(np.asarray(deliveries), np.asarray(wait_starts),
                     np.asarray(wait_ends), terminal)


def _prepare(cell: dict[str, Any], horizon: float, cancel: Any) -> _Prepared:
    ids = model.attribute_ids()
    rules, player, enemy, ability = (cell[key] for key in ("rules", "player", "enemy", "ability"))
    source = model.resolve_actor(player, rules)
    target = model.resolve_actor(enemy, rules)
    ability_tags = tuple(ability.get("tags", []))
    ability_source = model.resolve_actor(player, rules, ability_tags)
    is_spell = ability.get("kind", "melee") == "spell"
    curve = cell.get("curves", {}).get("melee", rules["accuracy_chance_by_level_gap"])
    source_level, target_level = int(player["level"]), int(enemy["level"])
    gap = target_level - source_level
    required = float(sim.required_hit_rating(source_level, target_level, rules))
    baseline = float(curve[min(max(gap, 0), len(curve) - 1)])
    if gap < 0:
        baseline = 1.0 - (1.0 - float(curve[0])) * min(
            1.0, max(0.0, required / rules["hit_rating_base_requirement"]))
    rating = ability_source[ids["HIT_RATING"]]
    accuracy = baseline + (1.0 - baseline) * min(1.0, rating / required) if required > 0.0 else 1.0
    target_tags = tuple(enemy.get("tags", []))
    effects: list[_Effect] = []
    delivery_tags = list(ability_tags)
    critical_tags = list(ability_tags)
    direct_schools = set()
    level_factor = float(sim.level_gap_factor(source_level, target_level, rules))
    critical_multiplier = float(sim.critical_damage_multiplier(ability_source[ids["CRITICAL_DAMAGE"]], rules))
    for index, definition in enumerate(ability.get("effects", [])):
        if float(definition.get("application_chance", 100.0)) <= 0.0:
            continue
        if not all(_matches(target_tags, tag) for tag in definition.get("required_target_tags", [])):
            continue
        if any(_matches(target_tags, tag) for tag in definition.get("blocked_target_tags", [])):
            continue
        tags = _effect_tags(ability, definition)
        delivery_tags.extend(tags)
        scoped_source = model.resolve_actor(player, rules, tags)
        scoped_target = model.resolve_actor(enemy, rules, tags)
        school = sim.canonical_school(definition.get("damage_type", "physical"))
        base = float(definition.get("base_damage", 0.0))
        minimum = float(definition.get("base_damage_min", base))
        maximum = float(definition.get("base_damage_max", base))
        if definition.get("scale_with_level", False):
            tier = 1.0 + rules["level_payload_per_level"] * (source_level - 1)
            minimum *= tier
            maximum *= tier
        if school == "physical":
            strength_factor = float(sim.strength_physical_multiplier(scoped_source[ids["STRENGTH"]], rules))
            minimum *= strength_factor
            maximum *= strength_factor
        else:
            power = scoped_source[ids["MAGIC_POWER"]] * float(definition.get("power_coefficient", 0.0))
            minimum += power
            maximum += power
        raw = magnitude = max(0.0, (minimum + maximum) / 2.0)
        periodic = bool(definition.get("periodic", False))
        if periodic:
            magnitude *= float(sim.damage_multiplier(scoped_source[ids["DOT_DAMAGE"]]))
        reduction = float(sim.school_damage_reduction(
            school, scoped_target[ids["ARMOR"]],
            scoped_target.get(ids.get(school.upper() + "_RESISTANCE", -1), 0.0),
            scoped_source[ids["ARMOR_PENETRATION"]], rules))
        magnitude = max(0.0, magnitude * level_factor * (1.0 - reduction))
        if not periodic and raw > 0.0:
            direct_schools.add(school)
        critical = bool(definition.get("critical", False)) and not periodic
        if not periodic and raw > 0.0:
            critical_tags.extend(tags)
        effects.append(_Effect(
            definition, str(definition.get("id") or "effect_%d" % index), magnitude,
            scoped_source[ids["CRITICAL_CHANCE"]] / 100.0 if critical else 0.0,
            float(sim.critical_damage_multiplier(scoped_source[ids["CRITICAL_DAMAGE"]], rules)),
            float(definition.get("application_chance", 100.0)) / 100.0,
            periodic, float(definition.get("duration", 0.0)), float(definition.get("period", 0.0)),
            bool(definition.get("execute_on_application", False)),
            "strongest" if definition.get("strongest_wins", False) else str(definition.get("reapplication", "refresh")),
            int(definition.get("maximum_stacks", 1)), school, raw,
            periodic and school == "physical" and (str(definition.get("ailment_family", "")).lower() == "bleed"
                or _matches(tags, "Damage.Bleed") or _matches(tags, "Ailment.Bleed")),
            minimum, maximum,
        ))
    ailment_chances = {}
    for school in direct_schools:
        family = sim.AILMENTS[school]
        elemental_tags = ("Damage.Elemental",) if school in ("fire", "cold", "lightning") else ()
        direct_tags = ability_tags + ("Damage.Direct", "Damage." + school.capitalize()) + elemental_tags
        scoped_source = model.resolve_actor(player, rules, direct_tags)
        ailment_chances[family] = scoped_source[ids[family.upper() + "_CHANCE"]] / 100.0
        if family not in ("burn", "bleed", "poison"):
            continue
        periodic_tags = ability_tags + ("Damage.Periodic", "Damage." + school.capitalize(), "Ailment." + family.capitalize()) + elemental_tags
        scoped_source = model.resolve_actor(player, rules, periodic_tags)
        scoped_target = model.resolve_actor(enemy, rules, periodic_tags)
        reduction = float(sim.school_damage_reduction(
            school, scoped_target[ids["ARMOR"]],
            scoped_target.get(ids.get(school.upper() + "_RESISTANCE", -1), 0.0),
            scoped_source[ids["ARMOR_PENETRATION"]], rules))
        period = float(rules[family + "_period"])
        # Magnitude is per unit raw seed; deliveries aggregate accepted components.
        per_seed = float(sim.ailment_damage_rate(1.0, family, scoped_source[ids["DOT_DAMAGE"]], rules))
        per_seed *= period * level_factor * (1.0 - reduction)
        definition = {"automatic_family": family}
        effects.append(_Effect(definition, "__automatic_" + family, per_seed, 0.0, 1.0, 1.0,
                               True, float(rules[family + "_duration"]), period, False,
                               "stack" if family == "poison" else "strongest",
                               0 if family == "poison" else 1, school, 0.0, family == "bleed"))
    delivery_tags = [tag for tag in dict.fromkeys(delivery_tags) if tag != "Damage.Periodic"]
    delivery_tags.append("Damage.Direct")
    defense_target = model.resolve_actor(enemy, rules, tuple(delivery_tags))
    dodge = float(sim.defense(defense_target[ids["EVASION"]], rules, evasion=True)) if ability.get("dodgeable", True) else 0.0
    block = defense_target[ids["BLOCK_CHANCE"]] / 100.0 if ability.get("blockable", True) else 0.0
    speed_id = ids["CAST_SPEED_RATING" if is_spell else "ATTACK_SPEED_RATING"]
    encumbrance = max(rules["encumbrance_multiplier_min"], min(1.0,
        source[ids["CARRY_CAPACITY"]] / max(source[ids["CARRY_CAPACITY"]], source[ids["CARRIED_WEIGHT"]])))
    base_duration = 1.0 / float(ability["weapon_attacks_per_second"]) if ability.get("weapon_attacks_per_second") is not None else float(ability["base_duration"])
    playback = float(sim.action_speed_rate(base_duration, float(ability["minimum_duration"]),
        ability_source[speed_id], rules, encumbrance=encumbrance, attack=not is_spell))
    duration = base_duration / playback
    cooldown = float(sim.efficient_cost(float(ability.get("cooldown", 0.0)), ability_source[ids["COOLDOWN_RECOVERY"]]))
    cost_id = int(ability.get("cost_attribute", -1))
    cost = float(sim.resource_cost(float(ability.get("cost_amount", 0.0)))) if cost_id != -1 else 0.0
    schedule_ability = dict(ability, _source_tags=player.get("tags", []),
        _automatic_regeneration=player.get("automatic_regeneration", True),
        _pause_stamina_regeneration=player.get("pause_stamina_regeneration", False))
    schedule = _make_schedule(source, ids, schedule_ability, duration, cooldown, cost, horizon, cancel)
    critical_source = model.resolve_actor(player, rules, tuple(dict.fromkeys(critical_tags)))
    hit_critical = critical_source[ids["CRITICAL_CHANCE"]] / 100.0
    expected_direct = sum(effect.magnitude * (1.0 + (hit_critical if effect.definition.get("critical", False) else 0.0)
        * (effect.critical_multiplier - 1.0)) * effect.application_chance for effect in effects if not effect.periodic)
    analytic = {
        "level_damage_multiplier": level_factor, "unrated_success": baseline,
        "accuracy": accuracy, "required_rating": required, "current_rating": rating,
        "evasion_chance": dodge, "block_chance": block,
        "expected_delivery_success": (1.0 - dodge) * (1.0 - block) * accuracy,
        "action_duration": duration, "cooldown": cooldown, "resource_cost": cost,
        "cycle_without_resource_wait": max(duration, cooldown),
        "scheduled_deliveries": len(schedule.deliveries), "eligible_effects": len(effects),
        "first_delivery_time": float(schedule.deliveries[0]) if len(schedule.deliveries) else None,
        "enemy_initial_health": target[ids["HEALTH"]], "enemy_max_health": target[ids["MAX_HEALTH"]],
        "enemy_initial_absorption": target[ids["ABSORPTION"]],
        "expected_direct_per_landed_delivery": _finite_or_none(expected_direct),
        "terminal_resource_time": _finite_or_none(schedule.terminal_resource_time),
        "unavailable_reason": schedule.unavailable_reason,
        "assumptions": [
            "One ability repeated; target does not attack and physical delivery is assumed to connect.",
            "No passive Health recovery. Consumable encounters are tested separately by the leveling study.",
            "Shared Hit Rating; Dodge then Block then independent delivery accuracy.",
            "Automatic school ailments; one critical result per Hit; periodic snapshots never reroll delivery.",
            "Absorption recovers after damaging-Hit delay; DoTs do not interrupt; Bleed/Necrotic bypass.",
            "Chill has no offensive effect on a non-attacking target; Zapped and Hollowed remain modeled.",
            "Optional damage ranges use independent continuous uniform rolls; melee weapon APS defines its base action duration.",
            "Damage totals include actual Health and Absorption removed, excluding overkill.",
        ],
    }
    return _Prepared(cell, ids, source, target, effects, dodge, block, accuracy, analytic, schedule,
                     hit_critical, critical_multiplier, ailment_chances)


def _periodic_capacities(prepared: _Prepared) -> dict[str, int]:
    configured = {}
    deliveries = prepared.schedule.deliveries
    if not len(deliveries):
        return configured
    for effect in prepared.effects:
        if not effect.periodic:
            continue
        limit = effect.maximum_stacks
        if limit == 0:
            # Storage bound follows possible overlapping applications, never a game cap.
            shortest = float(np.min(np.diff(deliveries))) if len(deliveries) > 1 else math.inf
            limit = min(len(deliveries), int(math.ceil(effect.duration / shortest)) + 1) if shortest > 0 else len(deliveries)
        configured[effect.identity] = max(configured.get(effect.identity, 0), min(limit, len(deliveries)))
    return configured


def _simulate_batch(prepared: _Prepared, count: int, offset: int, seed: int, horizon: float, cancel: Any) -> dict[str, Any]:
    ids, ability, rules = prepared.ids, prepared.cell["ability"], prepared.cell["rules"]
    random = _TrialRandom(seed, offset, count)
    health = np.full(count, prepared.target[ids["HEALTH"]], dtype=np.float64)
    absorption = np.full(count, prepared.target[ids["ABSORPTION"]], dtype=np.float64)
    max_absorption = prepared.target[ids["MAX_ABSORPTION"]]
    recharge_rate = float(sim.absorption_regeneration(max_absorption, rules))
    recharge_delay = float(rules["absorption_recovery_delay"])
    last_damaging_hit = np.full(count, -math.inf)
    utilities = {family: (np.zeros(count), np.zeros(count)) for family in ("chill", "zapped", "hollowed")}
    alive = health > 0.0
    killed = np.full(count, np.nan)
    killed[~alive] = 0.0
    metrics = {key: np.zeros(count, dtype=np.float64) for key in _METRICS}
    entropy = np.zeros(count)
    last_entropy = -math.inf
    groups = {identity: _PeriodicGroup(slots, count) for identity, slots in _periodic_capacities(prepared).items()}
    definitions = {effect.identity: effect for effect in prepared.effects if effect.periodic}

    def damage(selected, magnitude, critical, periodic, now, school, bleed=False):
        indices = np.flatnonzero(selected) if selected.dtype == bool else selected
        if indices.size == 0:
            return
        magnitude = np.broadcast_to(np.asarray(magnitude, dtype=float), (indices.size,))
        previous_absorption = absorption[indices].copy()
        remaining, health_damage, absorbed = sim.absorption_damage(magnitude, previous_absorption, school, bleed)
        absorption[indices] = remaining
        actual_health = np.minimum(health[indices], health_damage)
        health[indices] -= actual_health
        actual = actual_health + absorbed
        metrics["damage_periodic" if periodic else "damage_direct"][indices] += actual
        metrics["damage_absorbed"][indices] += absorbed
        metrics["damage_events"][indices] += 1.0
        metrics["critical_events"][indices] += critical
        if not periodic:
            last_damaging_hit[indices[magnitude > 0.0]] = now
        deaths = indices[health[indices] <= 0.0]
        if deaths.size:
            killed[deaths] = now
            alive[deaths] = False
            for group in groups.values():
                group.clear(deaths)

    def install(effect, selected, magnitudes, critical, now):
        group = groups[effect.identity]
        selected = selected.copy() & alive
        existing = np.any(group.active, axis=0)
        if effect.reapplication in ("refresh", "strongest"):
            for slot in range(group.active.shape[0]):
                present = selected & group.active[slot]
                if effect.reapplication == "strongest":
                    candidate = magnitudes / effect.period
                    current = group.magnitude[slot] / group.period[slot]
                    qualifies = present & (candidate >= current)
                    stronger = qualifies & (candidate > current)
                    group.magnitude[slot, stronger] = magnitudes[stronger]
                    group.critical[slot, stronger] = critical[stronger]
                    equal = qualifies & ~stronger
                    group.expires[slot, stronger] = now + effect.duration
                    group.expires[slot, equal] = np.maximum(group.expires[slot, equal], now + effect.duration)
                else:
                    group.expires[slot, present] = now + effect.duration
            selected &= ~existing
        elif effect.reapplication == "replace":
            group.clear(selected)
        elif effect.maximum_stacks > 0:
            selected &= np.sum(group.active, axis=0) < effect.maximum_stacks
        indices = np.flatnonzero(selected)
        if not indices.size:
            return
        free = ~group.active[:, indices]
        if np.any(~np.any(free, axis=0)):
            raise RuntimeError("Periodic storage bound exhausted; this is not an authored stack cap")
        slots = np.argmax(free, axis=0)
        group.active[slots, indices] = True
        group.magnitude[slots, indices] = magnitudes[indices]
        group.critical[slots, indices] = critical[indices]
        group.expires[slots, indices] = now + effect.duration
        group.period[slots, indices] = effect.period
        group.next_tick[slots, indices] = now + effect.period
        if effect.execute_on_application:
            damage(indices, magnitudes[indices], critical[indices], True, now, effect.school, effect.bleed)

    def apply_utility(family, selected, school_damage, now):
        magnitude, expires = utilities[family]
        maximum = {"chill": rules["chill_slow_max"], "zapped": rules["zapped_critical_bonus"],
                   "hollowed": rules["hollowed_recovery_reduction_max"]}[family]
        candidate = maximum * sim.ailment_potency(school_damage, prepared.cell["enemy"]["level"], rules)
        expired = expires <= now
        accepted = selected & ((candidate >= magnitude) | expired) & (candidate > 0.0)
        duration = float(rules[family + "_duration"])
        if family == "chill":
            duration *= float(sim.control_level_duration_factor(prepared.cell["player"]["level"], prepared.cell["enemy"]["level"], rules))
            duration *= 1.0 - prepared.target[ids["RESOLVE"]] / 100.0
        stronger = accepted & ((candidate > magnitude) | expired)
        equal = accepted & ~stronger
        magnitude[accepted] = candidate[accepted]
        expires[stronger] = now + duration
        expires[equal] = np.maximum(expires[equal], now + duration)

    def deliver(now):
        nonlocal last_entropy
        if not prepared.effects or not np.any(alive):
            return
        metrics["attempts"][alive] += 1.0
        connected = alive.copy()
        if ability.get("dodgeable", True):
            if now - last_entropy >= rules["entropy_reset_seconds"]:
                entropy[connected] = random.draw("entropy", connected) * 100.0
            last_entropy = now
            entropy[connected] += (1.0 - prepared.dodge_chance) * 100.0
            evaded = connected & (entropy < 100.0)
            entropy[connected & ~evaded] -= 100.0
            metrics["evaded"][evaded] += 1.0
            connected &= ~evaded
        if prepared.block_chance > 0.0:
            blocked = np.zeros(count, dtype=bool)
            blocked[connected] = random.draw("block", connected) < prepared.block_chance
            metrics["blocked"][blocked] += 1.0
            connected &= ~blocked
        if prepared.accuracy < 1.0:
            missed = np.zeros(count, dtype=bool)
            missed[connected] = random.draw("accuracy", connected) >= prepared.accuracy
            metrics["resisted" if ability.get("kind", "melee") == "spell" else "missed"][missed] += 1.0
            connected &= ~missed
        metrics["hits"][connected] += 1.0
        zapped, zap_expires = utilities["zapped"]
        chance = np.clip(prepared.critical_chance + np.where(zap_expires > now, zapped / 100.0, 0.0), 0.0, 1.0)
        hit_critical = np.zeros(count, dtype=bool)
        eligible_critical = any(not effect.periodic and effect.definition.get("critical", False) for effect in prepared.effects)
        if eligible_critical:
            hit_critical[connected] = random.draw("critical", connected) < chance[connected]
        raw_seeds = {school: np.zeros(count) for school in sim.AILMENTS}
        mitigated_seeds = {school: np.zeros(count) for school in sim.AILMENTS}
        authored_periodics = []
        for effect in prepared.effects:
            if effect.definition.get("automatic_family"):
                continue
            selected = connected & alive
            if effect.application_chance < 1.0:
                accepted = np.zeros(count, dtype=bool)
                accepted[selected] = random.draw("application", selected) < effect.application_chance
                selected &= accepted
            if not np.any(selected):
                continue
            if effect.periodic:
                authored_periodics.append((effect, selected))
                continue
            rolled_raw = np.full(np.count_nonzero(selected), effect.ordinary_raw)
            if effect.raw_maximum > effect.raw_minimum:
                rolled_raw = effect.raw_minimum + random.draw("damage", selected) * (effect.raw_maximum - effect.raw_minimum)
            ordinary = effect.magnitude * (rolled_raw / effect.ordinary_raw) if effect.ordinary_raw > 0 else np.zeros(rolled_raw.size)
            raw_seeds[effect.school][selected] += rolled_raw
            mitigated_seeds[effect.school][selected] += ordinary
            critical = hit_critical & bool(effect.definition.get("critical", False))
            magnitude = ordinary * np.where(critical[selected], effect.critical_multiplier, 1.0)
            damage(selected, magnitude, critical[selected], False, now, effect.school, effect.bleed)
        for effect, selected in authored_periodics:
            critical = np.zeros(count, dtype=bool)
            if effect.critical_chance > 0.0:
                critical[selected] = random.draw("critical", selected) < effect.critical_chance
            magnitudes = effect.magnitude * np.where(critical, effect.critical_multiplier, 1.0)
            install(effect, selected, magnitudes, critical, now)
        automatic = {effect.definition["automatic_family"]: effect for effect in prepared.effects
                     if effect.definition.get("automatic_family")}
        for school, family in sim.AILMENTS.items():
            selected = connected & alive & (raw_seeds[school] > 0.0)
            if _matches(prepared.cell["enemy"].get("tags", []), "Immunity." + family.capitalize()) or _matches(prepared.cell["enemy"].get("tags", []), "State.Dead"):
                continue
            if not np.any(selected):
                continue
            accepted = selected & hit_critical
            ordinary = selected & ~hit_critical
            accepted[ordinary] = random.draw("application", ordinary) < prepared.ailment_chances.get(family, 0.0)
            if family in automatic:
                effect = automatic[family]
                install(effect, accepted, raw_seeds[school] * effect.magnitude, np.zeros(count, dtype=bool), now)
            elif family in utilities:
                apply_utility(family, accepted, mitigated_seeds[school], now)

    now, delivery_index, completed = 0.0, 0, True
    while np.any(alive):
        if _cancelled(cancel):
            completed = False
            break
        next_delivery = float(prepared.schedule.deliveries[delivery_index]) if delivery_index < len(prepared.schedule.deliveries) else math.inf
        next_periodic = math.inf
        for group in groups.values():
            next_periodic = min(next_periodic, float(np.min(group.next_tick)), float(np.min(group.expires)))
        event_time = min(next_delivery, next_periodic, horizon)
        if event_time > now and recharge_rate > 0.0 and prepared.cell["enemy"].get("automatic_regeneration", True):
            start = np.maximum(now, last_damaging_hit + recharge_delay)
            eligible = np.maximum(0.0, event_time - start)
            hollowed, hollowed_until = utilities["hollowed"]
            suppressed_time = np.maximum(0.0, np.minimum(event_time, hollowed_until) - start)
            recovered = recharge_rate * (eligible - hollowed * suppressed_time)
            absorption[alive] = np.minimum(max_absorption, absorption[alive] + recovered[alive])
        now = event_time
        tolerance = _time_tolerance(now)
        for identity, group in groups.items():
            effect = definitions[identity]
            for slot in range(group.active.shape[0]):
                due = group.active[slot] & alive & (group.next_tick[slot] <= now + tolerance) & (group.next_tick[slot] <= group.expires[slot] + tolerance)
                if np.any(due):
                    previous_tick = group.next_tick[slot, due]
                    following_tick = previous_tick + group.period[slot, due]
                    if np.any(following_tick <= previous_tick):
                        raise ValueError("Periodic interval is too small for encounter precision")
                    group.next_tick[slot, due] = following_tick
                    damage(due, group.magnitude[slot, due], group.critical[slot, due], True, now, effect.school, effect.bleed)
            expired = group.active & (group.expires <= now + tolerance)
            group.active[expired] = False
            group.next_tick[expired] = np.inf
            group.expires[expired] = np.inf
        while next_delivery <= now + tolerance and delivery_index < len(prepared.schedule.deliveries):
            deliver(now)
            delivery_index += 1
            next_delivery = float(prepared.schedule.deliveries[delivery_index]) if delivery_index < len(prepared.schedule.deliveries) else math.inf
        if now >= horizon:
            break
    metrics["health_remaining"] = health
    metrics["absorption_remaining"] = absorption
    finished = np.ones(count, dtype=bool) if completed else ~np.isnan(killed)
    exposures = np.where(np.isnan(killed[finished]), horizon, killed[finished])
    resource_wait = prepared.schedule.wait_time(exposures)
    terminal = prepared.schedule.terminal_resource_time
    return {
        "count": int(np.count_nonzero(finished)), "kill_times": killed[finished][~np.isnan(killed[finished])],
        "exposure": float(np.sum(exposures)), "resource_wait": float(np.sum(resource_wait)),
        "resource_starved": int(np.count_nonzero(resource_wait > 0.0)),
        "resource_depleted": int(np.count_nonzero(np.isnan(killed[finished]) & (exposures >= terminal))) if math.isfinite(terminal) else 0,
        "metrics": {key: float(np.sum(values[finished])) for key, values in metrics.items()}, "cancelled": not completed,
    }


def simulate_cell(
    cell: dict[str, Any], trials: int, horizon: float, seed: int,
    batch_size: int = 4096, progress: Progress | None = None, cancel: Any = None,
) -> dict[str, Any]:
    """Run independent encounters for one expanded matrix cell.

    Damage fields are mean actual damage per completed trial.  Outcome rates use
    delivery attempts; crit_rate uses executed damage events, including ticks.
    effective_dps is total actual damage / total time exposed, stopping on death.
    Kill-time summaries are conditional on kills.  Timeouts contribute horizon
    only to restricted_mean_time.  Cancellation excludes unfinished encounters.
    """
    if int(trials) != trials or trials <= 0 or not math.isfinite(horizon) or horizon <= 0:
        raise ValueError("Trials and horizon must be positive; horizon must be finite")
    if int(batch_size) != batch_size or batch_size <= 0:
        raise ValueError("batch_size must be a positive integer")
    trials, batch_size = int(trials), int(batch_size)
    started = time.perf_counter()
    prepared = _prepare(cell, float(horizon), cancel)
    # Bound trial arrays to roughly32MiB.  This changes only batching, never an
    # authored stack limit or combat formula.  Per-trial RNG is partition-invariant.
    bytes_per_trial = 256 + 34 * sum(_periodic_capacities(prepared).values())
    batch_size = min(batch_size, max(1, (32 * 1024 * 1024) // bytes_per_trial))
    completed = resource_starved = resource_depleted = 0
    metrics = {key: 0.0 for key in _METRICS}
    exposure = resource_wait = 0.0
    kills: list[np.ndarray] = []
    derived_seed = _cell_seed(cell, seed)
    if not prepared.schedule.cancelled:
        for offset in range(0, trials, batch_size):
            if _cancelled(cancel):
                break
            batch = _simulate_batch(prepared, min(batch_size, trials - offset), offset,
                                    derived_seed, float(horizon), cancel)
            completed += batch["count"]
            exposure += batch["exposure"]
            resource_wait += batch["resource_wait"]
            resource_starved += batch["resource_starved"]
            resource_depleted += batch["resource_depleted"]
            kills.append(batch["kill_times"])
            for key in _METRICS:
                metrics[key] += batch["metrics"][key]
            _notify(progress, {"type": "progress", "completed_trials": completed,
                               "total_trials": trials, "cell_index": int(cell.get("index", 0))})
            if batch["cancelled"]:
                break
    times = np.concatenate(kills) if kills else np.empty(0, dtype=np.float64)
    kill_count = int(times.size)
    percentiles = np.percentile(times, [10, 50, 90, 95]) if kill_count else [None] * 4
    bin_edges = np.linspace(0.0, float(horizon), 31)
    counts, edges = np.histogram(times, bins=bin_edges)
    attempts = metrics["attempts"]
    total_damage = metrics["damage_direct"] + metrics["damage_periodic"]
    player, enemy, ability = (cell[key] for key in ("player", "enemy", "ability"))
    return {
        "index": int(cell.get("index", 0)),
        "player_name": str(player.get("name", player.get("id", "Player"))),
        "enemy_name": str(enemy.get("name", enemy.get("id", "Enemy"))),
        "ability_name": str(ability.get("name", ability.get("id", "Ability"))),
        "player_level": int(player["level"]), "enemy_level": int(enemy["level"]),
        "variants": copy.deepcopy(cell.get("variants", {})),
        "status": "complete" if completed == trials else "cancelled",
        "unavailable_reason": prepared.schedule.unavailable_reason,
        "requested_trials": trials, "trials": completed, "kills": kill_count,
        "timeouts": completed - kill_count,
        "kill_rate": kill_count / completed if completed else 0.0,
        "ttk_mean": float(np.mean(times)) if kill_count else None,
        "ttk_p10": float(percentiles[0]) if kill_count else None,
        "ttk_median": float(percentiles[1]) if kill_count else None,
        "ttk_p90": float(percentiles[2]) if kill_count else None,
        "ttk_p95": float(percentiles[3]) if kill_count else None,
        "ttk_max": float(np.max(times)) if kill_count else None,
        "restricted_mean_time": exposure / completed if completed else None,
        "effective_dps": total_damage / exposure if exposure > 0.0
            else (None if total_damage > 0.0 else 0.0),
        "mean_attempts": attempts / completed if completed else 0.0,
        "hit_rate": metrics["hits"] / attempts if attempts else 0.0,
        "miss_rate": metrics["missed"] / attempts if attempts else 0.0,
        "resist_rate": metrics["resisted"] / attempts if attempts else 0.0,
        "dodge_rate": metrics["evaded"] / attempts if attempts else 0.0,
        "block_rate": metrics["blocked"] / attempts if attempts else 0.0,
        "crit_rate": metrics["critical_events"] / metrics["damage_events"]
            if metrics["damage_events"] else 0.0,
        "damage_direct": metrics["damage_direct"] / completed if completed else 0.0,
        "damage_periodic": metrics["damage_periodic"] / completed if completed else 0.0,
        "damage_absorbed": metrics["damage_absorbed"] / completed if completed else 0.0,
        "enemy_health_remaining": metrics["health_remaining"] / completed if completed else 0.0,
        "enemy_absorption_remaining": metrics["absorption_remaining"] / completed if completed else 0.0,
        "resource_wait_time": resource_wait / completed if completed else 0.0,
        "resource_starved_trials": resource_starved, "resource_depleted_trials": resource_depleted,
        "elapsed_seconds": time.perf_counter() - started,
        "histogram": {"edges": edges.tolist(), "counts": counts.tolist()},
        "analytic": prepared.analytic,
    }


def run_matrix(
    session: dict[str, Any], progress: Progress | None = None, cancel: Any = None,
) -> dict[str, Any]:
    """Run an immutable JSON-compatible experiment snapshot, optionally by cell.

    Progress callbacks may run on worker threads.  Callers must marshal messages
    to the GUI thread rather than touch widgets from the callback.
    """
    started = time.perf_counter()
    snapshot = copy.deepcopy(session)
    model.validate_session(snapshot)
    cell_count = model.estimate_matrix_size(snapshot)
    cells = model.iter_matrix(snapshot)
    settings = snapshot["run"]
    trials, horizon = int(settings["trials"]), float(settings["horizon"])
    seed = int(settings.get("seed", 1))
    batch_size, workers = int(settings.get("batch_size", 4096)), int(settings.get("workers", 1))
    requested = cell_count * trials
    completed_by_cell: dict[int, int] = {}
    results: list[dict[str, Any]] = []
    lock = threading.Lock()
    abort = threading.Event()

    def stopping() -> bool:
        return abort.is_set() or _cancelled(cancel)

    def report(event: dict[str, Any]) -> None:
        if event.get("type") != "progress":
            return
        with lock:
            completed_by_cell[event["cell_index"]] = int(event["completed_trials"])
            completed = sum(completed_by_cell.values())
            # Serialize callback delivery as well as the counter update so two
            # worker messages cannot make the displayed total move backwards.
            _notify(progress, dict(event, completed_trials=completed, total_trials=requested,
                                   cell_completed_trials=int(event["completed_trials"]),
                                   cell_total_trials=trials))

    def work(cell: dict[str, Any]) -> dict[str, Any]:
        try:
            return simulate_cell(cell, trials, horizon, seed, batch_size, report, stopping)
        except BaseException:
            # An invalid cell must not wait for unrelated long-running workers
            # before the caller receives its error.  Do not mutate user events.
            abort.set()
            raise

    def accept(row: dict[str, Any]) -> None:
        results.append(row)
        _notify(progress, {"type": "cell", "result": row, "completed_cells": len(results),
                           "total_cells": cell_count})

    if workers <= 1:
        for cell in cells:
            if _cancelled(cancel):
                break
            accept(work(cell))
    elif not _cancelled(cancel):
        iterator = iter(cells)
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="combat-lab") as executor:
            pending = set()
            for _ in range(min(workers, cell_count)):
                pending.add(executor.submit(work, next(iterator)))
            while pending:
                done, pending = wait(pending, return_when=FIRST_COMPLETED)
                for future in done:
                    accept(future.result())
                    if not _cancelled(cancel):
                        following = next(iterator, None)
                        if following is not None:
                            pending.add(executor.submit(work, following))
    results.sort(key=lambda row: row["index"])
    completed = sum(row["trials"] for row in results)
    return {
        "status": "complete" if completed == requested else "cancelled",
        "requested_trials": requested, "completed_trials": completed, "cells": results,
        "elapsed_seconds": time.perf_counter() - started, "scenario_snapshot": snapshot,
    }
