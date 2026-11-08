"""Docked Qt workspace for the project's combat definitions."""

import json
import re
import sys
from pathlib import Path
from shutil import which
from tempfile import TemporaryDirectory

from PySide6.QtCore import (
    QByteArray, QEvent, QModelIndex, QPoint, QProcess, QSettings, QSortFilterProxyModel, Qt, QTimer, Signal,
)
from PySide6.QtGui import QAction, QKeySequence, QPalette, QStandardItem, QStandardItemModel
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QDockWidget, QFileDialog, QHBoxLayout, QHeaderView, QLabel, QLineEdit,
    QListWidget, QMainWindow, QMenu, QMessageBox, QStackedWidget, QStyle, QTableView, QTabBar,
    QToolBar, QToolButton, QVBoxLayout, QWidget,
)
import qt_themes

if __package__:
    from .attribute_registry import AttributeRegistry, AttributeRevision
    from .attribute_widgets import AttributeManager
    from .configuration_editor import ConfigurationEditor
    from .definition_picker import project_icon
    from .json_project import JsonDocument, JsonProject
    from .player_actions import PlayerActions
    from .tag_registry import TagRegistry
    from .tag_widgets import TagManager, choose_tag
else:
    from attribute_registry import AttributeRegistry, AttributeRevision
    from attribute_widgets import AttributeManager
    from configuration_editor import ConfigurationEditor
    from definition_picker import project_icon
    from json_project import JsonDocument, JsonProject
    from player_actions import PlayerActions
    from tag_registry import TagRegistry
    from tag_widgets import TagManager, choose_tag


ATTRIBUTE_SCRIPT = "tools/ability_editor/read_abilities.gd"
SCHEMA_SCRIPT = "tools/ability_editor/configuration_schema.gd"
SCHEMA_PREFIX = "ABILITY_EDITOR_SCHEMA "
VALIDATION_PREFIX = "ABILITY_EDITOR_VALIDATE "
ATTRIBUTE_DELETE_PREFIX = "ABILITY_EDITOR_ATTRIBUTE_DELETE "
ACCURACY_PREVIEW_PREFIX = "ABILITY_EDITOR_ACCURACY_PREVIEW "
ID_COLUMN, ICON_COLUMN, NAME_COLUMN, TAGS_COLUMN = range(4)
PATH_ROLE = Qt.ItemDataRole.UserRole
TAGS_ROLE = Qt.ItemDataRole.UserRole
LAYOUT_VERSION = 2


def find_project_file() -> Path | None:
    app_file = Path(sys.executable if getattr(sys, "frozen", False) else __file__)
    for directory in app_file.resolve().parents:
        candidate = directory / "project.godot"
        if candidate.is_file() and (directory / ATTRIBUTE_SCRIPT).is_file():
            return candidate
    return None


def _plain_label(text: str, parent: QWidget | None = None) -> QLabel:
    label = QLabel(text, parent)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    return label


class _CatalogFilter(QSortFilterProxyModel):
    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.tag = ""
        self.setFilterKeyColumn(-1)
        self.setFilterCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        self.setSortCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)

    def filterAcceptsRow(self, row: int, parent: QModelIndex) -> bool:
        if not super().filterAcceptsRow(row, parent):
            return False
        if not self.tag:
            return True
        tags = self.sourceModel().index(row, TAGS_COLUMN, parent).data(TAGS_ROLE) or []
        return any(tag == self.tag or tag.startswith(self.tag + ".") for tag in tags)

    def lessThan(self, left: QModelIndex, right: QModelIndex) -> bool:
        if left.column() == ICON_COLUMN:
            role = Qt.ItemDataRole.DecorationRole
            return (left.data(role) is not None) < (right.data(role) is not None)
        return super().lessThan(left, right)


class _Catalog(QWidget):
    open_requested = Signal(str)
    hover_requested = Signal(str, str)
    delete_requested = Signal(list)

    def __init__(self, kind: str, registry: TagRegistry) -> None:
        super().__init__()
        self.kind = kind
        self._registry = registry
        self._model = QStandardItemModel(0, 4, self)
        self._model.setHorizontalHeaderLabels(["ID", "Icon", "Name", "Tags"])
        self._filter = _CatalogFilter(self)
        self._filter.setSourceModel(self._model)
        self._hover_path = ""
        self._hover_timer = QTimer(self)
        self._hover_timer.setSingleShot(True)
        self._hover_timer.setInterval(250)
        self._hover_timer.timeout.connect(self._open_hovered)
        self._filter.layoutChanged.connect(self._cancel_hover)

        search = QLineEdit()
        search.setPlaceholderText("Search by ID, name, or tag")
        search.setAccessibleName(f"Search {kind} definitions")
        search.setClearButtonEnabled(True)
        search.textChanged.connect(self._filter.setFilterFixedString)
        search.textChanged.connect(self._cancel_hover)
        self._tag = QToolButton()
        self._tag.setText("Tag…")
        self._tag.setAccessibleName("Filter by gameplay tag")
        self._tag.setToolTip("Filter by gameplay tag")
        self._tag.clicked.connect(self._pick_tag)
        self._clear_tag = QToolButton()
        self._clear_tag.setText("×")
        self._clear_tag.setAccessibleName("Clear gameplay tag filter")
        self._clear_tag.setToolTip("Clear gameplay tag filter")
        self._clear_tag.clicked.connect(lambda: self._set_tag(""))
        self._clear_tag.hide()
        registry.changed.connect(self._sync_tags)
        self._sync_tags()

        filters = QHBoxLayout()
        filters.setSpacing(4)
        filters.addWidget(search, 1)
        filters.addWidget(self._tag)
        filters.addWidget(self._clear_tag)
        self._table = QTableView()
        self._table.setAccessibleName(f"{kind.title()} definitions")
        self._table.setModel(self._filter)
        self._table.setAlternatingRowColors(True)
        self._table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._table.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self._table.verticalHeader().hide()
        header = self._table.horizontalHeader()
        header.setSectionResizeMode(TAGS_COLUMN, QHeaderView.ResizeMode.Stretch)
        header.setSortIndicator(ID_COLUMN, Qt.SortOrder.DescendingOrder)
        self._table.setSortingEnabled(True)
        self._table.setColumnWidth(ID_COLUMN, 40)
        self._table.setColumnWidth(ICON_COLUMN, 36)
        self._table.setColumnWidth(NAME_COLUMN, 118)
        self._table.clicked.connect(self._click)
        self._table.installEventFilter(self)
        self._table.viewport().setMouseTracking(True)
        self._table.viewport().installEventFilter(self)
        self._table.verticalScrollBar().valueChanged.connect(self._cancel_hover)
        self._table.horizontalScrollBar().valueChanged.connect(self._cancel_hover)
        self._table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self._table.customContextMenuRequested.connect(self._context_menu)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(5)
        layout.addLayout(filters)
        layout.addWidget(self._table)

    def set_entries(self, project: Path | None, entries: list[dict], selected_path: str) -> None:
        self._cancel_hover()
        self._model.removeRows(0, self._model.rowCount())
        for entry in entries:
            if entry["kind"] != self.kind:
                continue
            tag_list = entry["tags"]
            tags = ", ".join(tag_list)
            identity = QStandardItem()
            identity.setData(entry["id"], Qt.ItemDataRole.DisplayRole)
            identity.setData(entry["path"], PATH_ROLE)
            identity.setToolTip(entry["path"])
            icon = QStandardItem()
            icon_path = entry.get("icon", "")
            if icon_path:
                icon.setIcon(project_icon(project, icon_path))
            name = QStandardItem(entry["name"])
            name.setToolTip(f"{entry['name']}\n{entry['path']}")
            tag_item = QStandardItem(tags)
            tag_item.setData(tag_list, TAGS_ROLE)
            tag_item.setToolTip(tags)
            self._model.appendRow([identity, icon, name, tag_item])
        self.select_path(selected_path)

    def select_path(self, path: str) -> None:
        self._table.clearSelection()
        for row in range(self._filter.rowCount()):
            index = self._filter.index(row, ID_COLUMN)
            if index.data(PATH_ROLE) == path:
                self._table.selectRow(row)
                self._table.scrollTo(index)
                break

    def _sync_tags(self) -> None:
        tags = self._registry.entries
        self._tag.setEnabled(bool(tags) and not self._registry.error)
        if self._filter.tag and not any(
            item["name"] == self._filter.tag or item["name"].startswith(self._filter.tag + ".")
            for item in tags
        ):
            self._set_tag("")

    def _pick_tag(self) -> None:
        tag = choose_tag(self, self._registry.entries, "Filter by Tag")
        if tag is not None:
            self._set_tag(tag)

    def _set_tag(self, tag: str) -> None:
        self._cancel_hover()
        self._filter.beginFilterChange()
        self._filter.tag = tag
        self._filter.endFilterChange(QSortFilterProxyModel.Direction.Rows)
        self._tag.setText("Tag ✓" if tag else "Tag…")
        self._tag.setToolTip(f"Filter by tag {tag}" if tag else "Filter by gameplay tag")
        self._clear_tag.setVisible(bool(tag))

    def eventFilter(self, watched, event) -> bool:
        if watched is self._table.viewport():
            if event.type() == QEvent.Type.MouseMove:
                index = self._table.indexAt(event.position().toPoint())
                path = index.siblingAtColumn(ID_COLUMN).data(PATH_ROLE) or ""
                if event.buttons() or event.modifiers() & (
                    Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.ShiftModifier
                ):
                    path = ""
                if path != self._hover_path:
                    self._cancel_hover()
                    if path:
                        self._hover_path = path
                        self._hover_timer.start()
            elif event.type() in (QEvent.Type.Leave, QEvent.Type.Hide, QEvent.Type.MouseButtonPress):
                self._cancel_hover()
        elif watched is self._table and event.type() == QEvent.Type.KeyPress:
            if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
                self._open(self._table.currentIndex())
                return True
        return super().eventFilter(watched, event)

    def _cancel_hover(self) -> None:
        self._hover_timer.stop()
        self._hover_path = ""

    def hovered_path(self) -> str:
        selection = self._table.selectionModel()
        if self._hover_timer.isActive() or len(selection.selectedRows(ID_COLUMN)) > 1:
            return ""
        return self._hover_path

    def _open_hovered(self) -> None:
        if path := self.hovered_path():
            self.hover_requested.emit(path, self.kind)

    def _click(self, index: QModelIndex) -> None:
        if not QApplication.keyboardModifiers() & (
            Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.ShiftModifier
        ):
            self._open(index)

    def _open(self, index: QModelIndex) -> None:
        self._cancel_hover()
        path = index.siblingAtColumn(ID_COLUMN).data(PATH_ROLE)
        if path:
            self.open_requested.emit(path)

    def _context_menu(self, position: QPoint) -> None:
        self._cancel_hover()
        index = self._table.indexAt(position)
        if not index.isValid():
            return
        selection = self._table.selectionModel()
        if not selection.isRowSelected(index.row()):
            self._table.selectRow(index.row())
        paths = [selected.data(PATH_ROLE) for selected in selection.selectedRows(ID_COLUMN)]
        menu = QMenu(self)
        if len(paths) == 1:
            menu.addAction("Open", lambda: self.open_requested.emit(paths[0]))
        menu.addAction("Delete…", lambda: self.delete_requested.emit(paths))
        menu.exec(self._table.viewport().mapToGlobal(position))
        menu.deleteLater()


class AbilityEditorWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("AbilityEditorWindow")
        self.setWindowTitle("Ability Editor[*]")
        self.resize(1220, 780)
        self.setMinimumSize(840, 570)
        self._settings = QSettings("Untitled", "Ability Editor")
        saved_project = self._settings.value("project_file", "", type=str)
        self._project_file = Path(saved_project).resolve() if saved_project else find_project_file()
        self._godot_executable = self._settings.value("godot_executable", "", type=str)
        self._project: JsonProject | None = None
        self._document: JsonDocument | None = None
        self._document_kind = ""
        self._document_name = ""
        self._entries: list[dict] = []
        self._schema: dict = {}
        self._project_assets: dict = {}
        self._pending_document: tuple[JsonDocument, str, str] | None = None

        self._tag_registry = TagRegistry(self)
        self._attribute_registry = AttributeRegistry(self)
        self._editor = ConfigurationEditor(self._tag_registry)
        self._editor.changed.connect(self._update_document_state)
        self._editor.open_asset_requested.connect(self._open_asset)
        self._tags = TagManager()
        self._tags.tag_requested.connect(self._register_tag)
        self._tag_registry.changed.connect(self._sync_tag_manager)
        self._attributes = AttributeManager(self._attribute_registry)
        self._attributes.delete_requested.connect(self._confirm_attribute_delete)
        self._attributes.preview_requested.connect(self._queue_accuracy_preview)
        self._player_actions = PlayerActions()
        self._player_actions.assignment_saved.connect(
            lambda slot: self.statusBar().showMessage(f"Saved starting assignment for {slot}.", 5000)
        )

        self._empty_editor = _plain_label("")
        self._empty_editor.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._editor_page = QStackedWidget()
        self._editor_page.addWidget(self._empty_editor)
        self._editor_page.addWidget(self._editor)
        self._authoring = QMainWindow()
        self._authoring.setWindowFlags(Qt.WindowType.Widget)
        self._authoring.setCentralWidget(self._editor_page)
        self._hidden_authoring_layout: QByteArray | None = None
        self._workspace = QStackedWidget()
        for view in (self._authoring, self._tags, self._attributes, self._player_actions):
            self._workspace.addWidget(view)
        self.setCentralWidget(self._workspace)

        self._navigation = QTabBar()
        self._navigation.setAccessibleName("Project workspaces")
        self._navigation.setExpanding(False)
        self._workspace_indices = {}
        for kind, label in (("ability", "Abilities"), ("effect", "Effects"), ("tags", "Tags"),
                            ("attributes", "Attributes"), ("player_actions", "Player Actions")):
            index = self._navigation.addTab(label)
            self._navigation.setTabData(index, kind)
            self._workspace_indices[kind] = index

        navigation_bar = QToolBar("Project Workspaces", self)
        navigation_bar.setObjectName("projectWorkspaceBar")
        navigation_bar.setMovable(False)
        navigation_bar.setFloatable(False)
        navigation_bar.toggleViewAction().setVisible(False)
        navigation_bar.addWidget(self._navigation)
        self.addToolBar(navigation_bar)

        self._catalog_pages = QStackedWidget()
        self._catalog_pages.setMinimumWidth(250)
        self._catalogs = {
            kind: _Catalog(kind, self._tag_registry) for kind in ("ability", "effect")
        }
        for catalog in self._catalogs.values():
            catalog.open_requested.connect(self._open_asset)
            catalog.hover_requested.connect(self._hover_asset)
            catalog.delete_requested.connect(self._delete_assets)
            self._catalog_pages.addWidget(catalog)
        self._catalog_dock = self._dock(self._authoring, "Catalog", "projectAssetsDock", self._catalog_pages, Qt.DockWidgetArea.LeftDockWidgetArea)

        self._issues = QListWidget()
        self._issues.setAccessibleName("Validation and save issues")
        self._issues.setWordWrap(True)
        self._issues.setAlternatingRowColors(True)
        self._issues.setResizeMode(QListWidget.ResizeMode.Adjust)
        self._issues.itemActivated.connect(self._reveal_issue)
        self._issues_dock = self._dock(self, "Issues", "issuesDock", self._issues, Qt.DockWidgetArea.BottomDockWidgetArea)
        self._issues_dock.hide()
        self._build_commands()
        self._apply_workspace_theme()

        self._project_label = _plain_label("No project linked")
        self._save_label = _plain_label("No document")
        self.statusBar().addPermanentWidget(self._save_label)
        self.statusBar().addPermanentWidget(self._project_label)

        self._reader = QProcess(self)
        self._reader.finished.connect(self._tool_finished)
        self._reader.errorOccurred.connect(self._tool_error)
        self._tool_timer = QTimer(self)
        self._tool_timer.setSingleShot(True)
        self._tool_timer.timeout.connect(self._reader.kill)
        self._active_tool = ""
        self._validation_directory: TemporaryDirectory | None = None
        self._pending_attribute_delete: tuple[int, AttributeRevision] | None = None
        self._preview_reader = QProcess(self)
        self._preview_reader.finished.connect(self._accuracy_preview_finished)
        self._preview_reader.errorOccurred.connect(self._accuracy_preview_error)
        self._preview_timer = QTimer(self)
        self._preview_timer.setSingleShot(True)
        self._preview_timer.timeout.connect(self._preview_reader.kill)
        self._queued_preview: tuple[int, list, list] | None = None
        self._active_preview: tuple[int, list, list] | None = None

        self._navigation.currentChanged.connect(self._select_workspace)
        self._restore_workspace()
        self._set_project(self._project_file)

    @staticmethod
    def _dock(owner: QMainWindow, label: str, name: str, body: QWidget, area: Qt.DockWidgetArea) -> QDockWidget:
        dock = QDockWidget(label, owner)
        dock.setObjectName(name)
        dock.setWidget(body)
        owner.addDockWidget(area, dock)
        return dock

    def _build_commands(self) -> None:
        file_menu = self.menuBar().addMenu("&File")
        self._link_action = file_menu.addAction("&Link Godot Project…", self._link_project)
        self._godot_action = file_menu.addAction("&Choose Godot Executable…", self._choose_godot)
        file_menu.addSeparator()
        new_menu = file_menu.addMenu("&New")
        self._new_actions = [
            new_menu.addAction(kind.title(), lambda checked=False, kind=kind: self._new_asset(kind))
            for kind in ("ability", "effect")
        ]
        self._validate = QAction(self.style().standardIcon(QStyle.StandardPixmap.SP_DialogApplyButton), "&Validate", self)
        self._validate.triggered.connect(self._validate_asset)
        self._save = QAction(self.style().standardIcon(QStyle.StandardPixmap.SP_DialogSaveButton), "&Save", self)
        self._save.setShortcut(QKeySequence.StandardKey.Save)
        self._save.triggered.connect(self._save_asset)
        self._reload = QAction(self.style().standardIcon(QStyle.StandardPixmap.SP_BrowserReload), "&Reload", self)
        self._reload.setShortcut(QKeySequence.StandardKey.Refresh)
        self._reload.triggered.connect(self._reload_workspace)
        for action in (self._save, self._validate, self._reload):
            file_menu.addAction(action)
        file_menu.addSeparator()
        file_menu.addAction("E&xit", self.close)

        view_menu = self.menuBar().addMenu("&View")
        for dock in (self._catalog_dock, self._issues_dock):
            view_menu.addAction(dock.toggleViewAction())
        view_menu.addSeparator()
        view_menu.addAction("Reset Workspace Layout", self._reset_layout)

        toolbar = QToolBar("Document", self._authoring)
        toolbar.setObjectName("documentToolbar")
        toolbar.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        toolbar.setMovable(False)
        self._authoring.addToolBar(toolbar)
        new = QToolButton(toolbar)
        new.setText("New")
        new.setIcon(self.style().standardIcon(QStyle.StandardPixmap.SP_FileIcon))
        new.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        new.setMenu(new_menu)
        new.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self._new_button = new
        toolbar.addWidget(new)
        toolbar.addSeparator()
        toolbar.addAction(self._save)
        toolbar.addAction(self._validate)
        toolbar.addSeparator()
        toolbar.addAction(self._reload)

    def _apply_workspace_theme(self) -> None:
        theme = qt_themes.get_theme()
        if theme is None:
            return
        palette = QApplication.palette()
        palette.setColor(QPalette.ColorGroup.Active, QPalette.ColorRole.HighlightedText, theme.crust)
        palette.setColor(QPalette.ColorGroup.Inactive, QPalette.ColorRole.HighlightedText, theme.text.darker(110))
        palette.setColor(QPalette.ColorGroup.Active, QPalette.ColorRole.PlaceholderText, theme.subtext1)
        palette.setColor(QPalette.ColorGroup.Inactive, QPalette.ColorRole.PlaceholderText, theme.subtext1)
        palette.setColor(QPalette.ColorRole.ToolTipText, theme.text)
        QApplication.setPalette(palette)
        self.setStyleSheet(f"""
            QToolBar#documentToolbar, QToolBar#projectWorkspaceBar {{
                background: {theme.mantle.name()};
                border: 0;
                border-bottom: 1px solid {theme.surface0.name()};
                padding: 3px 5px;
                spacing: 4px;
            }}
            QDockWidget::title {{
                background: {theme.mantle.name()};
                border-bottom: 1px solid {theme.surface0.name()};
                padding: 4px 6px;
                text-align: left;
            }}
            QFrame#configurationSection {{
                background: {theme.crust.name()};
                border: 1px solid {theme.surface1.name()};
                border-radius: 5px;
            }}
            QFrame#configurationGroup {{
                border: 1px solid {theme.surface0.name()};
                border-radius: 4px;
            }}
            QFrame#configurationSection QToolButton[sectionHeading="true"] {{
                border: 1px solid transparent;
                border-radius: 3px;
                color: {theme.text.name()};
                font-weight: 600;
                padding: 4px 6px;
            }}
            QFrame#configurationSection QToolButton[primarySection="true"] {{
                background: {theme.mantle.name()};
                font-weight: 700;
                padding: 6px 8px;
            }}
            QFrame#configurationSection QToolButton[sectionHeading="true"]:hover {{
                background: {theme.surface0.name()};
            }}
            QFrame#configurationSection QToolButton[sectionHeading="true"]:focus {{
                border-color: {theme.primary.name()};
            }}
            QLabel#configurationTitle {{ color: {theme.primary.darker(125).name()}; }}
            QLabel[secondary="true"] {{ color: {theme.subtext1.name()}; }}
        """)

    def _reset_layout(self) -> None:
        self._hidden_authoring_layout = None
        for owner, dock, area in (
            (self._authoring, self._catalog_dock, Qt.DockWidgetArea.LeftDockWidgetArea),
            (self, self._issues_dock, Qt.DockWidgetArea.BottomDockWidgetArea),
        ):
            dock.setFloating(False)
            owner.addDockWidget(area, dock)
            dock.setVisible(dock != self._issues_dock or self._issues.count() > 0)
        if not self.isVisible():
            QTimer.singleShot(0, self._size_docks)
        else:
            self._size_docks()

    def _size_docks(self) -> None:
        self._authoring.resizeDocks([self._catalog_dock], [310], Qt.Orientation.Horizontal)
        self.resizeDocks([self._issues_dock], [130], Qt.Orientation.Vertical)

    def _restore_workspace(self) -> None:
        geometry = self._settings.value("workspace/geometry", QByteArray())
        if isinstance(geometry, QByteArray) and not geometry.isEmpty():
            self.restoreGeometry(geometry)
        window_state = self._settings.value("workspace/docks", QByteArray())
        authoring_state = self._settings.value("workspace/authoring", QByteArray())
        if not (isinstance(window_state, QByteArray) and isinstance(authoring_state, QByteArray)
                and self.restoreState(window_state, LAYOUT_VERSION)
                and self._authoring.restoreState(authoring_state, LAYOUT_VERSION)):
            self._reset_layout()

    def _workspace_kind(self) -> str:
        return self._navigation.tabData(self._navigation.currentIndex())

    def _select_workspace(self, index: int) -> None:
        kind = self._navigation.tabData(index)
        if kind in self._catalogs:
            self._catalog_pages.setCurrentWidget(self._catalogs[kind])
            self._workspace.setCurrentWidget(self._authoring)
            if self._hidden_authoring_layout is not None:
                self._authoring.restoreState(self._hidden_authoring_layout, LAYOUT_VERSION)
                self._hidden_authoring_layout = None
        else:
            if (self._workspace.currentWidget() is self._authoring and self._catalog_dock.isFloating()
                    and self._catalog_dock.isVisible()):
                self._hidden_authoring_layout = self._authoring.saveState(LAYOUT_VERSION)
                self._catalog_dock.hide()
            self._workspace.setCurrentWidget({
                "tags": self._tags, "attributes": self._attributes, "player_actions": self._player_actions,
            }[kind])
            if kind == "player_actions":
                self._player_actions.reload()
        self._update_document_state()

    def _set_project(self, file: Path | None) -> None:
        self._cancel_accuracy_preview()
        self._project_file = file
        root = file.parent if file and file.is_file() else None
        self._clear_issues()
        try:
            self._project = JsonProject(root) if root else None
        except (OSError, ValueError) as error:
            self._project = None
            self._show_issues(str(error))
            root = None
        self._tag_registry.set_project(root)
        self._attribute_registry.set_project(root)
        self._player_actions.set_project(self._project)
        self._schema = {}
        self._project_assets = {}
        self._pending_document = None
        self._close_document()
        self._attributes.show_list()
        self._project_label.setText(f"Project · {root.name}" if root else "No project linked")
        self._project_label.setToolTip(str(file) if file else "")
        self._refresh_catalog()

    def _link_project(self) -> None:
        start = str(self._project_file.parent) if self._project_file else ""
        selected, _ = QFileDialog.getOpenFileName(self, "Link Godot Project", start, "Godot project (project.godot)")
        if not selected:
            return
        file = Path(selected).resolve()
        if file.name != "project.godot" or not file.is_file():
            self._show_issues("Choose a valid project.godot file.")
            return
        if file == self._project_file or not self._can_leave_asset() or not self._attributes.can_leave_editor():
            return
        self._settings.setValue("project_file", str(file))
        self._set_project(file)

    def _choose_godot(self) -> None:
        selected, _ = QFileDialog.getOpenFileName(
            self, "Choose Godot Executable", self._godot_executable,
            "Godot executable (*.exe);;All files (*)",
        )
        if selected:
            self._godot_executable = selected
            self._settings.setValue("godot_executable", selected)
            self._schema = {}
            self.statusBar().showMessage("Godot executable linked.", 5000)

    def _refresh_catalog(self) -> None:
        self._entries = []
        warnings = []
        if self._project:
            try:
                self._entries, warnings = self._project.scan()
            except (OSError, ValueError) as error:
                warnings = [str(error)]
        self._update_catalog_selection()
        if warnings:
            self._show_issues(*warnings)
        self._update_document_state()

    def _update_catalog_selection(self) -> None:
        root = self._project_file.parent if self._project else None
        path = self._document.path if self._document else ""
        for catalog in self._catalogs.values():
            catalog.set_entries(root, self._entries, path)

    def _reload_workspace(self) -> None:
        configuration_active = self._document is not None and self._workspace_kind() == self._document_kind
        if configuration_active and not self._can_leave_asset():
            return
        self._clear_issues()
        self._tag_registry.reload()
        self._attribute_registry.reload()
        if self._workspace_kind() == "player_actions":
            self._player_actions.reload()
        self._schema = {}
        self._project_assets = {}
        if not configuration_active:
            self._refresh_catalog()
            self.statusBar().showMessage("Project catalog reloaded.", 5000)
            return
        path = self._document.path
        self._close_document()
        self._refresh_catalog()
        if path:
            self._open_asset(path)
        else:
            self.statusBar().showMessage("Project catalog reloaded.", 5000)

    def _hover_asset(self, path: str, kind: str) -> None:
        if not self._project or self._active_tool or self._has_dirty_document() or kind != self._workspace_kind():
            return
        if self._schema:
            self._open_asset(path)
        else:
            self._load_schema()

    def _open_asset(self, path: str) -> None:
        if not self._project:
            return
        if self._document and self._document.path == path:
            self._navigation.setCurrentIndex(self._workspace_indices[self._document_kind])
            return
        loading_schema = self._active_tool == "schema" and not self._has_dirty_document()
        if not loading_schema and not self._can_leave_asset():
            self._update_catalog_selection()
            return
        try:
            document = self._project.open(path)
        except (OSError, ValueError) as error:
            self._show_issues(str(error))
            return
        entry = next((entry for entry in self._entries if entry["path"] == path), {})
        kind = entry.get("kind", "effect" if path.endswith(".effect.json") else "ability")
        self._request_document(document, kind, entry.get("name") or Path(path).name)

    def _new_asset(self, kind: str) -> None:
        if not self._project or not self._can_leave_asset():
            return
        try:
            document = self._project.new(kind)
        except (OSError, ValueError) as error:
            self._show_issues(str(error))
            return
        self._request_document(document, kind, f"New {kind}")

    def _request_document(self, document: JsonDocument, kind: str, name: str) -> None:
        if not self._schema:
            self._pending_document = (document, kind, name)
            if self._active_tool != "schema" and not self._load_schema():
                self._pending_document = None
            return
        self._show_document(document, kind, name)

    def _show_document(self, document: JsonDocument, kind: str, name: str) -> None:
        try:
            self._editor.load(document.data, document.path, self._schema, self._editor_catalogs())
        except (KeyError, TypeError, ValueError) as error:
            self._show_issues(f"Could not display the configuration. {error}")
            return
        self._document = document
        self._document_kind = kind
        self._document_name = name
        self._navigation.setCurrentIndex(self._workspace_indices[kind])
        self._catalogs[kind].select_path(document.path)
        self._update_document_state()

    def _editor_catalogs(self) -> dict:
        return {
            "project": self._project.root if self._project else None,
            "abilities": [entry for entry in self._entries if entry["kind"] == "ability"],
            "effects": [entry for entry in self._entries if entry["kind"] == "effect"],
            "assets": self._project_assets,
        }

    def _close_document(self) -> None:
        self._document = None
        self._document_kind = ""
        self._document_name = ""
        self._editor_page.setCurrentIndex(0)
        self._editor.clear()
        self._update_document_state()

    def _update_document_state(self) -> None:
        kind = self._workspace_kind()
        authoring = kind in self._catalogs
        active = self._document is not None and kind == self._document_kind
        busy = bool(getattr(self, "_active_tool", ""))
        self._editor_page.setCurrentIndex(int(active))
        self._catalog_dock.toggleViewAction().setEnabled(authoring)
        if authoring:
            self._empty_editor.setText(
                f"Open an {kind}\n\nHover over or click an entry in the Catalog, or use New on the toolbar."
                if self._project else "Link a Godot project to get started.\n\nChoose File → Link Godot Project."
            )
        self._editor.setEnabled(not busy)
        dirty = self._has_dirty_document()
        cost_unit_repairs = active and self._editor.has_cost_unit_repairs
        self.setWindowTitle(f"{self._document_name} — Ability Editor[*]" if active else "Ability Editor[*]")
        self.setWindowModified(active and dirty)
        if active:
            if cost_unit_repairs and not dirty:
                self._save_label.setText("Save to update cost units")
            else:
                self._save_label.setText("Unsaved changes" if dirty else "Saved")
        else:
            self._save_label.setText(f"Unsaved {self._document_kind} draft" if dirty else "")
        self._save.setEnabled(active and (dirty or cost_unit_repairs) and not busy)
        self._validate.setEnabled(active and not busy)
        self._reload.setEnabled(self._project is not None and not busy)
        self._new_button.setEnabled(self._project is not None and not busy)
        self._link_action.setEnabled(not busy)
        self._godot_action.setEnabled(not busy)
        for action in self._new_actions:
            action.setEnabled(self._project is not None and not busy)

    def _has_dirty_document(self) -> bool:
        return self._document is not None and (not self._document.path or self._editor.dirty)

    def _can_leave_asset(self) -> bool:
        if getattr(self, "_active_tool", ""):
            return False
        if not self._has_dirty_document():
            return True
        answer = QMessageBox.question(
            self, "Unsaved Changes", "Save the current definition before leaving it?",
            QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Save,
        )
        if answer == QMessageBox.StandardButton.Save:
            return self._save_asset()
        return answer == QMessageBox.StandardButton.Discard

    def _choose_asset_path(self) -> str:
        root = self._project_file.parent
        suffix = f".{self._document_kind}.json"
        draft = self._editor.draft()
        name = draft["resources"][draft["root"]]["properties"].get("display_name") or self._document_name
        filename = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_") or "definition"
        selected, _ = QFileDialog.getSaveFileName(
            self, "Save New Definition", str(root / f"{filename}{suffix}"),
            f"{self._document_kind.title()} definitions (*{suffix})",
            options=QFileDialog.Option.DontConfirmOverwrite,
        )
        if not selected:
            return ""
        if selected.lower().endswith(suffix):
            selected = selected[:-len(suffix)] + suffix
        else:
            selected += suffix
        try:
            relative = Path(selected).absolute().relative_to(root)
        except ValueError as error:
            raise ValueError("Save definitions inside the linked project.") from error
        return "res://" + relative.as_posix()

    def _save_asset(self) -> bool:
        if not self._document or not self._project or getattr(self, "_active_tool", ""):
            return False
        try:
            path = self._document.path or self._choose_asset_path()
            if not path:
                return False
            document = self._project.save(path, self._editor.draft(), self._document.revision)
        except (OSError, ValueError) as error:
            self._show_issues(f"Save failed. {error}")
            self.statusBar().showMessage("Save failed. See Issues for details.")
            return False
        self._document = document
        self._editor.mark_saved(document.data, document.path)
        self._clear_issues()
        self._refresh_catalog()
        entry = next((entry for entry in self._entries if entry["path"] == document.path), None)
        if entry:
            self._document_name = entry["name"]
        self._update_document_state()
        self.statusBar().showMessage(f"Saved {document.path}", 8000)
        return True

    def _delete_assets(self, paths: list[str]) -> None:
        if not paths or not self._project or self._active_tool:
            return
        current = self._document is not None and self._document.path in paths
        if current and not self._can_leave_asset():
            return
        prompt = f"Move this definition to the Recycle Bin?\n\n{paths[0]}" if len(paths) == 1 else (
            f"Move {len(paths)} selected definitions to the Recycle Bin?"
        )
        answer = QMessageBox.question(
            self, "Delete Definitions", prompt,
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Cancel,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        try:
            revisions = [(path, self._project.open(path).revision) for path in paths]
            self._project.delete_many(revisions)
        except (OSError, ValueError) as error:
            if current and not (self._project.root / self._document.path.removeprefix("res://")).is_file():
                self._close_document()
            self._refresh_catalog()
            self._show_issues(f"Delete failed. {error}")
            return
        if current:
            self._close_document()
        self._clear_issues()
        self._refresh_catalog()
        count = len(paths)
        self.statusBar().showMessage(f"Moved {count} definition{'s' if count != 1 else ''} to the Recycle Bin.", 5000)

    def _show_issues(self, *messages: str) -> None:
        self._issues.clear()
        for message in messages:
            self._issues.addItem(str(message))
            self._issues.item(self._issues.count() - 1).setToolTip(str(message))
        self._issues_dock.setWindowTitle(f"Issues ({len(messages)})" if messages else "Issues")
        if messages:
            self._issues_dock.show()

    def _clear_issues(self) -> None:
        self._show_issues()

    def _reveal_issue(self, item) -> None:
        if self._document:
            self._navigation.setCurrentIndex(self._workspace_indices[self._document_kind])
            self._editor.reveal(item.text())

    def _load_schema(self) -> bool:
        return self._start_tool("schema", SCHEMA_SCRIPT, [], "Loading Godot configuration…")

    def _validate_asset(self) -> None:
        if self._document is None or self._project is None or self._active_tool:
            return
        self._clear_issues()
        try:
            draft = self._project.validation_data(self._editor.draft(), self._document_kind, self._document.path)
            self._validation_directory = TemporaryDirectory(prefix="ability-editor-")
            file = Path(self._validation_directory.name) / f"draft.{self._document_kind}.json"
            file.write_text(json.dumps(draft, ensure_ascii=False, allow_nan=False), encoding="utf-8")
            arguments = ["--validate-definition", str(file)]
            if self._document.path:
                arguments.append(self._document.path)
            if self._start_tool("validate", ATTRIBUTE_SCRIPT, arguments, "Validating in Godot…"):
                return
        except (OSError, ValueError) as error:
            self._show_issues(str(error))
        self._clear_validation_directory()

    def _clear_validation_directory(self) -> None:
        if self._validation_directory is not None:
            self._validation_directory.cleanup()
            self._validation_directory = None

    def _handle_authoring_result(self, action: str, output: str) -> None:
        if action == "schema":
            result = self._result(output, SCHEMA_PREFIX)
            if not isinstance(result.get("types"), dict) or not result["types"] or not isinstance(result.get("assets"), dict):
                raise ValueError("Expected Godot property types and asset paths.")
            self._schema = result
            self._project_assets = result["assets"]
            pending, self._pending_document = self._pending_document, None
            self.statusBar().clearMessage()
            if pending is not None:
                self._show_document(*pending)
            elif catalog := self._catalogs.get(self._workspace_kind()):
                if path := catalog.hovered_path():
                    self._hover_asset(path, catalog.kind)
        else:
            issues = self._result(output, VALIDATION_PREFIX).get("issues")
            if not isinstance(issues, list) or not all(isinstance(issue, str) for issue in issues):
                raise ValueError("Expected a list of validation issues.")
            self._show_issues(*issues)
            self.statusBar().showMessage(
                f"Godot reported {len(issues)} validation issue{'s' if len(issues) != 1 else ''}."
                if issues else "Godot validation passed.", 8000,
            )

    def _sync_tag_manager(self) -> None:
        error = self._tag_registry.error
        self._tags.set_entries(self._tag_registry.entries, not error, error)

    def _register_tag(self, name: str, description: str) -> None:
        try:
            registered = self._tag_registry.register(name, description)
        except (OSError, ValueError) as error:
            self._show_issues(str(error))
            return
        self.statusBar().showMessage(f"Registered {registered}.", 5000)

    def _godot_command(
        self, script: str, user_arguments: list[str], *, report_error: bool = True,
    ) -> tuple[str, list[str], Path] | None:
        project = self._project_file.parent if self._project else None
        executable = self._godot_executable or which("godot") or which("godot4")
        if not project:
            message = "Link this game's project.godot through File → Link Godot Project."
        elif not (project / script).is_file():
            message = f"The linked checkout is missing {script}."
        elif not (project / ".godot/global_script_class_cache.cfg").is_file():
            message = "Import the linked project in Godot once so its script classes are available."
        elif not executable or not Path(executable).is_file():
            message = "Link Godot through File → Choose Godot Executable."
        else:
            arguments = ["--headless", "--no-header", "--path", str(project), "--script", f"res://{script}"]
            if user_arguments:
                arguments.extend(["--", *user_arguments])
            return executable, arguments, project
        if report_error:
            self._show_issues(message)
        return None

    def _start_tool(self, action: str, script: str, arguments: list[str], message: str) -> bool:
        if self._active_tool:
            return False
        command = self._godot_command(script, arguments)
        if command is None:
            return False
        executable, arguments, project = command
        self._active_tool = action
        self._reader.setWorkingDirectory(str(project))
        self._tool_timer.start(30_000)
        self.statusBar().showMessage(message)
        self._update_document_state()
        self._reader.start(executable, arguments)
        return True

    def _tool_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.ProcessError.FailedToStart:
            self._finish_tool()
            self._pending_document = None
            self._pending_attribute_delete = None
            self._show_issues(f"Godot could not start. {self._reader.errorString()}")

    def _finish_tool(self) -> str:
        action = self._active_tool
        self._active_tool = ""
        self._tool_timer.stop()
        self._clear_validation_directory()
        self.statusBar().clearMessage()
        self._update_document_state()
        return action

    @staticmethod
    def _result(output: str, prefix: str) -> dict:
        line = next(line for line in output.splitlines() if line.startswith(prefix))
        result = json.loads(line[len(prefix):])
        if not isinstance(result, dict):
            raise ValueError("Expected a JSON result object.")
        return result

    def _tool_finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        timed_out = not self._tool_timer.isActive()
        action = self._finish_tool()
        output = bytes(self._reader.readAllStandardOutput()).decode("utf-8", errors="replace")
        errors = bytes(self._reader.readAllStandardError()).decode("utf-8", errors="replace").strip()
        if not action:
            return
        if timed_out or exit_code or exit_status != QProcess.ExitStatus.NormalExit:
            self._pending_document = None
            self._pending_attribute_delete = None
            self._show_issues("Godot took too long." if timed_out else errors or output or "Godot could not complete the request.")
            return
        try:
            if action == "attribute_delete":
                self._delete_checked_attribute(self._result(output, ATTRIBUTE_DELETE_PREFIX))
            else:
                self._handle_authoring_result(action, output)
        except (StopIteration, KeyError, TypeError, ValueError) as error:
            self._pending_document = None
            self._pending_attribute_delete = None
            self._show_issues(errors or f"Godot returned an unreadable result. {error}")

    def _confirm_attribute_delete(self, attribute_id: int) -> None:
        if self._active_tool:
            return
        entry = next((entry for entry in self._attribute_registry.entries if entry["id"] == attribute_id), None)
        revision = self._attribute_registry.revision
        if entry is None or entry["builtin"] or revision is None:
            return
        answer = QMessageBox.question(
            self, "Delete Attribute",
            f"Delete {entry['name']} (ID {attribute_id})? Godot will check saved references first.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Cancel,
        )
        if answer == QMessageBox.StandardButton.Yes:
            self._pending_attribute_delete = (attribute_id, revision)
            if not self._start_tool(
                "attribute_delete", ATTRIBUTE_SCRIPT, ["--check-attribute-delete", str(attribute_id)],
                "Checking saved attribute references…",
            ):
                self._pending_attribute_delete = None

    def _delete_checked_attribute(self, result: dict) -> None:
        pending = self._pending_attribute_delete
        self._pending_attribute_delete = None
        if not pending or result.get("id") != pending[0] or not isinstance(result.get("issues"), list):
            raise ValueError("Godot returned a different attribute selection.")
        if result["issues"]:
            self._show_issues(*result["issues"])
            return
        try:
            self._attribute_registry.delete(pending[0], revision=pending[1])
        except (OSError, ValueError) as error:
            self._show_issues(str(error))
            return
        self.statusBar().showMessage(f"Deleted attribute {pending[0]}.", 5000)

    def _queue_accuracy_preview(self, gap: int, base: list, ceiling: list) -> None:
        self._queued_preview = (gap, list(base), list(ceiling))
        self._start_accuracy_preview()

    def _start_accuracy_preview(self) -> None:
        if self._queued_preview is None or self._preview_reader.state() != QProcess.ProcessState.NotRunning:
            return
        request = self._queued_preview
        self._queued_preview = None
        gap, base, ceiling = request
        command = self._godot_command(
            ATTRIBUTE_SCRIPT,
            ["--preview-accuracy", str(gap), json.dumps(base, allow_nan=False), json.dumps(ceiling, allow_nan=False)],
            report_error=False,
        )
        if command is None:
            self._attributes.set_preview(*request, None)
            return
        executable, arguments, project = command
        self._active_preview = request
        self._preview_reader.setWorkingDirectory(str(project))
        self._preview_timer.start(15_000)
        self._preview_reader.start(executable, arguments)

    def _accuracy_preview_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.ProcessError.FailedToStart:
            self._finish_accuracy_preview(None)

    def _accuracy_preview_finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        output = bytes(self._preview_reader.readAllStandardOutput()).decode("utf-8", errors="replace")
        errors = self._preview_reader.readAllStandardError()
        chance = None
        if exit_code == 0 and exit_status == QProcess.ExitStatus.NormalExit and errors.isEmpty():
            try:
                candidate = self._result(output, ACCURACY_PREVIEW_PREFIX)["chance"]
                if type(candidate) in (float, int) and 0 <= candidate <= 1:
                    chance = float(candidate)
            except (StopIteration, ValueError, TypeError, KeyError):
                pass
        self._finish_accuracy_preview(chance)

    def _finish_accuracy_preview(self, chance: float | None) -> None:
        self._preview_timer.stop()
        request = self._active_preview
        self._active_preview = None
        if request is not None and self._queued_preview is None:
            self._attributes.set_preview(*request, chance)
        self._start_accuracy_preview()

    def _cancel_accuracy_preview(self) -> None:
        self._queued_preview = None
        self._active_preview = None
        if self._preview_reader.state() != QProcess.ProcessState.NotRunning:
            self._preview_reader.kill()
            self._preview_reader.waitForFinished(1000)

    def closeEvent(self, event) -> None:
        if not self._can_leave_asset() or not self._attributes.can_leave_editor():
            event.ignore()
            return
        self._settings.setValue("workspace/geometry", self.saveGeometry())
        self._settings.setValue("workspace/docks", self.saveState(LAYOUT_VERSION))
        authoring_state = self._hidden_authoring_layout or self._authoring.saveState(LAYOUT_VERSION)
        self._settings.setValue("workspace/authoring", authoring_state)
        self._cancel_accuracy_preview()
        super().closeEvent(event)


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Ability Editor")
    qt_themes.set_theme("catppuccin_latte", style="Fusion")
    window = AbilityEditorWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
