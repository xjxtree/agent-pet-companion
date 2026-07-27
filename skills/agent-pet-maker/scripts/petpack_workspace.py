#!/usr/bin/env python3
"""Prepare, motion-review, and finalize Agent Pet Companion petpack workspaces.

This helper never invents source artwork. It provides deterministic archive safety,
base-revision bookkeeping, motion QA previews, PetCore CLI discovery, validation,
and packaging.
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import json
import math
import os
import shutil
import stat
import statistics
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


HELPER_SCHEMA = "apc.pet-maker-helper.v1"
WORKSPACE_SCHEMA = "apc.pet-maker-workspace.v1"
RESULT_SCHEMA = "apc.pet-maker-result.v1"
SOURCE_SCHEMA = "apc.pet-source.v1"
SOURCE_EVENT_SCHEMA = "apc.pet-source-event.v1"
VALIDATION_SCHEMA = "apc.pet-validation.v1"
PETPACK_SCHEMA = "apc.petpack.v1"
MOTION_QA_SCHEMA = "apc.pet-motion-qa.v1"
MOTION_REVIEW_SCHEMA = "apc.pet-motion-review.v1"
MOTION_LOCK_SCHEMA = "apc.pet-motion-lock.v1"
STATES = ("idle", "start", "tool", "waiting", "review", "done", "failed")
ONE_SHOT_STATES = frozenset({"start", "done"})
VALID_NATIVE_FPS = (10, 20)
VALID_DURATION_MS = (1000, 2000)
DEFAULT_NATIVE_FPS = 10
DEFAULT_STATE_DURATIONS_MS = {
    "idle": 2000,
    "start": 1000,
    "tool": 2000,
    "waiting": 2000,
    "review": 2000,
    "done": 1000,
    "failed": 2000,
}

# Keep these limits aligned with PetCore's v1 archive limits.
MAX_ARCHIVE_BYTES = 1024 * 1024 * 1024
MAX_ENTRIES = 5_000
MAX_ENTRY_BYTES = 256 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
MAX_SESSION_BYTES = 256 * 1024
MAX_TEXT_METADATA_BYTES = 256 * 1024
MAX_PROMPT_BYTES = 64 * 1024
MAX_ANIMATED_PREVIEW_FRAMES = 120
MAX_DECODED_ANIMATED_PREVIEW_BYTES = 128 * 1024 * 1024
VISIBLE_ALPHA_THRESHOLD = 16
TRANSPARENT_ALPHA_THRESHOLD = 239
MIN_VISUAL_PIXEL_PERCENT = 1
COPY_CHUNK_BYTES = 1024 * 1024
CLI_TIMEOUT_SECONDS = 300
MOTION_PREVIEW_SIZE = (192, 208)
MOTION_KEYFRAME_COUNT = 5
MAX_MOTION_REVIEW_NOTE_CHARACTERS = 500
MIN_MOTION_REVIEW_NOTE_CHARACTERS = 12
PILLOW_REQUIRED_COMMANDS = frozenset(
    {"preflight", "prepare", "motion-qa", "motion-lock", "finalize", "install"}
)
PILLOW_REEXEC_MARKER = "APC_PET_MAKER_PILLOW_REEXEC"
PILLOW_PYTHON_OVERRIDE = "APC_PET_MAKER_PYTHON"

SOURCE_ALLOWED_KEYS = {
    "schema_version",
    "generator",
    "provenance",
    "created_at",
    "manifest_id",
    "pet_name",
    "style",
    "quality",
    "visual_source",
    "native_fps",
    "state_durations_ms",
    "state_frame_counts",
    "preview_only",
    "reference_visual_influence",
    "form",
    "reference_files",
    "input_reference_count",
    "copied_reference_count",
    "ai_brief",
    "palette_source",
    "palette",
    "skill_helper",
    "runner",
    "materialized_by",
    "base_manifest_id",
    "base_revision",
    "changed_states",
    "extensions",
}
EVENT_ALLOWED_KEYS = {
    "schema_version",
    "event",
    "created_at",
    "skill",
    "runner",
    "helper",
    "generator",
    "provenance",
    "materializer",
    "manifest_id",
    "petpack_source",
    "name",
    "style",
    "quality",
    "render_size",
    "states",
    "changed_states",
    "native_fps",
    "state_durations_ms",
    "state_frame_counts",
    "completed",
    "validation_ok",
    "reference_count",
    "extensions",
}
BRIEF_ALLOWED_KEYS = {
    "schema_version",
    "name",
    "style",
    "quality",
    "description",
    "generation",
    "ai_brief",
    "visual_brief",
    "render_notes",
    "palette",
    "references",
    "states",
    "runtime",
    "extensions",
}

PRIVATE_FIELD_CATEGORIES = {
    "threadid": "thread_id",
    "turnid": "turn_id",
    "sessionid": "session_id",
    "requestid": "request_id",
    "conversationid": "conversation_id",
    "conversation": "conversation",
    "conversations": "conversation",
    "messagehistory": "messages",
    "messages": "messages",
    "transcript": "transcript",
    "transcripts": "transcript",
    "fulltranscript": "transcript",
    "rawtranscript": "transcript",
    "assistanttext": "conversation_text",
    "assistantmessage": "conversation_text",
    "usermessage": "conversation_text",
    "usermessages": "conversation_text",
    "reasoning": "hidden_reasoning",
    "reasoningtext": "hidden_reasoning",
    "hiddenreasoning": "hidden_reasoning",
    "chainofthought": "hidden_reasoning",
    "internalthoughts": "hidden_reasoning",
    "command": "command",
    "commands": "command",
    "commandline": "command",
    "commandsource": "command",
    "shellcommand": "command",
    "toolargs": "tool_input",
    "toolarguments": "tool_input",
    "toolinput": "tool_input",
    "tooloutput": "tool_output",
    "toolresult": "tool_output",
    "toolresults": "tool_output",
    "toolresponse": "tool_output",
    "toolresponses": "tool_output",
    "stdout": "process_output",
    "stderr": "process_output",
    "environment": "execution_environment",
    "env": "execution_environment",
    "cwd": "execution_environment",
    "workingdirectory": "execution_environment",
    "workspacepath": "execution_environment",
    "token": "credential",
    "accesstoken": "credential",
    "refreshtoken": "credential",
    "apikey": "credential",
    "cookie": "authentication",
    "cookies": "authentication",
    "authorization": "authentication",
    "auth": "authentication",
    "authentication": "authentication",
    "secret": "credential",
    "secrets": "credential",
    "password": "credential",
    "credential": "credential",
    "credentials": "credential",
    "codexappserver": "codex_app_server",
}


class MakerError(Exception):
    def __init__(self, code: str, message: str, detail: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def bounded(text: str, limit: int = 4_096) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(COPY_CHUNK_BYTES):
            digest.update(chunk)
    return digest.hexdigest()


def minimum_visual_pixel_count(total_pixels: int) -> int:
    """Require one percent of a raster, rounded up, and never zero pixels."""

    return max(1, (total_pixels * MIN_VISUAL_PIXEL_PERCENT + 100 - 1) // 100)


def canonical_premultiplied_rgba(image: Any) -> bytes:
    """Return display-relevant pixels using PetCore's alpha normalization.

    Comparing encoded PNG/WebP bytes (or straight-alpha RGBA) lets a producer
    fake motion by changing RGB values hidden below the visible threshold. A
    premultiplied representation matches the compositor-facing visual value;
    pixels below PetCore's visible-alpha threshold map to zero RGBA.
    """

    rgba = image.convert("RGBA")
    canonical = bytearray(rgba.width * rgba.height * 4)
    offset = 0
    pixels = (
        rgba.get_flattened_data()
        if hasattr(rgba, "get_flattened_data")
        else rgba.getdata()
    )
    for red, green, blue, alpha in pixels:
        if alpha < VISIBLE_ALPHA_THRESHOLD:
            canonical[offset : offset + 4] = b"\x00\x00\x00\x00"
        else:
            canonical[offset] = (red * alpha + 127) // 255
            canonical[offset + 1] = (green * alpha + 127) // 255
            canonical[offset + 2] = (blue * alpha + 127) // 255
            canonical[offset + 3] = alpha
        offset += 4
    return bytes(canonical)


def visual_pixel_counts(image: Any) -> tuple[int, int, int]:
    """Return total, visibly occupied, and transparent-surrounding pixels."""

    alpha = image.convert("RGBA").getchannel("A")
    histogram = alpha.histogram()
    visible = sum(histogram[VISIBLE_ALPHA_THRESHOLD:])
    transparent = sum(histogram[: TRANSPARENT_ALPHA_THRESHOLD + 1])
    return image.width * image.height, visible, transparent


def decoded_png_digest(path: Path) -> str:
    """Hash a PNG's decoded compositor-visible pixels rather than file bytes."""

    try:
        from PIL import Image, UnidentifiedImageError
    except (ImportError, OSError) as error:
        raise MakerError(
            "capability_missing",
            "Python Pillow is required to inspect generated pet assets",
            bounded(str(error)),
        ) from error
    try:
        with Image.open(path) as decoded:
            if decoded.format != "PNG":
                raise MakerError("invalid_assets", f"Frame {path.name} is not a PNG")
            return hashlib.sha256(canonical_premultiplied_rgba(decoded)).hexdigest()
    except MakerError:
        raise
    except (OSError, ValueError, UnidentifiedImageError) as error:
        raise MakerError(
            "invalid_assets",
            f"Frame {path.name} could not be decoded as PNG",
            bounded(str(error)),
        ) from error


def write_json_atomic(path: Path, value: Any) -> None:
    path = path.expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        if path.stat().st_size > MAX_TEXT_METADATA_BYTES:
            raise MakerError("invalid_metadata", f"{label} exceeds the metadata size limit")
        value = json.loads(path.read_text(encoding="utf-8"))
    except MakerError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise MakerError("invalid_metadata", f"Could not read {label}: {error}") from error
    if not isinstance(value, dict):
        raise MakerError("invalid_metadata", f"{label} must contain a JSON object")
    return value


def is_executable_file(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def installed_cli_candidates() -> list[Path]:
    home = Path.home()
    apc_home = Path(
        os.environ.get(
            "APC_HOME",
            home / "Library" / "Application Support" / "AgentPetCompanion",
        )
    ).expanduser()
    candidates = [apc_home / "runtime" / "current" / "petcore-cli"]

    # A copy of this Skill bundled by Agent Pet Companion can use the CLI from
    # the same signed runtime without relying on the App's install location.
    script_path = Path(__file__).resolve()
    if len(script_path.parents) > 4:
        skill_dir = script_path.parents[1]
        skills_dir = script_path.parents[2]
        resources_dir = script_path.parents[3]
        if (
            skill_dir.name == "agent-pet-maker"
            and skills_dir.name == "skills"
            and resources_dir.name == "Resources"
            and resources_dir.parent.name == "Contents"
        ):
            candidates.append(resources_dir / "bin" / "petcore-cli")

    # AgentPetCompanion.app is the actual bundle name. Keep the historical
    # spaced spelling as a compatibility fallback for older local builds.
    for applications_root in (Path("/Applications"), home / "Applications"):
        for application_name in ("AgentPetCompanion.app", "Agent Pet Companion.app"):
            candidates.append(
                applications_root
                / application_name
                / "Contents"
                / "Resources"
                / "bin"
                / "petcore-cli"
            )
    return candidates


def repository_cli_candidates() -> list[Path]:
    script_path = Path(__file__).resolve()
    if len(script_path.parents) <= 3:
        return []
    repository = script_path.parents[3]
    return [
        repository / "target" / "release" / "petcore-cli",
        repository / "target" / "debug" / "petcore-cli",
    ]


def first_executable(candidates: Iterable[Path]) -> Path | None:
    seen: set[str] = set()
    for raw_candidate in candidates:
        candidate = raw_candidate.expanduser().resolve()
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        if is_executable_file(candidate):
            return candidate
    return None


def bundled_runtime_python_candidates() -> list[Path]:
    """Return bounded Python candidates from Codex's managed local runtimes."""

    runtime_root = Path.home() / ".cache" / "codex-runtimes"
    if not runtime_root.is_dir():
        return []
    return [
        candidate
        for candidate in sorted(
            runtime_root.glob("*/dependencies/python/bin/python3*")
        )[:32]
        if not candidate.name.endswith("-config")
    ]


def pillow_python_candidates() -> list[Path]:
    candidates: list[Path] = []
    override = os.environ.get(PILLOW_PYTHON_OVERRIDE, "").strip()
    if override:
        candidates.append(Path(override).expanduser())
    candidates.extend(bundled_runtime_python_candidates())
    for executable_name in ("python3.13", "python3.12", "python3.11", "python3"):
        if path := shutil.which(executable_name):
            candidates.append(Path(path))
    return candidates


def interpreter_has_pillow(candidate: Path) -> bool:
    try:
        completed = subprocess.run(
            [
                str(candidate),
                "-I",
                "-c",
                "from PIL import Image; assert Image.__version__",
            ],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=8,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0


def locate_pillow_python() -> Path | None:
    seen: set[str] = set()
    for raw_candidate in pillow_python_candidates():
        try:
            candidate = raw_candidate.resolve(strict=True)
        except OSError:
            continue
        key = str(candidate)
        if key in seen or not is_executable_file(candidate):
            continue
        seen.add(key)
        if interpreter_has_pillow(candidate):
            return candidate
    return None


def current_interpreter_has_pillow() -> bool:
    try:
        from PIL import Image
    except (ImportError, OSError):
        return False
    return getattr(Image, "__version__", None) is not None


def ensure_pillow_runtime(command: str, argv: list[str]) -> None:
    """Re-exec with a real managed Pillow runtime instead of accepting shims."""

    if command not in PILLOW_REQUIRED_COMMANDS or current_interpreter_has_pillow():
        return
    if os.environ.get(PILLOW_REEXEC_MARKER) == "1":
        raise MakerError(
            "capability_missing",
            "Python Pillow with PNG and animated WebP support is required",
        )
    interpreter = locate_pillow_python()
    if interpreter is None:
        raise MakerError(
            "capability_missing",
            "Python Pillow with PNG and animated WebP support is required; no supported local interpreter was found",
        )
    environment = dict(os.environ)
    environment[PILLOW_REEXEC_MARKER] = "1"
    os.execve(
        str(interpreter),
        [str(interpreter), str(Path(__file__).resolve()), *argv],
        environment,
    )


def locate_cli(explicit: str | None = None) -> Path:
    if explicit:
        candidate = Path(explicit).expanduser().resolve()
        if is_executable_file(candidate):
            return candidate
        raise MakerError(
            "capability_missing",
            f"The requested PetCore CLI is not executable: {candidate}",
        )

    candidates: list[Path] = []
    environment_cli = os.environ.get("APC_PETCORE_CLI", "").strip()
    if environment_cli:
        candidates.append(Path(environment_cli).expanduser())

    which_cli = shutil.which("petcore-cli")
    if which_cli:
        candidates.append(Path(which_cli))

    candidates.extend(installed_cli_candidates())
    candidates.extend(repository_cli_candidates())
    candidate = first_executable(candidates)
    if candidate:
        return candidate

    raise MakerError(
        "capability_missing",
        "petcore-cli is required but was not found. Set APC_PETCORE_CLI or install Agent Pet Companion.",
    )


def locate_install_cli(explicit: str | None = None) -> Path:
    """Locate the online mutation CLI, preferring the installed App runtime.

    An explicit CLI remains authoritative for testing and advanced use. Without
    one, the App-managed current runtime is deliberately selected before
    environment/PATH development tools so an install talks to the matching
    running daemon whenever possible.
    """

    if explicit:
        return locate_cli(explicit)
    candidates = installed_cli_candidates()
    environment_cli = os.environ.get("APC_PETCORE_CLI", "").strip()
    if environment_cli:
        candidates.append(Path(environment_cli).expanduser())
    which_cli = shutil.which("petcore-cli")
    if which_cli:
        candidates.append(Path(which_cli))
    candidates.extend(repository_cli_candidates())
    candidate = first_executable(candidates)
    if candidate:
        return candidate
    raise MakerError(
        "capability_missing",
        "An installed App PetCore CLI is required for online install. Start Agent Pet Companion or set APC_PETCORE_CLI.",
    )


def verify_image_codecs() -> dict[str, Any]:
    """Exercise the image codecs required by the portable creation workflow."""

    try:
        from PIL import Image
    except (ImportError, OSError) as error:
        raise MakerError(
            "capability_missing",
            "Python Pillow with PNG and animated WebP support is required",
            bounded(str(error)),
        ) from error

    try:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-codecs-") as temporary:
            root = Path(temporary)
            first = Image.new("RGBA", (2, 2), (255, 0, 0, 128))
            second = Image.new("RGBA", (2, 2), (0, 0, 255, 128))
            png = root / "probe.png"
            webp = root / "probe.webp"
            first.save(png, format="PNG")
            first.save(
                webp,
                format="WEBP",
                save_all=True,
                append_images=[second],
                duration=[80, 80],
                loop=0,
            )
            with Image.open(png) as decoded_png:
                decoded_png.load()
                if decoded_png.size != (2, 2):
                    raise OSError("PNG round-trip size mismatch")
            with Image.open(webp) as decoded_webp:
                if getattr(decoded_webp, "n_frames", 1) < 2:
                    raise OSError("animated WebP decoder returned fewer than two frames")
                decoded_webp.seek(1)
                decoded_webp.load()
    except (OSError, ValueError) as error:
        raise MakerError(
            "capability_missing",
            "Pillow cannot encode/decode the required PNG and animated WebP assets",
            bounded(str(error)),
        ) from error
    return {
        "pillow_version": getattr(Image, "__version__", "unknown"),
        "png": True,
        "animated_webp": True,
    }


def verify_cli_contract(cli: Path) -> dict[str, Any]:
    """Probe the petpack validation command without requiring a running daemon.

    Merely finding an executable is not enough: an older or unrelated binary
    can exist at the expected path. A deliberately incomplete manifest must
    reach both the positional `petpack validate <path>` command and the
    `petpack build --input ... --output ...` command, fail their schema
    contract, and produce no archive. An unknown-command diagnostic or an
    unexpected success means the CLI cannot safely be used by this helper.
    """

    try:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-cli-probe-") as temporary:
            source = Path(temporary, "source")
            source.mkdir()
            Path(source, "manifest.json").write_text("{}\n", encoding="utf-8")
            output = Path(temporary, "probe.petpack")
            probes = {
                "petpack_validate": [str(cli), "petpack", "validate", str(source)],
                "petpack_build": [
                    str(cli),
                    "petpack",
                    "build",
                    "--input",
                    str(source),
                    "--output",
                    str(output),
                ],
            }
            completed_probes = {
                name: subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=min(CLI_TIMEOUT_SECONDS, 30),
                )
                for name, command in probes.items()
            }
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MakerError(
            "capability_missing",
            "PetCore CLI contract probe could not run",
            bounded(str(error)),
        ) from error

    verified: dict[str, bool] = {}
    for name, completed in completed_probes.items():
        diagnostic = bounded(completed.stderr or completed.stdout or "")
        normalized = diagnostic.casefold()
        if (
            completed.returncode == 0
            or not diagnostic
            or "unknown" in normalized
            or "schema_version" not in normalized
        ):
            raise MakerError(
                "capability_missing",
                f"The located PetCore CLI does not expose the required {name.replace('_', ' ')} contract",
                diagnostic or f"unexpected exit status {completed.returncode}",
            )
        verified[name] = True
    if output.exists():
        raise MakerError(
            "capability_missing",
            "The PetCore CLI build probe wrote an archive for an invalid manifest",
        )
    return {**verified, "invalid_manifest_rejected": True}


def run_cli_value(cli: Path, arguments: list[str], error_code: str) -> Any:
    try:
        completed = subprocess.run(
            [str(cli), *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=CLI_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MakerError(error_code, f"PetCore CLI execution failed: {error}") from error

    if completed.returncode != 0:
        detail = bounded(completed.stderr or completed.stdout or "no diagnostic output")
        raise MakerError(error_code, "PetCore CLI rejected the operation", detail)
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise MakerError(
            error_code,
            "PetCore CLI returned non-JSON output",
            bounded(completed.stdout),
        ) from error
    return value


def run_cli(cli: Path, arguments: list[str], error_code: str) -> dict[str, Any]:
    value = run_cli_value(cli, arguments, error_code)
    if not isinstance(value, dict):
        raise MakerError(error_code, "PetCore CLI returned an unexpected result")
    return value


def run_cli_list(cli: Path, arguments: list[str], error_code: str) -> list[dict[str, Any]]:
    value = run_cli_value(cli, arguments, error_code)
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise MakerError(error_code, "PetCore CLI returned an unexpected list result")
    return value


def ensure_empty_workspace(workspace: Path) -> tuple[Path, bool]:
    raw = workspace.expanduser()
    if raw.is_symlink():
        raise MakerError("unsafe_workspace", "Workspace must not be a symbolic link")
    workspace = raw.resolve()
    created = False
    if workspace.exists():
        if not workspace.is_dir():
            raise MakerError("unsafe_workspace", "Workspace path is not a directory")
        if any(workspace.iterdir()):
            raise MakerError("workspace_not_empty", "Workspace must be new or empty")
    else:
        workspace.mkdir(parents=True, mode=0o700)
        created = True
    os.chmod(workspace, 0o700)
    return workspace, created


def safe_member_parts(name: str) -> tuple[str, ...]:
    if not name or "\x00" in name or "\\" in name:
        raise MakerError("unsafe_archive", "Petpack contains an invalid archive path")
    trimmed = name[:-1] if name.endswith("/") else name
    if not trimmed:
        raise MakerError("unsafe_archive", "Petpack contains an empty archive path")
    raw_parts = trimmed.split("/")
    if any(part in ("", ".", "..") for part in raw_parts):
        raise MakerError("unsafe_archive", f"Unsafe petpack path: {name}")
    pure = PurePosixPath(trimmed)
    if pure.is_absolute() or tuple(pure.parts) != tuple(raw_parts):
        raise MakerError("unsafe_archive", f"Unsafe petpack path: {name}")
    return tuple(raw_parts)


def verify_member_type(info: zipfile.ZipInfo) -> None:
    if info.flag_bits & 0x1:
        raise MakerError("unsafe_archive", f"Encrypted petpack entry is not supported: {info.filename}")
    unix_mode = (info.external_attr >> 16) & 0xFFFF
    file_type = stat.S_IFMT(unix_mode)
    allowed_types = {0, stat.S_IFREG, stat.S_IFDIR}
    if file_type not in allowed_types or file_type == stat.S_IFLNK:
        raise MakerError("unsafe_archive", f"Special or symbolic-link entry is not allowed: {info.filename}")


def safe_extract_petpack(archive_path: Path, destination: Path) -> None:
    if not archive_path.is_file():
        raise MakerError("invalid_input", f"Input petpack does not exist: {archive_path}")
    if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise MakerError("unsafe_archive", "Petpack archive exceeds the 1 GiB limit")

    destination.mkdir(parents=True, mode=0o700)
    destination_root = destination.resolve()
    seen: set[str] = set()
    total_declared = 0
    total_written = 0

    try:
        archive = zipfile.ZipFile(archive_path)
    except (OSError, zipfile.BadZipFile) as error:
        raise MakerError("invalid_input", f"Input is not a readable petpack ZIP: {error}") from error

    with archive:
        members = archive.infolist()
        if len(members) > MAX_ENTRIES:
            raise MakerError("unsafe_archive", "Petpack contains too many entries")

        prepared: list[tuple[zipfile.ZipInfo, tuple[str, ...]]] = []
        for info in members:
            verify_member_type(info)
            parts = safe_member_parts(info.filename)
            logical = "/".join(parts).casefold()
            if logical in seen:
                raise MakerError("unsafe_archive", f"Duplicate logical petpack path: {info.filename}")
            seen.add(logical)
            if info.file_size > MAX_ENTRY_BYTES:
                raise MakerError("unsafe_archive", f"Petpack entry is too large: {info.filename}")
            total_declared += info.file_size
            if total_declared > MAX_TOTAL_BYTES:
                raise MakerError("unsafe_archive", "Petpack uncompressed size exceeds 4 GiB")
            prepared.append((info, parts))

        for info, parts in prepared:
            target = destination.joinpath(*parts)
            target_resolved = target.resolve()
            try:
                target_resolved.relative_to(destination_root)
            except ValueError as error:
                raise MakerError("unsafe_archive", f"Petpack path escapes workspace: {info.filename}") from error

            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
                os.chmod(target, 0o700)
                continue

            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            written_for_entry = 0
            try:
                source = archive.open(info, "r")
                output = target.open("xb")
                with source, output:
                    while chunk := source.read(COPY_CHUNK_BYTES):
                        written_for_entry += len(chunk)
                        total_written += len(chunk)
                        if written_for_entry > MAX_ENTRY_BYTES or total_written > MAX_TOTAL_BYTES:
                            raise MakerError("unsafe_archive", "Petpack expanded beyond safety limits")
                        output.write(chunk)
            except MakerError:
                raise
            except (OSError, RuntimeError, zipfile.BadZipFile) as error:
                raise MakerError("unsafe_archive", f"Could not extract {info.filename}: {error}") from error
            os.chmod(target, 0o600)
            if written_for_entry != info.file_size:
                raise MakerError("unsafe_archive", f"Petpack entry size mismatch: {info.filename}")


def write_session(source_dir: Path, event: dict[str, Any]) -> None:
    session = source_dir / "source" / "skill_session.jsonl"
    session.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    session.write_text(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(session, 0o600)


def append_session_event(source_dir: Path, event: dict[str, Any]) -> None:
    session = source_dir / "source" / "skill_session.jsonl"
    with session.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")


def scaffold_source(source_dir: Path, operation: str, base: dict[str, Any] | None = None) -> None:
    for relative in (
        "assets/preview",
        "source/references",
        "build",
        *(f"assets/frames/{state}" for state in STATES),
    ):
        (source_dir / relative).mkdir(parents=True, exist_ok=True, mode=0o700)
    event: dict[str, Any] = {
        "schema_version": SOURCE_EVENT_SCHEMA,
        "event": "workspace.prepared",
        "created_at": utc_now(),
        "skill": "agent-pet-maker",
    }
    if base:
        event["manifest_id"] = base["pet_id"]
        event["changed_states"] = []
    write_session(source_dir, event)


def manifest_state_paths(manifest: dict[str, Any]) -> dict[str, str]:
    entries = manifest.get("states")
    if not isinstance(entries, list):
        raise MakerError("invalid_manifest", "manifest.json states must be an array")
    result: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise MakerError("invalid_manifest", "manifest.json contains an invalid state entry")
        name = entry.get("name")
        frames_dir = entry.get("frames_dir")
        if name in STATES and frames_dir == f"assets/frames/{name}":
            result[name] = frames_dir
    if set(result) != set(STATES):
        raise MakerError("invalid_manifest", "manifest.json must contain all seven fixed states")
    return result


def manifest_timing_contract(manifest: dict[str, Any]) -> dict[str, Any]:
    native_fps = manifest.get("native_fps")
    if type(native_fps) is not int or native_fps not in VALID_NATIVE_FPS:
        raise MakerError("invalid_manifest", "manifest.native_fps must be exactly 10 or 20")

    entries = manifest.get("states")
    if not isinstance(entries, list) or len(entries) != len(STATES):
        raise MakerError("invalid_manifest", "manifest.json must contain exactly seven states")
    durations: dict[str, int] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise MakerError("invalid_manifest", "manifest.json contains an invalid state entry")
        state = entry.get("name")
        duration_ms = entry.get("duration_ms")
        if state not in STATES or state in durations:
            raise MakerError("invalid_manifest", "manifest.json state names must be unique and fixed")
        if type(duration_ms) is not int or duration_ms not in VALID_DURATION_MS:
            raise MakerError(
                "invalid_manifest",
                f"State {state} duration_ms must be exactly 1000 or 2000",
            )
        durations[state] = duration_ms
    if set(durations) != set(STATES):
        raise MakerError("invalid_manifest", "manifest.json must contain all seven fixed states")

    frame_counts = {
        state: native_fps * durations[state] // 1000
        for state in STATES
    }
    return {
        "native_fps": native_fps,
        "state_durations_ms": durations,
        "state_frame_counts": frame_counts,
    }


def validate_exact_state_counts(
    state_counts: dict[str, int], timing: dict[str, Any]
) -> None:
    expected = timing["state_frame_counts"]
    for state in STATES:
        actual = state_counts.get(state)
        if actual != expected[state]:
            raise MakerError(
                "invalid_assets",
                f"State {state} has {actual or 0} PNG frames; expected exactly {expected[state]} "
                f"for {timing['native_fps']} FPS and {timing['state_durations_ms'][state]} ms",
            )


def natural_frame_name_cmp(left: str, right: str) -> int:
    """Mirror PetCore's natural_frame_path_cmp for runtime-identical ordering."""
    left_bytes = left.encode("utf-8")
    right_bytes = right.encode("utf-8")
    left_index = 0
    right_index = 0

    while left_index < len(left_bytes) and right_index < len(right_bytes):
        left_byte = left_bytes[left_index]
        right_byte = right_bytes[right_index]
        if 48 <= left_byte <= 57 and 48 <= right_byte <= 57:
            left_end = left_index
            while left_end < len(left_bytes) and 48 <= left_bytes[left_end] <= 57:
                left_end += 1
            right_end = right_index
            while right_end < len(right_bytes) and 48 <= right_bytes[right_end] <= 57:
                right_end += 1

            left_significant = left_index
            while left_significant < left_end and left_bytes[left_significant] == 48:
                left_significant += 1
            if left_significant == left_end:
                left_significant = max(left_index, left_end - 1)
            right_significant = right_index
            while right_significant < right_end and right_bytes[right_significant] == 48:
                right_significant += 1
            if right_significant == right_end:
                right_significant = max(right_index, right_end - 1)

            left_key = (
                left_end - left_significant,
                left_bytes[left_significant:left_end],
                left_end - left_index,
            )
            right_key = (
                right_end - right_significant,
                right_bytes[right_significant:right_end],
                right_end - right_index,
            )
            if left_key != right_key:
                return -1 if left_key < right_key else 1
            left_index = left_end
            right_index = right_end
            continue

        left_lower = left_byte + 32 if 65 <= left_byte <= 90 else left_byte
        right_lower = right_byte + 32 if 65 <= right_byte <= 90 else right_byte
        left_key = (left_lower, left_byte)
        right_key = (right_lower, right_byte)
        if left_key != right_key:
            return -1 if left_key < right_key else 1
        left_index += 1
        right_index += 1

    if len(left_bytes) == len(right_bytes):
        return 0
    return -1 if len(left_bytes) < len(right_bytes) else 1


NATURAL_FRAME_NAME_KEY = functools.cmp_to_key(natural_frame_name_cmp)


def collect_state_files(source_dir: Path, manifest: dict[str, Any]) -> tuple[dict[str, dict[str, str]], dict[str, int]]:
    hashes: dict[str, dict[str, str]] = {}
    counts: dict[str, int] = {}
    for state, relative in manifest_state_paths(manifest).items():
        state_dir = source_dir / relative
        if state_dir.is_symlink() or not state_dir.is_dir():
            raise MakerError("invalid_assets", f"Missing safe frame directory for state {state}")
        state_hashes: dict[str, str] = {}
        for child in sorted(
            state_dir.iterdir(),
            key=lambda path: NATURAL_FRAME_NAME_KEY(path.name),
        ):
            if child.is_symlink() or not child.is_file():
                raise MakerError("invalid_assets", f"State {state} contains a non-file or symlink entry")
            if child.suffix.lower() == ".png":
                state_hashes[child.name] = decoded_png_digest(child)
        if not state_hashes:
            raise MakerError("invalid_assets", f"State {state} requires at least one PNG frame")
        hashes[state] = state_hashes
        counts[state] = len(state_hashes)
    return hashes, counts


def collect_selected_state_files(
    source_dir: Path,
    manifest: dict[str, Any],
    states: Iterable[str],
) -> tuple[dict[str, dict[str, str]], dict[str, int]]:
    hashes: dict[str, dict[str, str]] = {}
    counts: dict[str, int] = {}
    for state in states:
        state_hashes = {
            path.name: decoded_png_digest(path)
            for path in ordered_state_frame_paths(source_dir, manifest, state)
        }
        hashes[state] = state_hashes
        counts[state] = len(state_hashes)
    return hashes, counts


def structural_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    states = manifest.get("states")
    state_layout = []
    if isinstance(states, list):
        state_layout = [
            {
                "name": entry.get("name"),
                "frames_dir": entry.get("frames_dir"),
                "loop": entry.get("loop"),
            }
            for entry in states
            if isinstance(entry, dict)
        ]
    return {
        "schema_version": manifest.get("schema_version"),
        "id": manifest.get("id"),
        "quality": manifest.get("quality"),
        "render_size": manifest.get("render_size"),
        "states": state_layout,
        "created_at": manifest.get("created_at"),
    }


def make_context(
    operation: str,
    workspace: Path,
    source_dir: Path,
    cli: Path,
    base: dict[str, Any] | None,
) -> dict[str, Any]:
    return {
        "schema_version": WORKSPACE_SCHEMA,
        "operation": operation,
        "workspace": str(workspace),
        "source_dir": str(source_dir),
        "cli_path": str(cli),
        "base": base,
        "prepared_at": utc_now(),
    }


def prepare(args: argparse.Namespace) -> dict[str, Any]:
    verify_image_codecs()
    cli = locate_cli(args.cli)
    operation = args.operation
    input_path: Path | None = None
    validation: dict[str, Any] | None = None
    base_digest: str | None = None
    if operation == "modify":
        if not args.input:
            raise MakerError("invalid_request", "--input is required for modify")
        input_path = Path(args.input).expanduser().resolve()
        if not input_path.is_file():
            raise MakerError("invalid_input", f"Input petpack does not exist: {input_path}")
        validation = run_cli(cli, ["petpack", "validate", str(input_path)], "validation_failed")
        base_digest = sha256_file(input_path)
    elif args.input:
        raise MakerError("invalid_request", "--input is only valid for modify")

    workspace, created = ensure_empty_workspace(Path(args.workspace))
    source_dir = workspace / "petpack-source"
    internal_dir = workspace / ".agent-pet-maker"
    try:
        internal_dir.mkdir(mode=0o700)
        base: dict[str, Any] | None = None
        if operation == "create":
            source_dir.mkdir(mode=0o700)
            scaffold_source(source_dir, operation)
        else:
            assert input_path is not None and validation is not None and base_digest is not None
            staging = workspace / ".petpack-source-extracting"
            safe_extract_petpack(input_path, staging)
            manifest = read_json(staging / "manifest.json", "manifest.json")
            if manifest.get("schema_version") != PETPACK_SCHEMA:
                raise MakerError("invalid_manifest", "Only apc.petpack.v1 packages can be modified")
            state_files, state_counts = collect_state_files(staging, manifest)
            timing = manifest_timing_contract(manifest)
            validate_exact_state_counts(state_counts, timing)
            source_dir = staging.rename(source_dir)
            base = {
                "pet_id": manifest.get("id"),
                "petpack_sha256": base_digest,
                "input_name": input_path.name,
                "input_path": str(input_path),
                "manifest": structural_manifest(manifest),
                "timing": timing,
                "manifest_sha256": sha256_file(source_dir / "manifest.json"),
                "state_files": state_files,
                "state_counts": state_counts,
            }
            # Do not propagate a possibly sensitive or instruction-bearing session transcript.
            scaffold_source(source_dir, operation, base)

        context = make_context(operation, workspace, source_dir, cli, base)
        context_path = internal_dir / "context.json"
        write_json_atomic(context_path, context)
        return {
            "schema_version": HELPER_SCHEMA,
            "ok": True,
            "status": "prepared",
            "operation": operation,
            "workspace": str(workspace),
            "source_dir": str(source_dir),
            "context_path": str(context_path),
            "cli_path": str(cli),
            "base": public_base(base),
        }
    except Exception:
        if workspace.exists():
            if created:
                shutil.rmtree(workspace, ignore_errors=True)
            else:
                for child in list(workspace.iterdir()):
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child, ignore_errors=True)
                    else:
                        child.unlink(missing_ok=True)
        raise


def public_base(base: dict[str, Any] | None) -> dict[str, Any] | None:
    if not base:
        return None
    return {
        "pet_id": base.get("pet_id"),
        "petpack_sha256": base.get("petpack_sha256"),
        "input_name": base.get("input_name"),
    }


def normalize_private_field(key: str) -> str:
    return "".join(character.casefold() for character in key if character.isascii() and character.isalnum())


def private_field_words(key: str) -> list[str]:
    words: list[str] = []
    current: list[str] = []
    for index, character in enumerate(key):
        if not character.isascii() or not character.isalnum():
            if current:
                words.append("".join(current).casefold())
                current.clear()
            continue

        previous = key[index - 1] if index > 0 else None
        following = key[index + 1] if index + 1 < len(key) else None
        camel_boundary = bool(current) and character.isupper() and (
            (previous is not None and (previous.islower() or previous.isdigit()))
            or (
                previous is not None
                and previous.isupper()
                and following is not None
                and following.islower()
            )
        )
        if camel_boundary:
            words.append("".join(current).casefold())
            current.clear()
        current.append(character)
    if current:
        words.append("".join(current).casefold())
    return words


def private_field_category(key: str) -> str | None:
    normalized = normalize_private_field(key)
    category = PRIVATE_FIELD_CATEGORIES.get(normalized)
    if category:
        return category
    category = affixed_private_field_category(normalized)
    if category:
        return category
    words = private_field_words(key)
    for start in range(len(words)):
        candidate = ""
        for word in words[start:]:
            candidate += word
            if len(candidate) > 32:
                break
            category = PRIVATE_FIELD_CATEGORIES.get(candidate)
            if category:
                return category
            category = affixed_private_field_category(candidate)
            if category:
                return category
    return None


def affixed_private_field_category(normalized: str) -> str | None:
    # Only compound identifiers that remain unambiguous with a joined affix.
    # Generic names such as token, secret, command, and auth intentionally stay
    # exact/boundary-matched so tokenized/secretary/commanding prose is allowed.
    for private_name, category in (
        ("threadid", "thread_id"),
        ("turnid", "turn_id"),
        ("sessionid", "session_id"),
        ("requestid", "request_id"),
        ("conversationid", "conversation_id"),
        ("apikey", "credential"),
        ("accesstoken", "credential"),
        ("refreshtoken", "credential"),
        ("codexappserver", "codex_app_server"),
    ):
        if len(normalized) > len(private_name) and (
            normalized.startswith(private_name) or normalized.endswith(private_name)
        ):
            return category
    return None


def contains_forbidden_key(value: Any) -> str | None:
    if isinstance(value, dict):
        for key, child in value.items():
            category = private_field_category(str(key))
            if category:
                return category
            found = contains_forbidden_key(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = contains_forbidden_key(child)
            if found:
                return found
    return None


def is_locator_boundary(previous: str | None) -> bool:
    return previous is None or previous.isspace() or not (
        previous.isascii() and previous.isalnum() or previous in "_-"
    )


def contains_external_locator(text: str) -> bool:
    offset = 0
    while True:
        separator = text.find("://", offset)
        if separator < 0:
            return False
        start = separator
        while start > 0:
            character = text[start - 1]
            if not character.isascii() or not (character.isalnum() or character in "+-."):
                break
            start -= 1
        scheme = text[start:separator]
        if scheme and scheme[0].isascii() and scheme[0].isalpha() and all(
            character.isascii() and (character.isalnum() or character in "+-.")
            for character in scheme
        ):
            return True
        offset = separator + 3


def contains_absolute_local_path(text: str) -> bool:
    for index, character in enumerate(text):
        previous = text[index - 1] if index > 0 else None
        if not is_locator_boundary(previous):
            continue
        following = text[index + 1] if index + 1 < len(text) else None
        after_following = text[index + 2] if index + 2 < len(text) else None
        if character == "~" and following in {"/", "\\"}:
            return True
        # POSIX/macOS absolute paths may start with any Unicode filename
        # character. Exclude whitespace-delimited prose such as "use / as a
        # separator", but do not assume a particular home directory prefix.
        if character == "/" and following is not None and not following.isspace():
            return True
        if (
            character.isascii()
            and character.isalpha()
            and following == ":"
            and after_following in {"/", "\\"}
        ):
            return True
        if (
            character == "\\"
            and following == "\\"
            and after_following is not None
            and not after_following.isspace()
        ):
            return True
    return False


def contains_sensitive_string(value: Any) -> str | None:
    if isinstance(value, dict):
        for child in value.values():
            found = contains_sensitive_string(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = contains_sensitive_string(child)
            if found:
                return found
    elif isinstance(value, str):
        if contains_external_locator(value):
            return "external_locator"
        if contains_absolute_local_path(value):
            return "absolute_local_path"
    return None


def validate_session(source_dir: Path) -> None:
    path = source_dir / "source" / "skill_session.jsonl"
    if not path.is_file() or path.stat().st_size > MAX_SESSION_BYTES:
        raise MakerError("invalid_metadata", "skill_session.jsonl is missing or exceeds 256 KiB")
    event_count = 0
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise MakerError("invalid_metadata", f"Invalid skill session line {line_number}: {error}") from error
        if not isinstance(event, dict) or not isinstance(event.get("event"), str):
            raise MakerError("invalid_metadata", f"Skill session line {line_number} has no event")
        unknown = sorted(set(event) - EVENT_ALLOWED_KEYS)
        if unknown:
            raise MakerError(
                "invalid_metadata",
                f"Skill session line {line_number} contains fields outside apc.pet-source-event.v1: {unknown}",
            )
        if event.get("schema_version") != SOURCE_EVENT_SCHEMA:
            raise MakerError(
                "invalid_metadata",
                f"Skill session line {line_number} must declare {SOURCE_EVENT_SCHEMA}",
            )
        forbidden = contains_forbidden_key(event)
        if forbidden:
            raise MakerError("privacy_violation", f"Skill session contains forbidden field: {forbidden}")
        if contains_sensitive_string(event):
            raise MakerError("privacy_violation", "Skill session must not contain absolute paths or URLs")
        event_count += 1
    if event_count == 0:
        raise MakerError("invalid_metadata", "skill_session.jsonl contains no events")


def validate_reference_files(source_dir: Path, metadata: dict[str, Any]) -> None:
    references = metadata.get("reference_files", [])
    if not isinstance(references, list):
        raise MakerError("invalid_metadata", "source.reference_files must be an array")
    reference_root = (source_dir / "source" / "references").resolve()
    for value in references:
        if not isinstance(value, str):
            raise MakerError("invalid_metadata", "Reference file paths must be strings")
        pure = PurePosixPath(value)
        if pure.is_absolute() or ".." in pure.parts or not value.startswith("source/references/"):
            raise MakerError("privacy_violation", f"Unsafe reference path: {value}")
        candidate = (source_dir / Path(*pure.parts)).resolve()
        try:
            candidate.relative_to(reference_root)
        except ValueError as error:
            raise MakerError("privacy_violation", f"Reference path escapes source/references: {value}") from error
        if not candidate.is_file() or candidate.is_symlink():
            raise MakerError("invalid_metadata", f"Reference file does not exist safely: {value}")


def normalize_source_metadata(
    source_dir: Path,
    operation: str,
    context: dict[str, Any],
    changed_states: list[str],
    state_counts: dict[str, int],
    manifest: dict[str, Any],
) -> dict[str, Any]:
    path = source_dir / "source" / "source.json"
    metadata = read_json(path, "source/source.json")
    unknown = sorted(set(metadata) - SOURCE_ALLOWED_KEYS)
    if unknown:
        raise MakerError(
            "invalid_provenance",
            f"source.json contains fields outside apc.pet-source.v1: {unknown}",
        )
    required_values = {"schema_version": SOURCE_SCHEMA, "provenance": "skill-full-source"}
    for key, expected in required_values.items():
        if metadata.get(key) != expected:
            raise MakerError("invalid_provenance", f"source.{key} must be {expected!r}")
    if not isinstance(metadata.get("generator"), str) or not metadata["generator"].strip():
        raise MakerError("invalid_provenance", "source.generator must name the actual image generator")
    if metadata.get("skill_helper") not in (None, "agent-pet-maker"):
        raise MakerError("invalid_provenance", "source.skill_helper must be agent-pet-maker")
    metadata["skill_helper"] = "agent-pet-maker"
    if metadata.get("preview_only") is not False:
        raise MakerError("invalid_provenance", "source.preview_only must be false")
    if metadata.get("visual_source") not in {"image-generation", "user-reference-derived"}:
        raise MakerError("invalid_provenance", "source.visual_source must describe real visual generation")
    if not isinstance(metadata.get("runner"), str) or not metadata["runner"].strip():
        raise MakerError("invalid_provenance", "source.runner must name the actual host agent")
    forbidden = contains_forbidden_key(metadata)
    if forbidden:
        raise MakerError("privacy_violation", f"source.json contains forbidden field: {forbidden}")
    if contains_sensitive_string(metadata):
        raise MakerError("privacy_violation", "source.json must not contain absolute paths or URLs")
    validate_reference_files(source_dir, metadata)

    timing = manifest_timing_contract(manifest)
    validate_exact_state_counts(state_counts, timing)
    metadata["native_fps"] = timing["native_fps"]
    metadata["state_durations_ms"] = timing["state_durations_ms"]
    metadata["state_frame_counts"] = timing["state_frame_counts"]
    metadata["manifest_id"] = manifest.get("id")
    metadata["pet_name"] = manifest.get("name")
    metadata["style"] = manifest.get("style")
    metadata["quality"] = manifest.get("quality")
    if operation == "modify":
        base = context.get("base") or {}
        metadata["base_manifest_id"] = base.get("pet_id")
        metadata["changed_states"] = changed_states
    else:
        metadata.pop("base_manifest_id", None)
        metadata.pop("base_revision", None)
        metadata.pop("changed_states", None)
    write_json_atomic(path, metadata)
    return metadata


def ensure_outside(path: Path, directory: Path, label: str) -> None:
    try:
        path.resolve().relative_to(directory.resolve())
    except ValueError:
        return
    raise MakerError("unsafe_output", f"{label} must stay outside petpack-source")


def compare_modified_states(
    base_files: dict[str, dict[str, str]], current_files: dict[str, dict[str, str]]
) -> list[str]:
    return [state for state in STATES if base_files.get(state) != current_files.get(state)]


def ordered_state_digests(state_files: dict[str, dict[str, str]], state: str) -> list[str]:
    return [
        digest
        for _, digest in sorted(
            state_files.get(state, {}).items(),
            key=lambda item: NATURAL_FRAME_NAME_KEY(item[0]),
        )
    ]


def runtime_sample_indices(
    source_frame_count: int,
    target_frame_count: int,
    loops: bool,
) -> list[int]:
    """Mirror FrameSamplingPlan so authored revisions preserve runtime poses."""
    if source_frame_count <= 0 or target_frame_count <= 0:
        return []
    target_frame_count = min(source_frame_count, target_frame_count)
    if target_frame_count == source_frame_count:
        return list(range(source_frame_count))
    if loops:
        return [
            logical_index * source_frame_count // target_frame_count
            for logical_index in range(target_frame_count)
        ]
    if target_frame_count == 1:
        return [source_frame_count - 1]

    denominator = target_frame_count - 1
    indices: list[int] = []
    for logical_index in range(target_frame_count):
        numerator = logical_index * (source_frame_count - 1)
        quotient, remainder = divmod(numerator, denominator)
        indices.append(quotient + (1 if remainder * 2 >= denominator else 0))
    return indices


def standard_sample_indices(state: str, source_frame_count: int, duration_ms: int) -> list[int]:
    return runtime_sample_indices(
        source_frame_count,
        10 * duration_ms // 1000,
        state not in ONE_SHOT_STATES,
    )


def validate_generated_motion(
    state_files: dict[str, dict[str, str]], generated_states: Iterable[str]
) -> None:
    for state in generated_states:
        digests = ordered_state_digests(state_files, state)
        if len(digests) < 2:
            raise MakerError(
                "invalid_assets",
                f"Generated state {state} requires at least two PNG frames",
            )
        for index, (previous, current) in enumerate(zip(digests, digests[1:]), 1):
            if previous == current:
                raise MakerError(
                    "invalid_assets",
                    f"Generated state {state} has copied adjacent frames at indices {index - 1} and {index}",
                )


def validate_native_frame_semantics(
    state_files: dict[str, dict[str, str]],
    generated_states: Iterable[str],
    timing: dict[str, Any],
) -> None:
    if timing.get("native_fps") != 20:
        return
    for state in generated_states:
        digests = ordered_state_digests(state_files, state)
        indices = standard_sample_indices(
            state,
            len(digests),
            timing["state_durations_ms"][state],
        )
        canonical = [digests[index] for index in indices]
        for index, (previous, current) in enumerate(zip(canonical, canonical[1:]), 1):
            if previous == current:
                raise MakerError(
                    "invalid_assets",
                    f"Generated state {state} has duplicate canonical 10 FPS poses at indices "
                    f"{indices[index - 1]} and {indices[index]}",
                )
        if (
            state not in ONE_SHOT_STATES
            and len(canonical) >= 2
            and canonical[-1] == canonical[0]
        ):
            raise MakerError(
                "invalid_assets",
                f"Generated loop state {state} has duplicate canonical 10 FPS poses across "
                f"the wrap boundary at indices {indices[-1]} and {indices[0]}",
            )


def reject_naive_duration_retime(state: str, before: list[str], after: list[str]) -> None:
    if not before or not after:
        return
    candidates: list[list[str]] = []
    if len(after) > len(before):
        candidates.extend(
            [
                before * (len(after) // len(before)),
                [before[index % len(before)] for index in range(len(after))],
            ]
        )
    else:
        candidates.extend([before[: len(after)], before[-len(after) :]])
        candidates.append(
            [
                before[index]
                for index in runtime_sample_indices(
                    len(before),
                    len(after),
                    state not in ONE_SHOT_STATES,
                )
            ]
        )
    if any(after == candidate for candidate in candidates) or set(after).issubset(set(before)):
        raise MakerError(
            "invalid_assets",
            f"State {state} duration changed by truncating, repeating, or sampling the old motion; re-storyboard it",
        )


def validate_timing_revision(
    base_files: dict[str, dict[str, str]],
    current_files: dict[str, dict[str, str]],
    base_timing: dict[str, Any],
    current_timing: dict[str, Any],
    changed_states: list[str],
) -> None:
    base_fps = base_timing.get("native_fps")
    current_fps = current_timing.get("native_fps")
    native_fps_changed = base_fps != current_fps
    duration_changed = {
        state
        for state in STATES
        if base_timing.get("state_durations_ms", {}).get(state)
        != current_timing.get("state_durations_ms", {}).get(state)
    }
    changed = set(changed_states)

    if native_fps_changed and changed != set(STATES):
        raise MakerError(
            "timing_change_incomplete",
            "Changing native_fps requires regenerated frame sequences for all seven states",
        )
    missing_duration_changes = duration_changed - changed
    if missing_duration_changes:
        raise MakerError(
            "timing_change_incomplete",
            "Changing duration_ms requires regenerated frames for states: "
            + ", ".join(sorted(missing_duration_changes, key=STATES.index)),
        )

    for state in STATES:
        before = ordered_state_digests(base_files, state)
        after = ordered_state_digests(current_files, state)
        if state in duration_changed:
            reject_naive_duration_retime(state, before, after)
            continue
        if not native_fps_changed:
            continue
        if base_fps == 10 and current_fps == 20:
            preserved_indices = standard_sample_indices(
                state,
                len(after),
                current_timing["state_durations_ms"][state],
            )
            if (
                len(after) != len(before) * 2
                or [after[index] for index in preserved_indices] != before
            ):
                raise MakerError(
                    "invalid_frame_interpolation",
                    f"State {state} 10 to 20 FPS conversion must preserve source frames at the runtime 10 FPS sample indices",
                )
            preserved = set(preserved_indices)
            source_poses = set(before)
            for index in range(len(after)):
                if index in preserved:
                    continue
                if after[index] in source_poses or after[index] == after[index - 1] or (
                    index + 1 < len(after) and after[index] == after[index + 1]
                ):
                    raise MakerError(
                        "invalid_frame_interpolation",
                        f"State {state} has a copied source pose instead of a real intermediate at index {index}",
                    )
        elif base_fps == 20 and current_fps == 10:
            source_indices = standard_sample_indices(
                state,
                len(before),
                base_timing["state_durations_ms"][state],
            )
            if after != [before[index] for index in source_indices]:
                raise MakerError(
                    "invalid_frame_downsample",
                    f"State {state} 20 to 10 FPS conversion must match the runtime 10 FPS sample indices",
                )
        else:
            raise MakerError(
                "invalid_manifest",
                f"Unsupported native FPS transition {base_fps!r} to {current_fps!r}",
            )


def validate_portable_visual_assets(source_dir: Path, manifest: dict[str, Any]) -> None:
    """Verify the visual promises that distinguish a portable skill result.

    PetCore remains the final trust boundary, but this helper can be paired
    with an older v1 CLI. Inspect alpha and animation locally so such a CLI
    cannot turn an opaque rectangle or static preview into a completed
    `skill-full-source` result.
    """

    try:
        from PIL import Image, UnidentifiedImageError
    except (ImportError, OSError) as error:
        raise MakerError(
            "capability_missing",
            "Python Pillow is required to inspect generated pet assets",
            bounded(str(error)),
        ) from error

    render_size = manifest.get("render_size")
    if not isinstance(render_size, dict):
        raise MakerError("invalid_manifest", "manifest.render_size must be an object")
    expected_size = (render_size.get("width"), render_size.get("height"))
    if not all(isinstance(value, int) and value > 0 for value in expected_size):
        raise MakerError("invalid_manifest", "manifest.render_size is invalid")

    try:
        for state, relative in manifest_state_paths(manifest).items():
            for frame_path in sorted(
                (source_dir / relative).glob("*.png"),
                key=lambda path: NATURAL_FRAME_NAME_KEY(path.name),
            ):
                with Image.open(frame_path) as decoded:
                    if decoded.format != "PNG" or decoded.size != expected_size:
                        raise MakerError(
                            "invalid_assets",
                            f"State {state} frame {frame_path.name} must be a {expected_size[0]}x{expected_size[1]} PNG",
                        )
                    total_pixels, visible_pixels, transparent_pixels = visual_pixel_counts(decoded)
                    required_pixels = minimum_visual_pixel_count(total_pixels)
                    if transparent_pixels < required_pixels:
                        raise MakerError(
                            "invalid_assets",
                            f"State {state} frame {frame_path.name} lacks transparent surroundings; "
                            f"at least {required_pixels} pixels with alpha <= {TRANSPARENT_ALPHA_THRESHOLD} are required",
                        )
                    if visible_pixels < required_pixels:
                        raise MakerError(
                            "invalid_assets",
                            f"State {state} frame {frame_path.name} lacks visible pet content; "
                            f"at least {required_pixels} pixels with alpha >= {VISIBLE_ALPHA_THRESHOLD} are required",
                        )

        cover_path = source_dir / "assets" / "preview" / "cover.png"
        with Image.open(cover_path) as cover:
            if cover.format != "PNG":
                raise MakerError("invalid_assets", "assets/preview/cover.png is not a PNG")
            total_pixels, visible_pixels, _ = visual_pixel_counts(cover)
            required_pixels = minimum_visual_pixel_count(total_pixels)
            if visible_pixels < required_pixels:
                raise MakerError(
                    "invalid_assets",
                    "assets/preview/cover.png lacks visible pet content; "
                    f"at least {required_pixels} pixels with alpha >= {VISIBLE_ALPHA_THRESHOLD} are required",
                )

        preview_path = source_dir / "assets" / "preview" / "animated_preview.webp"
        with Image.open(preview_path) as preview:
            if preview.format != "WEBP":
                raise MakerError(
                    "invalid_assets",
                    "assets/preview/animated_preview.webp is not a WebP image",
                )
            frame_count = getattr(preview, "n_frames", 1)
            if frame_count < 2:
                raise MakerError(
                    "invalid_assets",
                    "assets/preview/animated_preview.webp must contain at least two frames",
                )
            if frame_count > MAX_ANIMATED_PREVIEW_FRAMES:
                raise MakerError(
                    "invalid_assets",
                    f"Animated preview exceeds the {MAX_ANIMATED_PREVIEW_FRAMES}-frame limit",
                )

            first_digest: bytes | None = None
            has_distinct_frame = False
            decoded_bytes = 0
            for index in range(frame_count):
                preview.seek(index)
                rgba = preview.convert("RGBA")
                decoded_bytes += rgba.width * rgba.height * 4
                if decoded_bytes > MAX_DECODED_ANIMATED_PREVIEW_BYTES:
                    raise MakerError(
                        "invalid_assets",
                        "Animated preview exceeds the 128 MiB decoded budget",
                    )
                total_pixels, visible_pixels, _ = visual_pixel_counts(rgba)
                required_pixels = minimum_visual_pixel_count(total_pixels)
                if visible_pixels < required_pixels:
                    raise MakerError(
                        "invalid_assets",
                        f"Animated preview frame {index} lacks visible pet content; "
                        f"at least {required_pixels} pixels with alpha >= {VISIBLE_ALPHA_THRESHOLD} are required",
                    )
                digest = hashlib.sha256(canonical_premultiplied_rgba(rgba)).digest()
                if first_digest is None:
                    first_digest = digest
                elif digest != first_digest:
                    has_distinct_frame = True
            if not has_distinct_frame:
                raise MakerError(
                    "invalid_assets",
                    "assets/preview/animated_preview.webp contains no pixel-distinct frames",
                )
    except MakerError:
        raise
    except (OSError, ValueError, UnidentifiedImageError) as error:
        raise MakerError(
            "invalid_assets",
            "Generated pet visual assets could not be fully decoded",
            bounded(str(error)),
        ) from error


def ordered_state_frame_paths(
    source_dir: Path, manifest: dict[str, Any], state: str
) -> list[Path]:
    relative = manifest_state_paths(manifest)[state]
    state_dir = source_dir / relative
    if state_dir.is_symlink() or not state_dir.is_dir():
        raise MakerError("invalid_assets", f"Missing safe frame directory for state {state}")
    paths = sorted(
        (
            child
            for child in state_dir.iterdir()
            if child.is_file() and not child.is_symlink() and child.suffix.lower() == ".png"
        ),
        key=lambda path: NATURAL_FRAME_NAME_KEY(path.name),
    )
    if not paths:
        raise MakerError("invalid_assets", f"State {state} requires at least one PNG frame")
    return paths


def state_motion_digest(
    source_dir: Path, manifest: dict[str, Any], state: str
) -> str:
    digest = hashlib.sha256()
    digest.update(f"{MOTION_QA_SCHEMA}\0{state}\0".encode())
    for path in ordered_state_frame_paths(source_dir, manifest, state):
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(decoded_png_digest(path).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def motion_frame_set_digest(state_digests: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for state in STATES:
        if state in state_digests:
            digest.update(state.encode("ascii"))
            digest.update(b"\0")
            digest.update(state_digests[state].encode("ascii"))
            digest.update(b"\0")
    return digest.hexdigest()


def normalized_motion_frame(path: Path) -> Any:
    try:
        from PIL import Image, UnidentifiedImageError
    except (ImportError, OSError) as error:
        raise MakerError(
            "capability_missing",
            "Python Pillow is required to inspect generated pet motion",
            bounded(str(error)),
        ) from error
    try:
        with Image.open(path) as decoded:
            if decoded.format != "PNG":
                raise MakerError("invalid_assets", f"Frame {path.name} is not a PNG")
            rgba = decoded.convert("RGBA")
            if rgba.size != MOTION_PREVIEW_SIZE:
                resampling = getattr(Image, "Resampling", Image).LANCZOS
                rgba = rgba.resize(MOTION_PREVIEW_SIZE, resampling)
            return Image.frombytes(
                "RGBA",
                MOTION_PREVIEW_SIZE,
                canonical_premultiplied_rgba(rgba),
            )
    except MakerError:
        raise
    except (OSError, ValueError, UnidentifiedImageError) as error:
        raise MakerError(
            "invalid_assets",
            f"Frame {path.name} could not be decoded for motion QA",
            bounded(str(error)),
        ) from error


def motion_frame_signature(frame: Any) -> dict[str, float]:
    alpha = frame.getchannel("A")
    flattened = (
        alpha.get_flattened_data()
        if hasattr(alpha, "get_flattened_data")
        else alpha.getdata()
    )
    width, height = frame.size
    weight_total = 0
    weighted_x = 0
    weighted_y = 0
    for index, alpha_value in enumerate(flattened):
        if alpha_value < VISIBLE_ALPHA_THRESHOLD:
            continue
        x = index % width
        y = index // width
        weight_total += alpha_value
        weighted_x += x * alpha_value
        weighted_y += y * alpha_value
    mask = alpha.point(lambda value: 255 if value >= VISIBLE_ALPHA_THRESHOLD else 0)
    box = mask.getbbox() or (0, 0, 0, 0)
    left, top, right, bottom = box
    if weight_total:
        centroid_x = weighted_x / weight_total / width
        centroid_y = weighted_y / weight_total / height
    else:
        centroid_x = centroid_y = 0.0
    return {
        "visible_area": weight_total / (255 * width * height),
        "centroid_x": centroid_x,
        "centroid_y": centroid_y,
        "bbox_width": (right - left) / width,
        "bbox_height": (bottom - top) / height,
        "bbox_bottom": bottom / height,
        "bbox_left_margin": left / width,
        "bbox_top_margin": top / height,
        "bbox_right_margin": (width - right) / width,
        "bbox_bottom_margin": (height - bottom) / height,
    }


def normalized_frame_delta(left: Any, right: Any) -> float:
    from PIL import ImageChops, ImageStat

    difference = ImageChops.difference(left, right)
    return sum(ImageStat.Stat(difference).mean) / (4 * 255)


def linear_blend_fit(left: Any, middle: Any, right: Any) -> dict[str, float] | None:
    left_bytes = left.tobytes()
    middle_bytes = middle.tobytes()
    right_bytes = right.tobytes()
    if not (len(left_bytes) == len(middle_bytes) == len(right_bytes)):
        return None

    pixel_count = len(left_bytes) // 4
    stride = max(1, pixel_count // 50_000)
    denominator = 0.0
    numerator = 0.0
    channel_count = 0
    for pixel_index in range(0, pixel_count, stride):
        offset = pixel_index * 4
        for channel in range(4):
            start = float(left_bytes[offset + channel])
            delta = float(right_bytes[offset + channel]) - start
            observed = float(middle_bytes[offset + channel]) - start
            denominator += delta * delta
            numerator += observed * delta
            channel_count += 1
    if denominator <= 0 or channel_count == 0:
        return None

    motion_rms = math.sqrt(denominator / channel_count)
    blend_weight = numerator / denominator
    if motion_rms < 2.0 or not 0.05 <= blend_weight <= 0.95:
        return None

    residual = 0.0
    for pixel_index in range(0, pixel_count, stride):
        offset = pixel_index * 4
        for channel in range(4):
            start = float(left_bytes[offset + channel])
            delta = float(right_bytes[offset + channel]) - start
            observed = float(middle_bytes[offset + channel]) - start
            error = observed - blend_weight * delta
            residual += error * error
    relative_residual = math.sqrt(residual / denominator)
    if relative_residual > 0.06:
        return None
    return {
        "weight": round(blend_weight, 4),
        "relative_residual": round(relative_residual, 6),
        "motion_rms": round(motion_rms / 255, 6),
    }


def maximum_adjacent_step(values: list[float], relative: bool = False) -> float:
    steps: list[float] = []
    for previous, current in zip(values, values[1:]):
        difference = abs(current - previous)
        if relative:
            difference /= max(abs(previous), 0.000_001)
        steps.append(difference)
    return max(steps, default=0.0)


def motion_metrics(frames: list[Any], loops: bool) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    signatures = [motion_frame_signature(frame) for frame in frames]
    adjacent_deltas = [
        normalized_frame_delta(previous, current)
        for previous, current in zip(frames, frames[1:])
    ]
    median_delta = statistics.median(adjacent_deltas) if adjacent_deltas else 0.0
    max_delta = max(adjacent_deltas, default=0.0)
    max_delta_index = adjacent_deltas.index(max_delta) + 1 if adjacent_deltas else 0
    seam_delta = normalized_frame_delta(frames[-1], frames[0]) if loops and len(frames) > 1 else 0.0
    centroid_steps = [
        math.hypot(
            current["centroid_x"] - previous["centroid_x"],
            current["centroid_y"] - previous["centroid_y"],
        )
        for previous, current in zip(signatures, signatures[1:])
    ]
    area_step = maximum_adjacent_step(
        [signature["visible_area"] for signature in signatures],
        relative=True,
    )
    bbox_width_step = maximum_adjacent_step(
        [signature["bbox_width"] for signature in signatures]
    )
    bbox_height_step = maximum_adjacent_step(
        [signature["bbox_height"] for signature in signatures]
    )
    baseline_step = maximum_adjacent_step(
        [signature["bbox_bottom"] for signature in signatures]
    )
    edge_contact_frames = []
    for index, signature in enumerate(signatures):
        sides = [
            side
            for side, margin_key in (
                ("left", "bbox_left_margin"),
                ("top", "bbox_top_margin"),
                ("right", "bbox_right_margin"),
                ("bottom", "bbox_bottom_margin"),
            )
            if signature[margin_key] <= 0
        ]
        if sides:
            edge_contact_frames.append(
                {
                    "frame": index,
                    "sides": sides,
                }
            )
    minimum_edge_margin = min(
        (
            signature[margin_key]
            for signature in signatures
            for margin_key in (
                "bbox_left_margin",
                "bbox_top_margin",
                "bbox_right_margin",
                "bbox_bottom_margin",
            )
        ),
        default=0.0,
    )
    blend_candidates = [
        {"frame": index, **fit}
        for index in range(1, len(frames) - 1)
        if (
            fit := linear_blend_fit(
                frames[index - 1],
                frames[index],
                frames[index + 1],
            )
        )
        is not None
    ]
    metrics = {
        "adjacent_delta": {
            "median": round(median_delta, 6),
            "maximum": round(max_delta, 6),
            "maximum_arrival_frame": max_delta_index,
            "maximum_to_median_ratio": round(
                max_delta / max(median_delta, 0.000_001), 3
            ),
        },
        "maximum_visible_area_step_ratio": round(area_step, 4),
        "maximum_bbox_width_step": round(bbox_width_step, 4),
        "maximum_bbox_height_step": round(bbox_height_step, 4),
        "maximum_centroid_step": round(max(centroid_steps, default=0.0), 4),
        "maximum_baseline_step": round(baseline_step, 4),
        "minimum_edge_margin": round(minimum_edge_margin, 6),
        "edge_contact_frame_count": len(edge_contact_frames),
        "edge_contact_frames": edge_contact_frames[:8],
        "linear_blend_candidate_count": len(blend_candidates),
        "linear_blend_candidates": blend_candidates[:8],
        "loop_seam_delta": round(seam_delta, 6) if loops else None,
        "preview_width": MOTION_PREVIEW_SIZE[0],
        "preview_height": MOTION_PREVIEW_SIZE[1],
    }
    warnings: list[dict[str, Any]] = []

    def warn(code: str, message: str, evidence: dict[str, Any]) -> None:
        warnings.append(
            {
                "code": code,
                "severity": "review",
                "message": message,
                "evidence": evidence,
            }
        )

    spike_ratio = max_delta / max(median_delta, 0.000_001)
    if max_delta >= 0.004 and spike_ratio >= 3.5:
        warn(
            "abrupt_motion_spike",
            "One frame transition is much larger than the typical transition; inspect for a pose cut or prop teleport.",
            {
                "arrival_frame": max_delta_index,
                "delta": round(max_delta, 6),
                "ratio_to_median": round(spike_ratio, 3),
            },
        )
    if area_step >= 0.1 or bbox_width_step >= 0.08 or bbox_height_step >= 0.08:
        warn(
            "shape_or_scale_pop",
            "The occupied silhouette changes abruptly; inspect locked body regions, character scale, and prop continuity.",
            {
                "visible_area_step_ratio": round(area_step, 4),
                "bbox_width_step": round(bbox_width_step, 4),
                "bbox_height_step": round(bbox_height_step, 4),
            },
        )
    if max(centroid_steps, default=0.0) >= 0.035 or baseline_step >= 0.035:
        warn(
            "anchor_jump",
            "The pet anchor moves abruptly; inspect feet/baseline and non-moving body regions for drift.",
            {
                "centroid_step": round(max(centroid_steps, default=0.0), 4),
                "baseline_step": round(baseline_step, 4),
            },
        )
    if loops and seam_delta >= 0.004 and seam_delta >= max(median_delta * 2, 0.004):
        warn(
            "loop_seam_pop",
            "The last-to-first loop seam is harsher than the typical motion; inspect the return beat.",
            {
                "seam_delta": round(seam_delta, 6),
                "ratio_to_median": round(
                    seam_delta / max(median_delta, 0.000_001), 3
                ),
            },
        )
    if max_delta < 0.0008:
        warn(
            "near_inert_motion",
            "The sequence has very little visible change at in-app size; confirm that the action reads without relying on micro-jitter.",
            {"maximum_delta": round(max_delta, 6)},
        )
    if len(blend_candidates) >= 2:
        warn(
            "synthetic_frame_blending",
            "Multiple frames are near-linear blends of their neighbors; reject crossfade, morph, optical-flow, or interpolated filler and render genuine poses.",
            {"candidates": blend_candidates[:8]},
        )
    return metrics, warnings


def reject_severe_motion_registration(state: str, metrics: dict[str, Any]) -> None:
    """Fail obvious crop, attachment-loss, anchor, and loop-continuity defects."""

    edge_contact_count = int(metrics.get("edge_contact_frame_count", 0))
    if edge_contact_count:
        evidence = metrics.get("edge_contact_frames", [])
        raise MakerError(
            "invalid_motion_registration",
            f"State {state} has visible pixels touching the 192 × 208 runtime frame edge "
            f"in {edge_contact_count} frame(s) ({evidence}); the action is clipped. "
            "Regenerate or recompose the coherent row with fixed cell bounds and at least "
            "one transparent pixel of padding on every side before using motion-lock or "
            "generating another state",
        )

    width_step = float(metrics["maximum_bbox_width_step"])
    height_step = float(metrics["maximum_bbox_height_step"])
    visible_area_step = float(metrics["maximum_visible_area_step_ratio"])
    centroid_step = float(metrics["maximum_centroid_step"])
    baseline_step = float(metrics["maximum_baseline_step"])
    seam_delta = metrics.get("loop_seam_delta")
    median_delta = float(metrics["adjacent_delta"]["median"])
    severe_scale_pop = min(width_step, height_step) >= 0.12
    severe_anchor_jump = centroid_step >= 0.09 and baseline_step >= 0.055
    abrupt_attachment_loss = (
        state not in ONE_SHOT_STATES
        and max(width_step, height_step) >= 0.10
        and visible_area_step >= 0.04
    )
    broken_loop_closure = (
        isinstance(seam_delta, (int, float))
        and seam_delta >= 0.06
        and seam_delta >= median_delta * 1.5
    )
    if (
        severe_scale_pop
        or severe_anchor_jump
        or abrupt_attachment_loss
        or broken_loop_closure
    ):
        raise MakerError(
            "invalid_motion_registration",
            f"State {state} has an unstable crop, anchor, attachment silhouette, or loop closure "
            f"(bbox steps {width_step:.4f}/{height_step:.4f}, "
            f"visible area {visible_area_step:.4f}, centroid {centroid_step:.4f}, "
            f"baseline {baseline_step:.4f}, seam {float(seam_delta or 0):.4f}); "
            "repair the coherent row with fixed cell bounds and locked "
            "non-moving regions; regenerate when a moving limb, tail, or prop "
            "shrinks, disappears, detaches, or fails to return before generating another state",
        )


def keyframe_indices(frame_count: int, count: int = MOTION_KEYFRAME_COUNT) -> list[int]:
    if frame_count <= 0:
        return []
    count = min(frame_count, max(1, count))
    if count == 1:
        return [0]
    return [
        round(index * (frame_count - 1) / (count - 1))
        for index in range(count)
    ]


def checkerboard(size: tuple[int, int]) -> Any:
    from PIL import Image, ImageDraw

    background = Image.new("RGBA", size, (235, 235, 235, 255))
    draw = ImageDraw.Draw(background)
    tile = 12
    for y in range(0, size[1], tile):
        for x in range(0, size[0], tile):
            if (x // tile + y // tile) % 2:
                draw.rectangle(
                    (x, y, min(x + tile - 1, size[0] - 1), min(y + tile - 1, size[1] - 1)),
                    fill=(210, 210, 210, 255),
                )
    return background


def save_motion_preview(path: Path, frames: list[Any], frame_duration_ms: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.stem}.", suffix=".webp", dir=path.parent
    )
    os.close(descriptor)
    temporary_path = Path(temporary)
    try:
        frames[0].save(
            temporary_path,
            format="WEBP",
            save_all=True,
            append_images=frames[1:],
            duration=[frame_duration_ms] * len(frames),
            loop=0,
            lossless=True,
            exact=True,
            method=6,
        )
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def save_motion_keyframes(
    path: Path, rows: list[tuple[str, list[Any], list[int]]]
) -> None:
    from PIL import Image, ImageDraw

    cell_width, cell_height = MOTION_PREVIEW_SIZE
    header_height = 28
    sheet = Image.new(
        "RGB",
        (cell_width * MOTION_KEYFRAME_COUNT, (cell_height + header_height) * len(rows)),
        (32, 32, 36),
    )
    draw = ImageDraw.Draw(sheet)
    for row, (state, frames, indices) in enumerate(rows):
        y = row * (cell_height + header_height)
        draw.text((8, y + 7), f"{state} · frames {', '.join(map(str, indices))}", fill="white")
        for column, (frame, frame_index) in enumerate(zip(frames, indices)):
            cell = checkerboard(MOTION_PREVIEW_SIZE)
            cell.alpha_composite(frame)
            x = column * cell_width
            sheet.paste(cell.convert("RGB"), (x, y + header_height))
            draw.text(
                (x + 6, y + header_height + 6),
                str(frame_index),
                fill=(20, 20, 20),
                stroke_width=2,
                stroke_fill=(255, 255, 255),
            )
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.stem}.", suffix=".png", dir=path.parent
    )
    os.close(descriptor)
    temporary_path = Path(temporary)
    try:
        sheet.save(temporary_path, format="PNG")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def resolve_motion_workspace(
    workspace_value: str | None,
    source_value: str | None,
    output_value: str | None,
) -> tuple[Path | None, Path, Path, dict[str, Any] | None]:
    if bool(workspace_value) == bool(source_value):
        raise MakerError(
            "invalid_request",
            "Use exactly one of --workspace or --source for motion QA",
        )
    if workspace_value:
        workspace = Path(workspace_value).expanduser().resolve()
        context = read_json(
            workspace / ".agent-pet-maker" / "context.json",
            "workspace context",
        )
        if context.get("schema_version") != WORKSPACE_SCHEMA:
            raise MakerError("invalid_workspace", "Workspace context is incompatible")
        source_dir = Path(context.get("source_dir", "")).resolve()
        if source_dir != (workspace / "petpack-source").resolve() or not source_dir.is_dir():
            raise MakerError("invalid_workspace", "Workspace petpack-source is missing or redirected")
        output_dir = (
            Path(output_value).expanduser().resolve()
            if output_value
            else workspace / ".agent-pet-maker" / "motion-qa"
        )
        return workspace, source_dir, output_dir, context

    source_dir = Path(source_value or "").expanduser().resolve()
    if source_dir.is_symlink() or not source_dir.is_dir():
        raise MakerError("invalid_input", "Motion QA source must be a safe petpack-source directory")
    if not output_value:
        raise MakerError(
            "invalid_request",
            "Standalone motion QA requires --output-dir outside petpack-source",
        )
    output_dir = Path(output_value).expanduser().resolve()
    return None, source_dir, output_dir, None


def motion_qa(args: argparse.Namespace) -> dict[str, Any]:
    workspace, source_dir, output_dir, context = resolve_motion_workspace(
        args.workspace,
        args.source,
        args.output_dir,
    )
    ensure_outside(output_dir, source_dir, "Motion QA output")
    if output_dir.exists() and (output_dir.is_symlink() or not output_dir.is_dir()):
        raise MakerError("unsafe_output", "Motion QA output must be a safe directory")
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)

    manifest = read_json(source_dir / "manifest.json", "manifest.json")
    if manifest.get("schema_version") != PETPACK_SCHEMA:
        raise MakerError("invalid_manifest", "manifest.schema_version must be apc.petpack.v1")
    timing = manifest_timing_contract(manifest)
    selected = sorted(set(args.state or []), key=STATES.index)
    if selected:
        current_files, state_counts = collect_selected_state_files(
            source_dir, manifest, selected
        )
        for state in selected:
            actual = state_counts.get(state)
            expected = timing["state_frame_counts"][state]
            if actual != expected:
                raise MakerError(
                    "invalid_assets",
                    f"State {state} has {actual or 0} PNG frames; expected exactly {expected} "
                    f"for {timing['native_fps']} FPS and "
                    f"{timing['state_durations_ms'][state]} ms",
                )
    else:
        current_files, state_counts = collect_state_files(source_dir, manifest)
        validate_exact_state_counts(state_counts, timing)

    if not selected and context and context.get("operation") == "modify":
        base = context.get("base")
        if not isinstance(base, dict):
            raise MakerError("invalid_workspace", "Modify workspace has no base package context")
        selected = compare_modified_states(base.get("state_files", {}), current_files)
        if not selected:
            raise MakerError(
                "no_visual_changes",
                "Modify produced no changed states to inspect",
            )
    if not selected:
        selected = list(STATES)

    state_entries = {
        entry.get("name"): entry
        for entry in manifest.get("states", [])
        if isinstance(entry, dict)
    }
    report_states: dict[str, Any] = {}
    keyframe_rows: list[tuple[str, list[Any], list[int]]] = []
    state_digests: dict[str, str] = {}
    all_warnings: list[dict[str, Any]] = []
    previews_dir = output_dir / "previews"

    for state in selected:
        paths = ordered_state_frame_paths(source_dir, manifest, state)
        frames = [normalized_motion_frame(path) for path in paths]
        loops = bool(state_entries[state].get("loop"))
        metrics, warnings = motion_metrics(frames, loops)
        reject_severe_motion_registration(state, metrics)
        if metrics["linear_blend_candidate_count"] >= 2:
            candidate_frames = ", ".join(
                str(candidate["frame"])
                for candidate in metrics["linear_blend_candidates"]
            )
            raise MakerError(
                "invalid_frame_interpolation",
                f"State {state} contains synthetic blended filler near frames "
                f"{candidate_frames}; render the exact authored frame count as genuine poses "
                "instead of crossfade, morph, optical flow, or interpolation",
            )
        for warning in warnings:
            all_warnings.append({"state": state, **warning})
        digest = state_motion_digest(source_dir, manifest, state)
        state_digests[state] = digest

        standard_indices = standard_sample_indices(
            state,
            len(frames),
            timing["state_durations_ms"][state],
        )
        standard_path = previews_dir / f"{state}-standard.webp"
        save_motion_preview(
            standard_path,
            [frames[index] for index in standard_indices],
            100,
        )
        profiles: dict[str, str] = {
            "standard_10_fps": str(standard_path.relative_to(output_dir))
        }
        if timing["native_fps"] == 20:
            smooth_path = previews_dir / f"{state}-smooth.webp"
            save_motion_preview(smooth_path, frames, 50)
            profiles["smooth_20_fps"] = str(smooth_path.relative_to(output_dir))

        indices = keyframe_indices(len(frames))
        keyframe_rows.append(
            (state, [frames[index] for index in indices], indices)
        )
        report_states[state] = {
            "frame_count": len(frames),
            "duration_ms": timing["state_durations_ms"][state],
            "loops": loops,
            "motion_digest": digest,
            "keyframe_indices": indices,
            "previews": profiles,
            "metrics": metrics,
            "warnings": warnings,
        }

    keyframes_path = output_dir / "keyframes.png"
    save_motion_keyframes(keyframes_path, keyframe_rows)
    report = {
        "schema_version": MOTION_QA_SCHEMA,
        "generated_at": utc_now(),
        "manifest_id": manifest.get("id"),
        "native_fps": timing["native_fps"],
        "preview_size": {
            "width": MOTION_PREVIEW_SIZE[0],
            "height": MOTION_PREVIEW_SIZE[1],
        },
        "audited_states": selected,
        "frame_set_digest": motion_frame_set_digest(state_digests),
        "keyframes": str(keyframes_path.relative_to(output_dir)),
        "states": report_states,
        "warnings": all_warnings,
        "warning_count": len(all_warnings),
        "measurement_note": (
            "Heuristics identify review targets only. A visual reviewer must still verify "
            "identity lock, non-moving-region stability, action readability, prop continuity, "
            "timing, and loop/settle quality in every generated preview."
        ),
    }
    report_path = output_dir / "report.json"
    write_json_atomic(report_path, report)
    return {
        "schema_version": HELPER_SCHEMA,
        "ok": True,
        "status": "completed",
        "capability": "motion-qa",
        "workspace": str(workspace) if workspace else None,
        "report_path": str(report_path),
        "keyframes_path": str(keyframes_path),
        "audited_states": selected,
        "warning_count": len(all_warnings),
    }


def motion_lock(args: argparse.Namespace) -> dict[str, Any]:
    try:
        from PIL import Image, ImageFilter, UnidentifiedImageError
    except (ImportError, OSError) as error:
        raise MakerError(
            "capability_missing",
            "Python Pillow is required to lock generated motion regions",
            bounded(str(error)),
        ) from error

    source_dir = Path(args.source).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    mask_path = Path(args.moving_mask).expanduser().resolve()
    report_path = (
        Path(args.report).expanduser().resolve()
        if args.report
        else output_dir.with_name(f"{output_dir.name}.motion-lock.json")
    )
    if source_dir.is_symlink() or not source_dir.is_dir():
        raise MakerError(
            "invalid_input",
            "Motion lock source must be a safe petpack-source directory",
        )
    ensure_outside(output_dir, source_dir, "Motion lock output")
    ensure_outside(report_path, source_dir, "Motion lock report")
    if output_dir.is_symlink() or report_path.is_symlink() or mask_path.is_symlink():
        raise MakerError(
            "unsafe_output",
            "Motion lock paths must not be symbolic links",
        )
    if output_dir.exists():
        if not output_dir.is_dir() or any(output_dir.iterdir()):
            raise MakerError(
                "output_exists",
                "Motion lock output directory must be absent or empty",
            )
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not mask_path.is_file():
        raise MakerError(
            "invalid_input",
            "Motion lock requires a safe moving-region mask PNG",
        )

    manifest = read_json(source_dir / "manifest.json", "manifest.json")
    if manifest.get("schema_version") != PETPACK_SCHEMA:
        raise MakerError(
            "invalid_manifest",
            "manifest.schema_version must be apc.petpack.v1",
        )
    timing = manifest_timing_contract(manifest)
    frame_paths = ordered_state_frame_paths(source_dir, manifest, args.state)
    expected_count = timing["state_frame_counts"][args.state]
    if len(frame_paths) != expected_count:
        raise MakerError(
            "invalid_assets",
            f"State {args.state} has {len(frame_paths)} PNG frames; "
            f"expected exactly {expected_count}",
        )
    reference_index = args.reference_frame
    if reference_index < 0 or reference_index >= len(frame_paths):
        raise MakerError(
            "invalid_request",
            f"--reference-frame must be between 0 and {len(frame_paths) - 1}",
        )
    feather_px = args.feather_px
    if feather_px < 0 or feather_px > 24:
        raise MakerError(
            "invalid_request",
            "--feather-px must be between 0 and 24",
        )

    render_size = manifest.get("render_size")
    width = render_size.get("width") if isinstance(render_size, dict) else None
    height = render_size.get("height") if isinstance(render_size, dict) else None
    if type(width) is not int or type(height) is not int or width <= 0 or height <= 0:
        raise MakerError(
            "invalid_manifest",
            "manifest.render_size must contain positive integer width and height",
        )
    expected_size = (width, height)

    try:
        with Image.open(mask_path) as decoded_mask:
            if decoded_mask.format != "PNG":
                raise MakerError(
                    "invalid_input",
                    "Motion lock moving-region mask must be a PNG",
                )
            moving_mask = decoded_mask.convert("L")
        if moving_mask.size != expected_size:
            raise MakerError(
                "invalid_input",
                f"Motion lock mask is {moving_mask.size[0]}x{moving_mask.size[1]}; "
                f"expected {width}x{height}",
            )
        histogram = moving_mask.histogram()
        moving_pixels = sum(histogram[128:])
        total_pixels = width * height
        moving_ratio = moving_pixels / total_pixels
        if moving_ratio < 0.01 or moving_ratio > 0.65:
            raise MakerError(
                "invalid_input",
                "Motion lock mask must keep most of the frame locked while leaving a "
                "meaningful moving region",
            )
        if feather_px:
            moving_mask = moving_mask.filter(
                ImageFilter.MaxFilter(feather_px * 2 + 1)
            ).filter(ImageFilter.GaussianBlur(max(0.5, feather_px / 2)))

        with Image.open(frame_paths[reference_index]) as decoded_reference:
            if decoded_reference.format != "PNG":
                raise MakerError(
                    "invalid_assets",
                    f"Frame {frame_paths[reference_index].name} is not a PNG",
                )
            reference = decoded_reference.convert("RGBA")
        if reference.size != expected_size:
            raise MakerError(
                "invalid_assets",
                "Motion lock reference frame does not match manifest.render_size",
            )

        output_digests: dict[str, str] = {}
        for frame_path in frame_paths:
            with Image.open(frame_path) as decoded_frame:
                if decoded_frame.format != "PNG":
                    raise MakerError(
                        "invalid_assets",
                        f"Frame {frame_path.name} is not a PNG",
                    )
                frame = decoded_frame.convert("RGBA")
            if frame.size != expected_size:
                raise MakerError(
                    "invalid_assets",
                    f"Frame {frame_path.name} does not match manifest.render_size",
                )
            locked = Image.composite(frame, reference, moving_mask)
            descriptor, temporary = tempfile.mkstemp(
                prefix=f".{frame_path.stem}.",
                suffix=".png",
                dir=output_dir,
            )
            os.close(descriptor)
            temporary_path = Path(temporary)
            output_path = output_dir / frame_path.name
            try:
                locked.save(temporary_path, format="PNG")
                os.chmod(temporary_path, 0o600)
                os.replace(temporary_path, output_path)
            finally:
                temporary_path.unlink(missing_ok=True)
            output_digests[frame_path.name] = decoded_png_digest(output_path)
    except MakerError:
        raise
    except (OSError, ValueError, UnidentifiedImageError) as error:
        raise MakerError(
            "invalid_assets",
            "Motion lock inputs could not be decoded",
            bounded(str(error)),
        ) from error

    output_digest = hashlib.sha256()
    for name, digest in output_digests.items():
        output_digest.update(name.encode("utf-8"))
        output_digest.update(b"\0")
        output_digest.update(digest.encode("ascii"))
        output_digest.update(b"\0")
    report = {
        "schema_version": MOTION_LOCK_SCHEMA,
        "generated_at": utc_now(),
        "state": args.state,
        "frame_count": len(frame_paths),
        "reference_frame": reference_index,
        "moving_mask_sha256": sha256_file(mask_path),
        "moving_region_ratio": round(moving_ratio, 6),
        "feather_px": feather_px,
        "source_motion_digest": state_motion_digest(
            source_dir, manifest, args.state
        ),
        "output_motion_digest": output_digest.hexdigest(),
        "review_required": (
            "Inspect the complete locked output for mask seams, attachment errors, and "
            "action clipping. Locked pixels are stabilized; this operation cannot repair "
            "misregistered moving parts, bad anatomy, or bad action direction."
        ),
    }
    write_json_atomic(report_path, report)
    return {
        "schema_version": HELPER_SCHEMA,
        "ok": True,
        "status": "completed",
        "capability": "motion-lock",
        "state": args.state,
        "output_dir": str(output_dir),
        "report_path": str(report_path),
        "frame_count": len(frame_paths),
        "moving_region_ratio": round(moving_ratio, 6),
    }


def parse_state_notes(values: list[str] | None) -> dict[str, str]:
    notes: dict[str, str] = {}
    for raw in values or []:
        state, separator, note = raw.partition("=")
        state = state.strip()
        note = note.strip()
        if not separator or state not in STATES:
            raise MakerError(
                "invalid_request",
                "Each --state-note must use STATE=concrete visual inspection note",
            )
        if state in notes:
            raise MakerError("invalid_request", f"Duplicate motion review note for {state}")
        if not (
            MIN_MOTION_REVIEW_NOTE_CHARACTERS
            <= len(note)
            <= MAX_MOTION_REVIEW_NOTE_CHARACTERS
        ):
            raise MakerError(
                "invalid_request",
                f"Motion review note for {state} must be {MIN_MOTION_REVIEW_NOTE_CHARACTERS}-"
                f"{MAX_MOTION_REVIEW_NOTE_CHARACTERS} characters",
            )
        notes[state] = note
    return notes


def motion_review(args: argparse.Namespace) -> dict[str, Any]:
    workspace = Path(args.workspace).expanduser().resolve() if args.workspace else None
    if workspace:
        report_path = (
            Path(args.report).expanduser().resolve()
            if args.report
            else workspace / ".agent-pet-maker" / "motion-qa" / "report.json"
        )
        output_path = (
            Path(args.output).expanduser().resolve()
            if args.output
            else workspace / ".agent-pet-maker" / "motion-review.json"
        )
    else:
        if not args.report or not args.output:
            raise MakerError(
                "invalid_request",
                "Standalone motion review requires --report and --output",
            )
        report_path = Path(args.report).expanduser().resolve()
        output_path = Path(args.output).expanduser().resolve()
    if output_path.is_symlink():
        raise MakerError("unsafe_output", "Motion review output must not be a symbolic link")

    report = read_json(report_path, "motion QA report")
    if report.get("schema_version") != MOTION_QA_SCHEMA:
        raise MakerError("invalid_motion_qa", "Motion QA report is incompatible")
    audited_states = report.get("audited_states")
    if (
        not isinstance(audited_states, list)
        or not audited_states
        or any(state not in STATES for state in audited_states)
        or len(set(audited_states)) != len(audited_states)
    ):
        raise MakerError("invalid_motion_qa", "Motion QA report has invalid audited states")
    notes = parse_state_notes(args.state_note)
    missing = [state for state in audited_states if state not in notes]
    extra = [state for state in notes if state not in audited_states]
    if missing or extra:
        detail = []
        if missing:
            detail.append("missing " + ", ".join(missing))
        if extra:
            detail.append("unexpected " + ", ".join(extra))
        raise MakerError(
            "motion_review_incomplete",
            "Motion review notes must cover every audited state exactly (" + "; ".join(detail) + ")",
        )
    review = {
        "schema_version": MOTION_REVIEW_SCHEMA,
        "reviewed_at": utc_now(),
        "report_sha256": sha256_file(report_path),
        "frame_set_digest": report.get("frame_set_digest"),
        "audited_states": audited_states,
        "status": "approved",
        "review_contract": (
            "Reviewer inspected keyframes plus every reported playback profile for identity "
            "lock, non-moving-region stability, one readable action, prop continuity, timing, "
            "and loop/settle quality."
        ),
        "states": {
            state: {
                "status": "approved",
                "note": notes[state],
                "reviewed_profiles": sorted(
                    report.get("states", {}).get(state, {}).get("previews", {})
                ),
                "warning_codes": [
                    warning.get("code")
                    for warning in report.get("states", {}).get(state, {}).get("warnings", [])
                    if isinstance(warning, dict)
                ],
            }
            for state in audited_states
        },
    }
    write_json_atomic(output_path, review)
    return {
        "schema_version": HELPER_SCHEMA,
        "ok": True,
        "status": "completed",
        "capability": "motion-review",
        "review_path": str(output_path),
        "audited_states": audited_states,
    }


def verify_motion_review(
    workspace: Path,
    source_dir: Path,
    manifest: dict[str, Any],
    required_states: list[str],
) -> dict[str, Any]:
    report_path = workspace / ".agent-pet-maker" / "motion-qa" / "report.json"
    review_path = workspace / ".agent-pet-maker" / "motion-review.json"
    if report_path.is_symlink() or not report_path.is_file():
        raise MakerError(
            "motion_qa_required",
            "Run motion-qa and inspect its previews before finalize",
        )
    if review_path.is_symlink() or not review_path.is_file():
        raise MakerError(
            "motion_review_required",
            "Run motion-review after inspecting every motion QA preview",
        )
    report = read_json(report_path, "motion QA report")
    review = read_json(review_path, "motion review")
    if report.get("schema_version") != MOTION_QA_SCHEMA:
        raise MakerError("motion_qa_required", "Run current motion-qa before finalize")
    if review.get("schema_version") != MOTION_REVIEW_SCHEMA:
        raise MakerError("motion_review_required", "Run motion-review before finalize")
    if review.get("status") != "approved":
        raise MakerError("motion_review_required", "Motion review is not approved")
    if review.get("report_sha256") != sha256_file(report_path):
        raise MakerError(
            "stale_motion_review",
            "Motion QA changed after review; inspect the new previews and review again",
        )
    report_states = report.get("states")
    review_states = review.get("states")
    if not isinstance(report_states, dict) or not isinstance(review_states, dict):
        raise MakerError("invalid_motion_qa", "Motion QA evidence is incomplete")
    missing = [
        state
        for state in required_states
        if state not in report_states
        or state not in review_states
        or review_states[state].get("status") != "approved"
    ]
    if missing:
        raise MakerError(
            "motion_review_incomplete",
            "Motion QA and review must cover finalized states: " + ", ".join(missing),
        )
    current_state_digests = {
        state: state_motion_digest(source_dir, manifest, state)
        for state in required_states
    }
    stale = [
        state
        for state, digest in current_state_digests.items()
        if report_states[state].get("motion_digest") != digest
    ]
    if stale:
        raise MakerError(
            "stale_motion_qa",
            "Frames changed after motion QA; rerun QA and review for: " + ", ".join(stale),
        )
    warning_codes = sorted(
        {
            warning.get("code")
            for state in required_states
            for warning in report_states[state].get("warnings", [])
            if isinstance(warning, dict) and isinstance(warning.get("code"), str)
        }
    )
    return {
        "human_reviewed": True,
        "audited_states": required_states,
        "report_path": str(report_path),
        "review_path": str(review_path),
        "warning_codes": warning_codes,
    }


def validate_text_metadata(
    source_dir: Path,
    manifest: dict[str, Any],
    state_counts: dict[str, int],
    source_metadata: dict[str, Any],
) -> None:
    brief = read_json(source_dir / "brief.json", "brief.json")
    unknown = sorted(set(brief) - BRIEF_ALLOWED_KEYS)
    if unknown:
        raise MakerError(
            "invalid_metadata",
            f"brief.json contains fields outside apc.pet-brief.v1: {unknown}",
        )
    if brief.get("schema_version") != "apc.pet-brief.v1":
        raise MakerError("invalid_metadata", "brief.schema_version must be apc.pet-brief.v1")
    for key in ("name", "style", "quality", "states"):
        if key not in brief:
            raise MakerError("invalid_metadata", f"brief.json is missing required field: {key}")
    if brief.get("name") != manifest.get("name"):
        raise MakerError("invalid_metadata", "brief.name must match manifest.name")
    if brief.get("style") != manifest.get("style"):
        raise MakerError("invalid_metadata", "brief.style must match manifest.style")
    if brief.get("quality") != manifest.get("quality"):
        raise MakerError("invalid_metadata", "brief.quality must match manifest.quality")
    brief_states = brief.get("states")
    if not isinstance(brief_states, list) or len(brief_states) != len(STATES):
        raise MakerError("invalid_metadata", "brief.states must contain all seven fixed states")
    named_states: list[str] = []
    manifest_durations = manifest_timing_contract(manifest)["state_durations_ms"]
    for entry in brief_states:
        if isinstance(entry, str):
            named_states.append(entry)
            continue
        if not isinstance(entry, dict):
            raise MakerError("invalid_metadata", "brief.states contains an invalid state entry")
        state = entry.get("name", entry.get("state"))
        motion = entry.get("motion")
        if state not in STATES or not isinstance(motion, str) or not motion.strip():
            raise MakerError("invalid_metadata", "brief state objects require a fixed name and motion")
        duration_ms = entry.get("duration_ms")
        if duration_ms != manifest_durations[state]:
            raise MakerError(
                "invalid_metadata",
                f"brief state {state} duration_ms must match manifest.json",
            )
        if ("name" in entry) == ("state" in entry):
            raise MakerError("invalid_metadata", "brief state objects use exactly one of name or state")
        if set(entry) - {"name", "state", "label", "motion", "duration_ms"}:
            raise MakerError("invalid_metadata", "brief state object contains undeclared fields")
        named_states.append(state)
    if set(named_states) != set(STATES) or len(set(named_states)) != len(STATES):
        raise MakerError("invalid_metadata", "brief.states must identify each fixed state exactly once")
    runtime = brief.get("runtime")
    if runtime is not None:
        timing = manifest_timing_contract(manifest)
        expected_runtime = {
            "native_fps": timing["native_fps"],
            "state_durations_ms": timing["state_durations_ms"],
            "state_frame_counts": timing["state_frame_counts"],
            "render_size": manifest.get("render_size"),
        }
        if runtime != expected_runtime:
            raise MakerError("invalid_metadata", "brief.runtime must match the validated manifest and frames")
    generation = brief.get("generation")
    if generation is not None:
        if not isinstance(generation, dict) or set(generation) - {
            "generator",
            "provenance",
            "skill_helper",
            "preview_only",
        }:
            raise MakerError("invalid_metadata", "brief.generation contains undeclared fields")
        if generation.get("generator") != source_metadata.get("generator") or generation.get(
            "provenance"
        ) != source_metadata.get("provenance"):
            raise MakerError("invalid_metadata", "brief.generation must match source/source.json")
    forbidden = contains_forbidden_key(brief)
    if forbidden:
        raise MakerError("privacy_violation", f"brief.json contains forbidden field: {forbidden}")
    if contains_sensitive_string(brief):
        raise MakerError("privacy_violation", "brief.json must not contain absolute paths or URLs")

    prompt_path = source_dir / "source" / "prompt.md"
    try:
        if not prompt_path.is_file() or prompt_path.stat().st_size > MAX_PROMPT_BYTES:
            raise MakerError("invalid_metadata", "source/prompt.md is missing or exceeds 64 KiB")
        prompt = prompt_path.read_text(encoding="utf-8")
    except MakerError:
        raise
    except OSError as error:
        raise MakerError("invalid_metadata", f"Could not read source/prompt.md: {error}") from error
    if not prompt.strip():
        raise MakerError("invalid_metadata", "source/prompt.md must not be empty")
    if contains_sensitive_string(prompt):
        raise MakerError("privacy_violation", "source/prompt.md must not contain absolute paths or URLs")


def build_petpack_atomically(
    cli: Path, source_dir: Path, output: Path, replace: bool
) -> dict[str, Any]:
    """Build and validate beside the destination, then publish in one rename.

    In particular, `--replace` must never remove the known-good package before
    PetCore has both produced and validated its replacement. The temporary file
    lives in the destination directory so `os.replace` is an atomic same-volume
    handoff.
    """

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".building", dir=output.parent
    )
    os.close(descriptor)
    staged_output = Path(temporary_name)
    staged_output.unlink()
    try:
        run_cli(
            cli,
            ["petpack", "build", "--input", str(source_dir), "--output", str(staged_output)],
            "build_failed",
        )
        if staged_output.is_symlink() or not staged_output.is_file():
            raise MakerError(
                "build_failed",
                "PetCore CLI reported success but wrote no safe regular package",
            )
        validation = run_cli(
            cli,
            ["petpack", "validate", str(staged_output)],
            "validation_failed",
        )

        if replace:
            os.replace(staged_output, output)
        else:
            # Hard-link publication is atomic and fails rather than replacing a
            # destination created after the initial existence check.
            try:
                os.link(staged_output, output)
            except FileExistsError as error:
                raise MakerError(
                    "output_exists",
                    "Output appeared while the package was being built; no file was replaced",
                ) from error
            staged_output.unlink()
        return validation
    finally:
        staged_output.unlink(missing_ok=True)


def finalize(args: argparse.Namespace) -> dict[str, Any]:
    workspace = Path(args.workspace).expanduser().resolve()
    context_path = workspace / ".agent-pet-maker" / "context.json"
    context = read_json(context_path, "workspace context")
    if context.get("schema_version") != WORKSPACE_SCHEMA or context.get("operation") != args.operation:
        raise MakerError("invalid_workspace", "Workspace context does not match the requested operation")
    source_dir = Path(context.get("source_dir", "")).resolve()
    if source_dir != (workspace / "petpack-source").resolve() or not source_dir.is_dir():
        raise MakerError("invalid_workspace", "Workspace petpack-source is missing or redirected")

    raw_output = Path(args.output).expanduser()
    raw_result_path = (
        Path(args.result).expanduser()
        if args.result
        else workspace / "agent-pet-maker-result.json"
    )
    if raw_output.is_symlink():
        raise MakerError("unsafe_output", "Package output must not be a symbolic link")
    if raw_result_path.is_symlink():
        raise MakerError("unsafe_output", "Result sidecar must not be a symbolic link")
    output = raw_output.resolve()
    result_path = raw_result_path.resolve()
    ensure_outside(output, source_dir, "Package output")
    ensure_outside(result_path, source_dir, "Result sidecar")
    if output == result_path:
        raise MakerError("unsafe_output", "Package and result paths must differ")
    if output.exists() and not args.replace:
        raise MakerError("output_exists", "Output already exists; use --replace only when overwrite is intended")
    if output.exists() and output.is_dir():
        raise MakerError("unsafe_output", "Package output must not be a directory")
    if result_path.exists() and result_path.is_dir():
        raise MakerError("unsafe_output", "Result sidecar must not be a directory")

    cli = locate_cli(args.cli or context.get("cli_path"))
    manifest = read_json(source_dir / "manifest.json", "manifest.json")
    if manifest.get("schema_version") != PETPACK_SCHEMA:
        raise MakerError("invalid_manifest", "manifest.schema_version must be apc.petpack.v1")
    current_files, state_counts = collect_state_files(source_dir, manifest)
    timing = manifest_timing_contract(manifest)
    validate_exact_state_counts(state_counts, timing)

    changed_states: list[str] = []
    if args.operation == "modify":
        base = context.get("base")
        if not isinstance(base, dict):
            raise MakerError("invalid_workspace", "Modify workspace has no base package context")
        if structural_manifest(manifest) != base.get("manifest"):
            raise MakerError(
                "base_contract_changed",
                "Modify must preserve ID, format, quality, render size, state layout, and created_at",
            )
        changed_states = compare_modified_states(base.get("state_files", {}), current_files)
        declared = sorted(set(args.changed_state or []), key=STATES.index)
        if not changed_states:
            raise MakerError("no_visual_changes", "Modify produced no changed state frames")
        if declared and declared != changed_states:
            raise MakerError(
                "changed_state_mismatch",
                f"Declared states {declared} do not match actual changed states {changed_states}",
            )
        if not declared:
            raise MakerError("changed_states_required", "Declare every modified state with --changed-state")
        validate_generated_motion(current_files, changed_states)
        validate_native_frame_semantics(current_files, changed_states, timing)
        base_timing = base.get("timing")
        if not isinstance(base_timing, dict):
            raise MakerError("invalid_workspace", "Modify workspace has no base timing contract")
        validate_timing_revision(
            base.get("state_files", {}),
            current_files,
            base_timing,
            timing,
            changed_states,
        )

        base_input = Path(base.get("input_path", "")).resolve()
        if output == base_input:
            raise MakerError("unsafe_output", "Do not overwrite the base petpack during modify")
    elif args.changed_state:
        raise MakerError("invalid_request", "--changed-state is only valid for modify")
    else:
        validate_generated_motion(current_files, STATES)
        validate_native_frame_semantics(current_files, STATES, timing)

    validate_portable_visual_assets(source_dir, manifest)
    motion_quality = verify_motion_review(
        workspace,
        source_dir,
        manifest,
        changed_states if args.operation == "modify" else list(STATES),
    )

    source_metadata = normalize_source_metadata(
        source_dir, args.operation, context, changed_states, state_counts, manifest
    )
    validate_text_metadata(source_dir, manifest, state_counts, source_metadata)
    validate_session(source_dir)

    validation_path = source_dir / "build" / "validation.json"
    write_json_atomic(
        validation_path,
        {
            "schema_version": VALIDATION_SCHEMA,
            "ok": True,
            "validator": "agent-pet-maker",
            "frame_count": sum(timing["state_frame_counts"].values()),
            "native_fps": timing["native_fps"],
            "state_durations_ms": timing["state_durations_ms"],
            "state_frame_counts": timing["state_frame_counts"],
            "skipped": "Temporary workspace artifact; PetCore validation is pending.",
        },
    )
    try:
        validation = run_cli(cli, ["petpack", "validate", str(source_dir)], "validation_failed")
    except MakerError as error:
        write_json_atomic(
            validation_path,
            {
                "schema_version": VALIDATION_SCHEMA,
                "ok": True,
                "validator": "agent-pet-maker",
                "frame_count": sum(timing["state_frame_counts"].values()),
                "native_fps": timing["native_fps"],
                "state_durations_ms": timing["state_durations_ms"],
                "state_frame_counts": timing["state_frame_counts"],
                "skipped": f"PetCore validation failed ({error.code}); this workspace is not a completed package.",
            },
        )
        raise

    final_validation = {
        "schema_version": VALIDATION_SCHEMA,
        "ok": True,
        "validator": "petcore-cli",
        "frame_count": validation.get("frame_count"),
        "native_fps": timing["native_fps"],
        "state_durations_ms": timing["state_durations_ms"],
        "state_frame_counts": timing["state_frame_counts"],
        "warnings": validation.get("warnings", []),
        "validated_at": utc_now(),
        "manifest_id": manifest.get("id"),
        "generator": source_metadata.get("generator"),
        "provenance": source_metadata.get("provenance"),
        "skill_helper": "agent-pet-maker",
        "preview_only": False,
    }
    write_json_atomic(validation_path, final_validation)
    append_session_event(
        source_dir,
        {
            "schema_version": SOURCE_EVENT_SCHEMA,
            "event": "petpack.validated",
            "created_at": utc_now(),
            "helper": "agent-pet-maker",
            "manifest_id": manifest.get("id"),
            "changed_states": changed_states,
            "validation_ok": True,
            "completed": True,
        },
    )
    validate_session(source_dir)
    validation = run_cli(cli, ["petpack", "validate", str(source_dir)], "validation_failed")

    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    validation = build_petpack_atomically(cli, source_dir, output, args.replace)

    result: dict[str, Any] = {
        "schema_version": RESULT_SCHEMA,
        "status": "completed",
        "operation": args.operation,
        "petpack_path": str(output),
        "petpack_sha256": sha256_file(output),
        "manifest": {
            "schema_version": manifest.get("schema_version"),
            "id": manifest.get("id"),
            "name": manifest.get("name"),
            "quality": manifest.get("quality"),
            "render_size": manifest.get("render_size"),
            "native_fps": timing["native_fps"],
            "state_durations_ms": timing["state_durations_ms"],
        },
        "base": public_base(context.get("base")),
        "changed_states": changed_states,
        "validation": {
            "ok": validation.get("ok") is True,
            "frame_count": validation.get("frame_count"),
            "warnings": validation.get("warnings", []),
        },
        "motion_quality": motion_quality,
        "result_path": str(result_path),
    }
    write_json_atomic(result_path, result)
    return result


def pet_with_id(pets: list[dict[str, Any]], pet_id: str) -> dict[str, Any] | None:
    return next((pet for pet in pets if pet.get("id") == pet_id), None)


def validated_manifest(validation: dict[str, Any]) -> dict[str, Any]:
    if validation.get("ok") is not True:
        raise MakerError("validation_failed", "PetCore validation did not report ok=true")
    manifest = validation.get("manifest")
    if not isinstance(manifest, dict):
        raise MakerError("validation_failed", "PetCore validation returned no manifest")
    pet_id = manifest.get("id")
    if manifest.get("schema_version") != PETPACK_SCHEMA or not isinstance(pet_id, str):
        raise MakerError("validation_failed", "PetCore validation returned an incompatible manifest")
    return manifest


def installed_archive_matches(
    cli: Path, pet_id: str, expected_sha256: str
) -> tuple[bool, bool]:
    pets = run_cli_list(cli, ["pet", "list"], "install_verification_failed")
    listed = pet_with_id(pets, pet_id)
    if listed is None:
        return False, False
    raw_path = listed.get("petpack_path")
    if not isinstance(raw_path, str) or not raw_path:
        return True, False
    archive = Path(raw_path).expanduser()
    if archive.is_symlink() or not archive.is_file():
        return True, False
    try:
        return True, sha256_file(archive) == expected_sha256
    except OSError:
        return True, False


def reconcile_ambiguous_import(
    cli: Path, pet_id: str, expected_sha256: str, attempts: int = 20
) -> bool:
    """Resolve a transport failure without blindly issuing a second import."""

    for attempt in range(max(1, attempts)):
        try:
            imported, exact_archive = installed_archive_matches(cli, pet_id, expected_sha256)
        except MakerError:
            imported, exact_archive = False, False
        if imported and exact_archive:
            return True
        if attempt + 1 < attempts:
            time.sleep(0.5)
    return False


def install_verification(
    cli: Path, pet_id: str, expected_sha256: str | None = None
) -> dict[str, Any]:
    pets = run_cli_list(cli, ["pet", "list"], "install_verification_failed")
    snapshot = run_cli(cli, ["state", "snapshot"], "install_verification_failed")
    snapshot_pets = snapshot.get("pets")
    if not isinstance(snapshot_pets, list) or not all(isinstance(item, dict) for item in snapshot_pets):
        raise MakerError(
            "install_verification_failed", "PetCore snapshot returned an unexpected pets value"
        )
    listed = pet_with_id(pets, pet_id)
    snapshotted = pet_with_id(snapshot_pets, pet_id)
    behavior = snapshot.get("behavior")
    behavior_enabled = behavior.get("enabled") if isinstance(behavior, dict) else None
    if not isinstance(behavior_enabled, bool):
        behavior_enabled = None
    overlay = snapshot.get("overlay_visibility")
    overlay_visibility = (
        {
            "pet_visible": overlay.get("pet_visible"),
            "status_bubble_visible": overlay.get("status_bubble_visible"),
        }
        if isinstance(overlay, dict)
        else None
    )
    active_in_list = listed.get("active") if isinstance(listed, dict) else None
    active_in_snapshot = snapshotted.get("active") if isinstance(snapshotted, dict) else None
    active_consistent = (
        isinstance(active_in_list, bool)
        and isinstance(active_in_snapshot, bool)
        and active_in_list == active_in_snapshot
    )
    warnings: list[str] = []
    archive_sha256_matches: bool | None = None
    if listed is not None and expected_sha256 is not None:
        _, archive_sha256_matches = installed_archive_matches(cli, pet_id, expected_sha256)
        if not archive_sha256_matches:
            warnings.append("The installed archive does not match the validated input petpack.")
    if behavior_enabled is False:
        warnings.append("The pet is installed, but desktop-pet behavior is disabled in the App.")
    if isinstance(overlay_visibility, dict) and overlay_visibility.get("pet_visible") is False:
        warnings.append("The current snapshot reports that the desktop pet overlay is not visible.")
    if listed is not None and active_in_list is False:
        warnings.append("The installed pet is not the active library pet.")
    return {
        "imported_in_pet_list": listed is not None,
        "imported_in_snapshot": snapshotted is not None,
        "active": active_in_list if active_consistent else None,
        "active_consistent": active_consistent,
        "archive_sha256_matches": archive_sha256_matches,
        "behavior_enabled": behavior_enabled,
        "overlay_visibility": overlay_visibility,
        "warnings": warnings,
    }


def install(args: argparse.Namespace) -> dict[str, Any]:
    raw_input_path = Path(args.input).expanduser()
    input_is_symlink = raw_input_path.is_symlink()
    input_path = raw_input_path.resolve()
    default_result = input_path.with_name(f"{input_path.name}.install-result.json")
    raw_result_path = Path(args.result).expanduser() if args.result else default_result
    result_is_symlink = raw_result_path.is_symlink()
    # Never follow an explicitly supplied sidecar symlink. Record the rejection
    # at the deterministic default location instead.
    result_path = default_result.resolve() if result_is_symlink else raw_result_path.resolve()
    result: dict[str, Any] = {
        "schema_version": RESULT_SCHEMA,
        "status": "failed",
        "operation": "install",
        "petpack_path": str(input_path),
        "result_path": str(result_path),
        "install": {
            "requested_activate": bool(args.activate),
            "allow_existing_id_revision": bool(args.allow_existing_id_revision),
            "online_only": True,
            "import": {"attempted": False, "succeeded": False, "returned_id": None},
            "activation": {"attempted": False, "succeeded": False},
        },
    }
    cli: Path | None = None
    pet_id: str | None = None
    import_attempted = False
    imported = False
    try:
        if input_path == result_path:
            raise MakerError("unsafe_output", "Install result sidecar must differ from the petpack")
        if result_is_symlink:
            raise MakerError("unsafe_output", "Install result sidecar must not be a symbolic link")
        if input_is_symlink or not input_path.is_file():
            raise MakerError("invalid_input", "Install input must be an existing regular .petpack file")
        if input_path.stat().st_size > MAX_ARCHIVE_BYTES:
            raise MakerError("invalid_input", "Install input exceeds the 1 GiB petpack limit")
        cli = locate_install_cli(args.cli)
        result["install"]["cli_path"] = str(cli)

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-install-") as temporary:
            staged = Path(temporary) / "validated.petpack"
            source_hash_before = sha256_file(input_path)
            shutil.copyfile(input_path, staged)
            source_hash_after = sha256_file(input_path)
            staged_hash = sha256_file(staged)
            if source_hash_before != source_hash_after or staged_hash != source_hash_before:
                raise MakerError("input_changed", "Petpack changed while it was staged for install")

            first_validation = run_cli(
                cli, ["petpack", "validate", str(staged)], "validation_failed"
            )
            manifest = validated_manifest(first_validation)
            pet_id = manifest["id"]
            result["petpack_sha256"] = staged_hash
            result["manifest"] = {
                key: manifest.get(key)
                for key in ("schema_version", "id", "name", "quality", "render_size")
            }

            existing_pets = run_cli_list(cli, ["pet", "list"], "install_preflight_failed")
            existing = pet_with_id(existing_pets, pet_id)
            result["install"]["existing_before"] = existing is not None
            if existing is not None and not args.allow_existing_id_revision:
                raise MakerError(
                    "existing_pet_id",
                    "A library pet already uses this ID. Re-run with --allow-existing-id-revision only when replacing it with an intentional same-ID revision.",
                )

            second_validation = run_cli(
                cli, ["petpack", "validate", str(staged)], "validation_failed"
            )
            second_manifest = validated_manifest(second_validation)
            if second_manifest != manifest or sha256_file(staged) != staged_hash:
                raise MakerError("input_changed", "Staged petpack changed before online import")
            result["validation"] = {
                "ok": True,
                "frame_count": second_validation.get("frame_count"),
                "warnings": second_validation.get("warnings", []),
            }

            import_attempted = True
            result["install"]["import"]["attempted"] = True
            import_arguments = ["petpack", "import"]
            if not args.allow_existing_id_revision:
                import_arguments.append("--expect-absent")
            import_arguments.append(str(staged))
            try:
                imported_pet = run_cli(cli, import_arguments, "install_import_failed")
                returned_id = imported_pet.get("id")
            except MakerError as import_error:
                if not reconcile_ambiguous_import(cli, pet_id, staged_hash):
                    raise
                returned_id = pet_id
                result["install"]["import"]["reconciled_after_error"] = True
                result["install"]["import"]["recovered_error"] = import_error.code
            imported = True
            result["install"]["import"].update(
                {"succeeded": True, "returned_id": returned_id}
            )
            if returned_id != pet_id:
                raise MakerError(
                    "import_id_mismatch",
                    f"PetCore imported ID {returned_id!r}, expected {pet_id!r}",
                )

            if args.activate:
                result["install"]["activation"]["attempted"] = True
                activation = run_cli(
                    cli, ["pet", "activate", "--id", pet_id], "install_activation_failed"
                )
                if activation.get("ok") is not True:
                    raise MakerError(
                        "install_activation_failed", "PetCore activation did not report ok=true"
                    )
                result["install"]["activation"]["succeeded"] = True

        verification = install_verification(cli, pet_id, result.get("petpack_sha256"))
        result["install"]["verification"] = verification
        if not verification["imported_in_pet_list"] or not verification["imported_in_snapshot"]:
            raise MakerError(
                "install_verification_failed", "Imported pet is missing from PetCore verification"
            )
        if not verification["active_consistent"]:
            raise MakerError(
                "install_verification_failed", "Pet active state differs between list and snapshot"
            )
        if verification["archive_sha256_matches"] is not True:
            raise MakerError(
                "install_verification_failed",
                "Installed archive differs from the validated input petpack",
            )
        if args.activate and verification["active"] is not True:
            raise MakerError(
                "install_verification_failed", "Activation was requested but the pet is not active"
            )
        result["status"] = "completed"
    except MakerError as error:
        if cli is not None and pet_id is not None and (import_attempted or imported):
            try:
                result["install"]["verification"] = install_verification(
                    cli, pet_id, result.get("petpack_sha256")
                )
            except MakerError as verification_error:
                result["install"]["verification_error"] = {
                    "code": verification_error.code,
                    "message": verification_error.message,
                }
        result["status"] = "partial_success" if import_attempted else "failed"
        if import_attempted and not imported:
            result["install"]["import"]["mutation_state"] = "unknown"
        result["error"] = {"code": error.code, "message": error.message}
        if error.detail:
            result["error"]["detail"] = error.detail
    except OSError as error:
        result["status"] = "partial_success" if import_attempted else "failed"
        if import_attempted and not imported:
            result["install"]["import"]["mutation_state"] = "unknown"
        result["error"] = {
            "code": "install_io_failed",
            "message": "A local I/O error interrupted installation",
            "detail": bounded(str(error)),
        }
    write_json_atomic(result_path, result)
    return result


def capability_missing(args: argparse.Namespace) -> dict[str, Any]:
    result_path = Path(args.result).expanduser().resolve()
    result = {
        "schema_version": RESULT_SCHEMA,
        "status": "capability_missing",
        "operation": args.operation,
        "missing_capabilities": sorted(set(args.capability)),
        "message": args.message
        or "A required real image or PetCore capability is unavailable; no petpack was created.",
        "petpack_path": None,
        "result_path": str(result_path),
    }
    write_json_atomic(result_path, result)
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    locate = subparsers.add_parser("locate-cli", help="Locate a compatible petcore-cli")
    locate.add_argument("--cli", help="Explicit petcore-cli path")

    preflight = subparsers.add_parser(
        "preflight", help="Verify PetCore CLI plus PNG and animated WebP codecs"
    )
    preflight.add_argument("--cli", help="Explicit petcore-cli path")

    prepare_parser = subparsers.add_parser("prepare", help="Prepare a create or modify workspace")
    prepare_parser.add_argument("--operation", choices=("create", "modify"), required=True)
    prepare_parser.add_argument("--workspace", required=True)
    prepare_parser.add_argument("--input", help="Base .petpack for modify")
    prepare_parser.add_argument("--cli", help="Explicit petcore-cli path")

    motion_qa_parser = subparsers.add_parser(
        "motion-qa",
        help="Render in-app-size motion previews and deterministic review targets",
    )
    motion_qa_parser.add_argument("--workspace")
    motion_qa_parser.add_argument("--source")
    motion_qa_parser.add_argument("--output-dir")
    motion_qa_parser.add_argument("--state", action="append", choices=STATES)

    motion_review_parser = subparsers.add_parser(
        "motion-review",
        help="Record a visual review bound to the current motion QA evidence",
    )
    motion_review_parser.add_argument("--workspace")
    motion_review_parser.add_argument("--report")
    motion_review_parser.add_argument("--output")
    motion_review_parser.add_argument(
        "--state-note",
        action="append",
        required=True,
        help="Concrete inspection note in STATE=note form; repeat for every audited state",
    )

    motion_lock_parser = subparsers.add_parser(
        "motion-lock",
        help="Preserve explicit non-moving pixels from one generated reference frame",
    )
    motion_lock_parser.add_argument("--source", required=True)
    motion_lock_parser.add_argument("--state", required=True, choices=STATES)
    motion_lock_parser.add_argument("--moving-mask", required=True)
    motion_lock_parser.add_argument("--output-dir", required=True)
    motion_lock_parser.add_argument("--report")
    motion_lock_parser.add_argument("--reference-frame", type=int, default=0)
    motion_lock_parser.add_argument("--feather-px", type=int, default=4)

    finalize_parser = subparsers.add_parser("finalize", help="Validate and build a petpack")
    finalize_parser.add_argument("--operation", choices=("create", "modify"), required=True)
    finalize_parser.add_argument("--workspace", required=True)
    finalize_parser.add_argument("--output", required=True)
    finalize_parser.add_argument("--result", help="Result sidecar path")
    finalize_parser.add_argument("--cli", help="Explicit petcore-cli path")
    finalize_parser.add_argument("--changed-state", action="append", choices=STATES)
    finalize_parser.add_argument("--replace", action="store_true")

    missing = subparsers.add_parser("capability-missing", help="Write an honest no-package result")
    missing.add_argument("--operation", choices=("create", "modify"), required=True)
    missing.add_argument("--capability", action="append", required=True)
    missing.add_argument("--message")
    missing.add_argument("--result", required=True)

    install_parser = subparsers.add_parser(
        "install", help="Validate and import a petpack through the running PetCore daemon"
    )
    install_parser.add_argument("--input", required=True)
    install_parser.add_argument("--activate", action="store_true")
    install_parser.add_argument("--result", help="Install result sidecar path")
    install_parser.add_argument("--cli", help="Explicit installed petcore-cli path")
    install_parser.add_argument(
        "--allow-existing-id-revision",
        action="store_true",
        help="Allow an intentional same-ID library revision to replace the current revision",
    )

    return parser


def main(argv: Iterable[str] | None = None) -> int:
    raw_argv = list(argv) if argv is not None else sys.argv[1:]
    parser = build_parser()
    args = parser.parse_args(raw_argv)
    try:
        ensure_pillow_runtime(args.command, raw_argv)
        if args.command == "locate-cli":
            cli = locate_cli(args.cli)
            result = {
                "schema_version": HELPER_SCHEMA,
                "ok": True,
                "status": "available",
                "capability": "petcore-cli",
                "path": str(cli),
            }
        elif args.command == "preflight":
            cli = locate_cli(args.cli)
            result = {
                "schema_version": HELPER_SCHEMA,
                "ok": True,
                "status": "available",
                "capability": "petpack-create-modify",
                "path": str(cli),
                "cli_contract": verify_cli_contract(cli),
                "image_codecs": verify_image_codecs(),
            }
        elif args.command == "prepare":
            result = prepare(args)
        elif args.command == "motion-qa":
            result = motion_qa(args)
        elif args.command == "motion-review":
            result = motion_review(args)
        elif args.command == "motion-lock":
            result = motion_lock(args)
        elif args.command == "finalize":
            result = finalize(args)
        elif args.command == "install":
            result = install(args)
        else:
            result = capability_missing(args)
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0 if result.get("status") not in {"failed", "partial_success"} else 2
    except MakerError as error:
        status = "capability_missing" if error.code == "capability_missing" else "failed"
        payload: dict[str, Any] = {
            "schema_version": HELPER_SCHEMA,
            "ok": False,
            "status": status,
            "error": {"code": error.code, "message": error.message},
        }
        if error.detail:
            payload["error"]["detail"] = error.detail
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
        return 3 if status == "capability_missing" else 2


if __name__ == "__main__":
    raise SystemExit(main())
