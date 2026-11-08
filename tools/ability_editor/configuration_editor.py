"""Native Qt editor for a linked ability or effect definition."""

from collections import Counter
from copy import deepcopy
from pathlib import PurePosixPath
import re

from PySide6.QtCore import Qt, QSignalBlocker, QTimer, Signal
from PySide6.QtWidgets import (
    QAbstractSpinBox, QCheckBox, QComboBox, QFormLayout, QFrame, QHBoxLayout, QLabel, QListWidget,
    QPushButton, QScrollArea, QSizePolicy, QSpinBox, QToolButton,
    QVBoxLayout, QWidget,
)

if __package__:
    from .configuration_fields import (
        SECTION_FIELDS, choose_item, edit_element, element_field, enum_items, humanize,
        resource_title, section_names, value_editor,
    )
    from .configuration_visibility import RESOURCE_PERCENT_SOURCE, is_applicable
    from .definition_picker import pick_effect, project_icon
    from .tag_widgets import choose_tag
else:
    from configuration_fields import (
        SECTION_FIELDS, choose_item, edit_element, element_field, enum_items, humanize,
        resource_title, section_names, value_editor,
    )
    from configuration_visibility import RESOURCE_PERCENT_SOURCE, is_applicable
    from definition_picker import pick_effect, project_icon
    from tag_widgets import choose_tag

COLLECTIONS = {"Array", "PackedStringArray", "CurvePoints"}
BASE_RESOURCES = {
    "AbilityExecution", "AbilityActionDefinition", "CombatReactionAction",
    "GameplayEffectComponent", "GameplayEffectExecution",
}
GODOT_METADATA_FIELDS = {"resource_name", "resource_local_to_scene"}
LEGACY_COST_AMOUNT_RULES = {"unit": 0, "sources": (0, 1, 2, 3)}
CURRENT_POOL_VALUE = 0
GESTURE_PRESS = 1
GESTURE_HOLD = 2
GESTURE_HOLD_RELEASE = 4
CAST_IMMEDIATE = 0
CAST_LEGACY_HOLD_RELEASE = 3
CAST_CHANNEL = 4
CAST_SUSTAINED = 5
COST_FIELD_LABELS = {
    "pool": "Payment pool",
    "spend_up_to_maximum": "Payment mode",
    "use_payment_pool": "Calculate from",
    "amount": "Cost amount (points)",
    "maximum": "Spending cap (points)",
}
COST_MODE_HELP = (
    "The caster pays the calculated amount.",
    "The calculated amount is the minimum needed to cast. The caster spends available points up to the cap.",
)
OPEN_SECTIONS = {
    "AbilityDefinition": {"Basics", "Activation", "Targeting", "Delivery", "Costs and cooldown", "What happens"},
    "AbilityTargetingDefinition": {"Geometry", "Who it can affect"},
    "AbilityDeliveryDefinition": {"Method"},
    "AbilityPhaseDefinition": {"Actions"},
    "GameplayEffectDefinition": {"Basics", "What it does", "When it runs"},
}
SECTION_GUIDANCE = {
    "Activation": "Choose the input gesture, when the cast delivers, and what must be true to start.",
    "Targeting": "Choose the ability's initial target or aim point.",
    "Delivery": "Choose how the ability reaches its targets.",
    "Costs and cooldown": "Set what the caster spends and when another use becomes available.",
    "What happens": "Add steps and choose the event that runs each step's actions.",
    "Presentation": "Choose an optional actor visual for the cast before it releases.",
    "What it does": "Add damage, attribute changes, or other behavior applied to the target.",
    "When it runs": "Choose whether the effect happens once, lasts for a duration, or repeats.",
    "Who it affects": "Set the tags a target must have or must lack for this effect to apply.",
}
ADD_LABELS = {
    "activation_conditions": "Add condition",
    "conditions": "Add condition",
    "phases": "Add step",
    "actions": "Add action",
    "effects": "Add effect",
    "executions": "Add operation",
    "modifiers": "Add attribute change",
    "resource_costs": "Add cost",
    "reactions": "Add reaction",
}
REMOVE_LABELS = {
    "activation_conditions": "Remove condition",
    "conditions": "Remove condition",
    "phases": "Remove step",
    "actions": "Remove action",
    "effects": "Remove effect",
    "executions": "Remove operation",
    "modifiers": "Remove change",
    "resource_costs": "Remove cost",
    "reactions": "Remove reaction",
}
STEP_TITLES = {
    "ability.cast_started": "When casting starts",
    "ability.released": "On release",
    "ability.channel_tick": "On each channel pulse",
    "delivery.impact": "On impact",
    "target.entered": "When a target enters",
    "target.exited": "When a target leaves",
}


def _label(text: str = "", *, secondary: bool = False) -> QLabel:
    label = QLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    if secondary:
        label.setProperty("secondary", True)
    return label


def _resource_references(value):
    if isinstance(value, dict):
        if "$resource" in value:
            yield value["$resource"]
        else:
            for item in value.values():
                yield from _resource_references(item)
    elif isinstance(value, list):
        for item in value:
            yield from _resource_references(item)


class ConfigurationEditor(QWidget):
    changed = Signal()
    open_asset_requested = Signal(str)

    def __init__(self, tag_registry) -> None:
        super().__init__()
        self._tags = tag_registry
        self._document: dict = {}
        self._saved: dict = {}
        self._path = ""
        self._schema: dict = {}
        self._catalogs: dict = {}
        self._cost_amounts: dict[str, list[dict]] = {}
        self._shared_cost_amounts: set[str] = set()
        self._supports_payment_pool = False
        self._rows: dict[tuple[str, str], tuple[QFormLayout, QWidget]] = {}
        self._anchors: dict[str, QWidget] = {}
        self._entry_titles: dict[str, list[QToolButton]] = {}
        self._panels: dict[QFormLayout, QFrame] = {}
        self._rendered: set[str] = set()
        self._folds: dict[tuple[str, str], bool] = {}
        self._fold_buttons: dict[QWidget, QToolButton] = {}

        self._heading = _label()
        self._heading.setObjectName("configurationTitle")
        self._heading.setWordWrap(True)
        self._heading.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        font = self._heading.font()
        font.setPointSizeF(font.pointSizeF() + 5)
        font.setBold(True)
        self._heading.setFont(font)
        self._inactive = QCheckBox("Show inactive settings")
        self._inactive.toggled.connect(self._update_visibility)
        self._breadcrumb = _label(secondary=True)
        self._breadcrumb.setWordWrap(True)

        self._form_holder = QVBoxLayout()
        self._form_holder.setContentsMargins(0, 0, 0, 0)
        body = QWidget()
        body.setMaximumWidth(880)
        body.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum)
        body_layout = QVBoxLayout(body)
        body_layout.setContentsMargins(0, 0, 0, 0)
        body_layout.setSpacing(10)
        body_layout.addWidget(self._heading)
        body_layout.addWidget(self._breadcrumb)
        body_layout.addWidget(self._inactive, alignment=Qt.AlignmentFlag.AlignLeft)
        body_layout.addSpacing(5)
        body_layout.addLayout(self._form_holder)
        viewport = QWidget()
        viewport_layout = QVBoxLayout(viewport)
        viewport_layout.setContentsMargins(14, 16, 14, 20)
        viewport_layout.addWidget(body)
        viewport_layout.addStretch(1)
        self._scroll = QScrollArea()
        self._scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self._scroll.setWidgetResizable(True)
        self._scroll.setWidget(viewport)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self._scroll)

    @property
    def dirty(self) -> bool:
        return self._document != self._saved

    @property
    def has_cost_unit_repairs(self) -> bool:
        return any(self._cost_unit_needs_repair(self._resources[key]) for key in self._cost_amounts)

    def load(self, document: dict, path: str, schema: dict, catalogs: dict) -> None:
        self._schema = schema
        self._catalogs = catalogs
        cost_fields = schema["types"].get("AbilityResourceCost", {}).get("fields", ())
        self._supports_payment_pool = any(field["key"] == "use_payment_pool" for field in cost_fields)
        root = document["root"]
        if document["resources"][root]["type"] not in schema["types"]:
            raise ValueError("The linked Godot project does not describe this definition type.")
        with QSignalBlocker(self._inactive):
            self._inactive.setChecked(False)
        self._folds.clear()
        self._scroll.verticalScrollBar().setValue(0)
        self.mark_saved(document, path)

    def clear(self) -> None:
        self._document = {}
        self._saved = {}
        self._folds.clear()
        self._rebuild_form()

    def draft(self) -> dict:
        draft = deepcopy(self._document)
        if self.has_cost_unit_repairs:
            resources = draft["resources"]
            references = Counter(_resource_references(resources))
            for key, owners in self._cost_amount_owners(resources).items():
                amount = resources[key]
                if not self._cost_unit_needs_repair(amount):
                    continue
                if references[key] > len(owners):
                    # Keep the original amount for callers outside the resource cost.
                    amount = deepcopy(amount)
                    new_key = self._next_resource_id(resources)
                    resources[new_key] = amount
                    for owner in owners:
                        owner["amount"] = {"$resource": new_key}
                amount["properties"]["unit"] = self._cost_amount_rules["unit"]
        return draft

    def mark_saved(self, document: dict, path: str) -> None:
        self._document = deepcopy(document)
        self._saved = deepcopy(document)
        self._path = path
        self._rebuild_form()
        self.changed.emit()

    def reveal(self, path: str) -> None:
        if not self._document:
            return
        for resource_id, key in re.findall(r"(?=\b(\w+)\]?(?:\.properties)?\.([a-z_]\w*))", path):
            if (resource_id, key) in self._rows:
                self._jump_to(resource_id, key)
                return
        for resource_id, key in self._rows:
            if re.search(rf"(?<![\w]){re.escape(key)}(?![\w])", path):
                self._jump_to(resource_id, key)
                return

    @property
    def _resources(self) -> dict:
        return self._document["resources"]

    @property
    def _cost_amount_rules(self) -> dict:
        return self._schema.get("ability_cost_amount", LEGACY_COST_AMOUNT_RULES)

    @staticmethod
    def _cost_amount_owners(resources: dict) -> dict[str, list[dict]]:
        result = {}
        for resource in resources.values():
            if resource["type"] != "AbilityResourceCost":
                continue
            properties = resource["properties"]
            amount = properties.get("amount")
            key = amount.get("$resource") if isinstance(amount, dict) else None
            if resources.get(key, {}).get("type") == "AmountDefinition":
                result.setdefault(key, []).append(properties)
        return result

    def _cost_unit_needs_repair(self, amount: dict) -> bool:
        points = self._cost_amount_rules["unit"]
        unit = amount["properties"].get("unit", points)
        return type(unit) is bool or unit != points

    def _sections(self, resource_id: str) -> dict:
        resource = self._resources[resource_id]
        metadata = self._schema["types"].get(resource["type"], {})
        fields = [field for field in metadata.get("fields", ()) if field["key"] not in GODOT_METADATA_FIELDS]
        known = GODOT_METADATA_FIELDS | {field["key"] for field in fields}
        fields.extend({
            "key": key, "type": "JSON", "group": "Additional settings",
            "description": "Stored property of this resource.",
        } for key in resource["properties"] if key not in known)
        if resource["type"] == "AbilityResourceCost":
            fields = [
                {**field, "label": COST_FIELD_LABELS.get(field["key"], humanize(field["key"]))}
                for field in fields
                if field["key"] != "use_payment_pool" or self._supports_payment_pool
            ]
        elif resource_id in self._cost_amounts:
            fields = self._cost_amount_fields(fields)
        return section_names(resource["type"], fields)

    def _cost_amount_fields(self, fields: list[dict]) -> list[dict]:
        sources = self._cost_amount_rules["sources"]
        result = []
        for field in fields:
            key = field["key"]
            if key in {"unit", "outcome_basis", "amount_per_target"}:
                continue
            if key == "source":
                options = enum_items(field.get("hint_string", ""))
                field = {
                    **field,
                    "hint_string": ",".join(f"{name}:{value}" for name, value in options if value in sources),
                    "unlisted_placeholder": "Choose a supported cost source…",
                }
            elif key in {"minimum", "maximum"}:
                field = {**field, "label": f"Amount clamp {key} (points)"}
            elif key in {"resource", "resource_basis"}:
                field = {**field, "label": "Basis pool" if key == "resource" else "Pool value"}
            result.append(field)
        return result

    def _title(self, resource_id: str) -> str:
        resource = self._resources[resource_id]
        properties = resource["properties"]
        event = properties.get("event_key")
        return (
            properties.get("display_name") or STEP_TITLES.get(event, event) or resource_title(resource["type"])
        )

    def _jump_to(self, resource_id: str, key: str = "") -> None:
        row = self._rows.get((resource_id, key))
        widget = row[1] if row else self._anchors.get(resource_id)
        if widget is None:
            return
        if isinstance(widget, QToolButton) and widget.isCheckable():
            widget.setChecked(True)
        row_layouts = {control: form for form, control in self._rows.values()}
        ancestor = widget
        while ancestor is not None:
            button = self._fold_buttons.get(ancestor)
            if button is not None:
                button.setChecked(True)
            form = row_layouts.get(ancestor)
            if form is not None and not form.isRowVisible(ancestor):
                self._inactive.setChecked(True)
            ancestor = ancestor.parentWidget()

        def reveal() -> None:
            if self._scroll.isAncestorOf(widget) and not widget.isHidden():
                self._scroll.ensureWidgetVisible(widget, 8, 12)
                if row:
                    widget.setFocus(Qt.FocusReason.OtherFocusReason)
                    if isinstance(widget, QAbstractSpinBox):
                        widget.selectAll()

        QTimer.singleShot(0, widget, reveal)

    def _update_header(self) -> None:
        self._heading.setText(self._title(self._document["root"]))
        self._breadcrumb.setText(self._path or "New definition")

    def _rebuild_form(self) -> None:
        scroll = self._scroll.verticalScrollBar()
        position = scroll.value()
        if self._form_holder.count():
            old = self._form_holder.takeAt(0).widget()
            old.hide()
            old.deleteLater()
        self._rows.clear()
        self._anchors.clear()
        self._entry_titles.clear()
        self._panels.clear()
        self._rendered.clear()
        self._fold_buttons.clear()
        resources = self._document.get("resources", {})
        self._cost_amounts = self._cost_amount_owners(resources)
        references = Counter(_resource_references(resources))
        self._shared_cost_amounts = {
            key for key, owners in self._cost_amounts.items() if references[key] > len(owners)
        }
        if not self._document:
            self._heading.clear()
            self._breadcrumb.clear()
            self._inactive.hide()
            return
        self._update_header()
        pane = self._resource_form(self._document["root"])
        self._form_holder.addWidget(pane)
        self._update_visibility()
        if position:
            QTimer.singleShot(0, pane, lambda: scroll.setValue(position))

    def _form_sections(self, resource_id: str, pane: QWidget) -> dict:
        groups = {
            title: [(resource_id, field) for field in fields]
            for title, fields in self._sections(resource_id).items()
        }
        resource = self._resources[resource_id]
        if resource["type"] != "AbilityDefinition":
            return groups
        execution = resource["properties"].get("execution") or {}
        child = execution.get("$resource") if isinstance(execution, dict) else None
        if child in self._rendered or self._resources.get(child, {}).get("type") != "PhasedAbilityExecution":
            return groups

        # Put the standard behavior's fields alongside the ability fields that use them.
        self._rendered.add(child)
        self._anchors[child] = pane
        activation = [
            pair for pair in groups.get("Activation", ()) if pair[1]["key"] != "execution"
        ]
        groups["Activation"] = activation
        timing_index = 1 if activation and activation[0][1]["key"] == "input_gesture" else 0
        for title, fields in self._sections(child).items():
            rows = [(child, field) for field in fields]
            if title == "Activation":
                activation[timing_index:timing_index] = rows
            elif title == "Activation conditions":
                activation.extend(rows)
            else:
                groups.setdefault(title, []).extend(rows)
        ordered = {title: groups.pop(title) for title, _ in SECTION_FIELDS["AbilityDefinition"] if title in groups}
        return ordered | groups

    @staticmethod
    def _panel(primary: bool = False) -> tuple[QFrame, QVBoxLayout]:
        panel = QFrame()
        panel.setObjectName("configurationSection" if primary else "configurationGroup")
        layout = QVBoxLayout(panel)
        horizontal_margin = 10 if primary else 8
        layout.setContentsMargins(horizontal_margin, 7, horizontal_margin, 8)
        layout.setSpacing(6)
        return panel, layout

    def _resource_form(self, resource_id: str) -> QWidget:
        pane = QWidget()
        layout = QVBoxLayout(pane)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)
        self._rendered.add(resource_id)
        self._anchors[resource_id] = pane
        resource_type = self._resources[resource_id]["type"]
        primary = resource_id == self._document["root"]
        sections = self._form_sections(resource_id, pane)
        for section, fields in sections.items():
            group = QWidget()
            form = QFormLayout(group)
            form.setContentsMargins(0, 2, 0, 4)
            form.setHorizontalSpacing(12)
            form.setVerticalSpacing(6)
            form.setLabelAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
            form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
            form.setRowWrapPolicy(QFormLayout.RowWrapPolicy.WrapLongRows)
            foldable = primary or (len(sections) > 1 and not (
                resource_type == "AmountDefinition" and section == "Calculation"
            ))
            if foldable:
                panel, contents = self._panel(primary)
                open_sections = OPEN_SECTIONS.get(resource_type)
                opened = section in open_sections if open_sections is not None else section != "Limits"
                button = self._fold_button(section, group, (resource_id, section), opened)
                button.setProperty("primarySection", primary)
                contents.addWidget(button)
                contents.addWidget(group)
                layout.addWidget(panel)
                self._panels[form] = panel
            else:
                layout.addWidget(group)
            if primary and (guidance := SECTION_GUIDANCE.get(section)):
                description = _label(guidance, secondary=True)
                description.setWordWrap(True)
                form.addRow(description)
            if resource_id in self._cost_amounts and section == "Calculation" \
                    and self._cost_unit_needs_repair(self._resources[resource_id]):
                description = _label("Save to update this cost's stored unit to Points.", secondary=True)
                description.setWordWrap(True)
                form.addRow(description)
            for owner, field in fields:
                show_name = len(fields) != 1 or humanize(field["key"]) != section
                self._add_field(form, owner, field, show_name=show_name)
        return pane

    def _fold_button(self, title: str, group: QWidget, key: tuple[str, str], opened: bool) -> QToolButton:
        button = QToolButton()
        button.setText(title)
        button.setProperty("sectionHeading", True)
        button.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        button.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        button.setCheckable(True)
        button.setAutoRaise(True)
        font = button.font()
        font.setBold(True)
        button.setFont(font)
        opened = self._folds.get(key, opened)
        button.setChecked(opened)

        def set_arrow(visible: bool) -> None:
            button.setArrowType(Qt.ArrowType.DownArrow if visible else Qt.ArrowType.RightArrow)

        def toggle(visible: bool) -> None:
            self._folds[key] = visible
            set_arrow(visible)
            group.setVisible(visible)

        # Expanded groups become visible when their layout adopts them. Showing them here opens top-level windows.
        set_arrow(opened)
        if not opened:
            group.hide()
        button.toggled.connect(toggle)
        self._fold_buttons[group] = button
        return button

    def _add_field(self, form: QFormLayout, resource_id: str, field: dict, *, show_name: bool) -> None:
        key = field["key"]
        resource = self._resources[resource_id]
        value = deepcopy(resource["properties"].get(key, field.get("default")))
        control = self._field_control(resource_id, field, value, show_name=show_name)
        name = field.get("label", humanize(key))
        description = field.get("description", "")
        control.setAccessibleName(name)
        control.setAccessibleDescription(description)
        control.setObjectName(key)
        if self._is_embeddable(field):
            form.addRow(control)
        else:
            control.setToolTip(description)
            label = _label(name)
            label.setWordWrap(True)
            label.setMinimumWidth(125)
            label.setMaximumWidth(165)
            label.setBuddy(control)
            label.setToolTip(description)
            form.addRow(label, control)
        self._rows[(resource_id, key)] = form, control

    @staticmethod
    def _is_embeddable(field: dict) -> bool:
        if field["type"] in COLLECTIONS:
            field = element_field(field)
        return field["type"] == "Object" and field["target"] not in {"Texture2D", "PackedScene"}

    def _update_visibility(self, _checked: bool = False) -> None:
        values_by_resource = {}
        events = self._schema.get("lifecycle_events", ())
        hidden = False
        visible_forms = set()
        for (resource_id, key), (form, control) in self._rows.items():
            resource = self._resources[resource_id]
            if resource_id not in values_by_resource:
                fields = self._schema["types"].get(resource["type"], {}).get("fields", ())
                defaults = {field["key"]: field.get("default") for field in fields}
                values_by_resource[resource_id] = defaults | resource["properties"]
            applicable = is_applicable(
                resource["type"], key, values_by_resource[resource_id], self._resources, events,
            )
            visible = applicable or self._inactive.isChecked()
            if resource["type"] == "AbilityResourceCost" and key in {"maximum", "use_payment_pool"}:
                visible = applicable
                if key == "use_payment_pool":
                    with QSignalBlocker(control):
                        control.setItemText(0, self._payment_pool_label(resource_id))
                        control.setCurrentIndex(0 if values_by_resource[resource_id].get(key) else 1)
            elif resource_id in self._cost_amounts and values_by_resource[resource_id].get("source") \
                    not in self._cost_amount_rules["sources"]:
                visible = key == "source"
            elif key in {"actor", "resource", "timing"} and self._uses_payment_pool(resource_id):
                visible = False
            else:
                hidden |= not applicable
            form.setRowVisible(control, visible)
            if visible:
                visible_forms.add(form)
        for form, panel in self._panels.items():
            panel.setVisible(form in visible_forms)
        self._inactive.setVisible(hidden or self._inactive.isChecked())

    def _uses_payment_pool(self, resource_id: str) -> bool:
        owners = self._cost_amounts.get(resource_id)
        return (
            self._supports_payment_pool and bool(owners) and resource_id not in self._shared_cost_amounts
            and self._resources[resource_id]["properties"].get("source") == RESOURCE_PERCENT_SOURCE
            and all(owner.get("use_payment_pool", False) for owner in owners)
        )

    def _set_value(self, resource_id: str, key: str, value, *, structure: bool = False,
                   focus: tuple[str, str] | None = None) -> None:
        input_timing = key in {"input_gesture", "cast_mode"} and self._supports_input_gestures()
        if input_timing:
            self._update_input_timing(key, value)
        if key == "source" and value == RESOURCE_PERCENT_SOURCE and self._supports_payment_pool:
            saved = self._saved.get("resources", {}).get(resource_id, {})
            if saved.get("properties", {}).get("source") != RESOURCE_PERCENT_SOURCE:
                for owner in self._cost_amounts.get(resource_id, ()):
                    owner.setdefault("use_payment_pool", True)
        self._resources[resource_id]["properties"][key] = value
        if structure:
            self._drop_unreferenced()
        if structure or (input_timing and key == "input_gesture"):
            self._rebuild_form()
            self._jump_to(*(focus or (resource_id, key)))
        else:
            self._update_visibility()
        if key in {"display_name", "event_key"}:
            for title in self._entry_titles.get(resource_id, ()):
                title.setText(self._title(resource_id))
                title.setToolTip(title.text())
        if key == "display_name" and resource_id == self._document["root"]:
            self._update_header()
        self.changed.emit()

    def _drop_unreferenced(self) -> None:
        reachable = set()

        def visit(key: str) -> None:
            if key not in self._resources or key in reachable:
                return
            reachable.add(key)
            for reference in _resource_references(self._resources[key]["properties"]):
                visit(reference)

        visit(self._document["root"])
        self._document["resources"] = {
            key: item for key, item in self._resources.items() if key in reachable
        }
        self._folds = {key: opened for key, opened in self._folds.items() if key[0] in reachable}

    def _field_control(self, resource_id: str, field: dict, value, *, show_name: bool) -> QWidget:
        write = lambda updated: self._set_value(resource_id, field["key"], updated)
        if field["key"] in {"input_gesture", "cast_mode"} and self._supports_input_gestures():
            return self._input_timing_control(field, value, write)
        if field["key"] == "spend_up_to_maximum" and self._resources[resource_id]["type"] == "AbilityResourceCost":
            return self._cost_mode_control(value, write)
        if field["key"] == "use_payment_pool" and self._supports_payment_pool \
                and self._resources[resource_id]["type"] == "AbilityResourceCost":
            return self._payment_pool_control(resource_id, value, write)
        if field["type"] == "Object":
            return self._reference_control(resource_id, field, value, show_name=show_name)
        if field["type"] in COLLECTIONS:
            return self._collection_control(resource_id, field, value, show_name=show_name)
        if field.get("tag_kind"):
            return self._tag_control(field, value, write)
        control = value_editor(field, value, write)
        if field["key"] in {"ability_id", "effect_id"} and isinstance(control, QSpinBox):
            control.setMinimum(0)
            control.setSpecialValueText("Assigned on save")
            if resource_id == self._document["root"] and self._path:
                control.setReadOnly(True)
                control.setButtonSymbols(QSpinBox.ButtonSymbols.NoButtons)
        return control

    def _supports_input_gestures(self) -> bool:
        return any(field["key"] == "input_gesture"
                   for field in self._schema["types"].get("AbilityDefinition", {}).get("fields", ()))

    def _ability_timing(self) -> tuple[dict, dict | None]:
        properties = self._resources[self._document["root"]]["properties"]
        reference = properties.get("execution")
        execution = self._resources.get(reference.get("$resource"), {}) if isinstance(reference, dict) else {}
        timing = execution.get("properties") if execution.get("type") == "PhasedAbilityExecution" else None
        return properties, timing

    def _update_input_timing(self, key: str, value: int) -> None:
        properties, timing = self._ability_timing()
        if timing is None:
            return
        mode = timing.get("cast_mode", CAST_IMMEDIATE)
        if key == "cast_mode":
            if mode == CAST_LEGACY_HOLD_RELEASE and not properties.get("input_gesture"):
                properties["input_gesture"] = GESTURE_HOLD_RELEASE
            return
        if value == GESTURE_HOLD and mode not in (CAST_CHANNEL, CAST_SUSTAINED):
            timing["cast_mode"] = CAST_SUSTAINED
        elif mode == CAST_LEGACY_HOLD_RELEASE or (
                value == GESTURE_HOLD_RELEASE and mode in (CAST_CHANNEL, CAST_SUSTAINED)):
            timing["cast_mode"] = CAST_IMMEDIATE

    def _input_timing_control(self, field: dict, value: int, write) -> QWidget:
        properties, timing = self._ability_timing()
        mode = timing.get("cast_mode", CAST_IMMEDIATE) if timing is not None else CAST_IMMEDIATE
        gesture = properties.get("input_gesture") or (
            GESTURE_HOLD_RELEASE if mode == CAST_LEGACY_HOLD_RELEASE else GESTURE_PRESS
        )
        options = enum_items(field.get("hint_string", ""))
        if field["key"] == "input_gesture":
            value = gesture
            options = [("Hold + release" if code == GESTURE_HOLD_RELEASE else name, code)
                       for name, code in options if code != 0]
        else:
            value = CAST_IMMEDIATE if value == CAST_LEGACY_HOLD_RELEASE else value
            available = {code for _, code in options if code != CAST_LEGACY_HOLD_RELEASE}
            if gesture == GESTURE_HOLD:
                available.intersection_update({CAST_CHANNEL, CAST_SUSTAINED})
            elif gesture == GESTURE_HOLD_RELEASE:
                available.difference_update({CAST_CHANNEL, CAST_SUSTAINED})
            options = [(name, code) for name, code in options if code in available]
        choice_hint = ",".join(f"{name}:{code}" for name, code in options)
        return value_editor({**field, "hint_string": choice_hint}, value, write)

    @staticmethod
    def _cost_mode_control(value: bool, write) -> QWidget:
        widget = QWidget()
        layout = QVBoxLayout(widget)
        layout.setContentsMargins(0, 0, 0, 0)
        selector = QComboBox()
        selector.addItems(["Exact cost", "Variable spending"])
        for index, text in enumerate(COST_MODE_HELP):
            selector.setItemData(index, text, Qt.ItemDataRole.ToolTipRole)
        selector.setCurrentIndex(int(bool(value)))
        explanation = _label(COST_MODE_HELP[selector.currentIndex()], secondary=True)
        explanation.setWordWrap(True)

        def change(index: int) -> None:
            if index < 0:
                return
            explanation.setText(COST_MODE_HELP[index])
            write(bool(index))

        selector.currentIndexChanged.connect(change)
        widget.setFocusProxy(selector)
        layout.addWidget(selector)
        layout.addWidget(explanation)
        return widget

    def _payment_pool_label(self, resource_id: str) -> str:
        fields = self._schema["types"]["AbilityResourceCost"]["fields"]
        pool_field = next(field for field in fields if field["key"] == "pool")
        pool = self._resources[resource_id]["properties"].get("pool", pool_field["default"])
        name = next((label for label, value in enum_items(pool_field["hint_string"]) if value == pool), "")
        return f"Payment pool ({name})" if name else "Payment pool"

    def _payment_pool_control(self, resource_id: str, value: bool, write) -> QComboBox:
        selector = QComboBox()
        selector.addItem(self._payment_pool_label(resource_id), True)
        selector.addItem("Custom resource", False)
        selector.setItemData(0, "Use the caster's live value from the selected payment pool.",
                             Qt.ItemDataRole.ToolTipRole)
        selector.setItemData(1, "Choose the actor and pool used to calculate the cost.",
                             Qt.ItemDataRole.ToolTipRole)
        selector.setCurrentIndex(0 if value else 1)
        selector.currentIndexChanged.connect(lambda index: write(selector.itemData(index)) if index >= 0 else None)
        return selector

    def _choose_tag(self, field: dict) -> str | None:
        entries = self._tags.entries
        if field["key"] == "casting_cue":
            entries = [entry for entry in entries if entry["name"].startswith("GameplayCue.")]
        if field["key"] == "event_key":
            names = {entry["name"] for entry in entries}
            entries = entries + [
                {"name": name, "description": "Built-in ability lifecycle event.", "code_owned": True}
                for name in self._schema.get("lifecycle_events", ()) if name not in names
            ]
        return choose_tag(
            self, entries, f"Choose {humanize(field['key']).lower()}",
            allow_implied=field["tag_kind"] == 2,
        )

    def _tag_control(self, field: dict, value: str, write) -> QWidget:
        widget, layout = self._inline_layout()
        button = QPushButton(value or "Choose tag…")
        button.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Fixed)
        widget.setFocusProxy(button)
        clear = QPushButton("Clear")
        clear.setEnabled(bool(value))

        def apply(updated: str) -> None:
            button.setText(updated or "Choose tag…")
            clear.setEnabled(bool(updated))
            write(updated)

        def choose() -> None:
            selected = self._choose_tag(field)
            if selected is not None:
                apply(selected)

        button.clicked.connect(choose)
        clear.clicked.connect(lambda: apply(""))
        layout.addWidget(button)
        layout.addWidget(clear)
        layout.addStretch(1)
        return widget

    @staticmethod
    def _inline_layout() -> tuple[QWidget, QHBoxLayout]:
        widget = QWidget()
        layout = QHBoxLayout(widget)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(6)
        return widget, layout

    def _compatible_types(self, target: str) -> list[str]:
        types = self._schema["types"]

        def accepts(candidate: str) -> bool:
            while candidate:
                if candidate == target:
                    return True
                candidate = types.get(candidate, {}).get("base", "")
            return False

        return sorted(kind for kind in types if kind not in BASE_RESOURCES and accepts(kind))

    def _external_options(self, target: str) -> list[tuple[str, str]]:
        catalog = {"AbilityDefinition": "abilities", "GameplayEffectDefinition": "effects"}.get(target)
        if catalog:
            rows = self._catalogs.get(catalog, ())
            return [
                (f"{row['name']} · #{row['id']} · {row['path']}", row["path"])
                for row in rows if row["path"] != self._path
            ]
        assets = self._schema.get("assets", {}) | self._catalogs.get("assets", {})
        paths = self._catalogs.get(target, assets.get(target, ()))
        return [(path, path) for path in paths]

    def _pick_reference(self, field: dict):
        target = field["target"]
        if target == "GameplayEffectDefinition":
            choice = pick_effect(
                self, self._catalogs.get("project"), self._catalogs.get("effects", ()),
                allow_inline=target in self._compatible_types(target),
            )
        else:
            options = [(f"New {resource_title(kind)}", ("resource", kind)) for kind in self._compatible_types(target)]
            options += [(label, ("asset", path)) for label, path in self._external_options(target)]
            if not options:
                return None
            if len(options) == 1 and options[0][1][0] == "resource":
                choice = options[0][1]
            else:
                choice = choose_item(self, f"Choose {humanize(field['key']).lower()}", options)
        if choice is None:
            return None
        kind, value = choice
        if kind == "asset":
            return {"$asset": value}
        resource_id = self._next_resource_id(self._resources)
        properties = {"use_payment_pool": True} if value == "AbilityResourceCost" and self._supports_payment_pool else {}
        self._resources[resource_id] = {"type": value, "properties": properties}
        return {"$resource": resource_id}

    @staticmethod
    def _next_resource_id(resources: dict) -> str:
        index = 1
        while f"r{index}" in resources:
            index += 1
        return f"r{index}"

    def _display_value(self, field: dict, value) -> str:
        if field["type"] == "Object":
            if isinstance(value, dict):
                if value.get("$resource") in self._resources:
                    return self._title(value["$resource"])
                if "$asset" in value:
                    path = value["$asset"]
                    entry = self._catalog_entry(path)
                    return entry["name"] if entry else PurePosixPath(path).name
            return "Unassigned"
        if field["type"] == "CurvePoint":
            return f"X {value['x']:g}    Y {value['y']:g}"
        if field["type"] == "int":
            return next((name for name, code in enum_items(field["hint_string"]) if code == value), str(value))
        return str(value)

    @staticmethod
    def _is_linked_definition(value) -> bool:
        return isinstance(value, dict) and value.get("$asset", "").endswith((".ability.json", ".effect.json"))

    def _catalog_entry(self, path: str) -> dict | None:
        if not path.endswith((".ability.json", ".effect.json")):
            return None
        catalog = "effects" if path.endswith(".effect.json") else "abilities"
        return next((row for row in self._catalogs.get(catalog, ()) if row["path"] == path), None)

    def _add_effect_badge(self, row: QHBoxLayout, value) -> None:
        if not isinstance(value, dict):
            return
        if "$asset" in value:
            entry = self._catalog_entry(value["$asset"])
            if entry is None:
                return
            effect_id, icon_path = entry["id"], entry.get("icon", "")
        else:
            properties = self._resources.get(value.get("$resource"), {}).get("properties", {})
            effect_id = properties.get("effect_id", 0)
            icon = properties.get("icon")
            icon_path = icon.get("$asset", "") if isinstance(icon, dict) else ""
        icon = project_icon(self._catalogs.get("project"), icon_path)
        thumbnail = QLabel()
        thumbnail.setPixmap(icon.pixmap(20, 20))
        row.addWidget(thumbnail)
        identity = _label(f"#{effect_id}" if effect_id else "New", secondary=True)
        identity.setToolTip("Effect ID" if effect_id else "An ID is assigned on save.")
        row.addWidget(identity)

    def _append_embedded(self, layout: QVBoxLayout, resource_id: str) -> None:
        if resource_id in self._rendered:
            button = QPushButton("Jump to shared settings")
            button.clicked.connect(lambda: self._jump_to(resource_id))
            layout.addWidget(button, alignment=Qt.AlignmentFlag.AlignLeft)
            return
        layout.addWidget(self._resource_form(resource_id))

    def _reference_control(self, resource_id: str, field: dict, value, *, show_name: bool) -> QWidget:
        key = field["key"]
        step_targets = key == "targeting" and self._resources[resource_id]["type"] == "AbilityPhaseDefinition"
        name = field.get("label", humanize(key))
        if step_targets:
            name = "Step targets" if value is None else "Step target override"
        child = value.get("$resource") if isinstance(value, dict) else None
        embedded = child in self._resources
        named = show_name and self._is_embeddable(field)
        if named:
            widget, layout = self._panel()
        else:
            widget = QWidget()
            layout = QVBoxLayout(widget)
            layout.setContentsMargins(0, 0, 0, 0)
        header, actions = self._inline_layout()
        description = field.get("description", "")
        if step_targets:
            description = "Use targets from the triggering event, or run a separate target query for this step."
        header.setToolTip(description)
        layout.addWidget(header)
        body = None
        if embedded:
            body = QWidget()
            fields = QVBoxLayout(body)
            fields.setContentsMargins(0, 0, 0, 0)
            self._append_embedded(fields, child)
        if named and body is not None:
            button = self._fold_button(name, body, (resource_id, f"field:{key}"), not step_targets)
            actions.addWidget(button, 1)
        elif named:
            field_label = _label(name)
            field_label.setWordWrap(True)
            actions.addWidget(field_label)
        is_effect = field["target"] == "GameplayEffectDefinition"
        if is_effect and value is not None:
            self._add_effect_badge(actions, value)
        if is_effect or not embedded or self._resources[child]["type"] != field["target"]:
            label_text = "From the triggering event" if step_targets and value is None else self._display_value(field, value)
            label = _label(label_text, secondary=True)
            label.setWordWrap(True)
            label.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            if isinstance(value, dict) and not self._catalog_entry(value.get("$asset", "")):
                label.setToolTip(value.get("$asset", ""))
            actions.addWidget(label, 1)
        elif not named:
            actions.addStretch(1)

        local_types = self._compatible_types(field["target"])
        external = self._external_options(field["target"])
        if not embedded or len(local_types) > 1 or external:
            if step_targets and value is None:
                title = "Override targets"
            elif is_effect:
                title = "Change effect…" if value is not None else "Choose effect…"
            elif value is not None:
                title = "Change…"
            elif len(local_types) == 1 and not external:
                title = f"Add {humanize(key).lower()}" if field["target"] == "AmountDefinition" or not named else "Add"
            else:
                title = "Choose…"
            choose = QPushButton(title)
            choose.setAccessibleName(f"{title} · {humanize(key)}")
            choose.setEnabled(bool(local_types or external))
            choose.clicked.connect(lambda: self._assign_reference(resource_id, field, value))
            actions.addWidget(choose)
            widget.setFocusProxy(choose)
        if self._is_linked_definition(value):
            button = QPushButton(self._open_link_label(value))
            button.clicked.connect(lambda: self.open_asset_requested.emit(value["$asset"]))
            actions.addWidget(button)
        if value is not None:
            if step_targets:
                clear_title = "Use event targets"
            elif is_effect:
                clear_title = "Unlink effect" if self._is_linked_definition(value) else "Remove effect"
            elif not show_name:
                clear_title = f"Clear {humanize(key).lower()}"
            else:
                clear_title = "Clear"
            clear = QPushButton(clear_title)
            clear.setAccessibleName(clear_title if clear_title != "Clear" else f"Clear {humanize(key).lower()}")
            clear.clicked.connect(lambda: self._set_value(resource_id, key, None, structure=True))
            actions.addWidget(clear)
        if body is not None:
            layout.addWidget(body)
        return widget

    def _assign_reference(self, resource_id: str, field: dict, current) -> None:
        selected = self._pick_reference(field)
        if selected is None or (isinstance(current, dict) and "$asset" in selected
                                and current.get("$asset") == selected["$asset"]):
            return
        child = selected.get("$resource")
        focus = None
        if child is not None:
            key = "fixed_amount" if field["target"] == "AmountDefinition" else ""
            focus = child, key
            if field["key"] == "amount" and self._resources[resource_id]["type"] == "AbilityResourceCost":
                amount = self._resources[child]["properties"]
                amount["unit"] = self._cost_amount_rules["unit"]
                if self._supports_payment_pool:
                    amount["resource_basis"] = CURRENT_POOL_VALUE
        self._set_value(resource_id, field["key"], selected, structure=True, focus=focus)

    @staticmethod
    def _open_link_label(value: dict) -> str:
        return "Open effect" if value["$asset"].endswith(".effect.json") else "Open ability"

    def _resource_collection(self, resource_id: str, field: dict, values: list, element: dict,
                             *, show_name: bool) -> QWidget:
        if show_name:
            widget, layout = self._panel()
        else:
            widget = QWidget()
            layout = QVBoxLayout(widget)
            layout.setContentsMargins(0, 0, 0, 0)
        key = field["key"]
        header, actions = self._inline_layout()
        header.setToolTip(field.get("description", ""))
        content = QWidget()
        entries = QVBoxLayout(content)
        entries.setContentsMargins(0, 0, 0, 0)
        entries.setSpacing(6)
        if show_name and values:
            fold = self._fold_button(humanize(key), content, (resource_id, f"collection:{key}"), True)
            actions.addWidget(fold, 1)
        elif show_name:
            name = _label(humanize(key))
            name.setWordWrap(True)
            actions.addWidget(name, 1)
        else:
            actions.addStretch(1)
        add = QPushButton(ADD_LABELS.get(key, "Add…"))
        add.setAccessibleName(f"Add to {humanize(key).lower()}")
        actions.addWidget(add)
        layout.addWidget(header)
        if values:
            layout.addWidget(content)
        widget.setFocusProxy(add)

        def insert() -> None:
            value = self._pick_reference(element)
            if value is not None:
                child = value.get("$resource")
                focus = (child, "") if child is not None else None
                self._set_value(resource_id, key, [*values, value], structure=True, focus=focus)

        def move(index: int, offset: int) -> None:
            other = index + offset
            updated = list(values)
            updated[index], updated[other] = updated[other], updated[index]
            child = values[index].get("$resource") if isinstance(values[index], dict) else None
            focus = (child, "") if child in self._resources else None
            self._set_value(resource_id, key, updated, structure=True, focus=focus)

        add.clicked.connect(insert)
        for index, value in enumerate(values):
            card, card_layout = self._panel()
            entry, row = self._inline_layout()
            child = value.get("$resource") if isinstance(value, dict) else None
            body = None
            if child in self._resources:
                body = QWidget()
                fields = QVBoxLayout(body)
                fields.setContentsMargins(0, 0, 0, 0)
                self._append_embedded(fields, child)
            title = self._display_value(element, value)
            if element["target"] == "GameplayEffectDefinition":
                self._add_effect_badge(row, value)
            if body is not None:
                button = self._fold_button(title, body, (child, f"{resource_id}.{key}"), index == 0)
                button.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
                button.setToolTip(title)
                self._entry_titles.setdefault(child, []).append(button)
                row.addWidget(button, 1)
            else:
                label = _label(title)
                label.setWordWrap(True)
                label.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
                if isinstance(value, dict) and not self._catalog_entry(value.get("$asset", "")):
                    label.setToolTip(value.get("$asset", ""))
                row.addWidget(label, 1)
            linked = self._is_linked_definition(value)
            if linked:
                link = QPushButton(self._open_link_label(value))
                link.clicked.connect(lambda checked=False, path=value["$asset"]: self.open_asset_requested.emit(path))
                row.addWidget(link)
            if len(values) > 1:
                row.addWidget(self._move_button("Move up", Qt.ArrowType.UpArrow, index > 0,
                                                lambda checked=False, i=index: move(i, -1)))
                row.addWidget(self._move_button("Move down", Qt.ArrowType.DownArrow, index < len(values) - 1,
                                                lambda checked=False, i=index: move(i, 1)))
            remove_title = "Unlink effect" if linked and key == "effects" else REMOVE_LABELS.get(key, "Remove")
            remove = QPushButton(remove_title)
            remove.setToolTip(f"{remove_title} · {title}")
            remove.clicked.connect(lambda checked=False, i=index: self._set_value(
                resource_id, key, values[:i] + values[i + 1:], structure=True,
            ))
            row.addWidget(remove)
            card_layout.addWidget(entry)
            if body is not None:
                card_layout.addWidget(body)
            entries.addWidget(card)
        return widget

    @staticmethod
    def _move_button(name: str, arrow: Qt.ArrowType, enabled: bool, move) -> QToolButton:
        button = QToolButton()
        button.setArrowType(arrow)
        button.setAccessibleName(name)
        button.setToolTip(name)
        button.setEnabled(enabled)
        button.clicked.connect(move)
        return button

    def _collection_control(self, resource_id: str, field: dict, values: list, *, show_name: bool) -> QWidget:
        element = element_field(field)
        if element["type"] == "Object":
            return self._resource_collection(resource_id, field, values, element, show_name=show_name)
        widget = QWidget()
        layout = QVBoxLayout(widget)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(6)
        items = QListWidget()
        items.setAccessibleName(humanize(field["key"]))
        layout.addWidget(items)
        buttons, actions = self._inline_layout()
        add = QPushButton("Add…")
        widget.setFocusProxy(add)
        edit = QPushButton("Edit…")
        remove = QPushButton("Remove")
        up = QToolButton()
        up.setArrowType(Qt.ArrowType.UpArrow)
        up.setAccessibleName("Move up")
        up.setToolTip("Move up")
        down = QToolButton()
        down.setArrowType(Qt.ArrowType.DownArrow)
        down.setAccessibleName("Move down")
        down.setToolTip("Move down")
        for button in (add, edit, remove, up, down):
            actions.addWidget(button)
        actions.addStretch(1)
        layout.addWidget(buttons)

        def update_actions(index: int) -> None:
            selected = 0 <= index < len(values)
            edit.setEnabled(selected)
            remove.setEnabled(selected)
            up.setEnabled(selected and index > 0)
            down.setEnabled(selected and index + 1 < len(values))

        def refresh(index: int) -> None:
            with QSignalBlocker(items):
                items.clear()
                for value in values:
                    items.addItem(self._display_value(element, value))
                items.setCurrentRow(index)
            if values:
                items.setFixedHeight(min(len(values), 6) * max(20, items.sizeHintForRow(0)) + 6)
            items.setVisible(bool(values))
            edit.setVisible(bool(values))
            remove.setVisible(bool(values))
            up.setVisible(len(values) > 1)
            down.setVisible(len(values) > 1)
            update_actions(index)

        def write(index: int) -> None:
            self._set_value(resource_id, field["key"], list(values))
            refresh(index)

        def choose(current=None):
            if element.get("tag_kind"):
                return self._choose_tag(field)
            return edit_element(self, element, element["default"] if current is None else current)

        def insert() -> None:
            value = choose()
            if value is not None and (not element.get("tag_kind") or value not in values):
                values.append(value)
                write(len(values) - 1)

        def open_or_edit() -> None:
            index = items.currentRow()
            if not 0 <= index < len(values):
                return
            current = values[index]
            value = choose(current)
            if value is not None and (not element.get("tag_kind") or value == current or value not in values):
                values[index] = value
                write(index)

        def delete() -> None:
            index = items.currentRow()
            values.pop(index)
            write(min(index, len(values) - 1))

        def move(offset: int) -> None:
            index = items.currentRow()
            other = index + offset
            values[index], values[other] = values[other], values[index]
            write(other)

        items.currentRowChanged.connect(update_actions)
        items.itemDoubleClicked.connect(lambda _item: open_or_edit())
        add.clicked.connect(insert)
        edit.clicked.connect(open_or_edit)
        remove.clicked.connect(delete)
        up.clicked.connect(lambda: move(-1))
        down.clicked.connect(lambda: move(1))
        refresh(0 if values else -1)
        return widget
