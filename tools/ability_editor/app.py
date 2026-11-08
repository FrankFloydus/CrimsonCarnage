"""Standalone desktop window for the ability editor."""

import base64
import json
import re
import sys
from pathlib import Path
from shutil import which
from uuid import uuid4

from PySide6.QtCore import (
    QFile, QModelIndex, QPoint, QProcess, QSettings, QSize, QSortFilterProxyModel, Qt, QTimer, Signal,
)
from PySide6.QtGui import QIcon, QKeySequence, QPalette, QPixmap, QStandardItem, QStandardItemModel
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QFileDialog,
    QHBoxLayout,
    QLineEdit,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPushButton,
    QStackedWidget,
    QTableView,
    QTabWidget,
    QToolButton,
    QVBoxLayout,
    QWidget,
)
import qt_themes

if __package__:
    from .ability_composer_io import COMPOSER_SCRIPT, AbilityComposerIO, resource_file
    from .ability_composer_widgets import AbilityComposer
    from .attribute_registry import AttributeRegistry, AttributeRevision
    from .attribute_widgets import AttributeManager
    from .tag_registry import TagRegistry
    from .tag_widgets import TagManager, choose_tag
else:
    from ability_composer_io import COMPOSER_SCRIPT, AbilityComposerIO, resource_file
    from ability_composer_widgets import AbilityComposer
    from attribute_registry import AttributeRegistry, AttributeRevision
    from attribute_widgets import AttributeManager
    from tag_registry import TagRegistry
    from tag_widgets import TagManager, choose_tag


CATALOG_SCRIPT = "tools/ability_editor/read_abilities.gd"
CATALOG_PREFIX = "ABILITY_EDITOR_CATALOG "
DELETE_CHECK_PREFIX = "ABILITY_EDITOR_DELETE_CHECK "
ATTRIBUTE_DELETE_PREFIX = "ABILITY_EDITOR_ATTRIBUTE_DELETE "
ACCURACY_PREVIEW_PREFIX = "ABILITY_EDITOR_ACCURACY_PREVIEW "
ID_COLUMN = 0
ICON_COLUMN = 1
NAME_COLUMN = 2
TAGS_COLUMN = 3


def find_project_file() -> Path | None:
    app_file = Path(sys.executable if getattr(sys, "frozen", False) else __file__)
    for directory in app_file.resolve().parents:
        project_file = directory / "project.godot"
        if project_file.is_file() and (directory / CATALOG_SCRIPT).is_file():
            return project_file
    return None


def catalog_rows(entries: list[dict]) -> list[list[QStandardItem]]:
    rows = []
    for entry in entries:
        entry_id = entry["id"]
        if type(entry_id) is not int:
            raise ValueError("The catalog must use integer IDs.")
        tags = ", ".join(entry["tags"])
        icon = QStandardItem()
        items = [QStandardItem(str(entry_id)), icon, QStandardItem(entry["name"]), QStandardItem(tags)]
        items[ID_COLUMN].setToolTip(entry["path"])
        items[ID_COLUMN].setData(entry["path"], Qt.ItemDataRole.UserRole)
        items[TAGS_COLUMN].setToolTip(tags)
        items[TAGS_COLUMN].setData(entry["tags"], Qt.ItemDataRole.UserRole)
        if entry["icon_png"]:
            pixmap = QPixmap()
            if pixmap.loadFromData(base64.b64decode(entry["icon_png"], validate=True), "PNG"):
                icon.setIcon(QIcon(pixmap))
        rows.append(items)
    return rows


class CatalogSortProxy(QSortFilterProxyModel):
    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.tag_filter = ""

    def set_tag_filter(self, tag: str) -> None:
        if tag == self.tag_filter:
            return
        self.beginFilterChange()
        self.tag_filter = tag
        self.endFilterChange(QSortFilterProxyModel.Direction.Rows)

    def filterAcceptsRow(self, source_row: int, source_parent: QModelIndex) -> bool:
        if not super().filterAcceptsRow(source_row, source_parent):
            return False
        if not self.tag_filter:
            return True
        tags_index = self.sourceModel().index(source_row, TAGS_COLUMN, source_parent)
        tags = tags_index.data(Qt.ItemDataRole.UserRole) or []
        return any(tag == self.tag_filter or tag.startswith(self.tag_filter + ".") for tag in tags)

    def lessThan(self, left: QModelIndex, right: QModelIndex) -> bool:
        if left.column() == ID_COLUMN:
            return int(left.data()) < int(right.data())
        if left.column() == ICON_COLUMN:
            role = Qt.ItemDataRole.DecorationRole
            return (left.data(role) is not None) < (right.data(role) is not None)
        return super().lessThan(left, right)


class CatalogTab(QWidget):
    delete_requested = Signal(list)
    edit_requested = Signal(str)
    new_requested = Signal()

    def __init__(self, entry_name: str, search_name: str, tag_registry: TagRegistry, *, authorable: bool = False) -> None:
        super().__init__()
        self._tag_registry = tag_registry
        self._authorable = authorable

        columns = ["ID", "Icon", f"{entry_name} Name", "Tags"]
        self._model = QStandardItemModel(0, len(columns), self)
        self._model.setHorizontalHeaderLabels(columns)

        self._filtered_catalog = CatalogSortProxy(self)
        filtered_catalog = self._filtered_catalog
        filtered_catalog.setSourceModel(self._model)
        filtered_catalog.setFilterKeyColumn(-1)
        filtered_catalog.setFilterCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        filtered_catalog.setSortCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)

        search = QLineEdit()
        search.setAccessibleName(f"Search {search_name}")
        search.setPlaceholderText("Search by ID, name, or tag…")
        search.setClearButtonEnabled(True)
        search.textChanged.connect(filtered_catalog.setFilterFixedString)

        self._tag_filter_button = QPushButton("Filter by Tag…")
        self._tag_filter_button.clicked.connect(self._choose_tag_filter)
        self._clear_tag_filter = QToolButton()
        self._clear_tag_filter.setText("×")
        self._clear_tag_filter.setToolTip("Clear tag filter")
        self._clear_tag_filter.setAccessibleName("Clear tag filter")
        self._clear_tag_filter.clicked.connect(lambda: self._set_tag_filter(""))
        self._clear_tag_filter.hide()
        tag_registry.changed.connect(self._sync_tag_filter)
        self._sync_tag_filter()

        actions = QHBoxLayout()
        actions.addWidget(search, 3)
        actions.addWidget(self._tag_filter_button)
        actions.addWidget(self._clear_tag_filter)
        actions.addStretch(2)
        new = QPushButton(f"New {entry_name}")
        if authorable:
            self._edit = QPushButton("Edit…")
            self._edit.setEnabled(False)
            self._edit.clicked.connect(self._edit_selection)
            actions.addWidget(self._edit)
            new.clicked.connect(self.new_requested.emit)
        actions.addWidget(new)

        self._table = QTableView()
        table = self._table
        table.setModel(filtered_catalog)
        palette = table.palette()
        base_color = palette.color(QPalette.ColorRole.Base)
        if palette.color(QPalette.ColorRole.AlternateBase) == base_color:
            palette.setColor(QPalette.ColorRole.AlternateBase, base_color.lighter(120))
            table.setPalette(palette)
        table.setAlternatingRowColors(True)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        if authorable:
            table.selectionModel().selectionChanged.connect(self._update_edit_action)
            table.doubleClicked.connect(self._edit_index)
        table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        table.customContextMenuRequested.connect(self._show_context_menu)
        table.setIconSize(QSize(24, 24))
        table.verticalHeader().hide()
        header = table.horizontalHeader()
        header.setStretchLastSection(True)
        header.setSortIndicator(ID_COLUMN, Qt.SortOrder.DescendingOrder)
        table.setSortingEnabled(True)
        table.setColumnWidth(ID_COLUMN, 48)
        table.setColumnWidth(ICON_COLUMN, 56)
        table.setColumnWidth(NAME_COLUMN, 250)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 12, 12, 12)
        layout.setSpacing(8)
        layout.addLayout(actions)
        layout.addWidget(table)

    def set_rows(self, rows: list[list[QStandardItem]]) -> None:
        self._model.removeRows(0, self._model.rowCount())
        for items in rows:
            self._model.appendRow(items)

    def _sync_tag_filter(self) -> None:
        entries = self._tag_registry.entries
        available = bool(entries) and not self._tag_registry.error
        self._tag_filter_button.setEnabled(available)
        tag = self._filtered_catalog.tag_filter
        if tag and (not available or not any(
            entry["name"] == tag or entry["name"].startswith(tag + ".") for entry in entries
        )):
            self._set_tag_filter("")

    def _choose_tag_filter(self) -> None:
        tag = choose_tag(self, self._tag_registry.entries, "Filter by Tag")
        if tag is not None:
            self._set_tag_filter(tag)

    def _set_tag_filter(self, tag: str) -> None:
        self._filtered_catalog.set_tag_filter(tag)
        self._tag_filter_button.setText(f"Tag: {tag}" if tag else "Filter by Tag…")
        self._clear_tag_filter.setVisible(bool(tag))

    def _update_edit_action(self) -> None:
        self._edit.setEnabled(len(self._table.selectionModel().selectedRows(ID_COLUMN)) == 1)

    def _edit_selection(self) -> None:
        rows = self._table.selectionModel().selectedRows(ID_COLUMN)
        if len(rows) == 1:
            self._edit_index(rows[0])

    def _edit_index(self, index: QModelIndex) -> None:
        path = index.siblingAtColumn(ID_COLUMN).data(Qt.ItemDataRole.UserRole)
        if isinstance(path, str):
            self.edit_requested.emit(path)

    def _show_context_menu(self, position: QPoint) -> None:
        selection = self._table.selectionModel()
        index = self._table.indexAt(position)
        if not index.isValid() or not selection.isSelected(index):
            return
        paths = [row.data(Qt.ItemDataRole.UserRole) for row in selection.selectedRows(ID_COLUMN)]
        menu = QMenu(self._table)
        edit = menu.addAction("Edit…") if self._authorable and len(paths) == 1 else None
        delete = menu.addAction("Delete")
        action = menu.exec(self._table.viewport().mapToGlobal(position))
        if action == delete:
            self.delete_requested.emit(paths)
        elif edit is not None and action == edit:
            self.edit_requested.emit(paths[0])
        menu.deleteLater()


class AbilityEditorWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Ability Editor")
        self.resize(1000, 680)

        self._settings = QSettings("Untitled", "Ability Editor")
        saved_project = self._settings.value("project_file", "", type=str)
        self._project_file = Path(saved_project) if saved_project else find_project_file()
        self._godot_executable = self._settings.value("godot_executable", "", type=str)

        file_menu = self.menuBar().addMenu("&File")
        link_project = file_menu.addAction("&Link Godot Project…", self._link_project)
        choose_godot = file_menu.addAction("&Choose Godot Executable…", self._choose_godot)
        refresh = file_menu.addAction("&Refresh Catalog", self._refresh_catalog)
        refresh.setShortcut(QKeySequence.StandardKey.Refresh)
        self._catalog_actions = (link_project, choose_godot, refresh)
        file_menu.addSeparator()
        file_menu.addAction("E&xit", self.close)

        self._tag_registry = TagRegistry(self)
        self._attribute_registry = AttributeRegistry(self)
        self._abilities = CatalogTab("Ability", "abilities", self._tag_registry, authorable=True)
        self._effects = CatalogTab("Effect", "effects", self._tag_registry)
        self._composer = AbilityComposer(self._tag_registry)
        self._ability_pages = QStackedWidget()
        self._ability_pages.addWidget(self._abilities)
        self._ability_pages.addWidget(self._composer)
        self._composer_io = AbilityComposerIO(self)
        self._composer_io.completed.connect(self._composer_finished)
        self._composer_path = ""
        self._composer_revision = ""
        self._composer_pending_path = ""
        self._composer_effects: list[dict] = []
        self._composer_assets: dict[str, list[str]] = {}
        self._abilities.edit_requested.connect(self._open_ability)
        self._abilities.new_requested.connect(self._new_ability)
        self._composer.back_requested.connect(self._back_to_abilities)
        self._composer.check_requested.connect(lambda draft: self._stage_ability(draft, publish=False))
        self._composer.save_requested.connect(lambda draft: self._stage_ability(draft, publish=True))
        self._tags = TagManager()
        self._attributes = AttributeManager(self._attribute_registry)
        self._attributes.delete_requested.connect(self._confirm_attribute_delete)
        self._attributes.preview_requested.connect(self._queue_accuracy_preview)
        self._tags.tag_requested.connect(self._register_tag)
        self._tag_registry.changed.connect(self._sync_tag_manager)
        self._abilities.delete_requested.connect(self._confirm_delete)
        self._effects.delete_requested.connect(self._confirm_delete)
        tabs = QTabWidget(self)
        tabs.addTab(self._ability_pages, "Abilities")
        tabs.addTab(self._effects, "Effects")
        tabs.addTab(self._tags, "Tags")
        tabs.addTab(self._attributes, "Attributes")
        self.setCentralWidget(tabs)

        self._reader = QProcess(self)
        self._reader.finished.connect(self._catalog_finished)
        self._reader.errorOccurred.connect(self._catalog_error)
        self._pending_delete: list[str] = []
        self._pending_attribute_delete: tuple[int, AttributeRevision] | None = None
        self._catalog_timer = QTimer(self)
        self._catalog_timer.setSingleShot(True)
        self._catalog_timer.timeout.connect(self._reader.kill)
        self._preview_reader = QProcess(self)
        self._preview_reader.finished.connect(self._accuracy_preview_finished)
        self._preview_reader.errorOccurred.connect(self._accuracy_preview_error)
        self._preview_timer = QTimer(self)
        self._preview_timer.setSingleShot(True)
        self._preview_timer.timeout.connect(self._preview_reader.kill)
        self._queued_preview: tuple[int, list, list] | None = None
        self._active_preview: tuple[int, list, list] | None = None
        self._tag_registry.set_project(self._project_file.parent if self._project_file else None)
        self._attribute_registry.set_project(self._project_file.parent if self._project_file else None)
        self._sync_tag_manager()
        self._start_catalog_command([])

    def _link_project(self) -> None:
        start_directory = str(self._project_file.parent) if self._project_file else ""
        selected, _ = QFileDialog.getOpenFileName(
            self, "Link Godot Project", start_directory, "Godot project (project.godot)"
        )
        if selected:
            project_file = Path(selected).resolve()
            if project_file.name != "project.godot" or not (project_file.parent / CATALOG_SCRIPT).is_file():
                self._show_status("Choose this game's project.godot from a checkout with the catalog script.")
                return
            if project_file != self._project_file:
                if not self._can_leave_composer() or not self._attributes.can_leave_editor():
                    return
                self._abilities.set_rows([])
                self._effects.set_rows([])
                self._ability_pages.setCurrentWidget(self._abilities)
                self._composer_effects = []
                self._composer_assets = {}
                self._attributes.show_list()
                self._queued_preview = None
                self._active_preview = None
            self._project_file = project_file
            self._settings.setValue("project_file", str(project_file))
            self._tag_registry.set_project(project_file.parent)
            self._attribute_registry.set_project(project_file.parent)
            self._start_catalog_command([])

    def _choose_godot(self) -> None:
        selected, _ = QFileDialog.getOpenFileName(
            self, "Choose Godot Executable", self._godot_executable,
            "Godot executable (*.exe);;All files (*)"
        )
        if selected:
            self._godot_executable = selected
            self._settings.setValue("godot_executable", selected)
            self._refresh_catalog()

    def _refresh_catalog(self) -> None:
        self._tag_registry.reload()
        self._attribute_registry.reload()
        self._start_catalog_command([])

    def _sync_tag_manager(self) -> None:
        error = self._tag_registry.error
        self._tags.set_entries(self._tag_registry.entries, not error, error)

    def _register_tag(self, name: str, description: str) -> None:
        try:
            registered = self._tag_registry.register(name, description)
        except (OSError, ValueError) as error:
            QMessageBox.warning(self, "Tag Registry", str(error))
            return
        self._show_status(f"Registered {registered}.")

    def _confirm_delete(self, paths: list[str]) -> None:
        if not paths or self._composer_io.busy or self._reader.state() != QProcess.ProcessState.NotRunning:
            return
        dialog = QMessageBox(self)
        dialog.setIcon(QMessageBox.Icon.Warning)
        dialog.setWindowTitle("Delete Selected")
        dialog.setTextFormat(Qt.TextFormat.PlainText)
        dialog.setText("Move the selected Godot resources to the Recycle Bin?")
        dialog.setInformativeText("\n".join(paths[:5]))
        if len(paths) > 5:
            dialog.setDetailedText("\n".join(paths))
        delete = dialog.addButton("Delete", QMessageBox.ButtonRole.DestructiveRole)
        dialog.setStandardButtons(QMessageBox.StandardButton.Cancel)
        dialog.setDefaultButton(QMessageBox.StandardButton.Cancel)
        dialog.exec()
        if dialog.clickedButton() == delete:
            self._start_catalog_command(paths)

    def _confirm_attribute_delete(self, attribute_id: int) -> None:
        if self._reader.state() != QProcess.ProcessState.NotRunning:
            self._show_status("Wait for the current Godot check to finish, then try again.")
            return
        entry = next((entry for entry in self._attribute_registry.entries if entry["id"] == attribute_id), None)
        if entry is None or entry["builtin"]:
            return
        revision = self._attribute_registry.revision
        if revision is None:
            return
        answer = QMessageBox.question(
            self, "Delete Attribute",
            f"Delete {entry['name']} (ID {attribute_id})? Godot will check saved references first.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Cancel,
        )
        if answer == QMessageBox.StandardButton.Yes:
            self._start_catalog_command([], (attribute_id, revision))

    def _godot_command(
        self, user_arguments: list[str], *, report_error: bool = True,
    ) -> tuple[str, list[str], Path] | None:
        project_file = self._project_file
        if not project_file or not project_file.is_file() or not (project_file.parent / CATALOG_SCRIPT).is_file():
            if report_error:
                self._show_status("Use File → Link Godot Project to choose this game's project.godot.")
            return None
        project = project_file.parent
        if not (project / ".godot/global_script_class_cache.cfg").is_file():
            if report_error:
                self._show_status("Open the project in Godot once to import it, then use File → Refresh Catalog.", str(project))
            return None
        executable = self._godot_executable or which("godot") or which("godot4")
        if not executable or not Path(executable).is_file():
            if report_error:
                self._show_status("Use File → Choose Godot Executable to load the catalog.", str(project))
            return None
        arguments = ["--headless", "--no-header", "--path", str(project), "--script", f"res://{CATALOG_SCRIPT}"]
        if user_arguments:
            arguments.extend(["--", *user_arguments])
        return executable, arguments, project

    def _start_catalog_command(
        self, delete_paths: list[str], attribute_delete: tuple[int, AttributeRevision] | None = None,
    ) -> None:
        if self._composer_io.busy or self._reader.state() != QProcess.ProcessState.NotRunning:
            return
        user_arguments = []
        if delete_paths:
            user_arguments = ["--check-delete", *delete_paths]
        elif attribute_delete:
            user_arguments = ["--check-attribute-delete", str(attribute_delete[0])]
        command = self._godot_command(user_arguments)
        if command is None:
            return
        executable, arguments, project = command

        for action in self._catalog_actions:
            action.setEnabled(False)
        self._pending_delete = delete_paths
        self._pending_attribute_delete = attribute_delete
        if delete_paths:
            self._show_status("Checking Godot references before deletion…", str(project))
        elif attribute_delete:
            self._show_status("Checking saved attribute references before deletion…", str(project))
        else:
            self._show_status(f"Loading abilities and effects from {project.name}…", str(project))
        self._reader.setWorkingDirectory(str(project))
        self._catalog_timer.start(30_000)
        self._reader.start(executable, arguments)

    def _finish_catalog_read(self) -> None:
        self._catalog_timer.stop()
        self._pending_delete = []
        self._pending_attribute_delete = None
        for action in self._catalog_actions:
            action.setEnabled(not self._composer_io.busy)

    def _catalog_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.ProcessError.FailedToStart:
            self._finish_catalog_read()
            self._show_status("Godot could not start. Check File → Choose Godot Executable.", self._reader.errorString())

    def _catalog_finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        timed_out = not self._catalog_timer.isActive()
        delete_paths = self._pending_delete
        attribute_delete = self._pending_attribute_delete
        self._finish_catalog_read()
        output = bytes(self._reader.readAllStandardOutput()).decode("utf-8", errors="replace")
        errors = bytes(self._reader.readAllStandardError()).decode("utf-8", errors="replace").strip()
        if timed_out:
            self._show_status("Godot took too long to finish. Try again.", errors)
            return
        if exit_code or exit_status != QProcess.ExitStatus.NormalExit:
            self._show_status("Godot could not complete the request. Hover here for the Godot error.", errors or output)
            return
        if (delete_paths or attribute_delete) and errors:
            self._show_status("Godot could not verify the selection for deletion.", errors)
            self._delete_warning("Godot reported errors while checking resource references.", errors)
            return

        try:
            if attribute_delete:
                prefix = ATTRIBUTE_DELETE_PREFIX
            else:
                prefix = DELETE_CHECK_PREFIX if delete_paths else CATALOG_PREFIX
            catalog_line = next(line for line in output.split("\n") if line.startswith(prefix))
            catalog = json.loads(catalog_line[len(prefix):])
            if delete_paths:
                self._delete_checked_files(catalog, delete_paths)
                return
            if attribute_delete:
                self._delete_checked_attribute(catalog, *attribute_delete)
                return
            warnings = "\n".join(catalog.get("warnings", []))
            abilities = catalog_rows(catalog["abilities"])
            effect_entries = catalog.get("effects", [])
            effects = catalog_rows(effect_entries)
            assets = catalog.get("assets", {})
            if not isinstance(assets, dict):
                raise ValueError("Godot returned an invalid composer asset list.")
        except (StopIteration, ValueError, TypeError, KeyError, AttributeError) as error:
            message = (
                "Godot did not return a delete check." if delete_paths or attribute_delete
                else "Godot did not return a readable catalog."
            )
            self._show_status(message, errors or str(error))
            return

        self._abilities.set_rows(abilities)
        self._effects.set_rows(effects)
        self._composer_effects = effect_entries
        self._composer_assets = assets
        project = self._project_file.parent
        status = f"Abilities {len(abilities)} · Effects {len(effects)} · {project.name}"
        if "effects" not in catalog:
            status += " · Update the linked checkout to load effects"
        if warnings or errors:
            status += " · Hover here for Godot warnings"
        self._show_status(status, "\n".join(part for part in (str(project), warnings, errors) if part))

    def _composer_project(self) -> tuple[str, Path] | None:
        if self._composer_io.busy or self._reader.state() != QProcess.ProcessState.NotRunning:
            self._show_status("Wait for the current Godot request to finish.")
            return None
        command = self._godot_command([])
        if command is None:
            return None
        executable, _, project = command
        if not (project / COMPOSER_SCRIPT).is_file():
            self._show_status("Update the linked Godot checkout to use the Ability Composer.")
            return None
        return executable, project

    def _set_composer_busy(self, busy: bool) -> None:
        self._composer.set_busy(busy)
        for action in self._catalog_actions:
            action.setEnabled(not busy and self._reader.state() == QProcess.ProcessState.NotRunning)

    def _open_ability(self, path: str) -> None:
        project = self._composer_project()
        if project is None:
            return
        self._composer_pending_path = path
        self._set_composer_busy(True)
        self._show_status("Opening ability…", path)
        try:
            self._composer_io.read(*project, path)
        except (OSError, ValueError) as error:
            self._set_composer_busy(False)
            self._show_status(str(error))

    def _new_ability(self) -> None:
        if self._composer_project() is not None:
            self._load_composer({}, "", "")

    def _load_composer(self, draft: dict, path: str, revision: str) -> None:
        self._composer_path = path
        self._composer_revision = revision
        self._composer.load(draft, path, self._composer_effects, self._composer_assets)
        self._ability_pages.setCurrentWidget(self._composer)

    def _can_leave_composer(self) -> bool:
        return not self._composer_io.busy and (
            self._ability_pages.currentWidget() != self._composer or self._composer.can_leave()
        )

    def _back_to_abilities(self) -> None:
        if not self._composer_io.busy:
            self._ability_pages.setCurrentWidget(self._abilities)

    def _choose_ability_path(self, project: Path, name: str) -> str:
        filename = re.sub(r"[^a-z0-9]+", "_", name.casefold()).strip("_") or "ability"
        selected, _ = QFileDialog.getSaveFileName(
            self, "Save New Ability", str(project / f"{filename}.tres"),
            "Godot text resources (*.tres)", options=QFileDialog.Option.DontConfirmOverwrite,
        )
        if not selected:
            return ""
        file = Path(selected)
        if not file.suffix:
            file = file.with_suffix(".tres")
        if not file.is_relative_to(project):
            raise ValueError("Save the ability inside the linked Godot project.")
        path = "res://" + file.relative_to(project).as_posix()
        resource_file(project, path)
        return path

    def _stage_ability(self, draft: dict, *, publish: bool) -> None:
        context = self._composer_project()
        if context is None:
            return
        executable, project = context
        path = self._composer_path
        try:
            if not path:
                path = (
                    self._choose_ability_path(project, draft.get("name", ""))
                    if publish else f"res://ability_editor_check_{uuid4().hex}.tres"
                )
                if not path:
                    return
            self._composer_pending_path = path
            self._set_composer_busy(True)
            self._composer.set_result("Validating in Godot…")
            self._composer_io.stage(executable, project, path, draft, self._composer_revision, publish=publish)
        except (OSError, TypeError, ValueError) as error:
            self._set_composer_busy(False)
            self._composer.set_result(str(error), True)

    def _composer_finished(self, mode: str, result: dict | None, error: str) -> None:
        self._set_composer_busy(False)
        if error or result is None:
            message = error or "Godot did not complete the ability operation."
            if mode == "read":
                self._show_status("The ability could not be opened. Hover here for details.", message)
            else:
                self._composer.set_result(message, True)
            return
        path = self._composer_pending_path
        if mode == "read":
            self._load_composer(result["draft"], path, result["revision"])
            self._show_status(f"Opened {result['draft']['name']}.", path)
        elif mode == "check":
            self._composer.set_result("Godot validated this draft.")
        else:
            self._composer_path = path
            self._composer_revision = result["revision"]
            self._composer.mark_saved(result["draft"], path)
            self._composer.set_result("Saved to the linked Godot project.")
            self._start_catalog_command([])

    def _delete_checked_attribute(self, result: dict, attribute_id: int, revision: AttributeRevision) -> None:
        if result["id"] != attribute_id or not isinstance(result["issues"], list):
            raise ValueError("Godot returned a different attribute selection.")
        if result["issues"]:
            issues = "\n".join(result["issues"])
            self._show_status("Delete blocked by Godot's attribute reference check.", issues)
            self._delete_warning("This attribute could not be safely deleted.", issues)
            return
        try:
            self._attribute_registry.delete(attribute_id, revision=revision)
        except (OSError, ValueError) as error:
            self._delete_warning("The attribute could not be deleted.", str(error))
            return
        self._show_status(f"Deleted attribute {attribute_id}.")

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
                line = next(line for line in output.splitlines() if line.startswith(ACCURACY_PREVIEW_PREFIX))
                candidate = json.loads(line[len(ACCURACY_PREVIEW_PREFIX):])["chance"]
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

    def _delete_checked_files(self, result: dict, requested_paths: list[str]) -> None:
        if result["issues"]:
            issues = "\n".join(result["issues"])
            self._show_status("Delete blocked by Godot's resource check.", issues)
            self._delete_warning("Godot could not clear the selection for deletion.", issues)
            return
        paths = result["paths"]
        if len(paths) != len(requested_paths) or set(paths) != set(requested_paths):
            raise ValueError("Godot returned a different file selection.")

        root = self._project_file.parent.resolve()
        files = []
        try:
            for path in paths:
                if not path.startswith("res://"):
                    raise ValueError(path)
                relative = Path(path.removeprefix("res://"))
                if relative.is_absolute() or relative.drive or ".." in relative.parts:
                    raise ValueError(path)
                candidate = root / relative
                resolved = candidate.resolve(strict=True)
                if (not resolved.is_relative_to(root) or resolved != candidate or not resolved.is_file()
                        or resolved.suffix.lower() not in {".tres", ".res"}):
                    raise ValueError(path)
                files.append(resolved)
        except (OSError, ValueError) as error:
            self._delete_warning("The selected files changed. Refresh the catalog before retrying.", str(error))
            self._refresh_catalog()
            return

        for index, file in enumerate(files):
            resource = QFile(str(file))
            if not resource.moveToTrash():
                self._delete_warning(
                    f"Moved {index} of {len(files)} files to the Recycle Bin.",
                    f"{paths[index]}\n{resource.errorString()}",
                )
                break
        self._refresh_catalog()

    def _delete_warning(self, message: str, details: str) -> None:
        dialog = QMessageBox(self)
        dialog.setIcon(QMessageBox.Icon.Warning)
        dialog.setWindowTitle("Delete Selected")
        dialog.setTextFormat(Qt.TextFormat.PlainText)
        dialog.setText(message)
        dialog.setDetailedText(details)
        dialog.exec()

    def _show_status(self, message: str, details: str = "") -> None:
        self.statusBar().showMessage(message)
        self.statusBar().setToolTip(details)

    def closeEvent(self, event) -> None:
        if not self._can_leave_composer() or not self._attributes.can_leave_editor():
            event.ignore()
            return
        self._queued_preview = None
        self._active_preview = None
        if self._preview_reader.state() != QProcess.ProcessState.NotRunning:
            self._preview_reader.kill()
            self._preview_reader.waitForFinished(1_000)
        if self._reader.state() != QProcess.ProcessState.NotRunning:
            self._reader.kill()
            self._reader.waitForFinished(1_000)
        super().closeEvent(event)


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Ability Editor")
    qt_themes.set_theme("atom_one", style="Fusion")
    window = AbilityEditorWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
