"""Shared gameplay tag tree and dialogs for the Ability Editor."""

from PySide6.QtCore import QModelIndex, QPoint, Qt, Signal
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMenu,
    QPushButton,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)


class _TagTree:
    def __init__(self) -> None:
        self.search = QLineEdit()
        self.search.setAccessibleName("Search gameplay tags")
        self.search.setPlaceholderText("Search tag paths…")
        self.search.setClearButtonEnabled(True)

        self.tree = QTreeWidget()
        self.tree.setAccessibleName("Gameplay tags")
        self.tree.setHeaderLabels(["Tag", "Description", "Source"])
        self.tree.setUniformRowHeights(True)
        header = self.tree.header()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Interactive)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        header.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        header.setStretchLastSection(False)
        self.tree.setColumnWidth(0, 220)

        self.entries: dict[str, dict] = {}
        self._items: dict[str, QTreeWidgetItem] = {}
        self._expanded: set[str] = set()
        self._filtering = False
        self.search.textChanged.connect(self._search_changed)

    def set_entries(self, entries: list[dict]) -> None:
        if not self._filtering:
            self._remember_expansion()
        selected = self.selected_path()
        self.entries = {entry["name"]: entry for entry in entries}
        self.tree.clear()
        self._items.clear()

        for name in sorted(self.entries, key=str.casefold):
            parent = self.tree.invisibleRootItem()
            path = ""
            for segment in name.split("."):
                path = f"{path}.{segment}" if path else segment
                if path not in self._items:
                    item = QTreeWidgetItem(parent, [segment, "", "Branch"])
                    item.setData(0, Qt.ItemDataRole.UserRole, path)
                    item.setToolTip(0, path)
                    self._items[path] = item
                parent = self._items[path]
            entry = self.entries[name]
            description = entry.get("description", "")
            parent.setText(1, description)
            parent.setToolTip(1, description)
            parent.setText(2, "Code-owned" if entry.get("code_owned") else "Project")

        self._apply_search(self.search.text().strip().casefold())
        if selected in self._items:
            item = self._items[selected]
            if not item.isHidden():
                self.tree.setCurrentItem(item)

    def selected_path(self) -> str | None:
        item = self.tree.currentItem()
        if item is None or item.isHidden():
            return None
        return item.data(0, Qt.ItemDataRole.UserRole)

    def reveal(self, path: str) -> None:
        item = self._items.get(path)
        if item is None:
            return
        if item.isHidden():
            self.search.clear()
        parent = item.parent()
        while parent is not None:
            parent.setExpanded(True)
            parent = parent.parent()
        self.tree.setCurrentItem(item)
        self.tree.scrollToItem(item)

    def _remember_expansion(self) -> None:
        self._expanded = {path for path, item in self._items.items() if item.isExpanded()}

    def _search_changed(self, text: str) -> None:
        query = text.strip().casefold()
        if not self._filtering:
            self._remember_expansion()
        self._filtering = bool(query)
        self._apply_search(query)

    def _apply_search(self, query: str) -> None:
        parents = set()
        for path, item in reversed(self._items.items()):
            visible = not query or query in path.casefold() or path in parents
            item.setHidden(not visible)
            if query:
                item.setExpanded(path in parents)
                if visible:
                    parents.add(path.rpartition(".")[0])
            else:
                item.setExpanded(path in self._expanded)
        current = self.tree.currentItem()
        if current is not None and current.isHidden():
            self.tree.clearSelection()
            self.tree.setCurrentIndex(QModelIndex())


class TagManager(QWidget):
    tag_requested = Signal(str, str)

    def __init__(self) -> None:
        super().__init__()
        self._tags = _TagTree()
        self._editable = False

        self._new_tag = QPushButton("New Tag")
        self._new_tag.setEnabled(False)
        self._new_tag.clicked.connect(lambda: self._add_tag())
        actions = QHBoxLayout()
        actions.addWidget(self._tags.search)
        actions.addWidget(self._new_tag)

        self._status = QLabel()
        self._status.setTextFormat(Qt.TextFormat.PlainText)
        self._status.setWordWrap(True)
        self._status.hide()

        tree = self._tags.tree
        tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        tree.customContextMenuRequested.connect(self._show_context_menu)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 12, 12, 12)
        layout.setSpacing(8)
        layout.addLayout(actions)
        layout.addWidget(tree, 1)
        layout.addWidget(self._status)

    def set_entries(self, entries: list[dict], editable: bool, status: str = "") -> None:
        self._editable = editable
        self._new_tag.setEnabled(editable)
        self._tags.set_entries(entries)
        self._status.setText(status)
        self._status.setVisible(bool(status))

    def _show_context_menu(self, position: QPoint) -> None:
        tree = self._tags.tree
        item = tree.itemAt(position)
        if item is None:
            return
        path = item.data(0, Qt.ItemDataRole.UserRole)
        menu = QMenu(tree)
        add_child = menu.addAction("Add Child Tag")
        add_child.setEnabled(self._editable)
        copy = menu.addAction("Copy Full Name")
        action = menu.exec(tree.viewport().mapToGlobal(position))
        if action == add_child:
            self._add_tag(path)
        elif action == copy:
            QApplication.clipboard().setText(path)
        menu.deleteLater()

    def _add_tag(self, parent_path: str = "") -> None:
        if not self._editable:
            return
        dialog = QDialog(self)
        dialog.setWindowTitle("Add Child Tag" if parent_path else "New Tag")
        dialog.setMinimumWidth(440)
        form = QFormLayout(dialog)
        name = QLineEdit()
        if parent_path:
            parent_label = QLabel(parent_path)
            parent_label.setTextFormat(Qt.TextFormat.PlainText)
            parent_label.setWordWrap(True)
            form.addRow("Parent", parent_label)
            name.setPlaceholderText("New segment")
            form.addRow("Child name", name)
        else:
            name.setPlaceholderText("Ability.Movement.Dash")
            form.addRow("Full name", name)
        description = QLineEdit()
        description.setPlaceholderText("Optional description")
        form.addRow("Description", description)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel,
        )
        add = buttons.button(QDialogButtonBox.StandardButton.Ok)
        add.setText("Add Tag")
        add.setEnabled(False)
        name.textChanged.connect(lambda text: add.setEnabled(bool(text.strip()) and (not parent_path or "." not in text)))
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        form.addRow(buttons)
        name.setFocus()

        if dialog.exec() == QDialog.DialogCode.Accepted:
            value = name.text().strip()
            full_name = f"{parent_path}.{value}" if parent_path else value
            new_name = full_name not in self._tags.entries
            self.tag_requested.emit(full_name, description.text().strip())
            if new_name and full_name in self._tags.entries:
                self._tags.reveal(full_name)


def choose_tag(parent: QWidget, entries: list[dict], title: str) -> str | None:
    dialog = QDialog(parent)
    dialog.setWindowTitle(title)
    dialog.resize(460, 500)
    tags = _TagTree()
    tags.set_entries(entries)
    buttons = QDialogButtonBox(
        QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel,
    )
    select = buttons.button(QDialogButtonBox.StandardButton.Ok)
    select.setText("Select Tag")
    select.setEnabled(False)
    tags.tree.currentItemChanged.connect(lambda: select.setEnabled(tags.selected_path() is not None))
    buttons.accepted.connect(dialog.accept)
    buttons.rejected.connect(dialog.reject)

    layout = QVBoxLayout(dialog)
    layout.addWidget(tags.search)
    layout.addWidget(tags.tree)
    layout.addWidget(buttons)
    tags.search.setFocus()

    if dialog.exec() == QDialog.DialogCode.Accepted:
        return tags.selected_path()
    return None
