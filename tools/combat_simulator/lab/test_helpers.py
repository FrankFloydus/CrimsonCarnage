"""Small serializable fixtures with independent combat expectations; no Tk or desktop use."""
from __future__ import annotations

import copy
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from tools.combat_simulator.lab import model


def ids():
    return {entry["key"]: int(entry["id"]) for entry in model.attribute_catalogue()}


def actor(actor_id="player", *, level=1, **attributes):
    names = ids()
    defaults = {key: 0 for key in ("BURN_CHANCE", "CHILL_CHANCE", "ZAPPED_CHANCE", "BLEED_CHANCE", "POISON_CHANCE", "HOLLOWED_CHANCE")}
    defaults.update(attributes)
    attributes = defaults
    return {
        "id": actor_id,
        "name": actor_id.title(),
        "level": level,
        "allocations": {"strength": 0, "dexterity": 0, "intellect": 0, "vitality": 0},
        "base_values": {str(names[key]): float(value) for key, value in attributes.items()},
        "modifiers": [],
        "tags": [],
        "automatic_regeneration": True,
        "pause_stamina_regeneration": False,
    }


def effect(**changes):
    value = {
        "id": "impact", "name": "Impact", "base_damage": 10.0,
        "scaling_attribute": -1, "power_coefficient": 0.0,
        "scale_with_level": False, "damage_type": "physical", "critical": False,
        "application_chance": 100.0, "periodic": False,
        "duration": 0.0, "period": 0.0, "execute_on_application": False,
        "reapplication": "refresh", "maximum_stacks": 1,
        "damage_tags": [], "required_target_tags": [], "blocked_target_tags": [],
    }
    value.update(changes)
    return value


def ability(**changes):
    value = {
        "id": "attack", "name": "Attack", "kind": "melee",
        "tags": ["Ability.Attack.Melee"], "base_duration": 1.0,
        "minimum_duration": 1.0, "release_fraction": 0.25, "travel_time": 0.0,
        "cooldown": 0.0, "cost_attribute": -1, "cost_amount": 0.0,
        "effects": [effect()],
    }
    value.update(changes)
    return value


def session(*, player=None, enemy=None, attack=None, trials=1, horizon=20.0, seed=493):
    value = copy.deepcopy(model.default_session())
    value["players"] = [player if player is not None else actor(
        HIT_RATING=50, CRITICAL_CHANCE=0, STAMINA_REGEN=0, MANA_REGEN=0)]
    value["enemies"] = [enemy if enemy is not None else actor(
        "enemy", MAX_HEALTH=25, ARMOR=0, EVASION=0, BLOCK_CHANCE=0)]
    value["abilities"] = [attack if attack is not None else ability()]
    value["matrix"] = {"player_ids": [], "enemy_ids": [], "ability_ids": [],
                       "player_levels": [], "enemy_levels": [], "sweeps": []}
    value["run"] = {"trials": trials, "horizon": horizon, "seed": seed,
                    "batch_size": 256, "workers": 1}
    return value


def first_cell(settings):
    return model.build_matrix(settings)[0]
