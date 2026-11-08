"""Project-backed authoring registry for gameplay tags."""

import json
import re
from pathlib import Path

from PySide6.QtCore import QFileSystemWatcher, QIODevice, QLockFile, QObject, QSaveFile, Signal


REGISTRY_PATH = Path("combat/tags/gameplay_tags.json")
TAG_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*")


def _sort_and_validate(entries: list[dict]) -> list[dict]:
    names: set[str] = set()
    branches: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Each tag must be a JSON object.")
        name = entry.get("name")
        if not isinstance(name, str) or not TAG_NAME.fullmatch(name):
            raise ValueError(f"Invalid tag name {name!r}. Use dot-separated letters, digits, or underscores.")
        key = name.casefold()
        if key in names:
            raise ValueError(f"The tag {name!r} is already registered.")
        names.add(key)
        if not isinstance(entry.get("description", ""), str) or type(entry.get("code_owned", False)) is not bool:
            raise ValueError(f"Invalid metadata for {name!r}.")

        branch = ""
        for segment in name.split("."):
            branch = f"{branch}.{segment}" if branch else segment
            canonical = branches.setdefault(branch.casefold(), branch)
            if canonical != branch:
                raise ValueError(f"Use the existing spelling {canonical!r} instead of {branch!r}.")

    return sorted(entries, key=lambda entry: entry["name"].casefold())


class TagRegistry(QObject):
    changed = Signal()

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._path: Path | None = None
        self._contents: bytes | None = None
        self._document: dict = {}
        self.error = "Link a Godot project to edit gameplay tags."
        self._watcher = QFileSystemWatcher(self)
        self._watcher.fileChanged.connect(self.reload)
        self._watcher.directoryChanged.connect(self.reload)

    @property
    def entries(self) -> list[dict]:
        return self._document.get("tags", [])

    def set_project(self, project: Path | None) -> None:
        path = project.resolve() / REGISTRY_PATH if project is not None else None
        if path != self._path:
            self._path = path
            self._contents = None
        self.reload()

    def reload(self) -> None:
        self._update_watches()
        contents = None
        document = {}
        error = ""
        if self._path is None:
            error = "Link a Godot project to edit gameplay tags."
        else:
            try:
                contents = self._path.read_bytes()
                if contents == self._contents:
                    return
                document = json.loads(contents.decode("utf-8"))
                if not isinstance(document, dict) or type(document.get("version")) is not int or document["version"] != 1:
                    raise ValueError("Expected tag registry version 1.")
                if not isinstance(document.get("tags"), list):
                    raise ValueError("Expected a list of tags.")
                document["tags"] = _sort_and_validate(document["tags"])
            except FileNotFoundError:
                error = f"This checkout is missing {REGISTRY_PATH.as_posix()}."
            except (OSError, ValueError) as exc:
                error = f"Could not load the gameplay tag registry. {exc}"

        self._contents = contents
        if error:
            document = {}
        if document != self._document or error != self.error:
            self._document = document
            self.error = error
            self.changed.emit()

    def register(self, name: str, description: str) -> str:
        path = self._path
        if path is None or self.error:
            raise ValueError(self.error)
        lock = QLockFile(str(path.with_name(f".{path.name}.lock")))
        if not lock.tryLock(0):
            raise OSError("Could not lock the gameplay tag registry. Check the folder permissions and try again.")
        try:
            return self._register_locked(path, name, description)
        finally:
            lock.unlock()

    def _register_locked(self, path: Path, name: str, description: str) -> str:
        self._require_current(path)

        entry = {"name": name.strip()}
        if description.strip():
            entry["description"] = description.strip()
        entries = _sort_and_validate([*self.entries, entry])
        document = {**self._document, "tags": entries}
        contents = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

        output = QSaveFile(str(path))
        output.setDirectWriteFallback(False)
        if not output.open(QIODevice.OpenModeFlag.WriteOnly):
            raise OSError(output.errorString())
        if output.write(contents) != len(contents):
            raise OSError(output.errorString())
        try:
            self._require_current(path)
        except (OSError, ValueError):
            output.cancelWriting()
            raise
        if not output.commit():
            raise OSError(output.errorString())

        self.reload()
        return entry["name"]

    def _require_current(self, path: Path) -> None:
        try:
            if path.read_bytes() == self._contents:
                return
        except OSError as exc:
            self.reload()
            raise OSError(f"Could not reread the gameplay tag registry. {exc}") from exc
        self.reload()
        raise ValueError("The gameplay tag registry changed on disk. Review the latest tags and try again.")

    def _update_watches(self) -> None:
        paths: set[str] = set()
        if self._path is not None:
            if self._path.is_file():
                paths.add(str(self._path))
            for directory in self._path.parents:
                if directory.is_dir():
                    paths.add(str(directory))
                    break
        watched = set(self._watcher.files()) | set(self._watcher.directories())
        if obsolete := watched - paths:
            self._watcher.removePaths(sorted(obsolete))
        if missing := paths - watched:
            self._watcher.addPaths(sorted(missing))
