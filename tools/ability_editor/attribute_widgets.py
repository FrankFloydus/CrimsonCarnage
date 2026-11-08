"""Attribute catalog and curve authoring views for the Ability Editor."""

from PySide6.QtCore import QPoint, QPointF, QRectF, QSignalBlocker, QSortFilterProxyModel, Qt, QTimer, Signal
from PySide6.QtGui import QBrush, QPainter, QPalette, QPen, QPolygonF, QStandardItem, QStandardItemModel
from PySide6.QtWidgets import (
    QAbstractItemView,
    QComboBox,
    QDoubleSpinBox,
    QFormLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QStackedWidget,
    QTableView,
    QVBoxLayout,
    QWidget,
)

if __package__:
    from .attribute_registry import AttributeRegistry
else:
    from attribute_registry import AttributeRegistry


ACCURACY_ID = 40
ID_ROLE = Qt.ItemDataRole.UserRole
CURVE_LABELS = {"base": "Base chance", "ceiling": "Hit chance ceiling"}
CATEGORIES = ("Resources", "Primaries", "Offense", "Defense", "Movement")
UNITS = ("Points", "Points/sec", "Rating", "%", "Weight")


def _plain_label(text: str = "") -> QLabel:
    label = QLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    return label


class _CurveGraph(QWidget):
    point_selected = Signal(int)
    point_adjusted = Signal(int, float)

    def __init__(self) -> None:
        super().__init__()
        self.setAccessibleName("Hit chance curve graph")
        self.setAccessibleDescription("Drag a point vertically. Use Left and Right to select points and Up or Down to edit.")
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMinimumSize(255, 245)
        self._curves: dict[str, list[float]] = {}
        self._kind = "base"
        self._gap = 6
        self._drag: tuple[int, float, float] | None = None

    def set_curve(self, curves: dict[str, list[float]], kind: str, gap: int) -> None:
        self._curves = curves
        self._kind = kind
        self._gap = gap
        self.update()

    def _plot(self) -> QRectF:
        return QRectF(self.rect()).adjusted(48, 17, -17, -48)

    @staticmethod
    def _point(plot: QRectF, gap: int, chance: float) -> QPointF:
        return QPointF(plot.left() + plot.width() * gap / 10, plot.bottom() - plot.height() * chance / 100)

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        palette = self.palette()
        base = palette.color(QPalette.ColorRole.Base)
        text = palette.color(QPalette.ColorRole.Text)
        grid = palette.color(QPalette.ColorRole.Mid)
        accent = palette.color(QPalette.ColorRole.Highlight)
        if abs(accent.lightness() - base.lightness()) < 60:
            accent = accent.lighter(170) if base.lightness() < 128 else accent.darker(155)
        painter.fillRect(self.rect(), base)
        if not self._curves:
            return

        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        plot = self._plot()
        for chance in (0, 25, 50, 75, 100):
            y = self._point(plot, 0, chance).y()
            painter.setPen(grid)
            painter.drawLine(QPointF(plot.left(), y), QPointF(plot.right(), y))
            painter.setPen(text)
            painter.drawText(
                QRectF(1, y - 9, plot.left() - 9, 18),
                Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
                f"{chance}%",
            )
        for gap in range(11):
            if gap % 2 and plot.width() < 330 and gap != self._gap:
                continue
            x = self._point(plot, gap, 0).x()
            painter.drawText(QRectF(x - 14, plot.bottom() + 6, 28, 16), Qt.AlignmentFlag.AlignCenter, f"+{gap}")
        painter.drawText(
            QRectF(plot.left(), plot.bottom() + 24, plot.width(), 19),
            Qt.AlignmentFlag.AlignCenter,
            "Target level gap",
        )

        reference = "ceiling" if self._kind == "base" else "base"
        for kind, color, style in (
            (reference, text, Qt.PenStyle.DashLine),
            (self._kind, accent, Qt.PenStyle.SolidLine),
        ):
            painter.setPen(QPen(color, 1.8, style))
            painter.drawPolyline(QPolygonF([self._point(plot, gap, value) for gap, value in enumerate(self._curves[kind])]))
        painter.setPen(QPen(accent, 1.8))
        for gap, value in enumerate(self._curves[self._kind]):
            selected = gap == self._gap
            radius = 5 if selected else 3.5
            painter.setBrush(QBrush(accent if selected else base))
            painter.drawEllipse(self._point(plot, gap, value), radius, radius)
        if self.hasFocus():
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.setPen(QPen(accent, 1, Qt.PenStyle.DotLine))
            painter.drawRect(self.rect().adjusted(1, 1, -2, -2))

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton and self._curves:
            plot = self._plot()
            mouse = event.position()
            for gap, value in enumerate(self._curves[self._kind]):
                point = self._point(plot, gap, value)
                if (point.x() - mouse.x()) ** 2 + (point.y() - mouse.y()) ** 2 <= 11 ** 2:
                    self.setFocus(Qt.FocusReason.MouseFocusReason)
                    self.point_selected.emit(gap)
                    self._drag = (gap, mouse.y(), value)
                    self.setCursor(Qt.CursorShape.SizeVerCursor)
                    event.accept()
                    return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event) -> None:
        if self._drag is None:
            super().mouseMoveEvent(event)
            return
        gap, start_y, start_value = self._drag
        delta = 100 * (start_y - event.position().y()) / self._plot().height()
        self.point_adjusted.emit(gap, round(start_value + delta))
        event.accept()

    def mouseReleaseEvent(self, event) -> None:
        if self._drag is not None and event.button() == Qt.MouseButton.LeftButton:
            self._drag = None
            self.unsetCursor()
            event.accept()
            return
        super().mouseReleaseEvent(event)

    def keyPressEvent(self, event) -> None:
        key = event.key()
        if self._curves and key in (Qt.Key.Key_Left, Qt.Key.Key_Right, Qt.Key.Key_Up, Qt.Key.Key_Down):
            if key in (Qt.Key.Key_Left, Qt.Key.Key_Right):
                shift = 1 if key == Qt.Key.Key_Right else -1
                self.point_selected.emit(max(0, min(10, self._gap + shift)))
            else:
                step = 1 if key == Qt.Key.Key_Up else -1
                self.point_adjusted.emit(self._gap, self._curves[self._kind][self._gap] + step)
            event.accept()
            return
        super().keyPressEvent(event)


class _AccuracyCurveEditor(QWidget):
    preview_requested = Signal(int, object, object)

    def __init__(self, registry: AttributeRegistry) -> None:
        super().__init__()
        self._registry = registry
        self._curves: dict[str, list[float]] = {}
        self._saved: dict[str, list[float]] = {}
        self._revision = None
        self._preview_timer = QTimer(self)
        self._preview_timer.setSingleShot(True)
        self._preview_timer.setInterval(300)
        self._preview_timer.timeout.connect(self._request_preview)

        self._kind = QComboBox()
        for kind, label in CURVE_LABELS.items():
            self._kind.addItem(label, kind)
        self._gap = QComboBox()
        self._gap.addItems([f"+{gap}" for gap in range(11)])
        self._chance = QDoubleSpinBox()
        self._chance.setSuffix("%")
        self._chance.setDecimals(3)
        self._chance.setSingleStep(1)
        self._chance.setKeyboardTracking(False)
        self._graph = _CurveGraph()
        self._graph.point_selected.connect(self._gap.setCurrentIndex)
        self._graph.point_adjusted.connect(self._edit_point)
        self._kind.currentIndexChanged.connect(self._update_selection)
        self._gap.currentIndexChanged.connect(self._selection_changed)
        self._chance.valueChanged.connect(self._change_chance)
        self._legend = _plain_label()
        self._preview = _plain_label()
        self._status = _plain_label()
        self._save = QPushButton("Save Curve")
        self._save.clicked.connect(self._save_curve)

        controls = QHBoxLayout()
        for title, control, stretch in (
            ("Curve", self._kind, 2), ("Level Gap", self._gap, 1), ("Chance", self._chance, 1),
        ):
            stack = QVBoxLayout()
            label = QLabel(title)
            label.setBuddy(control)
            stack.addWidget(label)
            stack.addWidget(control)
            controls.addLayout(stack, stretch)
        buttons = QHBoxLayout()
        buttons.addWidget(self._status, 1)
        buttons.addWidget(self._save)
        self._contents = QWidget()
        body = QVBoxLayout(self._contents)
        body.setContentsMargins(0, 0, 0, 0)
        body.addLayout(controls)
        body.addWidget(self._graph, 1)
        body.addWidget(self._legend)
        body.addWidget(self._preview)
        body.addLayout(buttons)

        self._error = _plain_label()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(QLabel("Hit Chance Curve"))
        layout.addWidget(self._error)
        layout.addWidget(self._contents, 1)

    def load(self) -> None:
        self._revision = self._registry.revision
        self._curves = self._registry.accuracy_curves
        self._saved = {kind: points.copy() for kind, points in self._curves.items()}
        self._status.clear()
        self._error.setText(self._registry.curve_error)
        self._error.setVisible(bool(self._registry.curve_error))
        self._contents.setVisible(bool(self._curves))
        if self._curves:
            with QSignalBlocker(self._kind), QSignalBlocker(self._gap):
                self._kind.setCurrentIndex(0)
                self._gap.setCurrentIndex(6)
            self._update_selection()
            self._queue_preview()
        self._save.setEnabled(False)

    def clear(self) -> None:
        self._preview_timer.stop()
        self._curves = {}
        self._saved = {}
        self._graph.set_curve({}, "base", 6)

    def has_changes(self) -> bool:
        return self._curves != self._saved

    def set_preview(self, gap: int, base: list, ceiling: list, chance: float | None) -> None:
        if gap != self._gap.currentIndex() or self._curves != {"base": base, "ceiling": ceiling}:
            return
        sample = f"Lv 50 vs Lv {50 + gap} · 69 Accuracy"
        value = f"{chance:.2%} hit chance" if chance is not None else "Godot preview unavailable"
        self._preview.setText(f"{sample} · {value}")

    def _update_selection(self) -> None:
        kind = self._kind.currentData()
        gap = self._gap.currentIndex()
        low = 0 if kind == "base" else self._curves["base"][gap]
        high = self._curves["ceiling"][gap] if kind == "base" else 100
        with QSignalBlocker(self._chance):
            self._chance.setRange(low, high)
            self._chance.setValue(self._curves[kind][gap])
        self._graph.set_curve(self._curves, kind, gap)
        reference = "ceiling" if kind == "base" else "base"
        self._legend.setText(f"{CURVE_LABELS[kind]} (solid)   ·   {CURVE_LABELS[reference]} (dashed)")

    def _selection_changed(self) -> None:
        self._update_selection()
        self._queue_preview()

    def _change_chance(self, value: float) -> None:
        self._edit_point(self._gap.currentIndex(), value)

    def _edit_point(self, gap: int, value: float) -> None:
        kind = self._kind.currentData()
        low = 0 if kind == "base" else self._curves["base"][gap]
        high = self._curves["ceiling"][gap] if kind == "base" else 100
        bounded = max(low, min(value, high))
        if bounded == self._curves[kind][gap]:
            return
        self._curves[kind][gap] = bounded
        self._update_selection()
        dirty = self.has_changes()
        self._save.setEnabled(dirty)
        self._status.setText("Unsaved curve changes" if dirty else "")
        self._queue_preview()

    def _queue_preview(self) -> None:
        gap = self._gap.currentIndex()
        self._preview.setText(f"Lv 50 vs Lv {50 + gap} · 69 Accuracy · Updating preview…")
        self._preview_timer.start()

    def _request_preview(self) -> None:
        self.preview_requested.emit(self._gap.currentIndex(), self._curves["base"].copy(), self._curves["ceiling"].copy())

    def _save_curve(self) -> None:
        try:
            self._registry.save_accuracy_curves(self._curves, revision=self._revision)
        except (OSError, ValueError) as error:
            self._status.setText(str(error))
            return
        self._saved = {kind: points.copy() for kind, points in self._curves.items()}
        self._revision = self._registry.revision
        self._save.setEnabled(False)
        self._status.setText("Curve saved")


class AttributeManager(QWidget):
    """List attributes and open a dedicated editor for one definition at a time."""

    delete_requested = Signal(int)
    preview_requested = Signal(int, object, object)

    def __init__(self, registry: AttributeRegistry) -> None:
        super().__init__()
        self._registry = registry
        self._entries: dict[int, dict] = {}
        self._editing: int | None = None
        self._revision = None
        self._original: tuple[str, ...] = ()
        self._pages = QStackedWidget()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 12, 12, 12)
        layout.addWidget(self._pages)
        self._build_catalog()
        self._build_editor()
        registry.changed.connect(self._sync_registry)
        self._sync_registry()

    def _build_catalog(self) -> None:
        self._catalog = QWidget()
        self._pages.addWidget(self._catalog)
        self._model = QStandardItemModel(0, 5, self)
        self._model.setHorizontalHeaderLabels(["ID", "Name", "Category", "Unit", "Curve"])
        self._proxy = QSortFilterProxyModel(self)
        self._proxy.setSourceModel(self._model)
        self._proxy.setFilterKeyColumn(-1)
        self._proxy.setFilterCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        self._proxy.setSortCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)

        self._search = QLineEdit()
        self._search.setAccessibleName("Search attributes")
        self._search.setPlaceholderText("Search by ID, name, or category…")
        self._search.setClearButtonEnabled(True)
        self._search.textChanged.connect(self._proxy.setFilterFixedString)
        self._new = QPushButton("New Attribute")
        self._new.clicked.connect(lambda: self._open_editor(None))
        self._edit = QPushButton("Edit…")
        self._edit.clicked.connect(self._open_selection)
        actions = QHBoxLayout()
        actions.addWidget(self._search, 1)
        actions.addWidget(self._edit)
        actions.addWidget(self._new)

        self._table = QTableView()
        table = self._table
        table.setAccessibleName("Attribute definitions")
        table.setModel(self._proxy)
        palette = table.palette()
        base = palette.color(QPalette.ColorRole.Base)
        if palette.color(QPalette.ColorRole.AlternateBase) == base:
            palette.setColor(QPalette.ColorRole.AlternateBase, base.lighter(120))
            table.setPalette(palette)
        table.setAlternatingRowColors(True)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        table.selectionModel().selectionChanged.connect(self._update_actions)
        table.doubleClicked.connect(self._open_selection)
        table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        table.customContextMenuRequested.connect(self._show_context_menu)
        table.verticalHeader().hide()
        header = table.horizontalHeader()
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        header.setSortIndicator(0, Qt.SortOrder.DescendingOrder)
        table.setSortingEnabled(True)
        table.setColumnWidth(0, 48)

        self._catalog_status = _plain_label()
        layout = QVBoxLayout(self._catalog)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addLayout(actions)
        layout.addWidget(table, 1)
        layout.addWidget(self._catalog_status)

    def _build_editor(self) -> None:
        self._editor = QWidget()
        self._pages.addWidget(self._editor)
        self._heading = _plain_label()
        font = self._heading.font()
        font.setBold(True)
        self._heading.setFont(font)
        back = QPushButton("Back to Attributes")
        back.clicked.connect(self._return_to_catalog)
        title = QHBoxLayout()
        title.addWidget(self._heading, 1)
        title.addWidget(back)

        self._id = QLineEdit()
        self._id.setReadOnly(True)
        self._key = QLineEdit()
        self._key.setPlaceholderText("LUCK_RATING")
        self._name = QLineEdit()
        self._category = QComboBox()
        self._category.addItems(CATEGORIES)
        self._unit = QComboBox()
        self._unit.addItems(UNITS)
        self._description = QPlainTextEdit()
        self._description.setMaximumHeight(105)
        self._detail_status = _plain_label()
        self._save_details_button = QPushButton("Save Details")
        self._save_details_button.clicked.connect(self._save_details)

        details = QFormLayout()
        details.addRow("ID", self._id)
        details.addRow("Internal Key", self._key)
        details.addRow("Display Name", self._name)
        details.addRow("Category", self._category)
        details.addRow("Unit", self._unit)
        details.addRow("Description", self._description)
        details.addRow(self._save_details_button)
        details.addRow(self._detail_status)
        self._details = QWidget()
        self._details.setLayout(details)
        self._details.setMaximumWidth(405)
        self._curves = _AccuracyCurveEditor(self._registry)
        self._curves.preview_requested.connect(self.preview_requested.emit)

        body = QHBoxLayout()
        body.addWidget(self._details, 1, Qt.AlignmentFlag.AlignTop)
        body.addWidget(self._curves, 2)
        layout = QVBoxLayout(self._editor)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addLayout(title)
        layout.addLayout(body, 1)

        self._key.textChanged.connect(self._update_detail_button)
        self._name.textChanged.connect(self._update_detail_button)
        self._description.textChanged.connect(self._update_detail_button)
        self._category.currentTextChanged.connect(self._update_detail_button)
        self._unit.currentTextChanged.connect(self._update_detail_button)

    def _sync_registry(self) -> None:
        selected = self._selected_id()
        self._entries = {entry["id"]: entry for entry in self._registry.entries}
        self._model.removeRows(0, self._model.rowCount())
        for entry in self._entries.values():
            item = QStandardItem()
            item.setData(entry["id"], Qt.ItemDataRole.DisplayRole)
            item.setData(entry["id"], ID_ROLE)
            item.setTextAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            name = QStandardItem(entry["name"])
            name.setToolTip(entry["description"])
            self._model.appendRow([
                item, name, QStandardItem(entry["category"]), QStandardItem(entry["unit"]),
                QStandardItem("Hit Chance" if entry["id"] == ACCURACY_ID else ""),
            ])
        if selected is not None:
            self._select_id(selected)
        self._update_actions()
        status = self._registry.error or ("Link a Godot project to edit attributes." if self._registry.revision is None else "")
        self._catalog_status.setText(status)
        self._catalog_status.setVisible(bool(status))

    def _selected_id(self) -> int | None:
        indexes = self._table.selectionModel().selectedRows(0)
        return indexes[0].data(ID_ROLE) if indexes else None

    def _select_id(self, attribute_id: int) -> None:
        for row in range(self._proxy.rowCount()):
            index = self._proxy.index(row, 0)
            if index.data(ID_ROLE) == attribute_id:
                self._table.selectRow(row)
                self._table.scrollTo(index)
                return

    def _update_actions(self) -> None:
        ready = self._registry.revision is not None and not self._registry.error
        self._new.setEnabled(ready)
        self._edit.setEnabled(ready and self._selected_id() is not None)

    def _show_context_menu(self, position: QPoint) -> None:
        index = self._table.indexAt(position)
        if not index.isValid():
            return
        self._table.selectRow(index.row())
        selected = self._selected_id()
        if selected is None or not self._edit.isEnabled():
            return
        menu = QMenu(self._table)
        edit = menu.addAction("Edit")
        delete = menu.addAction("Delete")
        delete.setEnabled(not self._entries[selected]["builtin"])
        action = menu.exec(self._table.viewport().mapToGlobal(position))
        if action == edit:
            self._open_editor(selected)
        elif action == delete:
            self.delete_requested.emit(selected)
        menu.deleteLater()

    def _open_selection(self) -> None:
        selected = self._selected_id()
        if selected is not None and self._edit.isEnabled():
            self._open_editor(selected)

    @staticmethod
    def _set_choice(combo: QComboBox, value: str) -> None:
        if combo.findText(value) < 0:
            combo.addItem(value)
        combo.setCurrentText(value)

    def _open_editor(self, attribute_id: int | None) -> None:
        self._editing = attribute_id
        self._revision = self._registry.revision
        entry = self._entries.get(attribute_id, {})
        self._id.setText(str(attribute_id) if attribute_id is not None else "Assigned on registration")
        self._key.setReadOnly(attribute_id is not None)
        self._key.setText(entry.get("key", ""))
        self._name.setText(entry.get("name", ""))
        self._description.setPlainText(entry.get("description", ""))
        self._set_choice(self._category, entry.get("category", "Offense"))
        self._set_choice(self._unit, entry.get("unit", "Points"))
        self._unit.setEnabled(not entry.get("builtin", False))
        self._heading.setText(f"Edit Attribute · {entry['name']}" if entry else "New Attribute")
        self._save_details_button.setText("Save Details" if entry else "Register Attribute")
        self._detail_status.clear()
        self._original = self._detail_values()
        self._update_detail_button()
        self._curves.setVisible(attribute_id == ACCURACY_ID)
        if attribute_id == ACCURACY_ID:
            self._curves.load()
        else:
            self._curves.clear()
        self._pages.setCurrentWidget(self._editor)
        (self._key if attribute_id is None else self._name).setFocus()

    def _detail_values(self) -> tuple[str, ...]:
        return (
            self._key.text().strip(), self._name.text().strip(), self._description.toPlainText().strip(),
            self._category.currentText(), self._unit.currentText(),
        )

    def _update_detail_button(self) -> None:
        values = self._detail_values()
        self._save_details_button.setEnabled(bool(values[0] and values[1] and values != self._original))

    def _save_details(self) -> None:
        values = self._detail_values()
        key, name, description, category, unit = values
        try:
            if self._editing is None:
                attribute_id = self._registry.register(key, name, description, category, unit, revision=self._revision)
                self.show_list()
                self._search.clear()
                self._select_id(attribute_id)
                return
            self._registry.update(self._editing, name, description, category, unit, revision=self._revision)
        except (OSError, ValueError) as error:
            self._detail_status.setText(str(error))
            return
        self._revision = self._registry.revision
        self._original = values
        self._heading.setText(f"Edit Attribute · {name}")
        self._detail_status.setText("Details saved")
        self._update_detail_button()

    def _return_to_catalog(self) -> None:
        if self.can_leave_editor():
            self.show_list()

    def can_leave_editor(self) -> bool:
        if self._pages.currentWidget() != self._editor:
            return True
        if self._detail_values() == self._original and not self._curves.has_changes():
            return True
        result = QMessageBox.question(
            self, "Discard changes?", "Discard unsaved attribute changes?",
            QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Cancel,
        )
        return result == QMessageBox.StandardButton.Discard

    def show_list(self) -> None:
        self._curves.clear()
        self._pages.setCurrentWidget(self._catalog)
        self._table.setFocus()

    def set_preview(self, gap: int, base: list, ceiling: list, chance: float | None) -> None:
        if self._pages.currentWidget() == self._editor and self._editing == ACCURACY_ID:
            self._curves.set_preview(gap, base, ceiling, chance)
