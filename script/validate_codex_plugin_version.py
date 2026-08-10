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
HOOKS_TEMPLATE = pathlib.PurePosixPath("plugins/codex/hooks/hooks.json.tpl")
# Every App-managed Codex artifact states its own release version. Ownership and
# staleness are read from these markers, so no list of past release digests has
# to be maintained; a missing entry in such a list stranded real installs.
VERSIONED_SKILLS = (
    pathlib.PurePosixPath("skills/agent-pet-studio/SKILL.md"),
    pathlib.PurePosixPath("skills/agent-pet-maker/SKILL.md"),
)
HOOKS_VERSION_PLACEHOLDER = "__APC_CODEX_PLUGIN_VERSION__"
SKILL_VERSION_PATTERN = re.compile(r"^version:[ \t]*(\S+)[ \t]*$", re.MULTILINE)
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
    return read_base_file(commit, MANIFEST, description="Codex plugin manifest")


def read_base_file(
    commit: str,
    path: pathlib.PurePosixPath,
    *,
    description: str,
) -> bytes:
    result = git("show", f"{commit}:{path.as_posix()}", check=False)
    if result.returncode != 0:
        raise ValueError(f"base commit does not contain the {description}")
    return result.stdout


def skill_front_matter_version(data: bytes, *, source: str) -> tuple[int, int, int]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{source} Skill is not valid UTF-8") from error
    if not text.startswith("---\n"):
        raise ValueError(f"{source} Skill must start with YAML front matter")
    front_matter, separator, _ = text[4:].partition("\n---")
    if not separator:
        raise ValueError(f"{source} Skill front matter is not terminated")
    matches = SKILL_VERSION_PATTERN.findall(front_matter)
    if len(matches) != 1:
        raise ValueError(
            f"{source} Skill front matter must declare exactly one version: line"
        )
    return parse_version(matches[0], source=f"{source} Skill")


def hooks_template_declares_version(data: bytes, *, source: str) -> None:
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{source} hooks template is not valid UTF-8 JSON") from error
    if not isinstance(value, dict) or value.get("release_version") != HOOKS_VERSION_PLACEHOLDER:
        raise ValueError(
            f"{source} hooks template must carry "
            f'"release_version": "{HOOKS_VERSION_PLACEHOLDER}"'
        )


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

    # Ownership and staleness are read from each artifact's own version marker,
    # so every App-managed artifact must carry one and they must agree. A Skill
    # left at a stale marker would be reported as the wrong version forever.
    hooks_template_declares_version(
        (ROOT / HOOKS_TEMPLATE).read_bytes(),
        source="current",
    )
    for skill in VERSIONED_SKILLS:
        skill_version = skill_front_matter_version(
            (ROOT / skill).read_bytes(),
            source=skill.as_posix(),
        )
        if skill_version != current:
            raise ValueError(
                f"{skill.as_posix()} declares version "
                f"{'.'.join(map(str, skill_version))} but the Codex plugin ships "
                f"{'.'.join(map(str, current))}"
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
    print(f"Plugin, hooks, and both Skills declare version {current}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
