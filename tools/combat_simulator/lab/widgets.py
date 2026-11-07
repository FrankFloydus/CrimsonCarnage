"""Native Tk presentation for editable experiment rules and encounter results.

Importing this module creates no windows. Widgets are constructed only by the lab app.
"""
from __future__ import annotations

import copy
import json
import math
import tkinter as tk
from tkinter import ttk

import numpy as np

from .. import simulator as sim


def finite_number(text, name="Value"):
    """Parse an editable number without accepting NaN or infinity."""
    if isinstance(text, bool):
        raise ValueError(f"{name} must be a number, not a boolean.")
    try:
        result = float(text)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a number.") from exc
    if not math.isfinite(result):
        raise ValueError(f"{name} must be finite.")
    return result


def validated_curve(values, name="Accuracy"):
    """Validate session-only probability points without forcing monotonicity."""
    if not isinstance(values, (list, tuple)) or not 1 <= len(values) <= 60:
        raise ValueError(f"{name} needs between 1 and 60 points.")
    result = [finite_number(value, f"{name}, gap +{index}") for index, value in enumerate(values)]
    if any(value < 0 or value > 1 for value in result):
        raise ValueError(f"{name} points must be between 0% and 100%.")
    return result


def format_result_value(value, kind="number"):
    """Format measured values while retaining explicit missing kill-time values."""
    if value is None:
        return "—"
    if kind == "variants":
        if isinstance(value, dict):
            return ", ".join(f"{key}={item}" for key, item in value.items()) or "Default"
        if isinstance(value, (list, tuple)):
            return ", ".join(map(str, value)) or "Default"
        return str(value) if value else "Default"
    if kind == "text":
        return str(value)
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return str(value)
    if not math.isfinite(numeric):
        return "—"
    if kind == "integer":
        return f"{int(numeric):,}"
    if kind == "percent":
        return f"{numeric * 100:.2f}%"
    if kind == "seconds":
        return f"{numeric:,.3f}s"
    return f"{numeric:,.2f}"


def histogram_bins(histogram):
    """Return valid (start, end, count) bins, excluding malformed external data."""
    if not isinstance(histogram, dict):
        return []
    edges, counts = histogram.get("edges", []), histogram.get("counts", [])
    if not isinstance(edges, (list, tuple, np.ndarray)) or not isinstance(counts, (list, tuple, np.ndarray)):
        return []
    if len(edges) != len(counts) + 1:
        return []
    try:
        numeric_counts = [float(count) for count in counts]
        if any(not math.isfinite(count) or not count.is_integer() for count in numeric_counts):
            return []
        bins = [(float(edges[i]), float(edges[i + 1]), int(count)) for i, count in enumerate(numeric_counts)]
    except (ValueError, TypeError, OverflowError):
        return []
    if any(not math.isfinite(a) or not math.isfinite(b) or b <= a or count < 0
           for a, b, count in bins):
        return []
    return bins


def result_page(positions, page, page_size=200):
    """Return a bounded page, its clamped index, and the number of available pages."""
    if page_size < 1:
        raise ValueError("Page size must be positive.")
    pages = max(1, math.ceil(len(positions) / page_size))
    selected_page = min(max(0, int(page)), pages - 1)
    start = selected_page * page_size
    return positions[start:start + page_size], selected_page, pages


class ResultCatalogue:
    """Window-free row storage with indexed updates and cached presentation data.

    Upserts touch only one row and its aggregate counts. Filtering and sorting are
    explicit user operations; receiving another progress cell never repeats them.
    """

    def __init__(self, columns=()):
        self.columns = tuple(columns)
        self.clear()

    def clear(self):
        self.rows = []
        self._index_positions = {}
        self._formatted = []
        self._search = []
        self.totals = {key: 0 for key in ("trials", "kills", "timeouts")}

    def upsert(self, row):
        if not isinstance(row, dict):
            raise ValueError("A result row must be a dictionary.")
        copied = copy.deepcopy(row)
        identity = copied.get("index")
        try:
            position = self._index_positions.get(identity) if identity is not None else None
        except TypeError as exc:
            raise ValueError("A result index must be a scalar.") from exc
        is_new = position is None
        old = {} if is_new else self.rows[position]
        formatted = tuple(format_result_value(copied.get(key), kind)
                          for key, _title, _width, kind in self.columns)
        search = (" ".join(formatted) if self.columns else json.dumps(copied, default=str)).casefold()
        deltas = {key: int(copied.get(key, 0)) - int(old.get(key, 0)) for key in self.totals}
        for key, delta in deltas.items():
            self.totals[key] += delta
        if is_new:
            position = len(self.rows)
            if identity is not None:
                self._index_positions[identity] = position
            self.rows.append(copied)
            self._formatted.append(formatted)
            self._search.append(search)
        else:
            self.rows[position] = copied
            self._formatted[position] = formatted
            self._search[position] = search
        return position, is_new

    def formatted(self, position):
        return self._formatted[position]

    def matches(self, position, query):
        return not query or query in self._search[position]

    def matching_positions(self, query=""):
        query = query.strip().casefold()
        return [position for position in range(len(self.rows)) if self.matches(position, query)]

    def sorted_positions(self, positions, column, descending=False):
        present, missing = [], []
        for position in positions:
            (missing if self.rows[position].get(column) is None else present).append(position)
        def sort_key(position):
            value = self.rows[position][column]
            if isinstance(value, (float, int)) and not isinstance(value, bool):
                return (0, value)
            return (1, format_result_value(value, "variants").casefold())
        present.sort(key=sort_key, reverse=descending)
        return present + missing

    def export_rows(self):
        return copy.deepcopy(self.rows)


class _ScrollFrame(ttk.Frame):
    def __init__(self, master):
        super().__init__(master)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)
        self.canvas = tk.Canvas(self, borderwidth=0, highlightthickness=0, background="#f4f5f7")
        self.canvas.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.canvas.configure(yscrollcommand=scroll.set)
        self.body = ttk.Frame(self.canvas, padding=5)
        self._window = self.canvas.create_window((0, 0), window=self.body, anchor="nw")
        self.body.bind("<Configure>", lambda _event: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas.bind("<Configure>", lambda event: self.canvas.itemconfigure(self._window, width=event.width))
        self.bind_wheel(self.canvas)

    def bind_wheel(self, widget):
        widget.bind("<MouseWheel>", self._wheel, add="+")
        widget.bind("<Button-4>", lambda _event: self._scroll(-1), add="+")
        widget.bind("<Button-5>", lambda _event: self._scroll(1), add="+")

    def _scroll(self, units):
        self.canvas.yview_scroll(units, "units")
        return "break"

    def _wheel(self, event):
        return self._scroll(-1 if event.delta > 0 else 1)


class _AccuracyCurveEditor(ttk.Frame):
    def __init__(self, master, title, on_change, show_resist=False):
        super().__init__(master, padding=6)
        self._on_change = on_change
        self._show_resist = show_resist
        self._variables = []
        self._resist_labels = []
        self._points = []
        self._drag_index = None
        self._selected = 0
        self._loading = False
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)
        toolbar = ttk.Frame(self)
        toolbar.grid(row=0, column=0, sticky="ew", pady=(0, 5))
        ttk.Label(toolbar, text=title).pack(side="left")
        self._remove = ttk.Button(toolbar, text="Remove last gap", command=self._remove_point)
        self._remove.pack(side="right", padx=(5, 0))
        self._add = ttk.Button(toolbar, text="Add gap", command=self._add_point)
        self._add.pack(side="right")
        panes = ttk.Panedwindow(self, orient="horizontal")
        panes.grid(row=1, column=0, sticky="nsew")
        self.canvas = tk.Canvas(panes, background="#fafbfc", highlightthickness=1,
                                highlightbackground="#c7cbd1", width=430, height=240)
        panes.add(self.canvas, weight=3)
        self._table = _ScrollFrame(panes)
        panes.add(self._table, weight=2)
        self.canvas.bind("<Configure>", lambda _event: self._draw())
        self.canvas.bind("<Button-1>", self._start_drag)
        self.canvas.bind("<B1-Motion>", self._drag)
        self.canvas.bind("<ButtonRelease-1>", self._end_drag)
        self._status = ttk.Label(self, text="Drag a point vertically or type a percentage.", wraplength=750)
        self._status.grid(row=2, column=0, sticky="ew", pady=(6, 0))

    def set_values(self, values):
        values = validated_curve(values)
        self._loading = True
        for child in self._table.body.winfo_children():
            child.destroy()
        self._variables.clear()
        self._resist_labels.clear()
        headings = ["Enemy gap", "Success %"]
        if self._show_resist:
            headings.append("Full resist %")
        for column, heading in enumerate(headings):
            ttk.Label(self._table.body, text=heading).grid(row=0, column=column, padx=4, sticky="w")
        self._table.body.columnconfigure(1, weight=1)
        for index, probability in enumerate(values):
            gap = ttk.Label(self._table.body, text=f"+{index}" + (" onward" if index == len(values) - 1 else ""))
            gap.grid(row=index + 1, column=0, sticky="w", padx=4, pady=2)
            variable = tk.StringVar(self, value=format(probability * 100, ".15g"))
            self._variables.append(variable)
            entry = ttk.Spinbox(self._table.body, textvariable=variable, from_=0, to=100,
                                increment=.1, width=9)
            entry.grid(row=index + 1, column=1, sticky="ew", padx=4, pady=2)
            entry.bind("<FocusIn>", lambda _event, selected=index: self._select(selected))
            self._table.bind_wheel(entry)
            self._table.bind_wheel(gap)
            if self._show_resist:
                complement = ttk.Label(self._table.body, width=10)
                complement.grid(row=index + 1, column=2, padx=4, sticky="e")
                self._resist_labels.append(complement)
            variable.trace_add("write", self._edited)
        self._selected = min(self._selected, len(values) - 1)
        self._add.configure(state="normal" if len(values) < 60 else "disabled")
        self._remove.configure(state="normal" if len(values) > 1 else "disabled")
        self._loading = False
        self._draw()

    def get_values(self):
        return validated_curve([finite_number(value.get(), f"Gap +{index}") / 100
                                for index, value in enumerate(self._variables)])

    def _select(self, index):
        self._selected = index
        self._draw()

    def _edited(self, *_args):
        if self._loading:
            return
        self._draw()
        self._on_change()

    def _add_point(self):
        try:
            values = self.get_values()
        except ValueError as exc:
            self._status.configure(text=str(exc))
            return
        if len(values) < 60:
            self.set_values(values + [values[-1]])
            self._on_change()

    def _remove_point(self):
        try:
            values = self.get_values()
        except ValueError as exc:
            self._status.configure(text=str(exc))
            return
        if len(values) > 1:
            self.set_values(values[:-1])
            self._on_change()

    def _bounds(self):
        return (45, 18, max(70, self.canvas.winfo_width() - 18),
                max(60, self.canvas.winfo_height() - 37))

    def _draw(self):
        self.canvas.delete("all")
        self._points.clear()
        if not self._variables:
            return
        left, top, right, bottom = self._bounds()
        for percent in range(0, 101, 20):
            y = bottom - percent / 100 * (bottom - top)
            self.canvas.create_line(left, y, right, y, fill="#dde1e7")
            self.canvas.create_text(left - 7, y, text=str(percent), anchor="e", fill="#525b66")
        self.canvas.create_line(left, top, left, bottom, right, bottom, fill="#7a8591")
        self.canvas.create_text((left + right) / 2, bottom + 27,
                                text="Enemy level minus source level; final point is the floor", fill="#525b66")
        try:
            values = self.get_values()
        except ValueError as exc:
            self._status.configure(text=str(exc))
            return
        denominator = max(1, len(values) - 1)
        for index, value in enumerate(values):
            x = (left + right) / 2 if len(values) == 1 else left + index / denominator * (right - left)
            self._points.append((x, bottom - value * (bottom - top)))
            if index % max(1, math.ceil(len(values) / 12)) == 0 or index == len(values) - 1:
                self.canvas.create_text(x, bottom + 10, text=f"+{index}", fill="#525b66")
        if len(self._points) > 1:
            self.canvas.create_line(*[coordinate for point in self._points for coordinate in point],
                                    fill="#236fbe", width=2)
            if self._show_resist:
                complement = [(x, top + (bottom - y)) for x, y in self._points]
                self.canvas.create_line(*[coordinate for point in complement for coordinate in point],
                                        fill="#b94b44", width=2, dash=(5, 3))
        for index, (x, y) in enumerate(self._points):
            radius = 5 if index == self._selected else 4
            self.canvas.create_oval(x - radius, y - radius, x + radius, y + radius,
                                    fill="#164c88" if index == self._selected else "#428bd0",
                                    outline="#fafbfc")
        for index, label in enumerate(self._resist_labels):
            label.configure(text=f"{(1 - values[index]) * 100:.4g}")
        value = values[self._selected] * 100
        text = f"Gap +{self._selected}: {value:.6g}% success"
        if self._show_resist:
            text += f" / {100 - value:.6g}% full resist. Dashed red = full resist."
        text += f"  Beyond +{len(values) - 1}: {values[-1] * 100:.6g}% success."
        self._status.configure(text=text)

    def _start_drag(self, event):
        if not self._points:
            return
        self._drag_index = min(range(len(self._points)), key=lambda i:
                               (self._points[i][0] - event.x) ** 2 + (self._points[i][1] - event.y) ** 2)
        self._selected = self._drag_index
        self._drag(event)

    def _drag(self, event):
        if self._drag_index is None:
            return
        _left, top, _right, bottom = self._bounds()
        percent = round(min(100, max(0, (bottom - event.y) / (bottom - top) * 100)), 2)
        self._variables[self._drag_index].set(format(percent, ".15g"))

    def _end_drag(self, _event):
        self._drag_index = None


class RulesEditor(ttk.Frame):
    """Editable experiment rules and the shared Attack/Spell accuracy curve."""

    def __init__(self, master, on_change=None):
        super().__init__(master, padding=6)
        self._on_change = on_change
        self._rules = {}
        self._baseline = None
        self._variables = {}
        self._loading = False
        self._refresh_pending = False
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)
        toolbar = ttk.Frame(self)
        toolbar.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        ttk.Label(toolbar, text="Experiment rules · edits never write the game configuration").pack(side="left")
        ttk.Button(toolbar, text="Reset rule edits", command=self._reset).pack(side="right")
        self.notebook = ttk.Notebook(self)
        self.notebook.grid(row=1, column=0, sticky="nsew")
        accuracy = ttk.Notebook(self.notebook)
        self.notebook.add(accuracy, text="Accuracy curves")
        shared = _AccuracyCurveEditor(accuracy, "Attack and Spell success before Hit Rating", self._edited)
        # Retain the saved experiment's two keys, with one authoritative editor.
        self._curves = {"melee": shared, "spell": shared}
        accuracy.add(shared, text="Shared Hit Rating")
        self._forms = {}
        for name in ("Accuracy ratings", "Level damage", "Defenses", "Other rules"):
            form = _ScrollFrame(self.notebook)
            form.body.columnconfigure(1, weight=1)
            self.notebook.add(form, text=name)
            self._forms[name] = form
        previews = ttk.Frame(self.notebook, padding=5)
        previews.columnconfigure(0, weight=1)
        previews.rowconfigure(1, weight=1)
        previews.rowconfigure(3, weight=1)
        self.notebook.add(previews, text="Formula previews")
        ttk.Label(previews, text="Level damage multiplier · existing simulator formula").grid(row=0, column=0, sticky="w")
        self._level_canvas = tk.Canvas(previews, background="#fafbfc", height=170, highlightthickness=0)
        self._level_canvas.grid(row=1, column=0, sticky="nsew", pady=(3, 12))
        ttk.Label(previews, text="Armor reduction / Evasion chance · existing simulator formula").grid(row=2, column=0, sticky="w")
        self._defense_canvas = tk.Canvas(previews, background="#fafbfc", height=170, highlightthickness=0)
        self._defense_canvas.grid(row=3, column=0, sticky="nsew", pady=3)
        for canvas in (self._level_canvas, self._defense_canvas):
            canvas.bind("<Configure>", lambda _event: self._refresh_previews())
        self._message = ttk.Label(self, text="Drag curve points or edit numeric fields. Values are experiment-only.", wraplength=950)
        self._message.grid(row=2, column=0, sticky="ew", pady=(6, 0))

    def set_data(self, rules, curves):
        if not isinstance(rules, dict) or not isinstance(curves, dict):
            raise ValueError("Rules and curves must be dictionaries.")
        if not all(name in curves for name in ("melee", "spell")):
            raise ValueError("Provide matching Attack and Spell accuracy curve copies.")
        selected_curves = {name: validated_curve(curves[name], name.capitalize()) for name in ("melee", "spell")}
        if selected_curves["melee"] != selected_curves["spell"]:
            raise ValueError("Attack and Spell now use one Hit Rating curve. Reconcile different legacy curves before opening this experiment.")
        self._loading = True
        self._rules = copy.deepcopy(rules)
        self._baseline = (copy.deepcopy(rules), copy.deepcopy(selected_curves))
        self._variables.clear()
        for form in self._forms.values():
            for child in form.body.winfo_children():
                child.destroy()
        counters = dict.fromkeys(self._forms, 0)
        for key, value in rules.items():
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                continue
            group = self._group(key)
            form = self._forms[group]
            row = counters[group]
            counters[group] += 1
            label = ttk.Label(form.body, text=key.replace("_", " ").capitalize())
            label.grid(row=row, column=0, sticky="w", padx=(3, 12), pady=3)
            variable = tk.StringVar(self, value=format(value, ".15g"))
            self._variables[key] = variable
            entry = ttk.Entry(form.body, textvariable=variable, width=18)
            entry.grid(row=row, column=1, sticky="ew", padx=3, pady=3)
            form.bind_wheel(entry)
            form.bind_wheel(label)
            variable.trace_add("write", self._edited)
        for name, editor in self._curves.items():
            editor.set_values(selected_curves[name])
        self._loading = False
        self._refresh_previews()

    def get_data(self):
        if not self._rules:
            raise ValueError("Load game defaults or an experiment before editing rules.")
        rules = copy.deepcopy(self._rules)
        for key, variable in self._variables.items():
            value = finite_number(variable.get(), key.replace("_", " "))
            if isinstance(self._rules[key], int):
                if not value.is_integer():
                    raise ValueError(f"{key.replace('_', ' ')} must be an integer.")
                value = int(value)
            rules[key] = value
        for key in ("defense_curve_denominator_base", "defense_curve_denominator_per_rating",
                    "speed_rating_scale", "level_gap_width", "hit_rating_base_requirement",
                    "control_level_duration_width", "minimum_capacity"):
            if key in rules and rules[key] <= 0:
                raise ValueError(f"{key.replace('_', ' ')} must be greater than zero.")
        if not 1 <= rules.get("max_level", 60) <= 60:
            raise ValueError("Maximum level must be between 1 and 60.")
        if rules.get("speed_rating_min", 0) <= -rules.get("speed_rating_scale", 100):
            raise ValueError("Minimum speed rating must be greater than minus the speed scale.")
        curves = {name: editor.get_values() for name, editor in self._curves.items()}
        return rules, curves

    @staticmethod
    def _group(key):
        if key.startswith(("hit_rating_", "accuracy_rating_")):
            return "Accuracy ratings"
        if key.startswith(("level_gap_", "level_payload_")) or key == "max_level":
            return "Level damage"
        if key.startswith(("armor", "defense", "evasion", "resistance", "critical", "block", "control", "entropy")):
            return "Defenses"
        return "Other rules"

    def _reset(self):
        if self._baseline is not None:
            rules, curves = copy.deepcopy(self._baseline)
            self.set_data(rules, curves)
            if self._on_change:
                self._on_change()

    def _edited(self, *_args):
        if self._loading or self._refresh_pending:
            return
        self._refresh_pending = True
        self.after_idle(self._flush_edits)

    def _flush_edits(self):
        self._refresh_pending = False
        self._refresh_previews()
        if self._on_change:
            self._on_change()

    def _refresh_previews(self):
        if not self._rules:
            return
        try:
            rules, _curves = self.get_data()
            maximum_gap = max(1, int(rules.get("max_level", 60)) - 1)
            gaps = np.arange(-maximum_gap, maximum_gap + 1)
            factors = sim.level_gap_factor(np.maximum(gaps, 0) + 1, np.maximum(-gaps, 0) + 1, rules)
            self._plot(self._level_canvas, gaps, [("Damage ×", factors, "#236fbe")],
                       "Source level − target level", max(1.0, float(np.max(factors))))
            ratings = np.linspace(0, 2000, 101)
            armor = sim.defense(ratings, rules)
            evasion = sim.defense(ratings, rules, evasion=True)
            self._plot(self._defense_canvas, ratings,
                       [("Armor", armor * 100, "#236fbe"), ("Evasion", evasion * 100, "#b36920")],
                       "Raw rating", 100)
            self._message.configure(text="Experiment-only copies. Accuracy plots show zero-rating success; the final point applies to every larger gap.")
        except (ValueError, KeyError, ZeroDivisionError, OverflowError) as exc:
            self._message.configure(text=f"Fix an invalid field before running: {exc}")
            for canvas in (self._level_canvas, self._defense_canvas):
                canvas.delete("all")
                canvas.create_text(15, 20, anchor="nw", text="Preview unavailable until the invalid field is fixed.", fill="#525b66")

    @staticmethod
    def _plot(canvas, x_values, series, x_label, y_max):
        canvas.delete("all")
        left, right = 55, max(90, canvas.winfo_width() - 18)
        top, bottom = 28, max(80, canvas.winfo_height() - 35)
        x_min, x_max = float(x_values[0]), float(x_values[-1])
        y_max = max(.001, y_max)
        for fraction in (0, .25, .5, .75, 1):
            y = bottom - fraction * (bottom - top)
            canvas.create_line(left, y, right, y, fill="#dde1e7")
            canvas.create_text(left - 7, y, text=f"{y_max * fraction:.3g}", anchor="e", fill="#525b66")
        canvas.create_line(left, top, left, bottom, right, bottom, fill="#7a8591")
        for fraction in (0, .25, .5, .75, 1):
            x = left + fraction * (right - left)
            canvas.create_text(x, bottom + 12, text=f"{x_min + fraction * (x_max - x_min):.3g}", fill="#525b66")
        canvas.create_text((left + right) / 2, bottom + 28, text=x_label, fill="#525b66")
        for index, (name, values, color) in enumerate(series):
            coords = []
            for x_value, value in zip(x_values, values):
                coords.extend((left + (float(x_value) - x_min) / max(1, x_max - x_min) * (right - left),
                               bottom - min(y_max, max(0, float(value))) / y_max * (bottom - top)))
            if len(coords) >= 4:
                canvas.create_line(*coords, fill=color, width=2, dash=() if index == 0 else (5, 3))
            canvas.create_text(left + index * 145, 11, text=name, fill=color, anchor="w")


class ResultsPanel(ttk.Frame):
    """Sortable matchup matrix with selected-row kill-time distribution and caveats."""

    COLUMNS = (
        ("index", "#", 45, "integer"), ("player_name", "Player", 105, "text"),
        ("enemy_name", "Enemy", 105, "text"), ("ability_name", "Ability", 125, "text"),
        ("player_level", "Player L", 65, "integer"), ("enemy_level", "Enemy L", 65, "integer"),
        ("variants", "Variants", 150, "variants"), ("trials", "Trials", 75, "integer"),
        ("kill_rate", "Kill %", 85, "percent"), ("ttk_mean", "Mean TTK¹", 100, "seconds"),
        ("ttk_p10", "P10¹", 90, "seconds"), ("ttk_median", "Median¹", 95, "seconds"),
        ("ttk_p90", "P90¹", 90, "seconds"), ("ttk_p95", "P95¹", 90, "seconds"),
        ("ttk_max", "Max TTK¹", 100, "seconds"), ("timeouts", "Timeouts", 80, "integer"),
        ("restricted_mean_time", "Restricted mean²", 135, "seconds"),
        ("effective_dps", "Effective DPS", 110, "number"), ("mean_attempts", "Attempts / trial", 120, "number"),
        ("hit_rate", "Hit %", 85, "percent"), ("miss_rate", "Miss %", 85, "percent"),
        ("resist_rate", "Full resist %", 100, "percent"), ("dodge_rate", "Dodge %", 85, "percent"),
        ("block_rate", "Block %", 85, "percent"), ("crit_rate", "Crit events %", 110, "percent"),
        ("damage_direct", "Mean direct damage", 140, "number"),
        ("damage_periodic", "Mean periodic damage", 150, "number"),
        ("resource_wait_time", "Mean resource wait", 140, "seconds"),
        ("resource_starved_trials", "Resource-wait trials", 140, "integer"),
        ("resource_depleted_trials", "Depleted timeouts", 140, "integer"),
        ("elapsed_seconds", "Compute time", 110, "seconds"),
    )

    PAGE_SIZE = 200

    def __init__(self, master):
        super().__init__(master, padding=6)
        self._catalogue = ResultCatalogue(self.COLUMNS)
        self._result = {}
        self._sort_column = None
        self._sort_descending = False
        self._selected_row = None
        self._refresh_pending = False
        self._pending_positions = {}
        self._view_positions = []
        self._view_members = set()
        self._shown_values = {}
        self._shown_order = []
        self._query = ""
        self._page = 0
        self._filter_after = None
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)
        toolbar = ttk.Frame(self)
        toolbar.grid(row=0, column=0, sticky="ew", pady=(0, 5))
        self._summary = ttk.Label(toolbar, text="No encounter results yet.")
        self._summary.pack(side="left", fill="x", expand=True)
        ttk.Label(toolbar, text="Filter:").pack(side="left", padx=(8, 4))
        self._filter = tk.StringVar(self)
        ttk.Entry(toolbar, textvariable=self._filter, width=22).pack(side="left")
        self._filter.trace_add("write", self._schedule_filter)
        panes = ttk.Panedwindow(self, orient="vertical")
        panes.grid(row=1, column=0, sticky="nsew")
        matrix = ttk.Frame(panes)
        matrix.columnconfigure(0, weight=1)
        matrix.rowconfigure(0, weight=1)
        panes.add(matrix, weight=3)
        keys = [column[0] for column in self.COLUMNS]
        self.table = ttk.Treeview(matrix, columns=keys, show="headings", selectmode="browse", height=10)
        self.table.grid(row=0, column=0, sticky="nsew")
        for key, title, width, _kind in self.COLUMNS:
            self.table.heading(key, text=title, command=lambda selected=key: self._sort(selected))
            self.table.column(key, width=width, minwidth=45, stretch=False,
                              anchor="w" if key.endswith("name") or key == "variants" else "e")
        y_scroll = ttk.Scrollbar(matrix, orient="vertical", command=self.table.yview)
        y_scroll.grid(row=0, column=1, sticky="ns")
        x_scroll = ttk.Scrollbar(matrix, orient="horizontal", command=self.table.xview)
        x_scroll.grid(row=1, column=0, sticky="ew")
        self.table.configure(yscrollcommand=y_scroll.set, xscrollcommand=x_scroll.set)
        self.table.bind("<<TreeviewSelect>>", self._select_row)
        pagination = ttk.Frame(matrix)
        pagination.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(5, 2))
        self._previous_page = ttk.Button(pagination, text="Previous", command=lambda: self._change_page(-1))
        self._previous_page.pack(side="left")
        self._next_page = ttk.Button(pagination, text="Next", command=lambda: self._change_page(1))
        self._next_page.pack(side="left", padx=(5, 10))
        self._page_info = ttk.Label(pagination, text="Page 1 / 1 · 0 rows")
        self._page_info.pack(side="left")
        detail_panes = ttk.Panedwindow(panes, orient="horizontal")
        panes.add(detail_panes, weight=2)
        histogram = ttk.Frame(detail_panes)
        histogram.rowconfigure(1, weight=1)
        histogram.columnconfigure(0, weight=1)
        ttk.Label(histogram, text="Kill-time distribution · successful trials only").grid(row=0, column=0, sticky="w")
        self._histogram = tk.Canvas(histogram, background="#fafbfc", height=190, highlightthickness=0)
        self._histogram.grid(row=1, column=0, sticky="nsew")
        self._histogram.bind("<Configure>", lambda _event: self._draw_histogram())
        detail_panes.add(histogram, weight=3)
        details = ttk.Frame(detail_panes)
        details.rowconfigure(0, weight=1)
        details.columnconfigure(0, weight=1)
        self._details = tk.Text(details, width=44, height=10, wrap="word", relief="flat", padx=8, pady=6)
        self._details.grid(row=0, column=0, sticky="nsew")
        detail_scroll = ttk.Scrollbar(details, orient="vertical", command=self._details.yview)
        detail_scroll.grid(row=0, column=1, sticky="ns")
        self._details.configure(yscrollcommand=detail_scroll.set, state="disabled")
        detail_panes.add(details, weight=2)
        ttk.Label(self, text="¹ TTK values exclude trials without a kill.  ² Restricted mean includes timeouts at the horizon. Column clicks sort current matches; newly completed cells append. Export includes every row.",
                  wraplength=1150).grid(row=2, column=0, sticky="ew", pady=(6, 0))
        self._set_details("Select a matchup to inspect its outcome rates, kill-time distribution, and analytic reference.")

    def clear(self):
        self._catalogue.clear()
        self._result = {}
        self._selected_row = None
        self._pending_positions.clear()
        self._view_positions.clear()
        self._view_members.clear()
        self._shown_values.clear()
        self._shown_order.clear()
        self._page = 0
        self.table.delete(*self.table.get_children())
        self._summary.configure(text="No encounter results yet.")
        self._set_details("Select a matchup to inspect its results.")
        self._refresh_table()
        self._draw_histogram()

    def add_result(self, row):
        position, is_new = self._catalogue.upsert(row)
        self._pending_positions[position] = is_new
        if not self._refresh_pending:
            self._refresh_pending = True
            self.after_idle(self._flush_results)

    def set_results(self, resultdict):
        if not isinstance(resultdict, dict) or not isinstance(resultdict.get("cells", []), list):
            raise ValueError("Results must contain a cells list.")
        self.clear()
        self._result = {key: resultdict[key] for key in ("status", "requested_trials", "completed_trials", "elapsed_seconds")
                        if key in resultdict}
        for row in resultdict.get("cells", []):
            self._catalogue.upsert(row)
        self._rebuild_view()
        self._refresh_table()
        self._update_summary()

    def export_rows(self):
        return self._catalogue.export_rows()

    def _flush_results(self):
        self._refresh_pending = False
        self._merge_pending_positions()
        self._refresh_table()
        self._update_summary()

    def _update_summary(self):
        trials, kills, timeouts = (self._catalogue.totals[key] for key in ("trials", "kills", "timeouts"))
        status = str(self._result.get("status", "Running"))
        self._summary.configure(text=f"{status.capitalize()} · {len(self._catalogue.rows):,} matchups · {trials:,} trials · {kills:,} kills · {timeouts:,} timeouts")

    def _merge_pending_positions(self):
        removed = set()
        for position in self._pending_positions:
            matches = self._catalogue.matches(position, self._query)
            if matches and position not in self._view_members:
                self._view_positions.append(position)
                self._view_members.add(position)
            elif not matches and position in self._view_members:
                self._view_members.remove(position)
                removed.add(position)
        if removed:
            self._view_positions = [position for position in self._view_positions if position not in removed]
        self._pending_positions.clear()

    def _rebuild_view(self):
        self._query = self._filter.get().strip().casefold()
        positions = self._catalogue.matching_positions(self._query)
        if self._sort_column:
            positions = self._catalogue.sorted_positions(positions, self._sort_column, self._sort_descending)
        self._view_positions = positions
        self._view_members = set(positions)
        self._pending_positions.clear()

    def _schedule_filter(self, *_args):
        if self._filter_after is not None:
            self.after_cancel(self._filter_after)
        self._filter_after = self.after(250, self._apply_filter)

    def _apply_filter(self):
        self._filter_after = None
        self._page = 0
        self._rebuild_view()
        self._refresh_table()

    def _change_page(self, direction):
        self._merge_pending_positions()
        self._page += direction
        self._refresh_table()

    def _refresh_table(self):
        positions, self._page, pages = result_page(self._view_positions, self._page, self.PAGE_SIZE)
        wanted = {str(position) for position in positions}
        old_selection = self.table.selection()
        order_changed = positions != self._shown_order
        if order_changed:
            for identity in self.table.get_children():
                if identity not in wanted:
                    self.table.delete(identity)
        for order, position in enumerate(positions):
            identity = str(position)
            values = self._catalogue.formatted(position)
            if position not in self._shown_values:
                self.table.insert("", "end", iid=identity, values=values)
            elif self._shown_values.get(position) != values:
                self.table.item(identity, values=values)
            if order_changed:
                self.table.move(identity, "", order)
        self._shown_values = {position: self._catalogue.formatted(position) for position in positions}
        self._shown_order = positions
        selected = old_selection[0] if old_selection and old_selection[0] in wanted else (str(positions[0]) if positions else None)
        if selected is not None:
            if not old_selection or old_selection[0] != selected:
                self.table.selection_set(selected)
            if self._selected_row is not self._catalogue.rows[int(selected)]:
                self._select_row()
        elif self._selected_row is not None:
            self._select_row()
        count = len(self._view_positions)
        start = self._page * self.PAGE_SIZE + 1 if count else 0
        end = min(count, (self._page + 1) * self.PAGE_SIZE)
        self._page_info.configure(text=f"Page {self._page + 1:,} / {pages:,} · rows {start:,}–{end:,} of {count:,} matching")
        self._previous_page.configure(state="normal" if self._page else "disabled")
        self._next_page.configure(state="normal" if self._page + 1 < pages else "disabled")

    def _sort(self, column):
        if self._sort_column == column:
            self._sort_descending = not self._sort_descending
        else:
            self._sort_column = column
            self._sort_descending = False
        self._page = 0
        self._rebuild_view()
        self._refresh_table()

    def _select_row(self, _event=None):
        selected = self.table.selection()
        if not selected:
            self._selected_row = None
            self._set_details("No matchups match this filter.")
            self._draw_histogram()
            return
        self._selected_row = self._catalogue.rows[int(selected[0])]
        row = self._selected_row
        lines = [f"{row.get('player_name', 'Player')} → {row.get('enemy_name', 'Enemy')}",
                 f"{row.get('ability_name', 'Ability')} · levels {row.get('player_level', '?')} → {row.get('enemy_level', '?')}",
                 f"Variants: {format_result_value(row.get('variants'), 'variants')}", "",
                 f"Kills: {row.get('kills', 0):,} / {row.get('trials', 0):,} ({format_result_value(row.get('kill_rate'), 'percent')})",
                 f"Timeouts: {row.get('timeouts', 0):,}",
                 f"Trials with resource waits: {row.get('resource_starved_trials', 0):,}",
                 f"Unaffordable/depleted-source timeouts: {row.get('resource_depleted_trials', 0):,}",
                 "TTK values below are conditional on a kill:"]
        for key, label in (("ttk_mean", "Mean"), ("ttk_p10", "P10"), ("ttk_median", "Median"),
                           ("ttk_p90", "P90"), ("ttk_p95", "P95"), ("ttk_max", "Maximum")):
            lines.append(f"  {label}: {format_result_value(row.get(key), 'seconds')}")
        lines.extend(["", f"Restricted mean time: {format_result_value(row.get('restricted_mean_time'), 'seconds')}",
                      "This averages min(kill time, horizon); a timeout contributes the horizon, not an observed kill.",
                      f"Effective DPS: {format_result_value(row.get('effective_dps'))}",
                      "Actual health damage / total exposure time, including failed trials.", "", "Delivery outcomes (all attempts):"])
        for key, label in (("hit_rate", "Hit"), ("miss_rate", "Miss"), ("resist_rate", "Full resist"),
                           ("dodge_rate", "Dodge"), ("block_rate", "Block")):
            lines.append(f"  {label}: {format_result_value(row.get(key), 'percent')}")
        lines.extend([f"Critical damage events: {format_result_value(row.get('crit_rate'), 'percent')}",
                      "Critical fraction uses all executed direct and periodic damage events, including zero damage.",
                      f"Attempts / trial: {format_result_value(row.get('mean_attempts'))}",
                      f"Mean resource wait / trial: {format_result_value(row.get('resource_wait_time'), 'seconds')}",
                      f"Mean direct damage / trial: {format_result_value(row.get('damage_direct'))}",
                      f"Mean periodic damage / trial: {format_result_value(row.get('damage_periodic'))}",
                      f"Unavailable action reason: {row.get('unavailable_reason') or 'None'}", "", "Analytic reference:",
                      json.dumps(row.get("analytic", {}), indent=2, default=str)])
        self._set_details("\n".join(lines))
        self._draw_histogram()

    def _set_details(self, text):
        self._details.configure(state="normal")
        self._details.delete("1.0", "end")
        self._details.insert("1.0", text)
        self._details.configure(state="disabled")

    def _draw_histogram(self):
        canvas = self._histogram
        canvas.delete("all")
        row = self._selected_row
        bins = histogram_bins(row.get("histogram", {})) if row else []
        width, height = max(180, canvas.winfo_width()), max(130, canvas.winfo_height())
        if not row:
            canvas.create_text(width / 2, height / 2, text="Select a matchup", fill="#525b66")
            return
        if not bins or not any(count for _a, _b, count in bins):
            canvas.create_text(width / 2, height / 2, text="No observed kills — kill-time distribution is undefined.",
                               width=max(150, width - 30), fill="#525b66")
            return
        left, right, top, bottom = 48, width - 15, 27, height - 36
        maximum = max(count for _a, _b, count in bins)
        minimum_time, maximum_time = bins[0][0], bins[-1][1]
        span = maximum_time - minimum_time
        for fraction in (0, .5, 1):
            y = bottom - fraction * (bottom - top)
            canvas.create_line(left, y, right, y, fill="#dde1e7")
            canvas.create_text(left - 6, y, text=f"{fraction * maximum:.0f}", anchor="e", fill="#525b66")
        for start, end, count in bins:
            x0 = left + (start - minimum_time) / span * (right - left)
            x1 = left + (end - minimum_time) / span * (right - left)
            y = bottom - count / maximum * (bottom - top)
            canvas.create_rectangle(x0 + 1, y, max(x0 + 1, x1 - 1), bottom, fill="#428bd0", outline="")
        canvas.create_line(left, top, left, bottom, right, bottom, fill="#7a8591")
        for fraction in (0, .5, 1):
            x = left + fraction * (right - left)
            canvas.create_text(x, bottom + 11, text=f"{minimum_time + fraction * span:.3g}s", fill="#525b66")
        canvas.create_text((left + right) / 2, bottom + 28, text="Observed time to kill", fill="#525b66")
        canvas.create_text(left, 11, text=f"{row.get('kills', 0):,} kills; {row.get('timeouts', 0):,} timeouts omitted from histogram",
                           anchor="w", fill="#525b66")
