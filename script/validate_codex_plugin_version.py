#!/usr/bin/env python3
"""Require a Codex plugin version bump whenever its shipped bundle changes."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = pathlib.PurePosixPath("plugins/codex/.codex-plugin/plugin.json")
STUDIO_SKILL = pathlib.PurePosixPath("skills/agent-pet-studio/SKILL.md")
STUDIO_SKILL_HISTORY = pathlib.PurePosixPath(
    "crates/petcore/resources/codex-studio-skill-history.json"
)
RETIRED_V1_STUDIO_SKILL = pathlib.PurePosixPath(
    "crates/petcore/tests/fixtures/retired-agent-pet-studio-v1.md"
)
STUDIO_SKILL_HISTORY_SCHEMA = "apc.codex-studio-skill-history.v1"
# The App-managed 0.4.6 development bundle reached local installations before
# its Studio Skill revision was represented by a Git release baseline. Keep the
# exception exact so release validation can recover those installations without
# accepting arbitrary historical content.
RECOVERED_APP_MANAGED_STUDIO_SHA256 = frozenset(
    {
        "5150ab91ba5f14567f0a2be0b6053688dffcd564e665a3e281fd5a110f8e852d",
        "5611d90ef3aa0b94682915df0135b2b3cae2b3b23360e80625f0bf2a5fc8bafa",
    }
)
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


def read_optional_base_file(
    commit: str,
    path: pathlib.PurePosixPath,
) -> bytes | None:
    result = git("show", f"{commit}:{path.as_posix()}", check=False)
    return result.stdout if result.returncode == 0 else None


def load_studio_skill_history(data: bytes, *, source: str) -> frozenset[str]:
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(
            f"{source} Studio Skill history is not valid UTF-8 JSON"
        ) from error
    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "retired_sha256",
    }:
        raise ValueError(
            f"{source} Studio Skill history must contain only schema_version "
            "and retired_sha256"
        )
    if value.get("schema_version") != STUDIO_SKILL_HISTORY_SCHEMA:
        raise ValueError(f"{source} Studio Skill history has the wrong schema")
    retired = value.get("retired_sha256")
    if not isinstance(retired, list) or not retired:
        raise ValueError(
            f"{source} Studio Skill history must contain retired SHA-256 values"
        )
    if any(
        not isinstance(digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        for digest in retired
    ):
        raise ValueError(
            f"{source} Studio Skill history contains an invalid SHA-256"
        )
    if retired != sorted(set(retired)):
        raise ValueError(
            f"{source} Studio Skill history must be sorted and unique"
        )
    return frozenset(retired)


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


def validate(base_reference: str) -> tuple[str, str, bool, bool]:
    current_path = ROOT / MANIFEST
    current = load_manifest_bytes(current_path.read_bytes(), source="current")
    commit = resolve_commit(base_reference)
    previous = load_manifest_bytes(read_base_manifest(commit), source="base")
    changed = bundle_changed(commit)
    current_studio = (ROOT / STUDIO_SKILL).read_bytes()
    base_studio = read_base_file(
        commit,
        STUDIO_SKILL,
        description="agent-pet-studio Skill",
    )
    studio_changed = current_studio != base_studio
    current_studio_digest = hashlib.sha256(current_studio).hexdigest()
    base_studio_digest = hashlib.sha256(base_studio).hexdigest()
    current_history = load_studio_skill_history(
        (ROOT / STUDIO_SKILL_HISTORY).read_bytes(),
        source="current",
    )
    base_history_bytes = read_optional_base_file(commit, STUDIO_SKILL_HISTORY)
    base_history = (
        load_studio_skill_history(base_history_bytes, source="base")
        if base_history_bytes is not None
        else None
    )

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
    if current_studio_digest in current_history:
        raise ValueError(
            "current agent-pet-studio Skill SHA-256 must not be listed as retired"
        )
    if base_history is not None:
        removed = base_history - current_history
        if removed:
            raise ValueError(
                "Studio Skill history is append-only; retired SHA-256 values were removed: "
                + ", ".join(sorted(removed))
            )
        permitted_additions = set(RECOVERED_APP_MANAGED_STUDIO_SHA256)
        if studio_changed:
            permitted_additions.add(base_studio_digest)
        unexpected = (current_history - base_history) - permitted_additions
        if unexpected:
            raise ValueError(
                "Studio Skill history added SHA-256 values that are not the previous "
                "shipped Skill or a reviewed App-managed recovery digest: "
                + ", ".join(sorted(unexpected))
            )
    else:
        retired_v1_digest = hashlib.sha256(
            (ROOT / RETIRED_V1_STUDIO_SKILL).read_bytes()
        ).hexdigest()
        expected_bootstrap = {
            retired_v1_digest,
            *RECOVERED_APP_MANAGED_STUDIO_SHA256,
        }
        if studio_changed:
            expected_bootstrap.add(base_studio_digest)
        if current_history != expected_bootstrap:
            raise ValueError(
                "initial Studio Skill history must contain exactly the retired V1 "
                "Skill and, when Studio changed, the previous shipped Skill"
            )
    if studio_changed and base_studio_digest not in current_history:
        raise ValueError(
            "agent-pet-studio changed without preserving the previous shipped Skill "
            f"SHA-256 {base_studio_digest} in {STUDIO_SKILL_HISTORY.as_posix()}"
        )
    return (
        ".".join(map(str, previous)),
        ".".join(map(str, current)),
        changed,
        studio_changed,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-ref", required=True)
    arguments = parser.parse_args()
    try:
        previous, current, changed, studio_changed = validate(arguments.base_ref)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Codex plugin version validation failed: {error}", file=sys.stderr)
        return 1
    state = "changed with a required version increase" if changed else "unchanged"
    print(f"Codex plugin bundle {state}: {previous} -> {current}")
    if studio_changed:
        print("Previous shipped Studio Skill ownership digest is preserved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
