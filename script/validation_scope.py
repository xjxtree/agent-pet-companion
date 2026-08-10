#!/usr/bin/env python3
"""Classify changed paths for local, CI, and UI-validation routing."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import pathlib
import shlex
import subprocess
import sys


OVERLAY_SWIFT_PREFIXES = (
    "apps/macos/Sources/AgentPetCompanion/Overlay/",
)
OVERLAY_SWIFT_FILES = {
    "apps/macos/Sources/AgentPetCompanionCore/FrameScheduler.swift",
    "apps/macos/Tests/AgentPetCompanionTests/AppStoreOverlaySnapshotTests.swift",
    "apps/macos/Tests/AgentPetCompanionTests/FrameTimelineTests.swift",
    "apps/macos/Tests/AgentPetCompanionTests/OverlayDisplayWidthTests.swift",
    "apps/macos/Tests/AgentPetCompanionTests/OverlayGeometryTests.swift",
    "apps/macos/Tests/AgentPetCompanionTests/OverlayInteractionTelemetryTests.swift",
    "apps/macos/Tests/AgentPetCompanionTests/OverlayPlacementAuthorityTests.swift",
    "apps/macos/Tests/AgentPetCompanionTests/PetFramePipelineTests.swift",
}
LOCALIZATION_PREFIX = (
    "apps/macos/Sources/AgentPetCompanion/Resources/Localizable.xcstrings",
    "apps/macos/Sources/AgentPetCompanion/Resources/en.lproj/",
    "apps/macos/Sources/AgentPetCompanion/Resources/zh-Hans.lproj/",
)
BUNDLE_SCRIPT_PATHS = {
    "script/build_and_run.sh",
    "script/build_app_bundle.sh",
    "script/prepare_interaction_attestation.sh",
    "script/validate_app_bundle.sh",
    "script/validate_interaction_attestation.py",
    "script/validate_overlay_interaction.sh",
    "script/validate_overlay_offline.sh",
    "script/validation_helpers.sh",
}


def has_prefix(path: str, prefixes: tuple[str, ...]) -> bool:
    return any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in prefixes)


def is_localization(path: str) -> bool:
    return has_prefix(path, LOCALIZATION_PREFIX)


def is_overlay_swift(path: str) -> bool:
    return path in OVERLAY_SWIFT_FILES or has_prefix(path, OVERLAY_SWIFT_PREFIXES)


def recommends_computer_use(path: str) -> bool:
    if not path.endswith(".swift"):
        return False
    if "/Tests/" in path:
        return False
    return has_prefix(
        path,
        (
            "apps/macos/Sources/AgentPetCompanion/Overlay/",
            "apps/macos/Sources/AgentPetCompanion/Views/",
            "apps/macos/Sources/AgentPetCompanion/App/",
        ),
    )


@dataclasses.dataclass(frozen=True)
class ValidationScope:
    changed_count: int
    docs_only: bool
    localization: bool
    scripts: bool
    producer: bool
    connectors: bool
    schemas: bool
    plugin_version: bool
    rust_mode: str
    swift_mode: str
    bundle: bool
    computer_use: str

    def as_dict(self) -> dict[str, bool | int | str]:
        return dataclasses.asdict(self)


def classify(paths: list[str]) -> ValidationScope:
    normalized = sorted({path.strip("/") for path in paths if path.strip("/")})
    path_set = set(normalized)

    root_rust = bool(path_set & {"Cargo.toml", "Cargo.lock", "rust-toolchain.toml"})
    petcore_types = any(path.startswith("crates/petcore-types/") for path in normalized)
    petcore = any(path.startswith("crates/petcore/") for path in normalized)
    petcore_cli = any(path.startswith("crates/petcore-cli/") for path in normalized)
    schemas = any(path.startswith(("schemas/", "fixtures/")) for path in normalized)

    if root_rust or petcore_types or schemas:
        rust_mode = "workspace"
    elif petcore:
        rust_mode = "petcore"
    elif petcore_cli:
        rust_mode = "cli"
    else:
        rust_mode = "none"

    swift_inputs = [
        path
        for path in normalized
        if path.endswith(".swift")
        or path in {"apps/macos/Package.swift", "apps/macos/Package.resolved"}
    ]
    if not swift_inputs:
        swift_mode = "none"
    elif all(path.endswith(".swift") and is_overlay_swift(path) for path in swift_inputs):
        swift_mode = "overlay"
    else:
        swift_mode = "full"

    localization = any(is_localization(path) for path in normalized)
    scripts = any(path.startswith(("script/", ".github/")) for path in normalized)
    producer = any(
        path.startswith(("skills/agent-pet-maker/", "skills/agent-pet-studio/"))
        or path.startswith(("schemas/petpack", "fixtures/petpack"))
        or path.startswith(
            "apps/macos/Sources/AgentPetCompanion/Resources/BuiltInPets/"
        )
        for path in normalized
    )
    connectors = any(
        path.startswith("plugins/")
        or path == "docs/integrations/agent-connectors.md"
        for path in normalized
    )
    connector_code = any(path.startswith("plugins/") for path in normalized)
    plugin_version = any(
        path.startswith(
            ("plugins/codex/", "skills/agent-pet-maker/", "skills/agent-pet-studio/")
        )
        for path in normalized
    )

    non_localization_app_resource = any(
        path.startswith("apps/macos/Sources/AgentPetCompanion/Resources/")
        and not is_localization(path)
        for path in normalized
    )
    bundle_script = bool(path_set & BUNDLE_SCRIPT_PATHS)
    bundle = any(
        (
            rust_mode != "none",
            swift_mode != "none",
            schemas,
            producer,
            connector_code,
            non_localization_app_resource,
            bundle_script,
        )
    )

    documentation_paths = (
        "README.md",
        "README.zh-CN.md",
        "CHANGELOG.md",
        "AGENTS.md",
    )
    docs_only = bool(normalized) and all(
        path.startswith("docs/") or path in documentation_paths for path in normalized
    ) and not connectors

    computer_use = (
        "recommended"
        if any(recommends_computer_use(path) for path in normalized)
        else "not_required"
    )

    return ValidationScope(
        changed_count=len(normalized),
        docs_only=docs_only,
        localization=localization,
        scripts=scripts,
        producer=producer,
        connectors=connectors,
        schemas=schemas,
        plugin_version=plugin_version,
        rust_mode=rust_mode,
        swift_mode=swift_mode,
        bundle=bundle,
        computer_use=computer_use,
    )


def paths_from_git(root: pathlib.Path, base_ref: str) -> list[str]:
    base = base_ref
    if base == "0" * 40:
        result = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD^"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
        )
        base = result.stdout.strip() if result.returncode == 0 else "HEAD"
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", base, "HEAD", "--"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return [os.fsdecode(item) for item in result.stdout.split(b"\0") if item]


def paths_from_file(path: pathlib.Path) -> list[str]:
    return [os.fsdecode(item) for item in path.read_bytes().split(b"\0") if item]


def emit(scope: ValidationScope, output_format: str) -> None:
    values = scope.as_dict()
    if output_format == "json":
        print(json.dumps(values, sort_keys=True, separators=(",", ":")))
        return

    names = {
        "changed_count": "APC_CHANGED_COUNT",
        "docs_only": "APC_CHANGED_DOCS_ONLY",
        "localization": "APC_CHANGED_LOCALIZATION",
        "scripts": "APC_CHANGED_SCRIPTS",
        "producer": "APC_CHANGED_PRODUCER",
        "connectors": "APC_CHANGED_CONNECTORS",
        "schemas": "APC_CHANGED_SCHEMAS",
        "plugin_version": "APC_CHANGED_PLUGIN_VERSION",
        "rust_mode": "APC_RUST_MODE",
        "swift_mode": "APC_SWIFT_MODE",
        "bundle": "APC_BUILD_BUNDLE",
        "computer_use": "APC_COMPUTER_USE",
    }
    for key, value in values.items():
        rendered = "1" if value is True else "0" if value is False else str(value)
        if output_format == "shell":
            print(f"{names[key]}={shlex.quote(rendered)}")
        else:
            print(f"{key}={rendered}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--base-ref")
    source.add_argument("--paths-file", type=pathlib.Path)
    parser.add_argument("--format", choices=("github", "json", "shell"), default="json")
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    try:
        paths = (
            paths_from_git(root, arguments.base_ref)
            if arguments.base_ref is not None
            else paths_from_file(arguments.paths_file)
        )
        emit(classify(paths), arguments.format)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"could not classify validation scope: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
