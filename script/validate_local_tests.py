#!/usr/bin/env python3
"""Plan and optionally run domain-focused local tests for changed paths."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shlex
import subprocess
import sys
from dataclasses import dataclass

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from development_domains import Domain, load_manifest, path_matches  # noqa: E402
from validation_scope import classify, paths_from_file  # noqa: E402


@dataclass(frozen=True)
class LocalTestPlan:
    paths: tuple[str, ...]
    domains: tuple[str, ...]
    fallback: bool
    reason: str
    commands: tuple[tuple[str, ...], ...]

    def as_dict(self) -> dict[str, object]:
        return {
            "paths": list(self.paths),
            "domains": list(self.domains),
            "fallback": self.fallback,
            "reason": self.reason,
            "commands": [shlex.join(command) for command in self.commands],
        }


def domain_covers(domain: Domain, path: str) -> bool:
    return any(
        path_matches(path, pattern)
        for pattern in [
            *domain.owned_paths,
            *(shared.path for shared in domain.shared_paths),
        ]
    )


def append_unique(commands: list[tuple[str, ...]], command: tuple[str, ...]) -> None:
    if command not in commands:
        commands.append(command)


def local_paths_from_git(root: pathlib.Path, base_ref: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", base_ref, "--"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return [
        os.fsdecode(item)
        for item in result.stdout.split(b"\0") + untracked.stdout.split(b"\0")
        if item
    ]


def conservative_commands(root: pathlib.Path, paths: list[str]) -> list[tuple[str, ...]]:
    scope = classify(paths)
    commands: list[tuple[str, ...]] = []
    if scope.localization:
        append_unique(commands, ("./script/validate_localizations.py",))
    if scope.scripts:
        append_unique(commands, ("python3", "script/tests/test_validation_tooling.py"))
        append_unique(commands, ("./script/validate_build_scripts_safety.sh", "--static-only"))
    if scope.rust_mode != "none":
        for shard in ("core", "integration-a", "integration-b", "integration-c", "integration-d"):
            append_unique(
                commands,
                ("./script/validate_rust_test_shards.py", "--shard", shard),
            )
    if scope.swift_mode != "none":
        swift_scope = "overlay" if scope.swift_mode == "overlay" else "all"
        append_unique(commands, ("./script/validate_swift_tests.sh", "--scope", swift_scope))
    if scope.schemas:
        append_unique(commands, ("./script/validate_schema_fixtures.sh",))
        append_unique(commands, ("./script/validate_petpack_spec_schemas.sh",))
    if scope.producer:
        append_unique(commands, ("./script/validate_pet_skills.sh",))
        append_unique(commands, ("./script/validate_portable_pet_maker.sh",))
    if scope.connectors:
        append_unique(commands, ("./script/validate_connectors_runtime.sh",))
    return commands


def plan(
    root: pathlib.Path,
    paths: list[str],
    *,
    explicit_domain: str | None = None,
) -> LocalTestPlan:
    normalized = sorted({path.strip("/") for path in paths if path.strip("/")})
    if not normalized:
        return LocalTestPlan((), (), False, "no changes", ())
    scope = classify(normalized)
    if scope.docs_only:
        return LocalTestPlan(tuple(normalized), (), False, "documentation-only", ())

    manifest = load_manifest(root)
    candidates = [
        domain
        for domain in manifest.domains
        if not domain.control_plane
        and normalized
        and all(domain_covers(domain, path) for path in normalized)
    ]
    if explicit_domain is not None:
        selected = manifest.domain(explicit_domain)
        outside = [path for path in normalized if not domain_covers(selected, path)]
        if outside:
            raise ValueError(
                f"explicit domain {selected.id!r} does not cover changed paths: {outside}"
            )
        candidates = [selected]

    commands: list[tuple[str, ...]] = []
    if len(candidates) == 1:
        domain = candidates[0]
        for command in domain.focused_tests:
            append_unique(commands, command)
        if scope.localization:
            append_unique(commands, ("./script/validate_localizations.py",))
        return LocalTestPlan(
            tuple(normalized),
            (domain.id,),
            False,
            "single-domain focused validation",
            tuple(commands),
        )

    commands = conservative_commands(root, normalized)
    reason = "unknown path classification" if not candidates else "shared or overlapping domain surface"
    return LocalTestPlan(
        tuple(normalized),
        tuple(domain.id for domain in candidates),
        True,
        reason,
        tuple(commands),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--base-ref")
    source.add_argument("--paths-file", type=pathlib.Path)
    parser.add_argument("--domain")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        paths = (
            local_paths_from_git(root, args.base_ref)
            if args.base_ref is not None
            else paths_from_file(args.paths_file)
        )
        selected = plan(root, paths, explicit_domain=args.domain)
        print(json.dumps(selected.as_dict(), indent=2, sort_keys=True))
        if args.plan_only or not selected.commands:
            if not selected.commands:
                print(f"No local tests required: {selected.reason}.")
            return 0
        for command in selected.commands:
            subprocess.run(command, cwd=root, check=True)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"local tests: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
