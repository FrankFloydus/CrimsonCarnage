"""Phase timeline and block library for the Ability Editor."""

from copy import deepcopy
from dataclasses import dataclass
from uuid import uuid4

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QComboBox,
    QDoubleSpinBox,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSpinBox,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

if __package__:
    from .tag_widgets import choose_tag
else:
    from tag_widgets import choose_tag


PHASES = {
    "cast": ("On cast start", "When the ability starts"),
    "contact": ("On contact", "When delivery reaches an eligible target"),
    "payload": ("Delivered hit", "One shared hit check"),
    "hit": ("After confirmed hit", "Runs even if damage is fully absorbed"),
    "dealt": ("After damage dealt", "Requires actual Health loss"),
    "release": ("On input released", "When the input is released"),
}
DEFAULT_PHASES = ("contact", "payload", "hit", "dealt")
EXTRA_PHASES = ("cast", "release")
ACTION_PHASES = ("cast", "contact", "hit", "dealt", "release")
SCHOOLS = ("Physical", "Fire", "Cold", "Lightning", "Necrotic", "Void")


@dataclass(frozen=True)
class _Block:
    label: str
    phases: tuple[str, ...]
    defaults: dict


BLOCKS = {
    "damage": _Block("Deal damage", ("payload",), {"amount": 20.0, "school": "Cold"}),
    "dot": _Block("Damage over time", ("payload",), {
        "amount": 20.0, "school": "Cold", "duration": 4.0, "period": 1.0,
    }),
    "slow": _Block("Slow movement", ("payload", "hit", "dealt"), {"amount": 50.0, "duration": 4.0}),
    "stun": _Block("Stun", ("payload", "hit", "dealt"), {"duration": 4.0}),
    "silence": _Block("Silence", ("payload", "hit", "dealt"), {"duration": 4.0}),
    "heal": _Block("Heal", ACTION_PHASES, {"amount": 20.0, "recipient": "Caster"}),
    "restore": _Block("Restore resource", ACTION_PHASES, {
        "amount": 20.0, "pool": "Mana", "recipient": "Caster",
    }),
    "leech": _Block("Lifesteal", ("dealt",), {"amount": 20.0}),
    "shield": _Block("Absorb shield", ACTION_PHASES, {
        "amount": 20.0, "duration": 4.0, "recipient": "Caster",
    }),
    "reflect": _Block("Reflect spell", ACTION_PHASES, {"duration": 4.0, "recipient": "Caster"}),
    "link": _Block("Link target", ("contact", "hit", "dealt"), {"duration": 10.0}),
    "dispel": _Block("Cleanse / dispel", ("cast", "contact", "release"), {"tag": "", "amount": 1}),
    "ref": _Block("Apply saved effect", tuple(PHASES), {"path": ""}),
}
GROUPS = {
    "Offense": ("damage", "dot"),
    "Control": ("slow", "stun", "silence"),
    "Support": ("heal", "restore", "leech"),
    "Defense": ("shield", "reflect"),
    "World": ("link", "summon", "teleport", "dispel"),
    "Project": ("ref",),
}
UNAVAILABLE = {"summon": "Summon actor", "teleport": "Teleport"}


def _recipients(phase: str) -> tuple[str, ...]:
    if phase in ("cast", "release"):
        return ("Caster",)
    if phase == "contact":
        return ("Target",)
    return ("Caster", "Target")


def _plain_label(text: str = "") -> QLabel:
    label = QLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    return label


def _clear(layout: QVBoxLayout) -> None:
    while layout.count():
        item = layout.takeAt(0)
        if (widget := item.widget()) is not None:
            widget.hide()
            widget.deleteLater()


class AbilityBlockComposer(QWidget):
    """Edit supported ability actions while preserving opaque Godot rows."""

    changed = Signal()

    def __init__(self) -> None:
        super().__init__()
        self._blocks: list[dict] = []
        self._effects: dict[str, str] = {}
        self._tags: list[dict] = []
        self._capabilities: dict = {}
        self._extra_phases: set[str] = set()
        self._phase = "contact"
        self._editing: str | None = None

        self._outcome = QComboBox()
        for label, key in (("Editing", ""), ("Miss", "miss"), ("Fully absorbed", "absorbed"), ("Damage dealt", "dealt")):
            self._outcome.addItem(label, key)
        self._outcome.setToolTip("Illustrates the phase timing for each outcome.")
        outcome_label = QLabel("Example outcome")
        outcome_label.setBuddy(self._outcome)
        timeline_head = QHBoxLayout()
        timeline_head.addWidget(QLabel("What happens"), 1)
        timeline_head.addWidget(outcome_label)
        timeline_head.addWidget(self._outcome)
        timeline = QWidget()
        timeline_body = QVBoxLayout(timeline)
        timeline_body.setContentsMargins(0, 0, 0, 0)
        timeline_body.addLayout(timeline_head)
        self._timeline = QVBoxLayout()
        timeline_body.addLayout(self._timeline)
        self._add_timing = QComboBox()
        self._add_timing.setAccessibleName("Add timing")
        timeline_body.addWidget(self._add_timing, 0, Qt.AlignmentFlag.AlignLeft)
        timeline_body.addStretch()

        library = QGroupBox("Block Library")
        self._library = QVBoxLayout(library)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(timeline, 3)
        layout.addWidget(library, 1, Qt.AlignmentFlag.AlignTop)
        self._outcome.currentIndexChanged.connect(self._render_timeline)
        self._add_timing.activated.connect(self._show_timing)
        self._render()

    def load(self, blocks: list[dict], effects: list[dict], capabilities: dict | None = None) -> None:
        self._blocks = deepcopy(blocks)
        self._effects = {effect["path"]: effect["name"] for effect in effects if effect.get("path")}
        self._capabilities = capabilities or {}
        self._tags = self._capabilities.get("tags", [])
        self._extra_phases = {row["phase"] for row in blocks if row["phase"] not in DEFAULT_PHASES}
        self._phase = "contact"
        self._editing = None
        self._outcome.setCurrentIndex(0)
        self._render()

    def blocks(self) -> list[dict]:
        return deepcopy(self._blocks)

    def set_busy(self, busy: bool) -> None:
        self.setEnabled(not busy)

    def _show_timing(self, index: int) -> None:
        phase = self._add_timing.itemData(index)
        if phase:
            self._extra_phases.add(phase)
            self._select_phase(phase)

    def _select_phase(self, phase: str) -> None:
        self._phase = phase
        self._render()

    def _render(self) -> None:
        self._render_timeline()
        self._render_library()

    def _render_timeline(self) -> None:
        _clear(self._timeline)
        for phase in PHASES:
            if phase == "payload" or (phase in EXTRA_PHASES and phase not in self._extra_phases):
                continue
            self._timeline.addWidget(self._phase_widget(phase))
        for phase in sorted(self._extra_phases.difference(PHASES)):
            self._timeline.addWidget(self._phase_widget(phase))
        self._add_timing.clear()
        self._add_timing.addItem("Add timing…")
        for phase in EXTRA_PHASES:
            if phase not in self._extra_phases:
                self._add_timing.addItem(PHASES[phase][0], phase)
        self._add_timing.setVisible(self._add_timing.count() > 1)
        self._add_timing.setEnabled(not self._capabilities.get("locked"))

    def _phase_widget(self, phase: str) -> QWidget:
        section = QGroupBox()
        layout = QVBoxLayout(section)
        title, note = PHASES.get(phase, (phase, "Preserved from the Godot resource"))
        header = QHBoxLayout()
        target = QPushButton(title)
        target.setCheckable(True)
        target.setChecked(phase == self._phase)
        target.setEnabled(phase in PHASES)
        target.clicked.connect(lambda: self._select_phase(phase))
        header.addWidget(target, 0)
        header.addWidget(_plain_label(note + self._example(phase)), 1)
        layout.addLayout(header)
        rows = [row for row in self._blocks if row["phase"] == phase]
        for index, row in enumerate(rows):
            up = index > 0 and self._editable(rows[index - 1])
            down = index + 1 < len(rows) and self._editable(rows[index + 1])
            layout.addWidget(self._row_widget(row, up, down))
        if phase == "contact":
            layout.addWidget(self._phase_widget("payload"))
        if not rows and phase != "contact":
            layout.addWidget(_plain_label("No blocks"))
        return section

    def _example(self, phase: str) -> str:
        outcome = self._outcome.currentData()
        if not outcome:
            return ""
        if phase == "payload":
            return {"miss": " · Missed", "absorbed": " · Fully absorbed", "dealt": " · Hit"}[outcome]
        if phase == "contact":
            return " · Runs"
        if phase == "hit":
            return " · Skipped" if outcome == "miss" else " · Runs"
        if phase == "dealt":
            return " · Runs" if outcome == "dealt" else " · Skipped"
        return ""

    def _row_widget(self, row: dict, up: bool, down: bool) -> QWidget:
        body = QWidget()
        layout = QVBoxLayout(body)
        layout.setContentsMargins(0, 0, 0, 0)
        header = QHBoxLayout()
        label = row["label"]
        editable = self._editable(row)
        selected = editable and self._editing == row["key"]
        title = QPushButton(label)
        title.setFlat(True)
        title.setCheckable(True)
        title.setChecked(selected)
        title.setEnabled(editable)
        title.clicked.connect(lambda: self._edit_row(row["key"]))
        header.addWidget(title)
        summary = _plain_label(row.get("summary", ""))
        header.addWidget(summary, 1)
        if editable:
            for text, tip, enabled, handler in (
                ("↑", f"Move {label} up", up, lambda: self._reorder(row, -1)),
                ("↓", f"Move {label} down", down, lambda: self._reorder(row, 1)),
                ("×", f"Remove {label}", True, lambda: self._remove(row)),
            ):
                action = QToolButton()
                action.setText(text)
                action.setToolTip(tip)
                action.setAccessibleName(tip)
                action.setEnabled(enabled)
                action.clicked.connect(handler)
                header.addWidget(action)
        else:
            header.addWidget(_plain_label("Edit in Godot"))
        layout.addLayout(header)
        if selected:
            layout.addLayout(self._detail_form(row, summary))
        return body

    def _editable(self, row: dict) -> bool:
        return not self._capabilities.get("locked") and bool(row.get("editable")) and row["kind"] in BLOCKS

    def _edit_row(self, key: str) -> None:
        self._editing = None if self._editing == key else key
        self._render_timeline()

    def _detail_form(self, row: dict, summary: QLabel) -> QFormLayout:
        kind = row["kind"]
        spec = BLOCKS[kind]
        form = QFormLayout()
        form.setContentsMargins(10, 4, 0, 5)
        for key, default in spec.defaults.items():
            if key == "recipient":
                default = _recipients(row["phase"])[0]
            value = row["values"].get(key, default)
            label, control = self._field(row, key, value, summary)
            form.addRow(label, control)
        if len(spec.phases) > 1:
            phases = QComboBox()
            for phase, (label, _) in PHASES.items():
                if phase in spec.phases:
                    phases.addItem(label, phase)
            phases.setCurrentIndex(phases.findData(row["phase"]))
            phases.activated.connect(lambda index: self._move_phase(row, phases.itemData(index)))
            form.addRow("Run in", phases)
        return form

    def _field(self, row: dict, key: str, value, summary: QLabel) -> tuple[str, QWidget]:
        kind = row["kind"]
        if key == "tag":
            button = QPushButton(str(value or "Choose tag…"))
            button.setEnabled(bool(self._tags))
            button.clicked.connect(lambda: self._pick_tag(row, button, summary))
            return "Effect tag", button
        choices = {
            "path": ("Effect", [("Choose effect…", ""), *sorted(
                ((name, path) for path, name in self._effects.items()), key=lambda item: item[0].casefold(),
            )]),
            "school": ("Damage school", [(school, school) for school in SCHOOLS]),
            "pool": ("Resource", [("Mana", "Mana"), ("Stamina", "Stamina")]),
            "recipient": ("Recipient", [(name, name) for name in _recipients(row["phase"])]),
        }
        if key in choices:
            label, options = choices[key]
            combo = QComboBox()
            for name, option in options:
                combo.addItem(name, option)
            if combo.findData(value) < 0:
                combo.addItem(str(value), value)
            combo.setCurrentIndex(combo.findData(value))
            combo.activated.connect(lambda index: self._set_value(row, key, combo.itemData(index), summary))
            return label, combo
        if kind == "dispel" and key == "amount":
            count = QSpinBox()
            count.setRange(0, 2147483647)
            count.setSpecialValueText("All matches")
            count.setValue(int(value))
            count.valueChanged.connect(lambda current: self._set_value(row, key, current, summary))
            return "Maximum effects removed", count
        labels = {
            "amount": {"slow": "Slow (%)", "leech": "Damage returned (%)"}.get(kind, "Amount"),
            "duration": "Duration (s)",
            "period": "Tick interval (s)",
        }
        number = QDoubleSpinBox()
        number.setDecimals(4)
        positive = key in ("duration", "period") or (kind == "shield" and key == "amount")
        minimum = 0.0001 if positive else 0
        maximum = 100 if kind == "slow" and key == "amount" else 1000000000
        number.setRange(minimum, maximum)
        number.setKeyboardTracking(False)
        number.setValue(float(value))
        number.valueChanged.connect(lambda current: self._set_value(row, key, current, summary))
        return labels[key], number

    def _pick_tag(self, row: dict, button: QPushButton, summary: QLabel) -> None:
        tag = choose_tag(self, self._tags, "Select an effect tag")
        if tag is not None:
            button.setText(tag)
            self._set_value(row, "tag", tag, summary)

    def _set_value(self, row: dict, key: str, value, label: QLabel) -> None:
        if row["values"].get(key) == value:
            return
        row["values"][key] = value
        row["summary"] = self._summary(row)
        label.setText(row["summary"])
        self.changed.emit()

    def _render_library(self) -> None:
        _clear(self._library)
        title = PHASES.get(self._phase, (self._phase, ""))[0]
        self._library.addWidget(_plain_label(f"Selected timing · {title}"))
        for group, kinds in GROUPS.items():
            self._library.addWidget(_plain_label(group))
            for kind in kinds:
                spec = BLOCKS.get(kind)
                label = spec.label if spec else UNAVAILABLE[kind]
                button = QPushButton(f"+ {label}")
                button.setAccessibleName(f"Add {label}")
                reason = self._unavailable_reason(kind)
                button.setEnabled(not reason)
                button.setToolTip(reason)
                button.clicked.connect(lambda _checked=False, kind=kind: self._add(kind))
                self._library.addWidget(button)

    def _destination(self, kind: str) -> str:
        phases = BLOCKS[kind].phases
        if self._phase in phases:
            return self._phase
        if self._phase == "contact" and "payload" in phases:
            return "payload"
        return ""

    def _unavailable_reason(self, kind: str) -> str:
        if self._capabilities.get("locked"):
            return "Edit this shared or custom execution in Godot."
        if kind not in BLOCKS:
            return "This block requires a gameplay adapter in Godot."
        allowed = self._capabilities.get("blocks")
        if isinstance(allowed, list) and all(isinstance(value, str) for value in allowed) and kind not in allowed:
            return "This block is unavailable for this ability."
        if not self._destination(kind):
            timings = ", ".join(PHASES[phase][0] for phase in BLOCKS[kind].phases)
            return f"Available at {timings.lower()}."
        if kind == "ref" and not self._effects:
            return "The project has no saved effects to select."
        if kind == "dispel" and not self._tags:
            return "Register an effect tag before adding this block."
        return ""

    def _add(self, kind: str) -> None:
        if self._unavailable_reason(kind):
            return
        spec = BLOCKS[kind]
        row = {
            "key": f"new:{uuid4().hex}",
            "phase": self._destination(kind),
            "kind": kind,
            "label": spec.label,
            "editable": True,
            "values": deepcopy(spec.defaults),
        }
        if "recipient" in row["values"]:
            row["values"]["recipient"] = _recipients(row["phase"])[0]
        row["summary"] = self._summary(row)
        self._blocks.append(row)
        self._editing = row["key"]
        self._render_timeline()
        self.changed.emit()

    def _move_phase(self, row: dict, phase: str) -> None:
        if phase == row["phase"]:
            return
        row["phase"] = phase
        recipients = _recipients(phase)
        if "recipient" in BLOCKS[row["kind"]].defaults and row["values"].get("recipient") not in recipients:
            row["values"]["recipient"] = recipients[0]
        row["summary"] = self._summary(row)
        if phase in EXTRA_PHASES:
            self._extra_phases.add(phase)
        self._blocks.remove(row)
        self._blocks.append(row)
        self._phase = phase
        self._render()
        self.changed.emit()

    def _remove(self, row: dict) -> None:
        self._blocks.remove(row)
        if self._editing == row["key"]:
            self._editing = None
        self._render_timeline()
        self.changed.emit()

    def _reorder(self, row: dict, direction: int) -> None:
        phase_rows = [item for item in self._blocks if item["phase"] == row["phase"]]
        destination = phase_rows.index(row) + direction
        if not 0 <= destination < len(phase_rows) or not self._editable(phase_rows[destination]):
            return
        source = self._blocks.index(row)
        target = self._blocks.index(phase_rows[destination])
        self._blocks[source], self._blocks[target] = self._blocks[target], self._blocks[source]
        self._render_timeline()
        self.changed.emit()

    def _summary(self, row: dict) -> str:
        values = row["values"]
        kind = row["kind"]
        amount = f"{values.get('amount', 0):g}"
        duration = f"{values.get('duration', 0):g} s"
        recipient = values.get("recipient", "")
        if kind == "ref":
            path = values.get("path", "")
            return self._effects.get(path, path) if path else "Choose a saved effect"
        if kind == "damage":
            return f"{amount} {values['school']} damage"
        if kind == "dot":
            return f"{amount} {values['school']} per tick for {duration}"
        if kind == "slow":
            return f"{amount}% slower for {duration}"
        if kind == "heal":
            return f"Restore {amount} Health to {recipient}"
        if kind == "restore":
            return f"Restore {amount} {values['pool']} to {recipient}"
        if kind == "leech":
            return f"Heal for {amount}% of damage dealt"
        if kind == "shield":
            return f"Absorb {amount} damage on {recipient} for {duration}"
        if kind == "reflect":
            return f"Reflect spells on {recipient} for {duration}"
        if kind == "link":
            return f"Remember the target for {duration}"
        if kind == "dispel":
            if not values["tag"]:
                return "Choose an effect tag"
            count = "all" if not values["amount"] else f"up to {amount}"
            return f"Remove {count} matching {values['tag']}"
        return duration
