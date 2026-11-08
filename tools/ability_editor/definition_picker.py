"""Pick saved combat definitions from the project catalog."""

from pathlib import Path

from PySide6.QtCore import QSize, Qt
from PySide6.QtGui import QIcon, QImageReader
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QDialog, QDialogButtonBox, QHeaderView, QLabel,
    QLineEdit, QStyle, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

if __package__:
    from .json_project import _resource_parts
else:
    from json_project import _resource_parts


def project_icon(project: Path | None, icon_path: str) -> QIcon:
    if project is not None and icon_path:
        try:
            root = project.resolve()
            file = root.joinpath(*_resource_parts(icon_path)).resolve()
            if file.is_relative_to(root) and file.is_file() and QImageReader(str(file)).canRead():
                return QIcon(str(file))
        except (OSError, RuntimeError, ValueError):
            pass
    app = QApplication.instance()
    if isinstance(app, QApplication):
        return app.style().standardIcon(QStyle.StandardPixmap.SP_FileIcon)
    return QIcon()


def pick_effect(
    parent: QWidget, project: Path | None, effects: list[dict], *, allow_inline: bool = False,
) -> tuple[str, str] | None:
    selection = _pick_definition(parent, project, effects, "effect", allow_inline=allow_inline)
    if isinstance(selection, dict):
        return "asset", selection["path"]
    if selection == "inline":
        return "resource", "GameplayEffectDefinition"
    return None


def pick_ability(
    parent: QWidget, project: Path, abilities: list[dict], current_id: int | None,
) -> int | None:
    selection = _pick_definition(parent, project, abilities, "ability", current_id=current_id)
    return selection["id"] if isinstance(selection, dict) else None


def _pick_definition(
    parent: QWidget, project: Path | None, entries: list[dict], kind: str, *,
    current_id: int | None = None, allow_inline: bool = False,
) -> dict | str | None:
    singular = "an ability" if kind == "ability" else "an effect"
    plural = "abilities" if kind == "ability" else "effects"
    dialog = QDialog(parent)
    dialog.setWindowTitle(f"Choose {singular}")
    dialog.resize(520, 390)
    search = QLineEdit()
    search.setPlaceholderText("Search by name or ID")
    search.setAccessibleName(f"Search project {plural}")
    search.setClearButtonEnabled(True)

    icon_column, id_column, name_column = range(3)
    entry_role = Qt.ItemDataRole.UserRole
    table = QTableWidget(0, 3)
    table.setAccessibleName(f"Project {plural}")
    table.setHorizontalHeaderLabels(["Icon", "ID", "Name"])
    table.verticalHeader().hide()
    table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
    table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
    table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
    table.setAlternatingRowColors(True)
    table.setIconSize(QSize(24, 24))
    table.verticalHeader().setDefaultSectionSize(32)
    header = table.horizontalHeader()
    header.setSectionResizeMode(icon_column, QHeaderView.ResizeMode.ResizeToContents)
    header.setSectionResizeMode(id_column, QHeaderView.ResizeMode.ResizeToContents)
    header.setSectionResizeMode(name_column, QHeaderView.ResizeMode.Stretch)

    for entry in entries:
        row = table.rowCount()
        table.insertRow(row)
        icon = QTableWidgetItem()
        icon.setIcon(project_icon(project, entry.get("icon", "")))
        identity = QTableWidgetItem()
        identity.setData(Qt.ItemDataRole.DisplayRole, entry["id"])
        identity.setData(entry_role, entry)
        identity.setTextAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        table.setItem(row, icon_column, icon)
        table.setItem(row, id_column, identity)
        table.setItem(row, name_column, QTableWidgetItem(entry["name"]))
    table.setSortingEnabled(True)
    table.sortItems(name_column, Qt.SortOrder.AscendingOrder)

    empty = QLabel(f"No {plural} match your search." if entries else f"No available {plural}.")
    empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
    buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Cancel)
    choose = buttons.addButton(f"Choose {kind}", QDialogButtonBox.ButtonRole.AcceptRole)
    choose.setDefault(True)
    selection = None

    def accept_entry() -> None:
        row = table.currentRow()
        if row < 0 or table.isRowHidden(row):
            return
        nonlocal selection
        selection = table.item(row, id_column).data(entry_role)
        dialog.accept()

    def filter_entries(text: str) -> None:
        words = text.casefold().split()
        first = -1
        for row in range(table.rowCount()):
            identity = table.item(row, id_column).text()
            name = table.item(row, name_column).text().casefold()
            searchable = f"{name} #{identity}"
            matches = all(word in searchable for word in words)
            table.setRowHidden(row, not matches)
            if matches and first < 0:
                first = row
        current = table.currentRow()
        if first < 0:
            table.clearSelection()
            table.setCurrentCell(-1, -1)
        elif current < 0 or table.isRowHidden(current):
            table.selectRow(first)
        table.setVisible(first >= 0)
        empty.setVisible(first < 0)
        choose.setEnabled(first >= 0)

    buttons.accepted.connect(accept_entry)
    buttons.rejected.connect(dialog.reject)
    table.cellDoubleClicked.connect(lambda _row, _column: accept_entry())
    search.textChanged.connect(filter_entries)
    search.returnPressed.connect(accept_entry)
    if allow_inline:
        inline = buttons.addButton("New inline effect", QDialogButtonBox.ButtonRole.ActionRole)

        def create_inline() -> None:
            nonlocal selection
            selection = "inline"
            dialog.accept()

        inline.clicked.connect(create_inline)

    layout = QVBoxLayout(dialog)
    layout.addWidget(search)
    layout.addWidget(table, 1)
    layout.addWidget(empty, 1)
    layout.addWidget(buttons)
    for row in range(table.rowCount()):
        if table.item(row, id_column).data(Qt.ItemDataRole.DisplayRole) == current_id:
            table.selectRow(row)
            table.scrollToItem(table.item(row, name_column))
            break
    filter_entries("")
    search.setFocus()
    return selection if dialog.exec() == QDialog.DialogCode.Accepted else None
