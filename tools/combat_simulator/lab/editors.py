# Editable actor, ability, and matrix forms for the combat lab.
from __future__ import annotations

import copy
import math
import tkinter as tk
from tkinter import ttk
import uuid

from . import model


def number(text, label, integer=False):
    try:
        value = float(text)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label}: enter a number.") from exc
    if not math.isfinite(value) or (integer and not value.is_integer()):
        raise ValueError(f"{label}: enter a finite {'whole number' if integer else 'number'}.")
    return int(value) if integer else value


def number_list(text, label, integer=False):
    values = []
    for token in text.replace(";", ",").split(","):
        if not token.strip():
            continue
        value = number(token.strip(), label, integer)
        if value not in values:
            values.append(value)
    return values


def tags(text):
    return list(dict.fromkeys(item.strip() for item in text.split(",") if item.strip()))


def format_number(value):
    if value is None:
        return "—"
    return f"{float(value):,.4g}"


def wrap_to_width(label, container, margin=16):
    container.bind("<Configure>", lambda event: label.configure(wraplength=max(180, event.width - margin)), add=True)


class ScrollForm(ttk.Frame):
    def __init__(self, master):
        super().__init__(master)
        self.canvas = tk.Canvas(self, borderwidth=0, highlightthickness=0)
        self.scroll = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=self.scroll.set)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        self.scroll.grid(row=0, column=1, sticky="ns")
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)
        self.body = ttk.Frame(self.canvas, padding=8)
        self.window = self.canvas.create_window((0, 0), anchor="nw", window=self.body)
        self.body.bind("<Configure>", self._content_changed)
        self.canvas.bind("<Configure>", self._resized)
        self.bind("<MouseWheel>", self._wheel)
        self.body.bind("<MouseWheel>", self._wheel)

    def _content_changed(self, _event=None):
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _resized(self, event):
        self.canvas.itemconfigure(self.window, width=event.width)

    def _wheel(self, event):
        self.canvas.yview_scroll(-int(event.delta / 120), "units")
        return "break"

    def bind_wheel(self, widget):
        widget.bind("<MouseWheel>", self._wheel, add=True)


class ActorEditor(ttk.Frame):
    def __init__(self, master, on_change=None):
        super().__init__(master, padding=8)
        self.on_change = on_change
        self.actor = None
        self.rules = {}
        self.loading = False
        self.rows = {}
        self.catalogue = model.attribute_catalogue()
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)
        header = ttk.Frame(self)
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(1, weight=1)
        ttk.Label(header, text="Name").grid(row=0, column=0, padx=(0, 6))
        self.name = tk.StringVar()
        ttk.Entry(header, textvariable=self.name).grid(row=0, column=1, sticky="ew")
        ttk.Label(header, text="Level").grid(row=0, column=2, padx=(14, 6))
        self.level = tk.StringVar(value="1")
        ttk.Entry(header, textvariable=self.level, width=7).grid(row=0, column=3)
        self.summary = ttk.Label(self, text="Select an actor.", wraplength=750)
        self.summary.grid(row=1, column=0, sticky="w", pady=8)
        help_label = ttk.Label(self, text="Auto uses the actor's saved modifiers and derived stats. Enable Set to replace a base value.")
        help_label.grid(row=2, column=0, sticky="w", pady=(0, 5))
        wrap_to_width(help_label, self)
        wrap_to_width(self.summary, self)
        tabs = ttk.Notebook(self)
        tabs.grid(row=3, column=0, sticky="nsew")
        attrs = ttk.Frame(tabs)
        attrs.columnconfigure(0, weight=1)
        attrs.rowconfigure(1, weight=1)
        tabs.add(attrs, text="All attributes")
        search_bar = ttk.Frame(attrs, padding=(4, 5))
        search_bar.grid(row=0, column=0, sticky="ew")
        ttk.Label(search_bar, text="Filter").pack(side="left", padx=(0, 8))
        self.search = tk.StringVar()
        ttk.Entry(search_bar, textvariable=self.search).pack(side="left", fill="x", expand=True)
        ttk.Button(search_bar, text="Clear overrides", command=self.clear_overrides).pack(side="right", padx=6)
        self.scroll = ScrollForm(attrs)
        self.scroll.grid(row=1, column=0, sticky="nsew")
        body = self.scroll.body
        body.columnconfigure(1, weight=1)
        for col, heading in enumerate(("Set", "Attribute", "Base / starting pool", "Effective")):
            ttk.Label(body, text=heading, style="Heading.TLabel").grid(row=0, column=col, sticky="w", padx=6, pady=5)
        for index, attr in enumerate(self.catalogue, 1):
            attr_id = int(attr["id"])
            enabled = tk.BooleanVar()
            raw = tk.StringVar()
            effective = tk.StringVar(value="—")
            checkbox = ttk.Checkbutton(body, variable=enabled, command=self._changed)
            label = ttk.Label(body, text=attr["name"])
            entry = ttk.Entry(body, textvariable=raw, width=17)
            result = ttk.Label(body, textvariable=effective, width=18, anchor="e")
            controls = (checkbox, label, entry, result)
            for col, control in enumerate(controls):
                control.grid(row=index, column=col, sticky="ew" if col == 1 else "w", padx=6, pady=3)
                self.scroll.bind_wheel(control)
            self.rows[attr_id] = (enabled, raw, effective, entry, controls)
            raw.trace_add("write", lambda *_: self._changed())
        advanced = ttk.Frame(tabs, padding=8)
        advanced.columnconfigure(1, weight=1)
        advanced.rowconfigure(8, weight=1)
        tabs.add(advanced, text="Saved modifiers / tags")
        ttk.Label(advanced, text="Saved primary allocations (in addition to base 10)") \
            .grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 8))
        self.allocations = {}
        for index, key in enumerate(("strength", "dexterity", "intellect", "vitality"), 1):
            ttk.Label(advanced, text=key.capitalize()).grid(row=index, column=0, sticky="w", pady=3)
            value = tk.StringVar(value="0")
            ttk.Entry(advanced, textvariable=value, width=12).grid(row=index, column=1, sticky="w", pady=3)
            value.trace_add("write", lambda *_: self._changed())
            self.allocations[key] = value
        ttk.Label(advanced, text="Actor tags (comma separated)").grid(row=5, column=0, sticky="w", pady=6)
        self.actor_tags = tk.StringVar()
        ttk.Entry(advanced, textvariable=self.actor_tags).grid(row=5, column=1, sticky="ew", pady=6)
        regen_controls = ttk.Frame(advanced)
        regen_controls.grid(row=6, column=0, columnspan=2, sticky="w", pady=4)
        self.auto_regen = tk.BooleanVar(value=True)
        self.pause_stamina = tk.BooleanVar(value=False)
        ttk.Checkbutton(regen_controls, text="Automatic regeneration", variable=self.auto_regen, command=self._changed).pack(side="left")
        ttk.Checkbutton(regen_controls, text="Pause Stamina regeneration", variable=self.pause_stamina, command=self._changed).pack(side="left", padx=12)
        ttk.Label(advanced, text="Modifiers as JSON. Imported gear/talent and scoped bonuses are preserved here.") \
            .grid(row=7, column=0, columnspan=2, sticky="w", pady=5)
        self.modifiers = tk.Text(advanced, height=10, wrap="none", undo=True)
        self.modifiers.grid(row=8, column=0, columnspan=2, sticky="nsew")
        self.modifiers.bind("<FocusOut>", lambda _: self._changed())
        self.modifiers.bind("<Control-Return>", lambda _: self._changed())
        self.modifiers.bind("<<Modified>>", self._modifiers_changed)
        for var in (self.name, self.level, self.actor_tags):
            var.trace_add("write", lambda *_: self._changed())
        self.search.trace_add("write", lambda *_: self._filter())

    def set_data(self, actor, rules):
        import json
        self.loading = True
        self.actor = copy.deepcopy(actor)
        self.rules = rules
        self.name.set(actor["name"])
        self.level.set(str(actor["level"]))
        self.actor_tags.set(", ".join(actor.get("tags", [])))
        self.auto_regen.set(actor.get("automatic_regeneration", True))
        self.pause_stamina.set(actor.get("pause_stamina_regeneration", False))
        for key, value in self.allocations.items():
            value.set(str(actor.get("allocations", {}).get(key, 0)))
        self.modifiers.delete("1.0", "end")
        self.modifiers.insert("1.0", json.dumps(actor.get("modifiers", []), indent=2))
        self.modifiers.edit_modified(False)
        base = actor.get("base_values", {})
        values = model.resolve_actor_bases(actor, rules)
        for attr_id, (enabled, raw, _effective, _entry, _controls) in self.rows.items():
            manual = str(attr_id) in base or attr_id in base
            enabled.set(manual)
            raw.set(str(base.get(str(attr_id), base.get(attr_id, values.get(attr_id, 0)))))
        self.loading = False
        self.refresh_values()

    def get_data(self):
        import json
        if self.actor is None:
            raise ValueError("Select an actor first.")
        result = copy.deepcopy(self.actor)
        result["name"] = self.name.get().strip()
        result["level"] = number(self.level.get(), "Actor level", True)
        result["tags"] = tags(self.actor_tags.get())
        result["automatic_regeneration"] = self.auto_regen.get()
        result["pause_stamina_regeneration"] = self.pause_stamina.get()
        result["allocations"] = {key: number(value.get(), key.capitalize() + " allocation", True)
                                 for key, value in self.allocations.items()}
        result["base_values"] = {str(attr_id): number(raw.get(), f"Attribute {attr_id}")
                                 for attr_id, (enabled, raw, *_rest) in self.rows.items() if enabled.get()}
        try:
            result["modifiers"] = json.loads(self.modifiers.get("1.0", "end").strip() or "[]")
        except json.JSONDecodeError as exc:
            raise ValueError(f"Modifiers JSON: {exc.msg}, line {exc.lineno}.") from exc
        model.validate_actor(result, self.rules)
        return result

    def refresh_values(self, rules=None):
        if rules is not None:
            self.rules = rules
        if self.actor is None:
            return
        try:
            actor = self.get_data()
            values = model.resolve_actor(actor, self.rules)
        except (ValueError, TypeError, KeyError) as exc:
            self.summary.configure(text=f"Finish editing: {exc}")
            return
        for attr_id, (enabled, _raw, effective, entry, _controls) in self.rows.items():
            entry.configure(state="normal" if enabled.get() else "disabled")
            effective.set(format_number(values.get(attr_id)))
        by_key = {attr["key"].lower(): int(attr["id"]) for attr in self.catalogue}
        def val(key):
            return format_number(values.get(by_key[key]))
        self.summary.configure(text=f"Health {val('health')} / {val('max_health')}   ·   "
                               f"Mana {val('mana')} / {val('max_mana')}   ·   "
                               f"Stamina {val('stamina')} / {val('max_stamina')}\n"
                               "Effective values below use no ability-specific tag filter. Defensive/control stats do not change outgoing TTK unless used by the target.")

    def clear_overrides(self):
        for enabled, *_rest in self.rows.values():
            enabled.set(False)
        self._changed()

    def _filter(self):
        query = self.search.get().strip().casefold()
        for attr in self.catalogue:
            controls = self.rows[int(attr["id"])][4]
            for control in controls:
                if query and query not in attr["name"].casefold():
                    control.grid_remove()
                else:
                    control.grid()

    def _modifiers_changed(self, _event=None):
        if self.modifiers.edit_modified():
            self.modifiers.edit_modified(False)
            self._changed()

    def _changed(self):
        if not self.loading:
            self.refresh_values()
            if self.on_change:
                self.on_change()


class EffectEditor(ScrollForm):
    def __init__(self, master, on_change=None):
        super().__init__(master)
        self.on_change = on_change
        self.effect = None
        self.loading = False
        self.variables = {}
        self.catalogue = model.attribute_catalogue()
        self.power_choices = {"Automatic by damage school": -1, "Magic Power": model.attribute_ids()["MAGIC_POWER"]}
        self.body.columnconfigure(1, weight=1)
        specifications = [
            ("name", "Effect name", "text"),
            ("base_damage", "Base damage per hit / tick", "number"),
            ("damage_type", "Damage school", ("physical", "fire", "cold", "lightning", "necrotic", "void")),
            ("scaling_attribute", "School-based power", tuple(self.power_choices)),
            ("power_coefficient", "Magic damage per Magic Power (Physical ignores this)", "number"),
            ("application_chance", "Application chance (%) after delivery", "number"),
            ("critical", "Can critically strike", "bool"),
            ("scale_with_level", "Scale base damage with character level", "bool"),
            ("periodic", "Periodic damage", "bool"),
            ("duration", "Duration (seconds)", "number"),
            ("period", "Tick interval (seconds)", "number"),
            ("execute_on_application", "Also tick immediately on new application", "bool"),
            ("reapplication", "Reapplying this effect", ("refresh", "replace", "stack")),
            ("maximum_stacks", "Maximum stacks (0 = unlimited)", "integer"),
            ("damage_tags", "Additional damage tags (comma separated)", "tags"),
            ("required_target_tags", "Required target tags", "tags"),
            ("blocked_target_tags", "Blocked target tags / immunities", "tags"),
        ]
        for index, (key, label, kind) in enumerate(specifications):
            ttk.Label(self.body, text=label).grid(row=index, column=0, sticky="w", padx=(0, 12), pady=5)
            if kind == "bool":
                variable = tk.BooleanVar()
                control = ttk.Checkbutton(self.body, variable=variable, command=self._changed)
            else:
                variable = tk.StringVar()
                if isinstance(kind, tuple):
                    control = ttk.Combobox(self.body, textvariable=variable, values=kind, state="readonly")
                else:
                    control = ttk.Entry(self.body, textvariable=variable)
                variable.trace_add("write", lambda *_: self._changed())
            control.grid(row=index, column=1, sticky="ew", pady=5)
            self.bind_wheel(control)
            self.variables[key] = (variable, kind)
        note = ttk.Label(self.body, text="Physical damage uses Strength; magical damage uses Magic Power and its coefficient.\nDirect Hits automatically attempt school ailments; critical Hits guarantee them. Attack and Spell share Hit Rating.\nRefresh preserves the snapshot and next tick. Replace starts a new schedule.", wraplength=500)
        note.grid(row=len(specifications), column=0, columnspan=2, sticky="w", pady=12)
        wrap_to_width(note, self.body)

    def set_data(self, effect):
        self.loading = True
        self.effect = copy.deepcopy(effect)
        for key, (variable, kind) in self.variables.items():
            value = effect.get(key, False if kind == "bool" else "")
            if key == "scaling_attribute":
                value = next((name for name, attr_id in self.power_choices.items() if attr_id == value), "Automatic by damage school")
            elif kind == "tags":
                value = ", ".join(value)
            variable.set(value)
        self.loading = False

    def get_data(self):
        if self.effect is None:
            raise ValueError("Select an effect.")
        result = copy.deepcopy(self.effect)
        for key, (variable, kind) in self.variables.items():
            value = variable.get()
            if key == "scaling_attribute":
                value = self.power_choices.get(value, -1)
            elif kind in ("number", "integer"):
                value = number(value, key.replace("_", " ").capitalize(), kind == "integer")
            elif kind == "tags":
                value = tags(value)
            result[key] = value
        return result

    def _changed(self):
        if not self.loading and self.on_change:
            self.on_change()


def new_effect(periodic=False):
    return {
        "id": "effect_" + uuid.uuid4().hex[:10], "name": "Damage over time" if periodic else "Direct hit",
        "base_damage": 8.0 if periodic else 60.0, "scaling_attribute": -1, "power_coefficient": 0.0,
        "scale_with_level": False, "damage_type": "physical", "critical": not periodic,
        "application_chance": 100.0, "periodic": periodic, "duration": 10.0 if periodic else 0.0,
        "period": 2.0 if periodic else 0.0, "execute_on_application": False,
        "reapplication": "refresh", "maximum_stacks": 1, "damage_tags": [],
        "required_target_tags": [], "blocked_target_tags": ["State.Dead"],
    }


class AbilityEditor(ttk.Frame):
    def __init__(self, master, on_change=None):
        super().__init__(master, padding=8)
        self.on_change = on_change
        self.ability = None
        self.loading = False
        self.effect_index = None
        self.variables = {}
        self.rowconfigure(1, weight=1)
        self.columnconfigure(0, weight=1)
        general = ttk.LabelFrame(self, text="Repeated action", padding=8)
        general.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        catalogue = model.attribute_catalogue()
        self.resources = {"None": -1, **{a["name"]: int(a["id"]) for a in catalogue
                                       if a["key"].lower() in ("health", "stamina", "mana")}}
        specifications = [
            ("name", "Ability name", "text"), ("kind", "Delivery type", ("spell", "melee")),
            ("base_duration", "Base action duration (s)", "number"),
            ("minimum_duration", "Minimum action duration (s)", "number"),
            ("release_fraction", "Delivery point in action (0–1)", "number"),
            ("travel_time", "Travel time after delivery (s)", "number"),
            ("cooldown", "Base cooldown (s)", "number"),
            ("cost_attribute", "Resource cost uses", tuple(self.resources)),
            ("cost_amount", "Base resource cost", "number"),
            ("tags", "Ability tags (comma separated)", "tags"),
            ("required_tags", "Required source tags", "tags"),
            ("blocked_tags", "Blocked source tags", "tags"),
            ("dodgeable", "Can be dodged", "bool"),
            ("blockable", "Can be blocked", "bool"),
        ]
        for index, (key, label, kind) in enumerate(specifications):
            row, pair = divmod(index, 2)
            column = pair * 2
            ttk.Label(general, text=label).grid(row=row, column=column, sticky="w", padx=(0, 8), pady=3)
            variable = tk.BooleanVar(value=True) if kind == "bool" else tk.StringVar()
            if kind == "bool":
                control = ttk.Checkbutton(general, variable=variable)
            elif isinstance(kind, tuple):
                control = ttk.Combobox(general, textvariable=variable, values=kind, state="readonly", width=19)
            else:
                control = ttk.Entry(general, textvariable=variable, width=20)
            control.grid(row=row, column=column + 1, sticky="ew", padx=(0, 16), pady=3)
            general.columnconfigure(column + 1, weight=1)
            variable.trace_add("write", lambda *_: self._changed())
            self.variables[key] = (variable, kind)
        split = ttk.Panedwindow(self, orient="horizontal")
        split.grid(row=1, column=0, sticky="nsew")
        sidebar = ttk.Frame(split, padding=(0, 0, 8, 0))
        sidebar.rowconfigure(1, weight=1)
        sidebar.columnconfigure(0, weight=1)
        ttk.Label(sidebar, text="On-hit effects", style="Heading.TLabel").grid(row=0, column=0, sticky="w", pady=5)
        self.effects_list = tk.Listbox(sidebar, width=22, exportselection=False, activestyle="dotbox")
        self.effects_list.grid(row=1, column=0, sticky="nsew")
        self.effects_list.bind("<<ListboxSelect>>", self._select_effect)
        for index, (label, command) in enumerate([
                ("Add direct damage", lambda: self._add_effect(False)),
                ("Add periodic damage", lambda: self._add_effect(True)),
                ("Duplicate effect", self._duplicate_effect), ("Remove effect", self._remove_effect)], 2):
            ttk.Button(sidebar, text=label, command=command).grid(row=index, column=0, sticky="ew", pady=3)
        split.add(sidebar, weight=1)
        self.effect_editor = EffectEditor(split, self._effect_changed)
        split.add(self.effect_editor, weight=4)
        note = ttk.Label(self, text="One successful delivery qualifies its complete effect list. Effects still have their own application chance and immunity requirements.", wraplength=700)
        note.grid(row=2, column=0, sticky="w", pady=(7, 0))
        wrap_to_width(note, self)

    def set_data(self, ability):
        self.loading = True
        self.ability = copy.deepcopy(ability)
        for key, (variable, kind) in self.variables.items():
            value = ability.get(key, True if kind == "bool" else "")
            if key == "cost_attribute":
                value = next((name for name, attr_id in self.resources.items() if attr_id == value), "None")
            elif kind == "tags":
                value = ", ".join(value)
            variable.set(value)
        self.effect_index = None
        self._refresh_effect_list()
        if self.ability.get("effects"):
            self.effect_index = 0
            self.effects_list.selection_set(0)
            self.effect_editor.set_data(self.ability["effects"][0])
        else:
            self.effect_editor.effect = None
        self.loading = False

    def get_data(self):
        if self.ability is None:
            raise ValueError("Select an ability.")
        self._save_effect()
        result = copy.deepcopy(self.ability)
        for key, (variable, kind) in self.variables.items():
            value = variable.get()
            if key == "cost_attribute":
                value = self.resources.get(value, -1)
            elif kind == "number":
                value = number(value, key.replace("_", " ").capitalize())
            elif kind == "tags":
                value = tags(value)
            result[key] = value
        # Delivery classification and its contextual modifiers must agree.
        opposite = ("Ability.Attack", "Ability.Melee") if result["kind"] == "spell" else ("Ability.Spell",)
        result["tags"] = [tag for tag in result["tags"]
                          if not any(tag == parent or tag.startswith(parent + ".") for parent in opposite)]
        for tag in (["Ability.Spell"] if result["kind"] == "spell" else ["Ability.Attack", "Ability.Melee"]):
            if tag not in result["tags"]:
                result["tags"].append(tag)
        result["delivery"] = "projectile" if result["kind"] == "spell" else "melee_trace"
        return result

    def _refresh_effect_list(self):
        self.effects_list.delete(0, "end")
        for effect in self.ability.get("effects", []):
            self.effects_list.insert("end", ("DoT · " if effect.get("periodic") else "Hit · ") + effect["name"])

    def _save_effect(self):
        if self.effect_index is not None and self.effect_editor.effect is not None:
            self.ability["effects"][self.effect_index] = self.effect_editor.get_data()

    def _select_effect(self, _event=None):
        selection = self.effects_list.curselection()
        if not selection or self.loading:
            return
        new_index = selection[0]
        try:
            self._save_effect()
        except ValueError:
            if self.effect_index is not None:
                self.effects_list.selection_clear(0, "end")
                self.effects_list.selection_set(self.effect_index)
            return
        self.effect_index = new_index
        self.effect_editor.set_data(self.ability["effects"][new_index])

    def _add_effect(self, periodic):
        if self.ability is None:
            return
        try:
            self._save_effect()
        except ValueError:
            return
        self.ability.setdefault("effects", []).append(new_effect(periodic))
        self.effect_index = len(self.ability["effects"]) - 1
        self._refresh_effect_list()
        self.effects_list.selection_set(self.effect_index)
        self.effect_editor.set_data(self.ability["effects"][self.effect_index])
        self._changed()

    def _duplicate_effect(self):
        if self.effect_index is None:
            return
        try:
            self._save_effect()
        except ValueError:
            return
        clone = copy.deepcopy(self.ability["effects"][self.effect_index])
        clone["id"] = "effect_" + uuid.uuid4().hex[:10]
        clone["name"] += " copy"
        self.ability["effects"].append(clone)
        self.effect_index = len(self.ability["effects"]) - 1
        self._refresh_effect_list()
        self.effects_list.selection_set(self.effect_index)
        self.effect_editor.set_data(clone)
        self._changed()

    def _remove_effect(self):
        if self.effect_index is None:
            return
        del self.ability["effects"][self.effect_index]
        self.effect_index = None
        self._refresh_effect_list()
        if self.ability["effects"]:
            self.effect_index = 0
            self.effects_list.selection_set(0)
            self.effect_editor.set_data(self.ability["effects"][0])
        else:
            self.effect_editor.effect = None
        self._changed()

    def _effect_changed(self):
        if not self.loading:
            try:
                self._save_effect()
            except ValueError:
                pass
            self._changed()

    def _changed(self):
        if not self.loading and self.on_change:
            self.on_change()


class MatrixEditor(ttk.Frame):
    def __init__(self, master, on_change=None):
        super().__init__(master, padding=12)
        self.on_change = on_change
        self.loading = False
        self.ids = {}
        self.columnconfigure((0, 1, 2), weight=1)
        self.rowconfigure(1, weight=1)
        note = ttk.Label(self, text="Choose the profiles to cross. Each combination is a separate matchup, with X independent trials.", wraplength=850)
        note.grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 10))
        wrap_to_width(note, self)
        self.lists = {}
        for column, (key, heading) in enumerate((("player_ids", "Players"), ("enemy_ids", "Enemies"),
                                                ("ability_ids", "Abilities"))):
            group = ttk.LabelFrame(self, text=heading, padding=8)
            group.grid(row=1, column=column, sticky="nsew", padx=(0, 10))
            group.columnconfigure(0, weight=1)
            group.rowconfigure(0, weight=1)
            box = tk.Listbox(group, selectmode="extended", exportselection=False, height=8)
            box.grid(row=0, column=0, sticky="nsew")
            scrollbar = ttk.Scrollbar(group, orient="vertical", command=box.yview)
            scrollbar.grid(row=0, column=1, sticky="ns")
            box.configure(yscrollcommand=scrollbar.set)
            ttk.Button(group, text="Select all", command=lambda b=box: self._select_all(b)) \
                .grid(row=1, column=0, columnspan=2, sticky="ew", pady=(6, 0))
            box.bind("<<ListboxSelect>>", lambda _: self._changed())
            self.lists[key] = box
        levels = ttk.LabelFrame(self, text="Optional level matrix", padding=10)
        levels.grid(row=2, column=0, columnspan=3, sticky="ew", pady=10)
        levels.columnconfigure((1, 3), weight=1)
        self.player_levels = tk.StringVar()
        self.enemy_levels = tk.StringVar()
        ttk.Label(levels, text="Player levels").grid(row=0, column=0, padx=(0, 8))
        ttk.Entry(levels, textvariable=self.player_levels).grid(row=0, column=1, sticky="ew")
        ttk.Label(levels, text="Enemy levels").grid(row=0, column=2, padx=(16, 8))
        ttk.Entry(levels, textvariable=self.enemy_levels).grid(row=0, column=3, sticky="ew")
        ttk.Label(levels, text="Comma separated, e.g. 10, 12, 15. Leave blank to use each profile's own level.") \
            .grid(row=1, column=0, columnspan=4, sticky="w", pady=(6, 0))
        sweeps = ttk.LabelFrame(self, text="Optional attribute variations", padding=10)
        sweeps.grid(row=3, column=0, columnspan=3, sticky="ew")
        sweeps.columnconfigure(2, weight=1)
        self.attribute_choices = {"No variation": None, **{a["name"]: int(a["id"]) for a in model.attribute_catalogue()}}
        self.sweeps = []
        for index in range(2):
            side = tk.StringVar(value="enemy")
            attribute = tk.StringVar(value="No variation")
            values = tk.StringVar()
            ttk.Combobox(sweeps, textvariable=side, values=("player", "enemy"), state="readonly", width=12) \
                .grid(row=index, column=0, padx=(0, 8), pady=4)
            ttk.Combobox(sweeps, textvariable=attribute, values=tuple(self.attribute_choices), state="readonly", width=29) \
                .grid(row=index, column=1, padx=(0, 8), pady=4)
            ttk.Entry(sweeps, textvariable=values).grid(row=index, column=2, sticky="ew", pady=4)
            self.sweeps.append((side, attribute, values))
            for variable in (side, attribute, values):
                variable.trace_add("write", lambda *_: self._changed())
        ttk.Label(sweeps, text="Example: enemy Armor = 0, 250, 500, 1000. Both variations are crossed with every selected profile and level.") \
            .grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 0))
        self.preview = ttk.Label(self, text="", style="Heading.TLabel", wraplength=1100)
        self.preview.grid(row=4, column=0, columnspan=3, sticky="w", pady=12)
        wrap_to_width(self.preview, self)
        for variable in (self.player_levels, self.enemy_levels):
            variable.trace_add("write", lambda *_: self._changed())

    def set_data(self, session):
        self.loading = True
        matrix = session.get("matrix", {})
        selections = {key: matrix.get(key, []) or [profile["id"] for profile in session[source]]
                      for key, source in (("player_ids", "players"), ("enemy_ids", "enemies"), ("ability_ids", "abilities"))}
        self.refresh_profiles(session, selections)
        self.player_levels.set(", ".join(str(v) for v in matrix.get("player_levels", [])))
        self.enemy_levels.set(", ".join(str(v) for v in matrix.get("enemy_levels", [])))
        for index, (side, attribute, values) in enumerate(self.sweeps):
            existing = matrix.get("sweeps", [])
            if index < len(existing):
                row = existing[index]
                side.set(row["side"])
                attribute.set(next((name for name, attr_id in self.attribute_choices.items()
                                    if attr_id == row["attribute"]), "No variation"))
                values.set(", ".join(str(v) for v in row["values"]))
            else:
                side.set("enemy")
                attribute.set("No variation")
                values.set("")
        self.loading = False

    def refresh_profiles(self, session, selections=None):
        # Refresh names/IDs without replacing unfinished level and sweep edits.
        if selections is None:
            selections = {key: [self.ids.get(key, [])[index] for index in box.curselection()]
                          for key, box in self.lists.items()}
        was_loading = self.loading
        self.loading = True
        for key, source in (("player_ids", "players"), ("enemy_ids", "enemies"), ("ability_ids", "abilities")):
            box = self.lists[key]
            box.delete(0, "end")
            self.ids[key] = []
            selected = selections.get(key, [])
            for index, profile in enumerate(session[source]):
                self.ids[key].append(profile["id"])
                suffix = f" · level {profile['level']}" if source != "abilities" else f" · {profile['kind']}"
                box.insert("end", profile["name"] + suffix)
                if profile["id"] in selected:
                    box.selection_set(index)
        self.loading = was_loading

    def get_data(self):
        result = {key: [self.ids[key][index] for index in box.curselection()] for key, box in self.lists.items()}
        if any(not selection for selection in result.values()):
            raise ValueError("Select at least one player, enemy, and ability in Matrix.")
        result["player_levels"] = number_list(self.player_levels.get(), "Player level matrix", True)
        result["enemy_levels"] = number_list(self.enemy_levels.get(), "Enemy level matrix", True)
        result["sweeps"] = []
        for side, attribute, values in self.sweeps:
            attr_id = self.attribute_choices[attribute.get()]
            if attr_id is not None:
                parsed = number_list(values.get(), "Attribute variation")
                if not parsed:
                    raise ValueError(f"Enter at least one value for the {attribute.get()} variation.")
                result["sweeps"].append({"side": side.get(), "attribute": attr_id, "values": parsed})
        return result

    def _select_all(self, box):
        box.selection_set(0, "end")
        self._changed()

    def _changed(self):
        if not self.loading and self.on_change:
            self.on_change()
