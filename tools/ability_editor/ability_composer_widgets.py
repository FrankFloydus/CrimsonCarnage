"""Editor for a saved ability's activation, targeting and behavior blocks."""

from copy import deepcopy

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QKeySequence, QPalette, QShortcut
from PySide6.QtWidgets import (
    QComboBox,
    QDoubleSpinBox,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

if __package__:
    from .ability_block_widgets import AbilityBlockComposer
    from .tag_registry import TagRegistry
    from .tag_widgets import choose_tag
else:
    from ability_block_widgets import AbilityBlockComposer
    from tag_registry import TagRegistry
    from tag_widgets import choose_tag


# Numeric values match the Godot resource enums.
_CAST_MODES = {
    0: "Immediate",
    1: "Timed cast",
    2: "Animation marker",
    3: "Release input",
    4: "Channel",
    5: "Sustained",
}
_DELIVERIES = {
    0: "Direct",
    1: "Hitscan",
    2: "Projectile",
    3: "Area burst",
    4: "Field",
    5: "Aura",
    6: "Trap",
    7: "Beam",
    8: "No delivery",
    9: "Chain",
}
_SIMPLE_DELIVERIES = (0, 1, 2, 3, 8)
_DEFAULT_TARGETING = {0: (0, 0), 1: (2, 1), 2: (3, 1), 3: (4, 0)}
_SHAPES = {
    0: "Caster (self)",
    1: "Selected actor",
    2: "Ray",
    3: "Aim point",
    4: "Sphere",
    5: "Ground disk",
    6: "Cylinder",
    7: "Cone",
    8: "Box",
    9: "Capsule",
}
_ORIGINS = {0: "Caster", 1: "Crosshair", 2: "Cast socket", 3: "Delivery contact"}
_ALLEGIANCES = {0: "Any relationship", 1: "Hostile", 2: "Friendly", 3: "Neutral"}
_POOLS = {0: "Health", 1: "Mana", 2: "Stamina"}
_DEFAULT_DRAFT = {
    "id": 0,
    "name": "",
    "icon": "",
    "tags": [],
    "activation_event": "",
    "cast_mode": 0,
    "cast_duration": 0.0,
    "animation_name": "",
    "release_event": "Event.Combat.ProjectileRelease",
    "channel_period": 1.0,
    "delivery": 2,
    "projectile_scene": "",
    "shape": 3,
    "origin": 1,
    "allegiance": 1,
    "max_range": 100.0,
    "radius": 1.0,
    "cost_pool": 1,
    "cost": 0.0,
    "cooldown": 0.0,
    "cost_editable": True,
    "cooldown_editable": True,
    "settings_editable": True,
    "blocks_editable": True,
    "blocks": [],
}


def _plain_label(text: str = "") -> QLabel:
    label = QLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    return label


class AbilityComposer(QWidget):
    """Edit one draft and hand snapshots to the native-resource bridge."""

    back_requested = Signal()
    check_requested = Signal(object)
    save_requested = Signal(object)

    def __init__(self, tag_registry: TagRegistry) -> None:
        super().__init__()
        self._tag_registry = tag_registry
        self._draft = deepcopy(_DEFAULT_DRAFT)
        self._saved = deepcopy(self._draft)
        self._effects: list[dict] = []
        self._assets: dict = {}
        self._path = ""
        self._controls: dict[str, QWidget] = {}
        self._targeting_by_delivery: dict[int, tuple[int, int]] = {}
        self._busy = False
        self._loading = False

        self._back = QPushButton("Back to Abilities")
        self._back.clicked.connect(self._request_back)
        self._check = QPushButton("Check")
        self._check.clicked.connect(lambda: self._request_validation(self.check_requested))
        self._save = QPushButton("Save Ability")
        self._save.setDefault(True)
        self._save.clicked.connect(lambda: self._request_validation(self.save_requested))
        self._save_shortcut = QShortcut(QKeySequence.StandardKey.Save, self)
        self._save_shortcut.setContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        self._save_shortcut.activated.connect(self._save.click)

        actions = QHBoxLayout()
        actions.addWidget(self._back)
        actions.addStretch()
        actions.addWidget(self._check)
        actions.addWidget(self._save)

        self._title = _plain_label()
        font = self._title.font()
        font.setBold(True)
        font.setPointSizeF(font.pointSizeF() + 3.0)
        self._title.setFont(font)
        self._asset_line = _plain_label()
        title = QVBoxLayout()
        title.addWidget(self._title)
        title.addWidget(self._asset_line)
        self._details = QPushButton("Edit Details")
        self._details.setToolTip("Edit the ability name, icon and tags.")
        self._details.setCheckable(True)
        identity_header = QHBoxLayout()
        identity_header.addLayout(title, 1)
        identity_header.addWidget(self._details, 0, Qt.AlignmentFlag.AlignTop)
        self._identity = self._build_identity()
        self._details.toggled.connect(self._identity.setVisible)

        settings = QHBoxLayout()
        settings.addWidget(self._build_activation(), 1, Qt.AlignmentFlag.AlignTop)
        settings.addWidget(self._build_delivery(), 1, Qt.AlignmentFlag.AlignTop)
        self._blocks = AbilityBlockComposer()
        self._blocks.changed.connect(self._draft_changed)
        self._body = QWidget()
        document = QVBoxLayout(self._body)
        document.setContentsMargins(1, 1, 7, 7)
        document.setSpacing(10)
        document.addLayout(identity_header)
        document.addWidget(self._identity)
        document.addLayout(settings)
        document.addWidget(self._blocks)
        document.addStretch()
        self._scroll = QScrollArea()
        self._scroll.setWidget(self._body)
        self._scroll.setWidgetResizable(True)
        self._scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self._status = _plain_label()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 12, 12, 10)
        layout.setSpacing(8)
        layout.addLayout(actions)
        layout.addWidget(self._scroll, 1)
        layout.addWidget(self._status)

    def load(
        self, draft: dict, path: str, effects: list[dict], assets: dict | None = None
    ) -> None:
        self._loading = True
        self._draft = {**deepcopy(_DEFAULT_DRAFT), **deepcopy(draft)}
        self._path = path
        self._effects = effects
        self._assets = assets or {}
        self._targeting_by_delivery = {
            self._draft["delivery"]: (self._draft["shape"], self._draft["origin"])
        }

        delivery_choices = [(mode, _DELIVERIES[mode]) for mode in _SIMPLE_DELIVERIES]
        loaded_delivery = self._draft["delivery"]
        if loaded_delivery in _DELIVERIES and loaded_delivery not in _SIMPLE_DELIVERIES:
            delivery_choices.append((loaded_delivery, _DELIVERIES[loaded_delivery]))
        self._set_choices("delivery", delivery_choices)
        event_choices = [(entry["name"], entry["name"]) for entry in self._tag_registry.entries]
        self._set_choices("activation_event", [("", "Cast"), *event_choices])
        self._set_choices("icon", [("", "No icon"), *self._path_choices("icons")])
        self._set_choices(
            "projectile_scene", [("", "Choose a projectile scene…"), *self._path_choices("projectiles")]
        )
        for key, widget in self._controls.items():
            value = self._draft[key]
            if isinstance(widget, QComboBox):
                index = widget.findData(value)
                if index < 0:
                    widget.addItem(str(value), value)
                    index = widget.count() - 1
                widget.setCurrentIndex(index)
            elif isinstance(widget, QDoubleSpinBox):
                widget.setValue(float(value or 0.0))
            elif isinstance(widget, QLineEdit):
                widget.setText(value or "")

        self._refresh_tags()
        self._blocks.load(
            self._draft["blocks"], self._effects,
            {
                **self._assets.get("capabilities", {}),
                "tags": self._tag_registry.entries,
                "locked": not self._draft["blocks_editable"],
            },
        )
        self._saved = self.draft()
        self._loading = False
        self._update_title()
        self._update_visibility()
        self._details.setChecked(not bool(self._draft["id"]))
        self._identity.setVisible(self._details.isChecked())
        self._scroll.verticalScrollBar().setValue(0)
        self.set_result("New ability draft" if not self._draft["id"] else "Ready")
        self._refresh_actions()

    def draft(self) -> dict:
        return {**deepcopy(self._draft), "blocks": self._blocks.blocks()}

    def mark_saved(self, draft: dict, path: str) -> None:
        details_open = self._details.isChecked()
        self.load(draft, path, self._effects, self._assets)
        self._details.setChecked(details_open)
        self.set_result(f"Saved {path}")

    def set_busy(self, busy: bool) -> None:
        self._busy = busy
        for widget in (self._body, self._back, self._check):
            widget.setEnabled(not busy)
        self._refresh_actions()

    def set_result(self, message: str, error: bool = False) -> None:
        role = QPalette.ColorRole.BrightText if error else QPalette.ColorRole.WindowText
        self._status.setForegroundRole(role)
        self._status.setText(message)

    def can_leave(self) -> bool:
        if self._busy:
            return False
        if self.draft() == self._saved:
            return True
        answer = QMessageBox.question(
            self, "Discard changes?", "Discard unsaved ability changes?",
            QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Cancel,
        )
        return answer == QMessageBox.StandardButton.Discard

    def _request_back(self) -> None:
        if self.can_leave():
            self.back_requested.emit()

    def _request_validation(self, request) -> None:
        draft = self.draft()
        if not draft["name"].strip():
            self._details.setChecked(True)
            self._focus_field("name", "Enter an ability name.")
            return
        if (draft["settings_editable"] and draft["cast_mode"] != 5
                and draft["delivery"] == 2 and not draft["projectile_scene"]):
            self._focus_field("projectile_scene", "Choose a projectile scene.")
            return
        request.emit(draft)

    def _focus_field(self, key: str, message: str) -> None:
        field = self._controls[key]
        self.set_result(message, True)
        self._scroll.ensureWidgetVisible(field)
        field.setFocus()

    def _build_identity(self) -> QGroupBox:
        group = QGroupBox("Ability details")
        form = QFormLayout(group)
        form.addRow("Name", self._line("name"))
        form.addRow("Icon", self._combo("icon", {}))
        self._tags = QListWidget()
        self._tags.setAccessibleName("Ability tags")
        self._tags.setMaximumHeight(76)
        add = QPushButton("Add Tag")
        add.clicked.connect(self._add_tag)
        self._remove_tag_button = QPushButton("Remove Tag")
        self._remove_tag_button.setEnabled(False)
        self._remove_tag_button.clicked.connect(self._remove_tag)
        self._tags.currentItemChanged.connect(
            lambda current, previous: self._remove_tag_button.setEnabled(current is not None)
        )
        buttons = QHBoxLayout()
        buttons.addWidget(add)
        buttons.addWidget(self._remove_tag_button)
        buttons.addStretch()
        tags = QVBoxLayout()
        tags.addWidget(self._tags)
        tags.addLayout(buttons)
        form.addRow("Gameplay tags", tags)
        return group

    def _build_activation(self) -> QGroupBox:
        group = QGroupBox("Activation")
        self._activation_form = QFormLayout(group)
        self._activation_form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        self._activation_form.addRow("Started by", self._combo("activation_event", {}))
        self._activation_form.addRow("Cast mode", self._combo("cast_mode", _CAST_MODES))
        self._activation_form.addRow("Cast time", self._number("cast_duration", " s"))
        self._activation_form.addRow("Animation", self._line("animation_name"))
        self._activation_form.addRow("Release marker", self._line("release_event"))
        self._activation_form.addRow("Pulse period", self._number("channel_period", " s"))
        self._activation_form.addRow("Cooldown", self._number("cooldown", " s"))
        self._activation_form.addRow("Cost", self._number("cost"))
        self._activation_form.addRow("Uses", self._combo("cost_pool", _POOLS))
        self._cost_notice = _plain_label()
        self._activation_form.addRow(self._cost_notice)
        return group

    def _build_delivery(self) -> QGroupBox:
        group = QGroupBox("Delivery & Targets")
        self._delivery_form = QFormLayout(group)
        self._delivery_form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        self._delivery_form.addRow("How it reaches targets", self._combo("delivery", {}))
        self._delivery_form.addRow("Projectile scene", self._combo("projectile_scene", {}))
        self._delivery_form.addRow("Target shape", self._combo("shape", _SHAPES))
        self._delivery_form.addRow("Who can be affected", self._combo("allegiance", _ALLEGIANCES))
        self._delivery_form.addRow("Origin", self._combo("origin", _ORIGINS))
        self._delivery_form.addRow("Range", self._number("max_range", " m"))
        self._delivery_form.addRow("Radius", self._number("radius", " m"))
        self._controls["origin"].setToolTip("The transform used to aim or center the target query.")
        self._controls["allegiance"].setToolTip("The relationship an actor must have to be eligible.")
        self._delivery_notice = _plain_label()
        self._delivery_form.addRow(self._delivery_notice)
        return group

    def _combo(self, key: str, choices: dict) -> QComboBox:
        widget = QComboBox()
        widget.setObjectName(key)
        widget.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        widget.setMinimumContentsLength(12)
        self._controls[key] = widget
        self._set_choices(key, list(choices.items()))
        widget.currentIndexChanged.connect(lambda index: self._field_changed(key, widget.currentData()))
        return widget

    def _set_choices(self, key: str, choices: list[tuple]) -> None:
        widget = self._controls[key]
        widget.clear()
        for value, text in choices:
            widget.addItem(text, value)

    def _path_choices(self, key: str) -> list[tuple[str, str]]:
        paths = sorted(set(self._assets.get(key, [])), key=str.casefold)
        return [(path, path.removeprefix("res://")) for path in paths if path]

    def _line(self, key: str) -> QLineEdit:
        widget = QLineEdit()
        widget.setObjectName(key)
        self._controls[key] = widget
        widget.textEdited.connect(lambda text: self._field_changed(key, text))
        return widget

    def _number(self, key: str, suffix: str = "") -> QDoubleSpinBox:
        widget = QDoubleSpinBox()
        widget.setObjectName(key)
        widget.setRange(0.0, 1_000_000_000.0)
        widget.setDecimals(3)
        widget.setSingleStep(0.1)
        widget.setSuffix(suffix)
        self._controls[key] = widget
        widget.valueChanged.connect(lambda value: self._field_changed(key, value))
        return widget

    def _field_changed(self, key: str, value) -> None:
        if self._loading or value is None or self._draft[key] == value:
            return
        if key == "delivery":
            self._targeting_by_delivery[self._draft["delivery"]] = (
                self._draft["shape"], self._draft["origin"]
            )
            targeting = self._targeting_by_delivery.get(value, _DEFAULT_TARGETING.get(value))
            if targeting:
                self._draft["shape"], self._draft["origin"] = targeting
                self._loading = True
                for field in ("shape", "origin"):
                    widget = self._controls[field]
                    widget.setCurrentIndex(widget.findData(self._draft[field]))
                self._loading = False
        self._draft[key] = value
        self._update_title()
        self._update_visibility()
        self._draft_changed()

    def _update_visibility(self) -> None:
        cast_mode = self._draft["cast_mode"]
        for key, visible in (
            ("cast_duration", cast_mode in (1, 4)),
            ("animation_name", cast_mode == 2),
            ("release_event", cast_mode == 2),
            ("channel_period", cast_mode == 4),
        ):
            self._activation_form.setRowVisible(self._controls[key], visible)

        settings_editable = self._draft["settings_editable"]
        for key in ("cast_mode", "cast_duration", "animation_name", "release_event", "channel_period",
                    "delivery", "projectile_scene", "shape", "origin", "allegiance", "max_range", "radius"):
            self._controls[key].setEnabled(settings_editable)

        cost_editable = self._draft["cost_editable"]
        cooldown_editable = self._draft["cooldown_editable"]
        for key in ("cost", "cost_pool"):
            self._activation_form.setRowVisible(self._controls[key], cost_editable)
        self._activation_form.setRowVisible(self._controls["cooldown"], cooldown_editable)
        notices = []
        if not cost_editable:
            notices.append("This ability uses a custom cost. Its saved setup is preserved.")
        if not cooldown_editable:
            notices.append("This ability uses a custom charge pool. Its saved setup is preserved.")
        self._cost_notice.setText(" ".join(notices))
        self._activation_form.setRowVisible(self._cost_notice, bool(notices))

        delivery = self._draft["delivery"]
        shape = self._draft["shape"]
        active = cast_mode != 5
        has_targets = active and delivery != 8
        origin_label = self._delivery_form.labelForField(self._controls["origin"])
        origin_label.setText("Aim origin" if delivery == 2 else "Origin")
        for key, visible in (
            ("delivery", active),
            ("projectile_scene", active and delivery == 2),
            ("shape", has_targets),
            ("origin", has_targets and shape != 0),
            ("allegiance", has_targets and (shape != 0 or delivery == 2)),
            ("max_range", has_targets and shape in (1, 2, 3)),
            ("radius", has_targets and shape in (4, 5, 6, 7, 9)),
        ):
            self._delivery_form.setRowVisible(self._controls[key], visible)
        notice = ""
        if not settings_editable:
            notice = "This ability has linked or specialized execution settings. Edit them in Godot."
        elif not active:
            notice = "Sustained abilities stay active until one of their events ends the cast."
        elif delivery not in _SIMPLE_DELIVERIES:
            notice = "Specialized delivery settings remain in the saved Godot resource."
        self._delivery_notice.setText(notice)
        self._delivery_form.setRowVisible(self._delivery_notice, bool(notice))

    def _update_title(self) -> None:
        self._title.setText(self._draft["name"].strip() or "Untitled ability")
        badge = f"Ability #{self._draft['id']}" if self._draft["id"] else "New draft"
        self._asset_line.setText(f"{badge} · {self._path}" if self._path else badge)

    def _refresh_tags(self) -> None:
        self._tags.clear()
        self._tags.addItems(self._draft["tags"])

    def _add_tag(self) -> None:
        entries = self._tag_registry.entries
        tag = choose_tag(self, entries, "Add Ability Tag")
        if tag is None:
            return
        if not any(entry["name"] == tag for entry in entries):
            self.set_result("Select a registered tag. Branches group related tags.", True)
            return
        if tag not in self._draft["tags"]:
            self._draft["tags"].append(tag)
            self._refresh_tags()
            self._draft_changed()

    def _remove_tag(self) -> None:
        index = self._tags.currentRow()
        if index >= 0:
            del self._draft["tags"][index]
            self._refresh_tags()
            self._draft_changed()

    def _draft_changed(self) -> None:
        if not self._loading:
            self.set_result("Unsaved changes" if self.draft() != self._saved else "Ready")
            self._refresh_actions()

    def _refresh_actions(self) -> None:
        self._save.setEnabled(not self._busy and (not self._draft["id"] or self.draft() != self._saved))
