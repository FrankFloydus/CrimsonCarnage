# The desktop coordinator. Tk is created only when the user launches main().
from __future__ import annotations

import copy
import json
from pathlib import Path
import queue
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import uuid

from . import engine, model
from .editors import ActorEditor, AbilityEditor, MatrixEditor, new_effect, number, wrap_to_width
from .widgets import RulesEditor, ResultsPanel
from .storage import ensure_output_path, load_experiment, save_experiment, export_csv


class CombatLab(ttk.Frame):
    def __init__(self, master):
        super().__init__(master, padding=10)
        self.root = master
        self.session = model.default_session()
        self.path = None
        self.modified = False
        self.revision = 0
        self.loading = False
        self.actor_selection = None
        self.ability_selection = None
        self.last_result = None
        self.messages = queue.Queue()
        self.cancel_event = threading.Event()
        self.worker = None
        self.job_active = False
        self.job_id = 0
        self.started_at = 0.0
        self._preview_after = None
        self._configure_style()
        self.pack(fill="both", expand=True)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(2, weight=1)
        heading = ttk.Frame(self)
        heading.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        ttk.Label(heading, text="COMBAT LAB", style="Title.TLabel").pack(side="left")
        ttk.Label(heading, text="Build a test · cross your enemies · measure time to kill", style="Subtitle.TLabel") \
            .pack(side="left", padx=18)
        toolbar = ttk.Frame(self)
        toolbar.grid(row=1, column=0, sticky="ew", pady=(0, 8))
        for index, (label, command) in enumerate([("New experiment", self.new_session), ("Open…", self.open_session),
                               ("Save", self.save_session), ("Save as…", lambda: self.save_session(True)),
                               ("Import saved game actors", self.import_project), ("Export results CSV…", self.save_csv),
                               ("Save run + results…", self.save_run)]):
            ttk.Button(toolbar, text=label, command=command).grid(row=index // 4, column=index % 4,
                                                                 sticky="ew", padx=(0, 6), pady=2)
            toolbar.columnconfigure(index % 4, weight=1)
        self.tabs = ttk.Notebook(self)
        self.tabs.grid(row=2, column=0, sticky="nsew")
        self._build_actors()
        self._build_abilities()
        self.rules_editor = RulesEditor(self.tabs, on_change=self._inputs_changed)
        self.tabs.add(self.rules_editor, text="Curves & rules")
        self.matrix_editor = MatrixEditor(self.tabs, on_change=self._inputs_changed)
        self.tabs.add(self.matrix_editor, text="Matrix")
        self.results = ResultsPanel(self.tabs)
        self.tabs.add(self.results, text="Results")
        self.tabs.bind("<<NotebookTabChanged>>", self._tab_changed)
        controls = ttk.LabelFrame(self, text="Run settings · independent trials per matchup", padding=8)
        controls.grid(row=3, column=0, sticky="ew", pady=(8, 0))
        self.run_vars = {}
        for column, (key, label, default) in enumerate([
                ("trials", "Trials / matchup", 10000), ("horizon", "Maximum fight time (s)", 120),
                ("seed", "Random seed", 12345), ("workers", "Workers", 1)]):
            ttk.Label(controls, text=label).grid(row=0, column=column * 2, padx=(0, 6))
            value = tk.StringVar(value=str(default))
            ttk.Entry(controls, textvariable=value, width=12 if key != "workers" else 5) \
                .grid(row=0, column=column * 2 + 1, padx=(0, 16), sticky="ew")
            controls.columnconfigure(column * 2 + 1, weight=1)
            value.trace_add("write", lambda *_: self._inputs_changed())
            self.run_vars[key] = value
        progress = ttk.Frame(self)
        progress.grid(row=4, column=0, sticky="ew", pady=8)
        progress.columnconfigure(0, weight=1)
        self.progress = ttk.Progressbar(progress, mode="determinate", maximum=100)
        self.progress.grid(row=0, column=0, sticky="ew", padx=(0, 10))
        self.run_button = ttk.Button(progress, text="Run matrix", command=self.start_run, style="Run.TButton")
        self.run_button.grid(row=0, column=1, padx=4)
        self.cancel_button = ttk.Button(progress, text="Cancel", command=self.cancel_run, state="disabled")
        self.cancel_button.grid(row=0, column=2, padx=4)
        self.status = ttk.Label(self, text=model.LEGACY_NOTICE, wraplength=1180)
        self.status.grid(row=5, column=0, sticky="ew")
        wrap_to_width(self.status, self)
        footer = ttk.Label(self, text="Targets do not attack back. Physical contact is assumed. Results use inputs captured at Run; editing does not change an active run.", style="Subtitle.TLabel", wraplength=1000)
        footer.grid(row=6, column=0, sticky="w", pady=(5, 0))
        wrap_to_width(footer, self)
        self._load_into_forms(self.session)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.bind("<Control-s>", lambda _: self.save_session())
        self.root.bind("<Control-o>", lambda _: self.open_session())
        self.root.after(75, self._poll_messages)

    def _configure_style(self):
        self.root.title("Legacy Combat Lab — pre-2.0")
        width = min(1320, max(1000, self.root.winfo_screenwidth() - 100))
        height = min(860, max(650, self.root.winfo_screenheight() - 100))
        self.root.geometry(f"{width}x{height}")
        self.root.minsize(min(1050, width), min(690, height))
        style = ttk.Style(self.root)
        if "clam" in style.theme_names():
            style.theme_use("clam")
        style.configure(".", font=("Segoe UI", 10))
        style.configure("Treeview", rowheight=25)
        style.configure("Title.TLabel", font=("Segoe UI", 18, "bold"))
        style.configure("Heading.TLabel", font=("Segoe UI", 10, "bold"))
        style.configure("Subtitle.TLabel", foreground="#526171")
        style.configure("Run.TButton", padding=(18, 7))

    def _build_actors(self):
        tab = ttk.Panedwindow(self.tabs, orient="horizontal")
        self.tabs.add(tab, text="Player & enemies")
        sidebar = ttk.Frame(tab, padding=(8, 8, 6, 8))
        sidebar.rowconfigure(1, weight=1)
        sidebar.columnconfigure(0, weight=1)
        ttk.Label(sidebar, text="Actor profiles", style="Heading.TLabel").grid(row=0, column=0, sticky="w", pady=(0, 6))
        self.actor_tree = ttk.Treeview(sidebar, show="tree", selectmode="browse", height=12)
        self.actor_tree.column("#0", width=205, minwidth=140)
        self.actor_tree.grid(row=1, column=0, sticky="nsew")
        self.actor_tree.bind("<<TreeviewSelect>>", self._select_actor)
        for row, (label, command) in enumerate([
                ("Add player", lambda: self.add_actor("players")),
                ("Add enemy", lambda: self.add_actor("enemies")),
                ("Duplicate selected", self.duplicate_actor), ("Delete selected", self.delete_actor)], 2):
            ttk.Button(sidebar, text=label, command=command).grid(row=row, column=0, sticky="ew", pady=3)
        tab.add(sidebar, weight=1)
        self.actor_editor = ActorEditor(tab, on_change=self._actor_changed)
        tab.add(self.actor_editor, weight=5)

    def _build_abilities(self):
        tab = ttk.Panedwindow(self.tabs, orient="horizontal")
        self.tabs.add(tab, text="Abilities")
        sidebar = ttk.Frame(tab, padding=(8, 8, 6, 8))
        sidebar.rowconfigure(1, weight=1)
        sidebar.columnconfigure(0, weight=1)
        ttk.Label(sidebar, text="Ability profiles", style="Heading.TLabel").grid(row=0, column=0, sticky="w", pady=(0, 6))
        self.ability_tree = ttk.Treeview(sidebar, show="tree", selectmode="browse", height=10)
        self.ability_tree.column("#0", width=170, minwidth=130)
        self.ability_tree.grid(row=1, column=0, sticky="nsew")
        self.ability_tree.bind("<<TreeviewSelect>>", self._select_ability)
        for row, (label, command) in enumerate([("Add ability", self.add_ability),
                                               ("Duplicate selected", self.duplicate_ability),
                                               ("Delete selected", self.delete_ability)], 2):
            ttk.Button(sidebar, text=label, command=command).grid(row=row, column=0, sticky="ew", pady=3)
        tab.add(sidebar, weight=1)
        self.ability_editor = AbilityEditor(tab, on_change=self._ability_changed)
        tab.add(self.ability_editor, weight=6)

    def _load_into_forms(self, session):
        self.loading = True
        self.last_result = None
        self.results.clear()
        self.session = copy.deepcopy(session)
        self.actor_selection = None
        self.ability_selection = None
        self.actor_editor.actor = None
        self.ability_editor.ability = None
        self.rules_editor.set_data(self.session["rules"], self.session["curves"])
        self.matrix_editor.set_data(self.session)
        for key, variable in self.run_vars.items():
            variable.set(str(self.session["run"].get(key, 1)))
        self._refresh_actor_tree()
        self._refresh_ability_tree()
        self.loading = False
        if self.session["players"]:
            self._show_actor("players", self.session["players"][0]["id"])
        if self.session["abilities"]:
            self._show_ability(self.session["abilities"][0]["id"])
        self.modified = False
        self.tabs.select(0)
        self._update_title()
        self._update_preview()

    def _refresh_actor_tree(self):
        self.actor_tree.delete(*self.actor_tree.get_children())
        for group, heading in (("players", "Players"), ("enemies", "Enemies")):
            self.actor_tree.insert("", "end", iid=group, text=heading, open=True)
            for actor in self.session[group]:
                self.actor_tree.insert(group, "end", iid=f"{group}:{actor['id']}", text=f"{actor['name']} · L{actor['level']}")

    def _refresh_ability_tree(self):
        self.ability_tree.delete(*self.ability_tree.get_children())
        for ability in self.session["abilities"]:
            self.ability_tree.insert("", "end", iid=ability["id"], text=ability["name"])

    def _find_actor(self, group, actor_id):
        return next(actor for actor in self.session[group] if actor["id"] == actor_id)

    def _show_actor(self, group, actor_id):
        self.actor_selection = (group, actor_id)
        self.actor_editor.set_data(self._find_actor(group, actor_id), self.session["rules"])
        self.actor_tree.selection_set(f"{group}:{actor_id}")

    def _show_ability(self, ability_id):
        self.ability_selection = ability_id
        ability = next(a for a in self.session["abilities"] if a["id"] == ability_id)
        self.ability_editor.set_data(ability)
        self.ability_tree.selection_set(ability_id)

    def _commit_actor(self):
        if self.actor_selection and self.actor_editor.actor is not None:
            group, actor_id = self.actor_selection
            updated = self.actor_editor.get_data()
            index = next(index for index, actor in enumerate(self.session[group]) if actor["id"] == actor_id)
            self.session[group][index] = updated
            item_id = f"{group}:{actor_id}"
            if self.actor_tree.exists(item_id):
                self.actor_tree.item(item_id, text=f"{updated['name']} · L{updated['level']}")

    def _commit_ability(self):
        if self.ability_selection and self.ability_editor.ability is not None:
            updated = self.ability_editor.get_data()
            index = next(index for index, ability in enumerate(self.session["abilities"])
                         if ability["id"] == self.ability_selection)
            self.session["abilities"][index] = updated
            if self.ability_tree.exists(self.ability_selection):
                self.ability_tree.item(self.ability_selection, text=updated["name"])

    def _select_actor(self, _event=None):
        if self.loading:
            return
        selected = self.actor_tree.selection()
        if not selected or ":" not in selected[0]:
            return
        new_selection = tuple(selected[0].split(":", 1))
        if new_selection == self.actor_selection:
            return
        try:
            self._commit_actor()
            self._show_actor(*new_selection)
        except (ValueError, StopIteration) as exc:
            self.status.configure(text=f"Finish the current actor: {exc}")
            if self.actor_selection:
                self.actor_tree.selection_set(":".join(self.actor_selection))

    def _select_ability(self, _event=None):
        if self.loading:
            return
        selected = self.ability_tree.selection()
        if not selected or selected[0] == self.ability_selection:
            return
        try:
            self._commit_ability()
            self._show_ability(selected[0])
        except (ValueError, StopIteration) as exc:
            self.status.configure(text=f"Finish the current ability: {exc}")
            if self.ability_selection:
                self.ability_tree.selection_set(self.ability_selection)

    def _actor_changed(self):
        if self.loading:
            return
        try:
            self._commit_actor()
        except (ValueError, TypeError):
            pass
        self._inputs_changed()

    def _ability_changed(self):
        if self.loading:
            return
        try:
            self._commit_ability()
        except (ValueError, TypeError):
            pass
        self._inputs_changed()

    def _inputs_changed(self):
        if self.loading:
            return
        self.modified = True
        self.revision += 1
        self._update_title()
        if self._preview_after:
            self.after_cancel(self._preview_after)
        self._preview_after = self.after(200, self._update_preview)

    def _sync_inputs(self):
        self._commit_actor()
        self._commit_ability()
        self.session["rules"], self.session["curves"] = self.rules_editor.get_data()
        self.session["matrix"] = self.matrix_editor.get_data()
        for key, variable in self.run_vars.items():
            self.session["run"][key] = number(variable.get(), key.capitalize(), key != "horizon")
        model.validate_session(self.session)
        return copy.deepcopy(self.session)

    def _update_preview(self):
        self._preview_after = None
        try:
            snapshot = self._sync_inputs()
            self.actor_editor.refresh_values(self.session["rules"])
            count = model.estimate_matrix_size(snapshot)
            total = count * snapshot["run"]["trials"]
            text = f"{count:,} matchups × {snapshot['run']['trials']:,} trials = {total:,} fights. Maximum {snapshot['run']['horizon']:g} seconds per fight."
            self.matrix_editor.preview.configure(text=text)
            if not self._busy():
                self.status.configure(text=text)
        except (ValueError, TypeError, KeyError) as exc:
            self.matrix_editor.preview.configure(text=f"Finish editing: {exc}")
            if not self._busy():
                self.status.configure(text=f"Finish editing: {exc}")

    def _tab_changed(self, _event=None):
        if self.loading or not hasattr(self, "matrix_editor"):
            return
        try:
            self._commit_actor()
            self._commit_ability()
            self.session["rules"], self.session["curves"] = self.rules_editor.get_data()
            if self.tabs.index(self.tabs.select()) == 3:
                try:
                    self.session["matrix"] = self.matrix_editor.get_data()
                except ValueError:
                    pass
                self.matrix_editor.refresh_profiles(self.session)
            if self.tabs.index(self.tabs.select()) == 0:
                self.actor_editor.refresh_values(self.session["rules"])
        except (ValueError, TypeError) as exc:
            if hasattr(self, "status"):
                self.status.configure(text=f"Finish editing: {exc}")

    def _update_title(self):
        name = self.path.name if self.path else self.session.get("name", "Experiment")
        self.root.title(f"{'* ' if self.modified else ''}{name} — Legacy Combat Lab (pre-2.0)")

    def _busy(self):
        return self.job_active

    def add_actor(self, group):
        try:
            self._commit_actor()
        except ValueError as exc:
            messagebox.showerror("Finish actor", str(exc), parent=self.root)
            return
        actor = {"id": uuid.uuid4().hex[:12], "name": "New player" if group == "players" else "New enemy",
                 "level": 1, "allocations": {key: 0 for key in ("strength", "dexterity", "intellect", "vitality")},
                 "base_values": {}, "modifiers": [], "tags": []}
        self.session[group].append(actor)
        self._refresh_actor_tree()
        self._show_actor(group, actor["id"])
        self._refresh_matrix_profiles()
        self._inputs_changed()

    def duplicate_actor(self):
        if not self.actor_selection:
            return
        try:
            self._commit_actor()
        except ValueError as exc:
            messagebox.showerror("Finish actor", str(exc), parent=self.root)
            return
        group, actor_id = self.actor_selection
        clone = copy.deepcopy(self._find_actor(group, actor_id))
        clone["id"] = uuid.uuid4().hex[:12]
        clone["name"] += " copy"
        self.session[group].append(clone)
        self._refresh_actor_tree()
        self._show_actor(group, clone["id"])
        self._refresh_matrix_profiles()
        self._inputs_changed()

    def delete_actor(self):
        if not self.actor_selection:
            return
        group, actor_id = self.actor_selection
        self.session[group] = [actor for actor in self.session[group] if actor["id"] != actor_id]
        self.session["matrix"]["player_ids" if group == "players" else "enemy_ids"] = []
        self.actor_selection = None
        self.actor_editor.actor = None
        self._refresh_actor_tree()
        remaining = [(kind, actor["id"]) for kind in ("players", "enemies") for actor in self.session[kind]]
        if remaining:
            self._show_actor(*remaining[0])
        self._refresh_matrix_profiles()
        self._inputs_changed()

    def add_ability(self):
        try:
            self._commit_ability()
        except ValueError as exc:
            messagebox.showerror("Finish ability", str(exc), parent=self.root)
            return
        ability = {"id": uuid.uuid4().hex[:12], "name": "New ability", "kind": "spell", "tags": ["Ability.Spell"],
                   "required_tags": [], "blocked_tags": ["State.Dead", "State.Stunned", "State.Silenced", "State.PerformingAction"],
                   "base_duration": 0.8, "minimum_duration": 0.4, "release_fraction": 0.4,
                   "travel_time": 0.0, "cooldown": 1.5, "cost_attribute": -1, "cost_amount": 0.0,
                   "effects": [new_effect()]}
        self.session["abilities"].append(ability)
        self._refresh_ability_tree()
        self._show_ability(ability["id"])
        self._refresh_matrix_profiles()
        self._inputs_changed()

    def duplicate_ability(self):
        if not self.ability_selection:
            return
        try:
            self._commit_ability()
        except ValueError as exc:
            messagebox.showerror("Finish ability", str(exc), parent=self.root)
            return
        clone = copy.deepcopy(next(a for a in self.session["abilities"] if a["id"] == self.ability_selection))
        clone["id"] = uuid.uuid4().hex[:12]
        clone["name"] += " copy"
        self.session["abilities"].append(clone)
        self._refresh_ability_tree()
        self._show_ability(clone["id"])
        self._refresh_matrix_profiles()
        self._inputs_changed()

    def delete_ability(self):
        self.session["abilities"] = [a for a in self.session["abilities"] if a["id"] != self.ability_selection]
        self.session["matrix"]["ability_ids"] = []
        self.ability_selection = None
        self.ability_editor.ability = None
        self._refresh_ability_tree()
        if self.session["abilities"]:
            self._show_ability(self.session["abilities"][0]["id"])
        self._refresh_matrix_profiles()
        self._inputs_changed()

    def _refresh_matrix_profiles(self):
        self.matrix_editor.refresh_profiles(self.session)

    def new_session(self):
        if self._busy() or not self._confirm_discard():
            return
        self.path = None
        self._load_into_forms(model.default_session())

    def open_session(self):
        if self._busy() or not self._confirm_discard():
            return
        path = filedialog.askopenfilename(parent=self.root, title="Open combat experiment",
                                          filetypes=[("Combat experiment", "*.json"), ("All files", "*.*")])
        if path:
            try:
                session = load_experiment(path)
                document = json.loads(Path(path).read_text(encoding="utf-8-sig"))
                is_run = isinstance(document, dict) and "scenario_snapshot" in document and isinstance(document.get("cells"), list)
                self.path = None if is_run else Path(path)
                self._load_into_forms(session)
                if is_run:
                    self.last_result = document
                    self.results.set_results(document)
                    self.tabs.select(4)
                    self.status.configure(text="Loaded saved results and their original input snapshot. Save creates a separate experiment file.")
            except (ValueError, OSError, KeyError, TypeError) as exc:
                messagebox.showerror("Cannot open experiment", str(exc), parent=self.root)

    def save_session(self, save_as=False):
        try:
            snapshot = self._sync_inputs()
        except (ValueError, TypeError, KeyError) as exc:
            messagebox.showerror("Cannot save experiment", str(exc), parent=self.root)
            return False
        path = self.path
        if save_as or path is None:
            selected = filedialog.asksaveasfilename(parent=self.root, title="Save combat experiment",
                                                    defaultextension=".json", initialfile="combat_experiment.json",
                                                    filetypes=[("Combat experiment", "*.json")])
            if not selected:
                return False
            path = Path(selected)
        try:
            save_experiment(path, snapshot)
            self.path = path
            self.modified = False
            self._update_title()
            return True
        except (OSError, ValueError) as exc:
            messagebox.showerror("Cannot save experiment", str(exc), parent=self.root)
            return False

    def _confirm_discard(self):
        if not self.modified:
            return True
        answer = messagebox.askyesnocancel("Unsaved experiment", "Save your experiment before continuing?", parent=self.root)
        return self.save_session() if answer else answer is not None

    def import_project(self):
        if self._busy() or not self._confirm_discard():
            return
        self._begin_job("Reading the saved Godot scene and its abilities headlessly…", indeterminate=True)
        self.import_revision = self.revision
        job_id = self.job_id
        def work():
            try:
                imported = model.import_game()
                self.messages.put((job_id, {"type": "imported", "session": imported}))
            except Exception as exc:
                self.messages.put((job_id, {"type": "error", "message": str(exc)}))
        self.worker = threading.Thread(target=work, daemon=True)
        self.worker.start()

    def start_run(self):
        if self._busy():
            return
        try:
            snapshot = self._sync_inputs()
        except (ValueError, TypeError, KeyError) as exc:
            messagebox.showerror("Cannot run matrix", str(exc), parent=self.root)
            return
        self.results.clear()
        self.last_result = None
        self.tabs.select(4)
        self._begin_job(f"Starting {model.estimate_matrix_size(snapshot):,} matchups…")
        job_id = self.job_id
        def work():
            try:
                result = engine.run_matrix(snapshot,
                                           progress=lambda event: self.messages.put((job_id, event)),
                                           cancel=self.cancel_event)
                self.messages.put((job_id, {"type": "done", "result": result}))
            except Exception as exc:
                self.messages.put((job_id, {"type": "error", "message": str(exc)}))
        self.worker = threading.Thread(target=work, daemon=True)
        self.worker.start()

    def _begin_job(self, text, indeterminate=False):
        self.job_id += 1
        self.job_active = True
        self.cancel_event = threading.Event()
        self.started_at = time.perf_counter()
        self.run_button.configure(state="disabled")
        self.cancel_button.configure(state="normal")
        self.progress.configure(mode="indeterminate" if indeterminate else "determinate", value=0)
        if indeterminate:
            self.progress.start(12)
        self.status.configure(text=text)

    def cancel_run(self):
        self.cancel_event.set()
        self.cancel_button.configure(state="disabled")
        self.status.configure(text="Cancelling; completed results will be retained…")

    def _finish_job(self):
        self.job_active = False
        self.progress.stop()
        self.progress.configure(mode="determinate")
        self.run_button.configure(state="normal")
        self.cancel_button.configure(state="disabled")

    def _poll_messages(self):
        for _ in range(300):
            try:
                job_id, event = self.messages.get_nowait()
            except queue.Empty:
                break
            if job_id != self.job_id:
                continue
            kind = event.get("type")
            if kind == "progress":
                completed = event.get("completed_trials", 0)
                total = event.get("total_trials", 1)
                fraction = completed / total if total else 0
                self.progress.configure(value=min(100, max(0, 100 * fraction)))
                elapsed = time.perf_counter() - self.started_at
                self.status.configure(text=f"{completed:,} / {total:,} fights · {100 * fraction:.1f}% · {elapsed:.1f}s elapsed")
            elif kind == "cell":
                self.results.add_result(event["result"])
            elif kind == "done":
                self.last_result = event["result"]
                self.results.set_results(self.last_result)
                self._finish_job()
                count = len(self.last_result.get("cells", []))
                completed = self.last_result.get("completed_trials", 0)
                elapsed = self.last_result.get("elapsed_seconds", time.perf_counter() - self.started_at)
                cancelled = self.last_result.get("status") == "cancelled"
                self.progress.configure(value=100 if not cancelled else self.progress["value"])
                self.status.configure(text=f"{'Cancelled' if cancelled else 'Complete'} · {count:,} result rows · {completed:,} fights · {elapsed:.2f}s. TTK percentiles include kills only; check kill rate and timeouts.")
            elif kind == "imported":
                self._finish_job()
                if not self.cancel_event.is_set():
                    if self.revision != self.import_revision and not self._confirm_discard():
                        self.status.configure(text="Saved project data was read; your current experiment was kept.")
                        continue
                    self.path = None
                    self._load_into_forms(event["session"])
                    self.status.configure(text="Loaded saved project actors and abilities. Unsaved edits in a running playground are not included.")
                else:
                    self.status.configure(text="Import cancelled.")
            elif kind == "error":
                self._finish_job()
                self.status.configure(text="Stopped: " + event["message"])
                messagebox.showerror("Combat Lab", event["message"], parent=self.root)
        self.root.after(75, self._poll_messages)

    def save_csv(self):
        rows = self.results.export_rows()
        if not rows:
            self.status.configure(text="Run a matrix before exporting results.")
            return
        path = filedialog.asksaveasfilename(parent=self.root, title="Export combat results", defaultextension=".csv",
                                           initialfile="combat_results.csv", filetypes=[("CSV table", "*.csv")])
        if path:
            try:
                export_csv(path, rows)
            except (OSError, ValueError, TypeError) as exc:
                messagebox.showerror("Cannot export results", str(exc), parent=self.root)

    def save_run(self):
        if self.last_result is None:
            self.status.configure(text="Complete or cancel a run before saving its result snapshot.")
            return
        path = filedialog.asksaveasfilename(parent=self.root, title="Save run and original inputs", defaultextension=".json",
                                           initialfile="combat_run.json", filetypes=[("Run snapshot", "*.json")])
        if path:
            try:
                ensure_output_path(path, ".json").write_text(json.dumps(self.last_result, indent=2, allow_nan=False) + "\n", encoding="utf-8")
            except (OSError, ValueError, TypeError) as exc:
                messagebox.showerror("Cannot save run", str(exc), parent=self.root)

    def close(self):
        if not self._confirm_discard():
            return
        self.cancel_event.set()
        self.root.destroy()


def main():
    root = tk.Tk()
    CombatLab(root)
    root.mainloop()


if __name__ == "__main__":
    main()
