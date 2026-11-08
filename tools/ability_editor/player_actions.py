"""Author starting ability assignments for the linked player's Input Map actions."""

import json
from pathlib import Path
import re

from PySide6.QtCore import QSize, Qt, Signal
from PySide6.QtWidgets import (
    QAbstractItemView, QHBoxLayout, QHeaderView, QLabel, QPushButton, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)

if __package__:
    from .definition_picker import pick_ability, project_icon
    from .json_project import ABILITY_SLOT_PREFIX, JsonProject
else:
    from definition_picker import pick_ability, project_icon
    from json_project import ABILITY_SLOT_PREFIX, JsonProject


FIXED_ACTIONS = {
    "move_forward": "Move Forward",
    "move_backward": "Move Backward",
    "move_left": "Move Left",
    "move_right": "Move Right",
    "jump": "Jump",
    "sprint": "Sprint",
    "walk": "Walk",
    "crouch": "Crouch",
}
SPECIAL_KEY_FLAG = 1 << 22
SPECIAL_KEYS = (
    "", "Esc", "Tab", "Backtab", "Backspace", "Enter", "Numpad Enter", "Insert", "Delete",
    "Pause", "Print Screen", "SysRq", "Clear", "Home", "End", "Left Arrow", "Up Arrow",
    "Right Arrow", "Down Arrow", "Page Up", "Page Down", "Shift", "Ctrl", "Meta", "Alt",
    "Caps Lock", "Num Lock", "Scroll Lock",
)
MOUSE_BUTTONS = (
    "", "Left Mouse", "Right Mouse", "Middle Mouse", "Wheel Up", "Wheel Down", "Wheel Left",
    "Wheel Right", "Mouse Button 4", "Mouse Button 5",
)


def _key_name(code: int, location: int) -> str:
    if code == 32:
        return "Space"
    if code & SPECIAL_KEY_FLAG:
        special = code & ~SPECIAL_KEY_FLAG
        if 0 < special < len(SPECIAL_KEYS):
            name = SPECIAL_KEYS[special]
            if name in {"Shift", "Ctrl", "Meta", "Alt"} and location in {1, 2}:
                return f"{'Left' if location == 1 else 'Right'} {name}"
            return name
        if 0x1C <= special <= 0x3E:
            return f"F{special - 0x1B}"
        if 0x86 <= special <= 0x8F:
            return f"Numpad {special - 0x86}"
    elif 32 < code <= 0x10FFFF and chr(code).isprintable():
        return chr(code)
    return f"Key {code}"


def _binding_label(kind: str, raw_fields: str) -> str:
    fields = dict(re.findall(r'"(\w+)"\s*:\s*(true|false|-?\d+)\b', raw_fields))
    if kind == "Key":
        code = next((int(fields.get(field, "0")) for field in ("physical_keycode", "keycode", "key_label")
                     if fields.get(field, "0") != "0"), 0)
        name = _key_name(code, int(fields.get("location", "0")))
    elif kind == "MouseButton":
        button = int(fields.get("button_index", "0"))
        name = MOUSE_BUTTONS[button] if 0 < button < len(MOUSE_BUTTONS) else f"Mouse Button {button}"
    elif kind == "JoypadButton":
        name = f"Gamepad Button {fields.get('button_index', '0')}"
    elif kind == "JoypadMotion":
        direction = "−" if re.search(r'"axis_value"\s*:\s*-', raw_fields) else "+"
        name = f"Gamepad Axis {fields.get('axis', '0')}{direction}"
    else:
        return re.sub(r"(?<!^)(?=[A-Z])", " ", kind)
    modifiers = [name for name, prop in (("Ctrl", "ctrl"), ("Alt", "alt"), ("Shift", "shift"), ("Meta", "meta"))
                 if fields.get(f"{prop}_pressed") == "true"]
    return "+".join([*modifiers, name])


def _input_actions(root: Path) -> dict[str, str]:
    project = (root / "project.godot").read_text(encoding="utf-8-sig")
    section = re.search(r"(?ms)^\[input\][ \t]*\n(.*?)(?=^\[|\Z)", project)
    if not section:
        return {}
    actions = {}
    for action, data in re.findall(r"(?ms)^[ \t]*(\w+)\s*=\s*\{(.*?)\}[ \t]*(?:\n|\Z)", section[1]):
        events = re.findall(r"(?s)Object\(InputEvent(\w+),\s*(.*?)(?=Object\(|\Z)", data)
        bindings = dict.fromkeys(_binding_label(kind, fields) for kind, fields in events)
        actions[action] = " / ".join(bindings) or "Unbound"
    return actions


def _slot_order(action: str) -> tuple[bool, int, str]:
    suffix = action.removeprefix(ABILITY_SLOT_PREFIX)
    numeric = suffix.isascii() and suffix.isdecimal()
    return not numeric, int(suffix) if numeric else 0, suffix


def _granted_abilities(project: JsonProject) -> list[dict]:
    scene = (project.root / "player/player.tscn").read_text(encoding="utf-8-sig")
    grants = re.search(r"(?ms)^granted_ability_files\s*=\s*Array\[String\]\((\[.*?\])\)[ \t]*$", scene)
    if not grants:
        return []
    entries = {}
    duplicates = set()
    paths = dict.fromkeys(path for path in json.loads(grants[1]) if isinstance(path, str))
    for path in paths:
        if not path.endswith(".ability.json"):
            continue
        try:
            document = project.open(path).data
        except (OSError, ValueError):
            continue
        props = document["resources"][document["root"]]["properties"]
        if props.get("activation_event_tag") or any(
            tag == "Ability.Movement" or tag.startswith("Ability.Movement.")
            for tag in props.get("ability_tags", [])
        ):
            continue
        identity = props["ability_id"]
        icon = props.get("icon")
        if identity in entries:
            duplicates.add(identity)
        entries[identity] = {
            "id": identity, "name": props["display_name"], "path": path,
            "icon": icon.get("$asset", "") if isinstance(icon, dict) else "",
        }
    return [entry for identity, entry in entries.items() if identity not in duplicates]


class PlayerActions(QWidget):
    assignment_saved = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self._project: JsonProject | None = None
        self._assignments: dict[str, int] = {}
        self._abilities: list[dict] = []
        self._revision = ""

        title = QLabel("Player Actions", self)
        font = title.font()
        font.setBold(True)
        font.setPointSize(font.pointSize() + 2)
        title.setFont(font)
        description = QLabel("Choose the starting ability for each slot from the player's grants. Changes save immediately.", self)
        description.setWordWrap(True)
        controls = QLabel("Edit default bindings in Godot under Project Settings → Input Map, then Reload here.", self)
        controls.setProperty("secondary", "true")
        controls.setWordWrap(True)
        self._reload = QPushButton("Reload", self)
        self._reload.setAccessibleName("Reload player actions")
        self._reload.clicked.connect(self.reload)
        heading = QHBoxLayout()
        heading.addWidget(title)
        heading.addStretch(1)
        heading.addWidget(self._reload)
        self._notice = QLabel(self)
        self._notice.setTextFormat(Qt.TextFormat.PlainText)
        self._notice.setWordWrap(True)
        self._notice.hide()

        self._table = QTableWidget(0, 4, self)
        self._table.setAccessibleName("Player actions and starting abilities")
        self._table.setHorizontalHeaderLabels(["Action", "Default bindings", "Starting assignment", ""])
        self._table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self._table.setAlternatingRowColors(True)
        self._table.setIconSize(QSize(22, 22))
        self._table.verticalHeader().hide()
        self._table.verticalHeader().setDefaultSectionSize(34)
        header = self._table.horizontalHeader()
        for index in (0, 1, 3):
            header.setSectionResizeMode(index, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 16, 18, 16)
        layout.addLayout(heading)
        layout.addWidget(description)
        layout.addWidget(controls)
        layout.addWidget(self._notice)
        layout.addWidget(self._table, 1)

    def set_project(self, project: JsonProject | None) -> None:
        self._project = project
        self._reload.setEnabled(project is not None)
        self.reload()

    def reload(self) -> None:
        self._table.setRowCount(0)
        self._show_notice("")
        if self._project is None:
            self._show_notice("Link a Godot project to configure its player actions.")
            return
        try:
            actions = _input_actions(self._project.root)
            self._abilities = _granted_abilities(self._project)
            self._assignments, self._revision = self._project.starting_loadout()
        except (OSError, ValueError) as error:
            self._show_notice(f"Could not read player actions. {error}")
            return
        slots = sorted((name for name in actions if name.startswith(ABILITY_SLOT_PREFIX)), key=_slot_order)
        for action in slots:
            self._add_row(action, action.replace("_", " ").title(), actions[action], is_slot=True)
        for action, label in FIXED_ACTIONS.items():
            if action in actions:
                self._add_row(action, label, actions[action], is_slot=False)
        if not slots:
            self._show_notice("Add an Input Map action named ability_slot_1 to make a slot available here.")
        else:
            missing = self._assignments.keys() - actions.keys()
            if missing:
                self._show_notice("Input Map actions missing for saved assignments. " + ", ".join(sorted(missing)))

    def _add_row(self, action: str, label: str, bindings: str, *, is_slot: bool) -> None:
        row = self._table.rowCount()
        self._table.insertRow(row)
        title = QTableWidgetItem(label)
        title.setToolTip(action)
        self._table.setItem(row, 0, title)
        self._table.setItem(row, 1, QTableWidgetItem(bindings))
        ability_id = self._assignments.get(action) if is_slot else None
        entry = next((entry for entry in self._abilities if entry["id"] == ability_id), None)
        if entry:
            assignment = QTableWidgetItem(project_icon(self._project.root, entry["icon"]),
                                          f"{entry['name']}  ·  #{ability_id}")
        elif ability_id is not None:
            assignment = QTableWidgetItem(f"Unavailable  ·  #{ability_id}")
            assignment.setToolTip("This ability is missing from the player's assignable grants.")
        else:
            assignment = QTableWidgetItem("Empty" if is_slot else f"Player {label.lower()}")
        self._table.setItem(row, 2, assignment)
        if not is_slot:
            return

        commands = QWidget(self._table)
        layout = QHBoxLayout(commands)
        layout.setContentsMargins(5, 2, 5, 2)
        choose = QPushButton("Choose…", commands)
        choose.setAccessibleName(f"Choose ability for {label}")
        choose.clicked.connect(lambda: self._choose(action))
        clear = QPushButton("Clear", commands)
        clear.setAccessibleName(f"Clear starting ability for {label}")
        clear.setEnabled(ability_id is not None)
        clear.clicked.connect(lambda: self._save(action, None))
        layout.addWidget(choose)
        layout.addWidget(clear)
        self._table.setCellWidget(row, 3, commands)

    def _choose(self, action: str) -> None:
        current = self._assignments.get(action)
        identity = pick_ability(self, self._project.root, self._abilities, current)
        if identity is not None and identity != current:
            self._save(action, identity)

    def _save(self, action: str, ability_id: int | None) -> None:
        try:
            if action not in _input_actions(self._project.root):
                raise ValueError("This slot's Input Map action was removed. Reload the workspace.")
            ability_path = None
            if ability_id is not None:
                entry = next((entry for entry in _granted_abilities(self._project) if entry["id"] == ability_id), None)
                if entry is None:
                    raise ValueError("This ability is no longer an assignable grant. Reload the workspace.")
                ability_path = entry["path"]
            self._project.set_starting_assignment(action, ability_path, self._revision)
        except (OSError, ValueError) as error:
            self._show_notice(f"Could not save the starting assignment. {error}")
            return
        self.reload()
        self.assignment_saved.emit(action.replace("_", " ").title())

    def _show_notice(self, message: str) -> None:
        self._notice.setText(message)
        self._notice.setVisible(bool(message))
