#!/usr/bin/env python3
"""Require a Codex plugin version bump whenever its shipped bundle changes."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = pathlib.PurePosixPath("plugins/codex/.codex-plugin/plugin.json")
PLUGIN_BUNDLE_PATHS = (
    "plugins/codex",
    "skills/agent-pet-maker",
    "skills/agent-pet-studio",
)
SEMVER_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)"
)


def parse_version(value: Any, *, source: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        raise ValueError(f"{source} plugin version must be a string")
    match = SEMVER_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError(f"{source} plugin version must be strict X.Y.Z SemVer")
    return tuple(int(component) for component in match.groups())


def load_manifest_bytes(data: bytes, *, source: str) -> tuple[int, int, int]:
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{source} plugin manifest is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise ValueError(f"{source} plugin manifest must be a JSON object")
    if value.get("name") != "agent-pet-companion":
        raise ValueError(f"{source} plugin manifest has the wrong plugin name")
    if value.get("hooks") != "./hooks/hooks.json":
        raise ValueError(f"{source} plugin manifest must expose the bundled hooks file")
    if value.get("skills") != "./skills/":
        raise ValueError(f"{source} plugin manifest must expose only the bundled skills root")
    return parse_version(value.get("version"), source=source)


def git(*arguments: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def resolve_commit(reference: str) -> str:
    if not reference or reference.startswith("-") or any(
        character in reference for character in "\r\n\0"
    ):
        raise ValueError("--base-ref must be a non-option, single-line Git reference")
    result = git("rev-parse", "--verify", f"{reference}^{{commit}}")
    commit = result.stdout.decode("ascii").strip()
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("--base-ref did not resolve to one full Git commit")
    return commit


def read_base_manifest(commit: str) -> bytes:
    result = git("show", f"{commit}:{MANIFEST.as_posix()}", check=False)
    if result.returncode != 0:
        raise ValueError("base commit does not contain the Codex plugin manifest")
    return result.stdout


def bundle_changed(commit: str) -> bool:
    result = git(
        "diff",
        "--quiet",
        commit,
        "--",
        *PLUGIN_BUNDLE_PATHS,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise ValueError("Git could not compare the Codex plugin bundle")
    return result.returncode == 1


def validate(base_reference: str) -> tuple[str, str, bool]:
    current_path = ROOT / MANIFEST
    current = load_manifest_bytes(current_path.read_bytes(), source="current")
    commit = resolve_commit(base_reference)
    previous = load_manifest_bytes(read_base_manifest(commit), source="base")
    changed = bundle_changed(commit)

    if current < previous:
        raise ValueError(
            "Codex plugin version must never decrease "
            f"({'.'.join(map(str, previous))} -> {'.'.join(map(str, current))})"
        )
    if changed and current <= previous:
        raise ValueError(
            "Codex plugin, agent-pet-maker, or agent-pet-studio content changed "
            "without increasing plugins/codex/.codex-plugin/plugin.json version"
        )
    return (
        ".".join(map(str, previous)),
        ".".join(map(str, current)),
        changed,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-ref", required=True)
    arguments = parser.parse_args()
    try:
        previous, current, changed = validate(arguments.base_ref)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Codex plugin version validation failed: {error}", file=sys.stderr)
        return 1
    state = "changed with a required version increase" if changed else "unchanged"
    print(f"Codex plugin bundle {state}: {previous} -> {current}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
