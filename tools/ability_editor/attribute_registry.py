"""Project-backed attribute definitions and Accuracy curve anchors."""

import json
import re
from collections.abc import Callable
from copy import deepcopy
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import TypeVar

from PySide6.QtCore import QFileSystemWatcher, QIODevice, QLockFile, QObject, QSaveFile, Signal


ATTRIBUTES_PATH = Path("combat/attributes/attributes.json")
RULES_PATH = Path("combat/combat_rules.json")
FIRST_CUSTOM_ID = 100
MAX_ATTRIBUTE_ID = 2**31 - 1
ATTRIBUTE_KEY = re.compile(r"[A-Z][A-Z0-9_]*")
CURVE_KEYS = {"base": "accuracy_base_chance_by_gap", "ceiling": "accuracy_max_chance_by_gap"}
CURVE_GAP_COUNT = 11
_Result = TypeVar("_Result")


@dataclass(frozen=True)
class AttributeRevision:
    project: Path
    attributes: bytes | None
    rules: bytes | None


def _validate_attributes(document: dict) -> None:
    next_id = document.get("next_id")
    if type(document.get("schema_version")) is not int or document["schema_version"] != 1:
        raise ValueError("Expected attribute registry schema version 1.")
    if type(next_id) is not int or not FIRST_CUSTOM_ID <= next_id <= MAX_ATTRIBUTE_ID + 1:
        raise ValueError("Invalid next attribute ID.")
    entries = document.get("attributes")
    if not isinstance(entries, list):
        raise ValueError("Expected a list of attribute definitions.")
    ids: set[int] = set()
    keys: set[str] = set()
    names: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Each attribute must be a JSON object.")
        attribute_id = entry.get("id")
        builtin = entry.get("builtin")
        if type(attribute_id) is not int or not 0 <= attribute_id < next_id or attribute_id in ids:
            raise ValueError(f"Invalid or duplicate attribute ID {attribute_id!r}.")
        if type(builtin) is not bool or builtin != (attribute_id < FIRST_CUSTOM_ID):
            raise ValueError(f"Invalid built-in flag for attribute {attribute_id}.")
        ids.add(attribute_id)

        key = entry.get("key")
        if not isinstance(key, str) or not ATTRIBUTE_KEY.fullmatch(key) or key == "NONE":
            raise ValueError(f"Invalid attribute key {key!r}. Use uppercase letters, digits and underscores.")
        if key in keys:
            raise ValueError(f"The attribute key {key!r} is already registered.")
        keys.add(key)

        name = entry.get("name")
        if not isinstance(name, str) or not name.strip() or any(char in name for char in ":,\r\n"):
            raise ValueError("Enter a single-line display name without commas or colons.")
        folded_name = name.strip().casefold()
        if folded_name == "none":
            raise ValueError("The display name 'None' is reserved for optional attribute selectors.")
        if folded_name in names:
            raise ValueError(f"The attribute name {name!r} is already registered.")
        names.add(folded_name)
        description = entry.get("description")
        if not isinstance(description, str) or (builtin and not description.strip()):
            raise ValueError(f"Invalid description for {key}.")
        for field in ("category", "unit"):
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                raise ValueError(f"Enter a {field} for {key}.")


def _validate_curve_pair(curves: dict, upper_bound: float) -> None:
    for name in CURVE_KEYS:
        values = curves.get(name)
        if not isinstance(values, list) or len(values) != CURVE_GAP_COUNT:
            raise ValueError(f"The Accuracy {name} curve must contain level gaps +0 through +10.")
        if any(type(value) not in (int, float) or not 0 <= value <= upper_bound for value in values):
            raise ValueError(f"The Accuracy {name} curve contains a chance outside the supported range.")
    for gap, (base, ceiling) in enumerate(zip(curves["base"], curves["ceiling"])):
        if base > ceiling:
            raise ValueError(f"Base hit chance cannot exceed the ceiling at level gap +{gap}.")


def _validate_rules(document: dict) -> None:
    if document.get("schema_version") != 3 or document.get("accuracy_curve_max_gap") != CURVE_GAP_COUNT - 1:
        raise ValueError("Expected combat rules schema 3 with Accuracy anchors +0 through +10.")
    _validate_curve_pair({name: document.get(key) for name, key in CURVE_KEYS.items()}, 1.0)


def _parse(contents: bytes, validate: Callable[[dict], None]) -> dict:
    document = json.loads(contents.decode("utf-8"))
    if not isinstance(document, dict):
        raise ValueError("Expected a JSON object.")
    validate(document)
    return document


def _read(
    path: Path, validate: Callable[[dict], None], label: str
) -> tuple[bytes | None, dict, str]:
    contents = None
    try:
        contents = path.read_bytes()
        return contents, _parse(contents, validate), ""
    except (OSError, ValueError) as exc:
        return contents, {}, f"Could not load {label}. {exc}"


def _encode(document: dict, relative_path: Path) -> bytes:
    if relative_path == RULES_PATH:
        # The tuning file uses one setting per line, including its numeric arrays.
        lines = [
            f"  {json.dumps(key, ensure_ascii=False)}: {json.dumps(value, ensure_ascii=False, allow_nan=False)}"
            for key, value in document.items()
        ]
        return ("{\n" + ",\n".join(lines) + "\n}\n").encode("utf-8")
    return (json.dumps(document, ensure_ascii=False, allow_nan=False, indent=2) + "\n").encode("utf-8")


def _current_bytes(path: Path, expected: bytes | None) -> bytes:
    contents = path.read_bytes()
    if contents != expected:
        raise ValueError(f"{path.name} changed on disk. Reopen the edit to work from the latest saved data.")
    return contents


class AttributeRegistry(QObject):
    changed = Signal()

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._project: Path | None = None
        self._attributes: dict = {}
        self._rules: dict = {}
        self.revision: AttributeRevision | None = None
        self.error = "Link a Godot project to edit attributes."
        self.curve_error = self.error
        self._watcher = QFileSystemWatcher(self)
        self._watcher.fileChanged.connect(self.reload)
        self._watcher.directoryChanged.connect(self.reload)

    @property
    def entries(self) -> list[dict]:
        return deepcopy(self._attributes.get("attributes", []))

    @property
    def accuracy_curves(self) -> dict[str, list[float]]:
        if not self._rules:
            return {}
        return {
            name: [float(Decimal(str(value)) * 100) for value in self._rules[key]]
            for name, key in CURVE_KEYS.items()
        }

    def set_project(self, project: Path | None) -> None:
        self._project = project.resolve() if project is not None else None
        self.reload()

    def reload(self) -> None:
        self._update_watches()
        previous = (self.revision, self.error, self.curve_error)
        if self._project is None:
            self._attributes = {}
            self._rules = {}
            self.revision = None
            self.error = "Link a Godot project to edit attributes."
            self.curve_error = self.error
        else:
            attributes, self._attributes, self.error = _read(
                self._project / ATTRIBUTES_PATH, _validate_attributes, "the attribute registry"
            )
            rules, self._rules, self.curve_error = _read(
                self._project / RULES_PATH, _validate_rules, "the Accuracy curves"
            )
            self.revision = AttributeRevision(self._project, attributes, rules)
        if (self.revision, self.error, self.curve_error) != previous:
            self.changed.emit()

    def register(
        self, key: str, name: str, description: str, category: str, unit: str,
        *, revision: AttributeRevision | None,
    ) -> int:
        def register_entry(document: dict) -> int:
            attribute_id = document["next_id"]
            if attribute_id > MAX_ATTRIBUTE_ID:
                raise ValueError("The attribute ID range is exhausted.")
            document["attributes"].append({
                "id": attribute_id, "key": key.strip(), "name": name.strip(),
                "description": description.strip(), "category": category.strip(),
                "unit": unit.strip(), "builtin": False,
            })
            document["next_id"] += 1
            return attribute_id

        return self._write(ATTRIBUTES_PATH, revision, register_entry)

    def update(
        self, attribute_id: int, name: str, description: str, category: str, unit: str,
        *, revision: AttributeRevision | None,
    ) -> None:
        def update_entry(document: dict) -> None:
            entry = self._entry(document, attribute_id)
            if entry["builtin"] and unit.strip() != entry["unit"]:
                raise ValueError("The unit for a built-in attribute is fixed by the game.")
            entry.update(name=name.strip(), description=description.strip(), category=category.strip(), unit=unit.strip())

        self._write(ATTRIBUTES_PATH, revision, update_entry)

    def save_accuracy_curves(
        self, curves: dict[str, list[float]], *, revision: AttributeRevision | None
    ) -> None:
        _validate_curve_pair(curves, 100.0)

        def update_curves(document: dict) -> None:
            for name, key in CURVE_KEYS.items():
                for gap, (original, value) in enumerate(zip(document[key], curves[name])):
                    percent = float(Decimal(str(original)) * 100)
                    if value != percent:
                        document[key][gap] = float(Decimal(str(value)) / 100)

        self._write(RULES_PATH, revision, update_curves)

    def delete(self, attribute_id: int, *, revision: AttributeRevision | None) -> None:
        def delete_entry(document: dict) -> None:
            entry = self._entry(document, attribute_id)
            if entry["builtin"]:
                raise ValueError("Built-in attributes are required by the game.")
            document["attributes"].remove(entry)

        self._write(ATTRIBUTES_PATH, revision, delete_entry)

    @staticmethod
    def _entry(document: dict, attribute_id: int) -> dict:
        for entry in document["attributes"]:
            if entry["id"] == attribute_id:
                return entry
        raise ValueError(f"Attribute {attribute_id} is no longer registered.")

    def _write(
        self, relative_path: Path, revision: AttributeRevision | None, change: Callable[[dict], _Result]
    ) -> _Result:
        project = self._project
        if revision is None or project is None or revision.project != project:
            raise ValueError("The linked project changed. Reopen the edit in the current project.")
        path = project / relative_path
        lock = QLockFile(str(path.with_name(f".{path.name}.lock")))
        if not lock.tryLock(0):
            raise OSError(f"Could not lock {path.name}. Check the folder permissions and try again.")
        try:
            if relative_path == ATTRIBUTES_PATH:
                expected = revision.attributes
                validate = _validate_attributes
            else:
                expected = revision.rules
                validate = _validate_rules
            original = _parse(_current_bytes(path, expected), validate)
            document = deepcopy(original)
            result = change(document)
            validate(document)
            if document != original:
                self._publish(path, expected, _encode(document, relative_path))
            return result
        finally:
            lock.unlock()
            self.reload()

    @staticmethod
    def _publish(path: Path, expected: bytes | None, contents: bytes) -> None:
        output = QSaveFile(str(path))
        output.setDirectWriteFallback(False)
        if not output.open(QIODevice.OpenModeFlag.WriteOnly):
            raise OSError(output.errorString())
        if output.write(contents) != len(contents):
            output.cancelWriting()
            raise OSError(output.errorString())
        try:
            _current_bytes(path, expected)
        except (OSError, ValueError):
            output.cancelWriting()
            raise
        if not output.commit():
            raise OSError(output.errorString())

    def _update_watches(self) -> None:
        paths: set[str] = set()
        if self._project is not None:
            for relative_path in (ATTRIBUTES_PATH, RULES_PATH):
                path = self._project / relative_path
                if path.is_file():
                    paths.add(str(path))
                for directory in path.parents:
                    if directory.is_dir():
                        paths.add(str(directory))
                        break
        watched = set(self._watcher.files()) | set(self._watcher.directories())
        if obsolete := watched - paths:
            self._watcher.removePaths(sorted(obsolete))
        if missing := paths - watched:
            self._watcher.addPaths(sorted(missing))
