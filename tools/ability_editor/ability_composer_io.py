"""Run native ability authoring commands and publish validated Resources."""

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4

from PySide6.QtCore import QIODevice, QLockFile, QObject, QProcess, QSaveFile, QTimer, Signal


COMPOSER_SCRIPT = "tools/ability_editor/ability_composer.gd"
RESULT_PREFIX = "ABILITY_COMPOSER "
REVISION_PATTERN = re.compile(r"[0-9a-f]{64}")


def resource_file(project: Path, resource_path: str) -> Path:
    """Accept ordinary saved resources under the linked project."""
    if not resource_path.startswith("res://"):
        raise ValueError("Choose a resource inside the linked Godot project.")
    parts = resource_path.removeprefix("res://").split("/")
    if any(not part or part.startswith(".") or ":" in part or "\\" in part for part in parts):
        raise ValueError("Choose an ordinary project resource path.")
    project = project.resolve(strict=True)
    file = project.joinpath(*parts)
    if (parts[0] in {"addons", "builds", "exports", "tests"}
            or any((project.joinpath(*parts[:index]) / ".gdignore").is_file()
                   for index in range(len(parts)))):
        raise ValueError("Choose a resource folder included in the ability catalog.")
    if (file.suffix.lower() not in {".tres", ".res"} or not file.parent.is_dir()
            or file.parent.resolve() != file.parent or file.is_symlink()
            or (file.exists() and not file.is_file())):
        raise ValueError("Choose a .tres or .res resource in a regular project folder.")
    return file


def _revision(file: Path) -> str:
    try:
        return hashlib.sha256(file.read_bytes()).hexdigest()
    except FileNotFoundError:
        return ""


def _require_revision(file: Path, expected: str) -> None:
    if file.is_symlink() or file.parent.resolve() != file.parent:
        raise ValueError("The ability path changed on disk. Reopen it from the linked project.")
    if _revision(file) != expected:
        if expected:
            raise ValueError("This ability changed on disk. Reopen it from Abilities before saving.")
        raise ValueError("A resource already exists there. Choose a new file name.")


@dataclass
class _Job:
    mode: str
    file: Path
    revision: str = ""
    stage: Path | None = None
    request_dir: TemporaryDirectory | None = None
    lock: QLockFile | None = None

    def release(self) -> None:
        try:
            if self.stage is not None:
                self.stage.unlink(missing_ok=True)
                self.stage.with_name(f"{self.stage.name}.uidren").unlink(missing_ok=True)
        finally:
            try:
                if self.request_dir is not None:
                    self.request_dir.cleanup()
            finally:
                if self.lock is not None:
                    self.lock.unlock()


class AbilityComposerIO(QObject):
    completed = Signal(str, object, str)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._process = QProcess(self)
        self._process.finished.connect(self._finished)
        self._process.errorOccurred.connect(self._process_error)
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self._process.kill)
        self._job: _Job | None = None

    @property
    def busy(self) -> bool:
        return self._job is not None

    def read(self, executable: str, project: Path, path: str) -> None:
        file = resource_file(project, path)
        if not file.is_file():
            raise ValueError("The ability file is missing. Refresh the catalog.")
        self._start(executable, project, _Job("read", file), ["--read", path])

    def stage(
        self, executable: str, project: Path, path: str, draft: dict, revision: str, *, publish: bool,
    ) -> None:
        if self.busy:
            raise ValueError("Wait for the current ability operation to finish.")
        if revision and not REVISION_PATTERN.fullmatch(revision):
            raise ValueError("The opened ability has an invalid disk revision.")
        file = resource_file(project, path)
        if not revision and file.suffix.lower() != ".tres":
            raise ValueError("New abilities use the .tres extension.")
        job = _Job("save" if publish else "check", file, revision)
        try:
            if publish:
                lock = QLockFile(str(project / ".ability-editor-write.lock"))
                lock.setStaleLockTime(0)
                if not lock.tryLock(0):
                    raise OSError("Another Ability Editor is writing to this project. Try again shortly.")
                job.lock = lock
            _require_revision(file, revision)
            project = project.resolve(strict=True)
            stage_dir = project / ".godot" / "ability_editor"
            if stage_dir.resolve() != stage_dir:
                raise ValueError("The linked project's ability staging folder is redirected.")
            stage_dir.mkdir(parents=True, exist_ok=True)
            job.stage = stage_dir / f".ability-editor-{uuid4().hex}{file.suffix}"
            job.request_dir = TemporaryDirectory(prefix="ability-editor-request-")
            request = Path(job.request_dir.name) / "draft.json"
            request.write_text(json.dumps({"draft": draft, "revision": revision}, allow_nan=False), encoding="utf-8")
            stage_path = "res://" + job.stage.relative_to(project).as_posix()
            self._start(executable, project, job, ["--stage", path, str(request), stage_path])
        except (OSError, TypeError, ValueError):
            job.release()
            raise

    def _start(self, executable: str, project: Path, job: _Job, arguments: list[str]) -> None:
        if self.busy or self._process.state() != QProcess.ProcessState.NotRunning:
            raise ValueError("Wait for the current ability operation to finish.")
        self._job = job
        self._process.setWorkingDirectory(str(project))
        self._timer.start(45_000)
        self._process.start(executable, [
            "--headless", "--no-header", "--path", str(project), "--script", f"res://{COMPOSER_SCRIPT}",
            "--", *arguments,
        ])

    def _process_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.ProcessError.FailedToStart:
            self._complete(None, f"Godot could not start. {self._process.errorString()}")

    def _finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        job = self._job
        output = bytes(self._process.readAllStandardOutput()).decode("utf-8", errors="replace")
        diagnostics = bytes(self._process.readAllStandardError()).decode("utf-8", errors="replace").strip()
        if job is None:
            return
        if not self._timer.isActive():
            self._complete(None, "Godot took too long to finish the ability check.")
            return
        try:
            line = next((line for line in output.splitlines() if line.startswith(RESULT_PREFIX)), "")
            if not line:
                raise ValueError(diagnostics or "Godot did not return an ability authoring result.")
            result = json.loads(line[len(RESULT_PREFIX):])
            if not isinstance(result, dict):
                raise ValueError("Godot returned an invalid ability authoring result.")
            if result.get("error"):
                raise ValueError(str(result["error"]))
            if exit_code or exit_status != QProcess.ExitStatus.NormalExit or "ERROR:" in diagnostics:
                raise ValueError(diagnostics or "Godot reported an error while checking the ability.")
            revision = result.get("revision")
            if (not isinstance(result.get("draft"), dict) or not isinstance(revision, str)
                    or not REVISION_PATTERN.fullmatch(revision)):
                raise ValueError("Godot did not return a verified ability draft.")
            if job.mode == "read":
                _require_revision(job.file, revision)
            else:
                self._finish_stage(job, revision)
        except (OSError, ValueError) as error:
            self._complete(None, str(error))
            return
        self._complete(result, "")

    @staticmethod
    def _finish_stage(job: _Job, revision: str) -> None:
        stage = job.stage
        if stage is None or stage.is_symlink():
            raise ValueError("Godot did not produce a regular staged resource.")
        contents = stage.read_bytes()
        if not contents or hashlib.sha256(contents).hexdigest() != revision:
            raise ValueError("The staged resource changed after Godot verified it.")
        _require_revision(job.file, job.revision)
        if job.mode != "save":
            return
        output = QSaveFile(str(job.file))
        output.setDirectWriteFallback(False)
        if not output.open(QIODevice.OpenModeFlag.WriteOnly):
            raise OSError(output.errorString())
        try:
            if output.write(contents) != len(contents):
                raise OSError(output.errorString())
            _require_revision(job.file, job.revision)
            if not output.commit():
                raise OSError(output.errorString())
        except (OSError, ValueError):
            output.cancelWriting()
            raise
        _require_revision(job.file, revision)

    def _complete(self, result: dict | None, error: str) -> None:
        job = self._job
        if job is None:
            return
        self._job = None
        self._timer.stop()
        try:
            job.release()
        except OSError as cleanup_error:
            # A cleanup failure does not roll back a resource already published.
            if result is None and not error:
                error = str(cleanup_error)
        self.completed.emit(job.mode, result, error)
