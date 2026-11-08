"""Read and write the linked project's authored combat definitions."""

from copy import deepcopy
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
from secrets import randbits

from PySide6.QtCore import QFile, QIODevice, QLockFile, QSaveFile


FORMAT = "godot_combat_definition"
VERSION = 1
SUFFIXES = {"ability": ".ability.json", "effect": ".effect.json"}
TYPES = {"ability": "AbilityDefinition", "effect": "GameplayEffectDefinition"}
ID_FIELDS = {"AbilityDefinition": "ability_id", "GameplayEffectDefinition": "effect_id"}
MAX_ID = 2**31 - 1
STARTING_LOADOUT = "player/starting_loadout.json"
ABILITY_SLOT_PREFIX = "ability_slot_"
IGNORED_FOLDERS = {"builds", "exports", "__pycache__"}
HIDDEN_IN_CATALOG = {"addons", "tests"}
UID_ALPHABET = "abcdefghijklmnopqrstuvwxy012345678"
UID_PATTERN = re.compile(r"uid://[a-z0-9]{1,13}")


@dataclass(frozen=True)
class JsonDocument:
    path: str
    data: dict
    revision: str


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key {key!r}.")
        result[key] = value
    return result


def _invalid_constant(value: str) -> None:
    raise ValueError(f"{value} is not a valid JSON value.")


def _read_data(contents: bytes) -> dict:
    result = json.loads(contents.decode("utf-8-sig"), object_pairs_hook=_unique_object,
                        parse_constant=_invalid_constant)
    if not isinstance(result, dict):
        raise ValueError("Expected a JSON object.")
    return result


def _sha(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def _new_uid() -> str:
    number = randbits(63)
    digits = []
    while number:
        number, digit = divmod(number, len(UID_ALPHABET))
        digits.append(UID_ALPHABET[digit])
    return "uid://" + ("".join(reversed(digits)) or "a")


def _resource_parts(path: str) -> list[str]:
    if not isinstance(path, str) or not path.startswith("res://"):
        raise ValueError("Choose an asset inside the linked Godot project.")
    parts = path[6:].split("/")
    if any(not part or part.startswith(".") or ":" in part or "\\" in part for part in parts):
        raise ValueError(f"Invalid project path {path!r}.")
    return parts


def _kind(path: str) -> str:
    for kind, suffix in SUFFIXES.items():
        if path.endswith(suffix):
            return kind
    raise ValueError("Choose an .ability.json or .effect.json file.")


def _root(data: dict) -> dict:
    return data["resources"][data["root"]]


def _definitions(data: dict):
    for key, resource in data["resources"].items():
        id_field = ID_FIELDS.get(resource["type"])
        if id_field is not None:
            yield key, resource, id_field


def _validate_data(data: dict, kind: str, *, saved: bool) -> None:
    if data.get("format") != FORMAT or type(data.get("version")) is not int or data["version"] != VERSION:
        raise ValueError("Expected combat definition JSON version 1.")
    uid = data.get("uid", "")
    if not isinstance(uid, str) or ((saved or uid) and not UID_PATTERN.fullmatch(uid)):
        raise ValueError("Invalid combat definition UID.")
    root = data.get("root")
    resources = data.get("resources")
    if not isinstance(resources, dict) or not isinstance(root, str) or root not in resources:
        raise ValueError("Expected a resource graph with a valid root.")
    for key, resource in resources.items():
        if not isinstance(key, str) or not key or not isinstance(resource, dict):
            raise ValueError("Invalid embedded resource.")
        if not isinstance(resource.get("type"), str) or not resource["type"]:
            raise ValueError(f"Resource {key!r} needs a type.")
        if not isinstance(resource.get("properties"), dict):
            raise ValueError(f"Resource {key!r} needs a properties object.")
        _validate_references(resource["properties"], resources)
    if _root(data)["type"] != TYPES[kind]:
        raise ValueError(f"This filename expects a {TYPES[kind]}.")
    used = set()
    for key, resource, id_field in _definitions(data):
        asset_id = resource["properties"].get(id_field, 0)
        if type(asset_id) is not int or not (int(saved) <= asset_id <= MAX_ID):
            raise ValueError(f"{key}.{id_field} must be a positive integer once saved.")
        if asset_id and asset_id in used:
            raise ValueError(f"Ability or effect ID {asset_id} appears twice in this definition.")
        used.add(asset_id)
    properties = _root(data)["properties"]
    name = properties.get("display_name", "")
    if not isinstance(name, str) or (saved and not name.strip()):
        raise ValueError("Enter a display name.")
    tags = properties.get("ability_tags" if kind == "ability" else "asset_tags", [])
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        raise ValueError("Tags must be a list of names.")


def _validate_references(value, resources: dict) -> None:
    if isinstance(value, list):
        for item in value:
            _validate_references(item, resources)
    elif isinstance(value, dict):
        if "$resource" in value:
            if (set(value) != {"$resource"} or not isinstance(value["$resource"], str)
                    or value["$resource"] not in resources):
                raise ValueError(f"Missing embedded resource {value.get('$resource')!r}.")
        elif "$asset" in value:
            _resource_parts(value["$asset"])
            uid = value.get("uid", "")
            if (set(value) - {"$asset", "uid"} or not isinstance(uid, str)
                    or (uid and not UID_PATTERN.fullmatch(uid))):
                raise ValueError("Invalid linked asset reference.")
        elif "$variant" in value:
            if set(value) != {"$variant"}:
                raise ValueError("Invalid Godot value.")
        else:
            for item in value.values():
                _validate_references(item, resources)


class JsonProject:
    """The on-disk JSON is the authority. Drafts carry a content revision."""

    def __init__(self, root: Path) -> None:
        self.root = root.resolve(strict=True)
        if not (self.root / "project.godot").is_file():
            raise ValueError("Link a Godot project folder.")

    def scan(self) -> tuple[list[dict], list[str]]:
        rows = []
        issues = []
        ids: dict[int, str] = {}
        for file in self._files():
            path = self._relative(file)
            try:
                kind = _kind(path)
            except ValueError:
                continue
            try:
                data = self._read_file(file, kind)
            except (OSError, ValueError) as error:
                issues.append(f"{path} · {error}")
                continue
            for key, record, id_field in _definitions(data):
                asset_id = record["properties"][id_field]
                if asset_id in ids:
                    issues.append(f"ID {asset_id} is used by {ids[asset_id]} and {path} · {key}.")
                else:
                    ids[asset_id] = f"{path} · {key}"
            if file.relative_to(self.root).parts[0] in HIDDEN_IN_CATALOG:
                continue
            properties = _root(data)["properties"]
            icon = properties.get("icon")
            rows.append({
                "id": properties[ID_FIELDS[TYPES[kind]]], "name": properties["display_name"],
                "tags": properties.get("ability_tags" if kind == "ability" else "asset_tags", []),
                "icon": icon.get("$asset", "") if isinstance(icon, dict) else "",
                "kind": kind, "path": path,
            })
        rows.sort(key=lambda row: (-row["id"], row["path"]))
        return rows, issues

    def open(self, path: str) -> JsonDocument:
        file = self._path(path)
        contents = file.read_bytes()
        data = _read_data(contents)
        _validate_data(data, _kind(path), saved=True)
        return JsonDocument(path, data, _sha(contents))

    def new(self, kind: str) -> JsonDocument:
        root_type = TYPES.get(kind)
        if root_type is None:
            raise ValueError("Choose Ability or Effect.")
        properties = {ID_FIELDS[root_type]: 0, "display_name": ""}
        resources = {"r1": {"type": root_type, "properties": properties}}
        if kind == "ability":
            properties["execution"] = {"$resource": "r2"}
            resources["r2"] = {"type": "PhasedAbilityExecution", "properties": {}}
        return JsonDocument("", {
            "format": FORMAT, "version": VERSION, "uid": "", "root": "r1",
            "resources": resources,
        }, "")

    def validation_data(self, document: dict, kind: str, path: str = "") -> dict:
        data = deepcopy(document)
        _validate_data(data, kind, saved=False)
        file = self._path(path) if path else None
        original = self.open(path).data if file is not None else None
        self._prepare_ids(data, original, file)
        _validate_data(data, kind, saved=True)
        return data

    def save(self, path: str, document: dict, revision: str) -> JsonDocument:
        kind = _kind(path)
        file = self._path(path)
        data = deepcopy(document)
        _validate_data(data, kind, saved=False)
        lock = self._lock()
        try:
            original = self._require_revision(file, revision)
            old_data = _read_data(original) if original is not None else None
            self._prepare_ids(data, old_data, file)
            _validate_data(data, kind, saved=True)
            written = self._write_if_current(file, data, revision)
            saved = self.open(path)
            if saved.revision != written:
                raise OSError("The saved definition changed during readback. Reopen it before editing.")
            return saved
        finally:
            lock.unlock()

    def starting_loadout(self) -> tuple[dict[str, int], str]:
        file = self.root / STARTING_LOADOUT
        if file.is_symlink() or file.parent.resolve() != file.parent:
            raise ValueError("Choose a regular starting loadout file in the player folder.")
        try:
            contents = file.read_bytes()
        except FileNotFoundError:
            return {}, ""
        data = _read_data(contents)
        if any(not key.startswith(ABILITY_SLOT_PREFIX) or type(value) is not int or not 0 < value <= MAX_ID
               for key, value in data.items()):
            raise ValueError("Starting loadout entries must map ability slots to positive ability IDs.")
        return data, _sha(contents)

    def set_starting_assignment(self, action: str, ability_path: str | None, revision: str) -> None:
        if not action.startswith(ABILITY_SLOT_PREFIX) or (ability_path is not None and _kind(ability_path) != "ability"):
            raise ValueError("Choose an ability slot and a valid ability.")
        lock = self._lock()
        try:
            assignments, current = self.starting_loadout()
            if current != revision:
                raise ValueError("The starting loadout changed on disk. Reload it before assigning an ability.")
            if ability_path is None:
                assignments.pop(action, None)
            else:
                ability = _root(self.open(ability_path).data)
                assignments[action] = ability["properties"]["ability_id"]
            written = self._write_if_current(self.root / STARTING_LOADOUT, dict(sorted(assignments.items())), revision)
            if self.starting_loadout()[1] != written:
                raise OSError("The starting loadout changed during readback. Reload it before assigning an ability.")
        finally:
            lock.unlock()

    def _write_if_current(self, file: Path, data: dict, revision: str) -> str:
        contents = (json.dumps(data, indent="\t", ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
        output = QSaveFile(str(file))
        output.setDirectWriteFallback(False)
        if not output.open(QIODevice.OpenModeFlag.WriteOnly):
            raise OSError(output.errorString())
        try:
            if output.write(contents) != len(contents):
                raise OSError(output.errorString())
            self._require_revision(file, revision)
            if not output.commit():
                raise OSError(output.errorString())
        except (OSError, ValueError):
            output.cancelWriting()
            raise
        return _sha(contents)

    def delete(self, path: str, revision: str) -> None:
        self.delete_many([(path, revision)])

    def delete_many(self, entries: list[tuple[str, str]]) -> None:
        if not entries:
            return
        lock = self._lock()
        try:
            revisions = {}
            names = {}
            ability_ids = {}
            for path, revision in entries:
                file = self._path(path)
                original = self._require_revision(file, revision)
                if original is None or file in revisions:
                    raise ValueError("Choose a distinct set of saved definitions.")
                revisions[file] = revision
                data = _read_data(original)
                uid = data.get("uid", "")
                names[file] = [path, uid] if uid else [path]
                if _kind(path) == "ability":
                    ability_ids[file] = _root(data)["properties"]["ability_id"]
            owners = self._referrers(names)
            if ability_ids:
                assignments, _ = self.starting_loadout()
                assigned_ids = set(assignments.values())
                for file, ability_id in ability_ids.items():
                    if ability_id in assigned_ids:
                        owners[file].add(self.root / STARTING_LOADOUT)
            order = self._delete_order(owners)
            for index, file in enumerate(order):
                try:
                    self._require_revision(file, revisions[file])
                    trashed = QFile(str(file))
                    if not trashed.moveToTrash():
                        raise OSError(trashed.errorString())
                except (OSError, ValueError) as error:
                    raise OSError(f"Moved {index} of {len(order)} definitions to the Recycle Bin. "
                                  f"{self._relative(file)} · {error}") from error
        finally:
            lock.unlock()

    def _referrers(self, names: dict[Path, list[str]]) -> dict[Path, set[Path]]:
        tokens = {
            file: {token.encode("utf-8") for name in refs for token in (
                json.dumps(name, ensure_ascii=False), json.dumps(name, ensure_ascii=True), f"'{name}'",
            )}
            for file, refs in names.items()
        }
        owners = {file: set() for file in names}
        for source in self._files():
            if source.suffix.lower() not in {".json", ".tscn", ".tres", ".gd", ".godot"}:
                continue
            contents = source.read_bytes()
            for file, references in tokens.items():
                if source != file and any(token in contents for token in references):
                    owners[file].add(source)
        return owners

    def _delete_order(self, owners: dict[Path, set[Path]]) -> list[Path]:
        external = [
            f"{self._relative(file)} is referenced by {self._relative(source)}."
            for file, sources in owners.items() for source in sorted(sources) if source not in owners
        ]
        if external:
            raise ValueError("\n".join(external))
        remaining = set(owners)
        order = []
        while remaining:
            ready = [file for file in sorted(remaining) if not owners[file] & remaining]
            if not ready:
                raise ValueError("The selected definitions reference each other in a cycle.")
            order.extend(ready)
            remaining.difference_update(ready)
        return order

    def _lock(self) -> QLockFile:
        lock = QLockFile(str(self.root / ".combat-definitions-write.lock"))
        lock.setStaleLockTime(0)
        if not lock.tryLock(0):
            raise OSError("Another editor is writing combat definitions in this checkout.")
        return lock

    def _prepare_ids(self, data: dict, original: dict | None, file: Path | None) -> None:
        occupied = {}
        uids = set()
        for other in self._files():
            if other == file:
                continue
            try:
                kind = _kind(other.name)
            except ValueError:
                continue
            try:
                saved = self._read_file(other, kind)
            except (OSError, ValueError) as error:
                raise ValueError(f"Cannot verify unique IDs while {self._relative(other)} is invalid. {error}") from error
            for _, record, id_field in _definitions(saved):
                occupied[record["properties"][id_field]] = self._relative(other)
            uids.add(saved.get("uid", ""))
        if original is not None:
            id_field = ID_FIELDS[_root(original)["type"]]
            if _root(data)["properties"].get(id_field) != _root(original)["properties"].get(id_field):
                raise ValueError("The saved ability or effect ID cannot be changed.")
            data["uid"] = original.get("uid", "")
        if not data.get("uid"):
            data["uid"] = _new_uid()
            while data["uid"] in uids:
                data["uid"] = _new_uid()
        elif data["uid"] in uids:
            raise ValueError("A different definition already uses this UID.")
        rows = list(_definitions(data))
        explicit = {record["properties"].get(field, 0) for _, record, field in rows}
        next_id = max({0, *occupied, *explicit}) + 1
        for _, record, field in rows:
            properties = record["properties"]
            asset_id = properties.get(field, 0)
            if asset_id in occupied:
                raise ValueError(f"ID {asset_id} is already used by {occupied[asset_id]}.")
            if asset_id == 0:
                if next_id > MAX_ID:
                    raise ValueError("No ability or effect IDs remain in the supported range.")
                properties[field] = next_id
                next_id += 1

    @staticmethod
    def _read_file(file: Path, kind: str) -> dict:
        data = _read_data(file.read_bytes())
        _validate_data(data, kind, saved=True)
        return data

    def _path(self, path: str) -> Path:
        _kind(path)
        parts = _resource_parts(path)
        file = self.root.joinpath(*parts)
        if (parts[0].lower() in IGNORED_FOLDERS | HIDDEN_IN_CATALOG or not file.parent.is_dir()
                or file.parent.resolve() != file.parent or file.is_symlink()
                or (file.exists() and not file.is_file())):
            raise ValueError("Choose a regular combat definition file in a project content folder.")
        if any((self.root.joinpath(*parts[:index]) / ".gdignore").is_file()
               for index in range(len(parts))):
            raise ValueError("Choose a folder included in the Godot project.")
        return file

    def _require_revision(self, file: Path, revision: str) -> bytes | None:
        if file.is_symlink() or file.parent.resolve() != file.parent:
            raise ValueError("The definition path changed. Reopen it before editing.")
        try:
            contents = file.read_bytes()
        except FileNotFoundError:
            contents = None
        actual = _sha(contents) if contents is not None else ""
        if actual != revision:
            if revision:
                raise ValueError("This JSON file changed on disk. Reload it before saving.")
            raise ValueError("A definition already exists at this path. Choose a different filename.")
        return contents

    def _relative(self, file: Path) -> str:
        return "res://" + file.relative_to(self.root).as_posix()

    def _files(self):
        for folder, directories, files in os.walk(self.root):
            path = Path(folder)
            if ".gdignore" in files:
                directories.clear()
                continue
            directories[:] = sorted(
                name for name in directories if not name.startswith(".") and name not in IGNORED_FOLDERS
                and (path / name).resolve() == path / name
            )
            for name in sorted(files):
                if not name.startswith(".") and not (path / name).is_symlink():
                    yield path / name
