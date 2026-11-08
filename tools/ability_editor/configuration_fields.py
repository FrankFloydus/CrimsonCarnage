"""Controls and presentation metadata for reflected Godot configuration fields."""

import json
import re

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QDoubleSpinBox,
    QFormLayout, QHBoxLayout, QLabel, QLineEdit, QListWidget, QMenu,
    QPlainTextEdit, QSizePolicy, QSpinBox, QToolButton, QVBoxLayout, QWidget,
)

RANGE_HINT = 1
ENUM_HINT = 2
FLAGS_HINT = 6
PHYSICS_HINTS = {7, 8, 9, 10, 11, 12}

SECTION_FIELDS = {
    "AbilityDefinition": (
        ("Basics", "display_name icon ability_id ability_tags"),
        ("Activation", "input_gesture execution activation_event_tag required_tags activation_tags"),
        ("Targeting", ""),
        ("Delivery", ""),
        ("Costs and cooldown", "resource_costs charge_pool"),
        ("What happens", ""),
        ("Presentation", "casting_cue"),
        ("Interruptions and reactions", "interruption_policy cancel_ability_tags block_ability_tags reactions"),
    ),
    "PhasedAbilityExecution": (
        ("Activation", "cast_mode cast_duration channel_period animation_name release_event animation_fallback_seconds"),
        ("Activation conditions", "activation_conditions"),
        ("Targeting", "targeting"),
        ("Delivery", "delivery"),
        ("What happens", "phases"),
    ),
    "AbilityTargetingDefinition": (
        ("Geometry", "shape origin max_range radius half_height up_axis half_extents angle_degrees"),
        ("Who it can affect", "allegiance include_caster include_living include_dead required_target_tags blocked_target_tags"),
        ("Collision and limits", "max_targets collision_mask require_line_of_sight allow_world_surfaces"),
    ),
    "AbilityDeliveryDefinition": (
        ("Method", "kind projectile_scene spawn_offset detach_on_cancel"),
        ("Area and lifetime", "area_targeting lifetime period arm_delay maximum_surface_slope"),
        ("Chain jumps", "chain_hops chain_targeting stop_chain_on_failed_hit"),
    ),
    "AbilityPhaseDefinition": (
        ("Trigger and limits", "event_key synchronous_gameplay_event execution_mode failure_policy run_once_per_execution run_once_per_target max_fires"),
        ("Targets and conditions", "targeting conditions"),
        ("Actions", "actions"),
    ),
    "AbilityResourceCost": (
        ("Payment", "pool spend_up_to_maximum use_payment_pool amount maximum"),
    ),
    "GameplayEffectDefinition": (
        ("Basics", "display_name icon effect_id"),
        ("What it does", "executions modifiers damage_type magic_school damage_profile damage_tags status_profile granted_tags components"),
        ("When it runs", "timing duration period execute_periodic_on_application period_inhibition_policy tick_at_end"),
        ("Who it affects", "required_target_tags blocked_target_tags ongoing_required_target_tags ongoing_blocked_target_tags"),
        ("Stacking and ownership", "stacking_type stack_limit_count deny_overflow_application clear_stack_on_overflow stack_duration_policy stack_period_policy stack_expiration_policy exclusive_owner_slot transferable snapshot_source"),
        ("Tags and visuals", "asset_tags hud_category gameplay_cue_tags"),
        ("Reactions", "reactions"),
    ),
    "ReactionDefinition": (
        ("Trigger", "trigger once_policy timing_filter required_delivery required_provenance excluded_provenance required_ability_tags blocked_ability_tags removal_reason fire_limit"),
        ("Recipients", "recipient link_slot link_range link_exclude_trigger_target nearby_targeting"),
        ("Actions", "actions"),
    ),
    "AmountDefinition": (
        ("Calculation", "source unit fixed_amount percentage actor stat resource resource_basis outcome_basis timing curve_input curve amount_per_target"),
        ("Limits", "clamp_enabled minimum maximum"),
    ),
}

FIELD_LABELS = {
    "activation_event_tag": "Starts on event",
    "casting_cue": "Casting visual cue",
    "allegiance": "Allegiance",
    "ability_id": "Ability ID",
    "cast_mode": "Cast timing",
    "effect_id": "Effect ID",
    "display_name": "Display name",
    "event_key": "When this runs",
    "execution": "Ability behavior",
    "executions": "Effect operations",
    "hud_category": "HUD category",
    "input_gesture": "Input gesture",
    "modifiers": "Attribute changes",
    "phases": "Steps",
}

RESOURCE_TITLES = {
    "AbilityApplyEffectsAction": "Apply effects",
    "AbilityResourceCost": "Resource cost",
    "GameplayEffectDamageExecution": "Deal damage",
    "ResourceRegenerationExecution": "Regenerate resources",
}


def humanize(value: str) -> str:
    if value in FIELD_LABELS:
        return FIELD_LABELS[value]
    separated = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", value.replace("_", " "))
    return separated[:1].upper() + separated[1:]


def resource_title(value: str) -> str:
    return RESOURCE_TITLES.get(value) or humanize(value.removesuffix("Definition"))


def section_names(resource_type: str, fields: list[dict]) -> dict[str, list[dict]]:
    available = {field["key"]: field for field in fields}
    result = {}
    for section, keys in SECTION_FIELDS.get(resource_type, ()):
        group_fields = [available.pop(key) for key in keys.split() if key in available]
        if group_fields:
            result[section] = group_fields
    for field in available.values():
        section = field.get("group", "General")
        if section == "General":
            section = "Settings"
        result.setdefault(section, []).append(field)
    return result


def enum_items(hint: str, *, flags: bool = False) -> list[tuple[str, int]]:
    result = []
    for index, entry in enumerate(filter(None, hint.split(","))):
        name, separator, code = entry.rpartition(":")
        if not separator:
            name, code = entry, str((1 << index) if flags else index)
        try:
            result.append((name.strip(), int(code)))
        except ValueError:
            continue
    return result


def element_field(field: dict) -> dict:
    element = {**field, "type": "String", "target": "", "hint": 0, "hint_string": "", "default": ""}
    item_type, _, description = field.get("hint_string", "").partition(":")
    if item_type == "24/17":
        element.update(type="Object", target=description, default=None)
    elif item_type.startswith("2/"):
        element.update(type="int", default=0)
        if item_type == "2/2":
            element.update(hint=ENUM_HINT, hint_string=description)
    if field["type"] == "CurvePoints":
        element.update(type="CurvePoint", default={
            "x": 0.0, "y": 0.0, "left_tangent": 0.0, "right_tangent": 0.0,
            "left_mode": 0, "right_mode": 0,
        })
    return element


def value_editor(field: dict, value, write) -> QWidget:
    value_type = field["type"]
    hint = field.get("hint", 0)
    if value_type == "bool":
        widget = QCheckBox()
        widget.setChecked(bool(value))
        widget.toggled.connect(write)
        return widget
    if value_type == "int" and hint == ENUM_HINT:
        widget = QComboBox()
        widget.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        widget.setMinimumContentsLength(12)
        descriptions = field.get("choice_descriptions", {})
        for name, code in enum_items(field.get("hint_string", "")):
            widget.addItem(name, code)
            if description := descriptions.get(str(code)):
                widget.setItemData(widget.count() - 1, description, Qt.ItemDataRole.ToolTipRole)
        selected = widget.findData(value)
        if selected < 0:
            if placeholder := field.get("unlisted_placeholder"):
                widget.setPlaceholderText(placeholder)
            else:
                widget.addItem(f"Custom value ({value})", value)
                selected = widget.count() - 1
        widget.setCurrentIndex(selected)
        widget.currentIndexChanged.connect(lambda index: write(widget.itemData(index)) if index >= 0 else None)
        return widget
    if value_type == "int" and (hint == FLAGS_HINT or hint in PHYSICS_HINTS):
        return _flags_editor(field, value, write)
    if value_type in {"int", "float"}:
        return _number_editor(field, value, write)
    if value_type in {"String", "StringName"}:
        widget = QLineEdit(str(value))
        widget.textEdited.connect(write)
        return widget
    if value_type == "Vector3":
        return _vector_editor(value, write)
    widget = QPlainTextEdit(json.dumps(value, ensure_ascii=False, indent=2))
    widget.setMaximumHeight(115)

    def apply() -> None:
        try:
            updated = json.loads(widget.toPlainText())
        except ValueError:
            widget.setToolTip("Enter a valid JSON value.")
            return
        write(updated)

    widget.textChanged.connect(apply)
    return widget


def _number_editor(field: dict, value, write) -> QSpinBox | QDoubleSpinBox:
    integer = field["type"] == "int"
    widget = QSpinBox() if integer else QDoubleSpinBox()
    widget.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
    widget.setMinimumWidth(68)
    if not integer:
        widget.setDecimals(8)
    limit = 2**31 - 1 if integer else 1e100
    cast = (lambda number: int(float(number))) if integer else float
    low, high = (-limit - 1 if integer else -limit), limit
    if field.get("hint") == RANGE_HINT:
        parts = field.get("hint_string", "").split(",")
        if len(parts) >= 3:
            if "or_less" not in parts:
                low = min(cast(parts[0]), value)
            if "or_greater" not in parts:
                high = max(cast(parts[1]), value)
            widget.setSingleStep(cast(parts[2]))
            for part in parts[3:]:
                if part.startswith("suffix:"):
                    widget.setSuffix(" " + part[7:].strip())
                elif part == "degrees":
                    widget.setSuffix("°")
    widget.setRange(low, high)
    widget.setValue(value)
    widget.valueChanged.connect(write)
    return widget


def _flags_editor(field: dict, value: int, write) -> QWidget:
    widget = QToolButton()
    widget.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
    menu = QMenu(widget)
    widget.setMenu(menu)
    if field["hint"] in PHYSICS_HINTS:
        options = enum_items(field.get("hint_string", ""), flags=True) or [
            (f"Layer {index + 1}", 1 << index) for index in range(32)
        ]
    else:
        options = enum_items(field["hint_string"], flags=True)
    current = value

    def refresh() -> None:
        names = [name for name, bit in options if bit and current & bit == bit]
        widget.setText(", ".join(names) if 0 < len(names) <= 3 else (
            "None" if not names else f"{len(names)} selected"
        ))
        widget.setToolTip(f"Mask {current}")

    def toggle(bit: int, enabled: bool) -> None:
        nonlocal current
        current = (current | bit) if enabled else (current & ~bit)
        refresh()
        write(current)

    for name, bit in options:
        action = menu.addAction(name)
        action.setCheckable(True)
        action.setChecked(bool(bit and current & bit == bit))
        action.toggled.connect(lambda enabled, mask=bit: toggle(mask, enabled))
    refresh()
    return widget


def _vector_editor(value: dict, write) -> QWidget:
    widget = QWidget()
    layout = QHBoxLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)
    axes = list(value["$variant"]["args"])

    def change(index: int, number: float) -> None:
        axes[index] = number
        write({"$variant": {"type": "Vector3", "args": list(axes)}})

    for index, axis in enumerate(("X", "Y", "Z")):
        control = _number_editor({"type": "float"}, axes[index], lambda number, i=index: change(i, number))
        control.setPrefix(f"{axis}  ")
        control.setAccessibleName(axis)
        layout.addWidget(control, 1)
    return widget


def choose_item(parent: QWidget, title: str, options: list[tuple[str, object]]) -> object | None:
    dialog = QDialog(parent)
    dialog.setWindowTitle(title)
    dialog.resize(490, 390)
    search = QLineEdit()
    search.setPlaceholderText("Filter choices…")
    search.setAccessibleName("Filter choices")
    search.setClearButtonEnabled(True)
    choices = QListWidget()
    for label, _value in options:
        choices.addItem(label)
    buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
    accept = buttons.button(QDialogButtonBox.StandardButton.Ok)
    accept.setEnabled(False)
    buttons.accepted.connect(dialog.accept)
    buttons.rejected.connect(dialog.reject)
    choices.itemDoubleClicked.connect(lambda _item: dialog.accept())
    choices.currentRowChanged.connect(lambda row: accept.setEnabled(row >= 0))

    def filter_choices(text: str) -> None:
        words = text.casefold().split()
        first = -1
        for index in range(choices.count()):
            item = choices.item(index)
            visible = all(word in item.text().casefold() for word in words)
            item.setHidden(not visible)
            if visible and first < 0:
                first = index
        choices.setCurrentRow(first)

    search.textChanged.connect(filter_choices)
    layout = QVBoxLayout(dialog)
    layout.addWidget(search)
    layout.addWidget(choices, 1)
    layout.addWidget(buttons)
    filter_choices("")
    search.setFocus()
    if dialog.exec() and choices.currentRow() >= 0:
        return options[choices.currentRow()][1]
    return None


def edit_element(parent: QWidget, field: dict, value):
    dialog = QDialog(parent)
    dialog.setWindowTitle(f"Edit {humanize(field['key']).lower()} item")
    form = QFormLayout(dialog)
    result = value.copy() if isinstance(value, dict) else value

    def set_value(updated) -> None:
        nonlocal result
        result = updated

    if field["type"] == "CurvePoint":
        point = field["default"] | result
        result = point
        for key, number in point.items():
            mode = key.endswith("_mode")
            editor = value_editor(
                {"type": "int", "hint": ENUM_HINT, "hint_string": "Free:0,Linear:1"}
                if mode else {"type": "float"},
                number,
                lambda updated, name=key: point.__setitem__(name, updated),
            )
            form.addRow(humanize(key), editor)
    else:
        control = value_editor(field, value, set_value)
        form.addRow(QLabel(humanize(field["key"])), control)
    buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
    buttons.accepted.connect(dialog.accept)
    buttons.rejected.connect(dialog.reject)
    form.addRow(buttons)
    return result if dialog.exec() else None
