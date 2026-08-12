#!/usr/bin/env python3
"""Load and validate bounded development-domain and path-claim contracts."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shlex
import sys
from dataclasses import dataclass
from typing import Any, NoReturn


SCHEMA_VERSION = "apc.development-domains.v1"
DOMAIN_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
CI_FLAG = re.compile(r"[a-z][a-z0-9_]{0,63}")
MAX_DOMAINS = 32
MAX_PATTERNS = 256
MAX_COMMANDS = 32
DOMAIN_FIELDS = {
    "id",
    "owned_paths",
    "dependencies",
    "shared_paths",
    "durable_document",
    "focused_tests",
    "ci_flags",
    "allow_parallel_claims",
    "control_plane",
    "claims",
}


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def validate_relative_pattern(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 240:
        fail(f"{field} must be a bounded repository-relative path pattern")
    path = value[:-3] if value.endswith("/**") else value
    if (
        path.startswith("/")
        or path.endswith("/")
        or "\\" in path
        or "//" in path
        or any(part in {"", ".", ".."} for part in path.split("/"))
        or "*" in path
        or "?" in path
        or "[" in path
        or "{" in path
    ):
        fail(f"{field} contains an unsafe or unbounded pattern: {value!r}")
    return value


def pattern_prefix(pattern: str) -> tuple[str, bool]:
    return (pattern[:-3], True) if pattern.endswith("/**") else (pattern, False)


def path_matches(path: str, pattern: str) -> bool:
    normalized = validate_relative_pattern(path, field="changed path")
    prefix, recursive = pattern_prefix(pattern)
    return normalized == prefix or (recursive and normalized.startswith(prefix + "/"))


def patterns_overlap(first: str, second: str) -> bool:
    first_prefix, first_recursive = pattern_prefix(first)
    second_prefix, second_recursive = pattern_prefix(second)
    if first_prefix == second_prefix:
        return True
    if first_recursive and second_prefix.startswith(first_prefix + "/"):
        return True
    if second_recursive and first_prefix.startswith(second_prefix + "/"):
        return True
    return False


@dataclass(frozen=True)
class SharedPath:
    path: str
    risk: str


@dataclass(frozen=True)
class Claim:
    id: str
    paths: tuple[str, ...]


@dataclass(frozen=True)
class Domain:
    id: str
    owned_paths: tuple[str, ...]
    dependencies: tuple[str, ...]
    shared_paths: tuple[SharedPath, ...]
    durable_document: str
    focused_tests: tuple[tuple[str, ...], ...]
    ci_flags: dict[str, bool | str]
    allow_parallel_claims: bool
    control_plane: bool
    claims: tuple[Claim, ...]

    def claim(self, claim_id: str) -> Claim:
        matches = [claim for claim in self.claims if claim.id == claim_id]
        if len(matches) != 1:
            fail(f"unknown claim {claim_id!r} for domain {self.id!r}")
        return matches[0]

    def shared(self, pattern: str) -> SharedPath:
        matches = [item for item in self.shared_paths if item.path == pattern]
        if len(matches) != 1:
            fail(f"path {pattern!r} is not an approved shared path for {self.id!r}")
        return matches[0]


@dataclass(frozen=True)
class Manifest:
    path: pathlib.Path
    domains: tuple[Domain, ...]

    def domain(self, domain_id: str) -> Domain:
        matches = [domain for domain in self.domains if domain.id == domain_id]
        if len(matches) != 1:
            fail(f"unknown development domain: {domain_id!r}")
        return matches[0]


def string_list(value: Any, *, field: str, maximum: int = MAX_PATTERNS) -> tuple[str, ...]:
    if not isinstance(value, list) or len(value) > maximum:
        fail(f"{field} must be a bounded list")
    if any(not isinstance(item, str) for item in value):
        fail(f"{field} must contain strings")
    if len(value) != len(set(value)):
        fail(f"{field} contains duplicates")
    return tuple(value)


def parse_domain(payload: Any) -> Domain:
    if not isinstance(payload, dict) or set(payload) != DOMAIN_FIELDS:
        fail("development domain field inventory is invalid")
    domain_id = payload["id"]
    if not isinstance(domain_id, str) or DOMAIN_ID.fullmatch(domain_id) is None:
        fail("development domain id is invalid")
    owned = tuple(
        validate_relative_pattern(item, field=f"{domain_id}.owned_paths")
        for item in string_list(payload["owned_paths"], field=f"{domain_id}.owned_paths")
    )
    if not owned:
        fail(f"development domain {domain_id!r} owns no paths")
    dependencies = string_list(payload["dependencies"], field=f"{domain_id}.dependencies", maximum=MAX_DOMAINS)
    for dependency in dependencies:
        if DOMAIN_ID.fullmatch(dependency) is None or dependency == domain_id:
            fail(f"development domain {domain_id!r} has an invalid dependency")

    shared_payload = payload["shared_paths"]
    if not isinstance(shared_payload, list) or len(shared_payload) > MAX_PATTERNS:
        fail(f"{domain_id}.shared_paths must be a bounded list")
    shared: list[SharedPath] = []
    for item in shared_payload:
        if not isinstance(item, dict) or set(item) != {"path", "risk"}:
            fail(f"{domain_id}.shared_paths field inventory is invalid")
        risk = item["risk"]
        if risk not in {"amber", "red"}:
            fail(f"{domain_id}.shared_paths risk is invalid")
        shared.append(
            SharedPath(
                validate_relative_pattern(item["path"], field=f"{domain_id}.shared_paths"),
                risk,
            )
        )
    if len({item.path for item in shared}) != len(shared):
        fail(f"{domain_id}.shared_paths contains duplicate paths")

    document = validate_relative_pattern(payload["durable_document"], field=f"{domain_id}.durable_document")
    if not document.startswith("docs/") or not document.endswith(".md"):
        fail(f"{domain_id}.durable_document must name one Markdown document under docs/")

    tests_payload = payload["focused_tests"]
    if not isinstance(tests_payload, list) or not tests_payload or len(tests_payload) > MAX_COMMANDS:
        fail(f"{domain_id}.focused_tests must be a non-empty bounded command list")
    tests: list[tuple[str, ...]] = []
    for command in tests_payload:
        if (
            not isinstance(command, list)
            or not command
            or len(command) > 32
            or any(not isinstance(argument, str) or not argument or len(argument) > 240 for argument in command)
        ):
            fail(f"{domain_id}.focused_tests contains an invalid argv command")
        tests.append(tuple(command))

    flags = payload["ci_flags"]
    if not isinstance(flags, dict) or len(flags) > 32:
        fail(f"{domain_id}.ci_flags must be a bounded object")
    for key, value in flags.items():
        if CI_FLAG.fullmatch(key) is None or not isinstance(value, (bool, str)):
            fail(f"{domain_id}.ci_flags contains an invalid entry")

    claims_payload = payload["claims"]
    if not isinstance(claims_payload, list) or not claims_payload or len(claims_payload) > 64:
        fail(f"{domain_id}.claims must be a non-empty bounded list")
    claims: list[Claim] = []
    for item in claims_payload:
        if not isinstance(item, dict) or set(item) != {"id", "paths"}:
            fail(f"{domain_id}.claims field inventory is invalid")
        claim_id = item["id"]
        if not isinstance(claim_id, str) or DOMAIN_ID.fullmatch(claim_id) is None:
            fail(f"{domain_id}.claims contains an invalid id")
        paths = tuple(
            validate_relative_pattern(path, field=f"{domain_id}.{claim_id}.paths")
            for path in string_list(item["paths"], field=f"{domain_id}.{claim_id}.paths")
        )
        if not paths or any(not any(patterns_overlap(path, owner) for owner in owned) for path in paths):
            fail(f"claim {domain_id}/{claim_id} includes a path outside domain ownership")
        claims.append(Claim(claim_id, paths))
    if len({claim.id for claim in claims}) != len(claims):
        fail(f"{domain_id}.claims contains duplicate ids")

    if not isinstance(payload["allow_parallel_claims"], bool) or not isinstance(payload["control_plane"], bool):
        fail(f"{domain_id} boolean policy fields are invalid")
    return Domain(
        id=domain_id,
        owned_paths=owned,
        dependencies=dependencies,
        shared_paths=tuple(shared),
        durable_document=document,
        focused_tests=tuple(tests),
        ci_flags=dict(sorted(flags.items())),
        allow_parallel_claims=payload["allow_parallel_claims"],
        control_plane=payload["control_plane"],
        claims=tuple(claims),
    )


def load_manifest(root: pathlib.Path, path: pathlib.Path | None = None) -> Manifest:
    manifest_path = (path or root / "development/domains.json").resolve()
    metadata = manifest_path.lstat()
    if not manifest_path.is_file() or manifest_path.is_symlink() or metadata.st_size > 512 * 1024:
        fail("development-domain manifest must be a bounded regular file")
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or set(payload) != {"schema_version", "domains"}:
        fail("development-domain manifest field inventory is invalid")
    if payload["schema_version"] != SCHEMA_VERSION:
        fail("development-domain manifest schema is unsupported")
    domains_payload = payload["domains"]
    if not isinstance(domains_payload, list) or not domains_payload or len(domains_payload) > MAX_DOMAINS:
        fail("development-domain manifest must contain a bounded domain list")
    domains = tuple(parse_domain(item) for item in domains_payload)
    ids = [domain.id for domain in domains]
    if ids != sorted(ids) or len(ids) != len(set(ids)):
        fail("development domains must be unique and deterministically sorted")
    known = set(ids)
    for domain in domains:
        missing = sorted(set(domain.dependencies) - known)
        if missing:
            fail(f"development domain {domain.id!r} has unknown dependencies: {missing}")
    owners: list[tuple[str, str]] = []
    for domain in domains:
        for pattern in domain.owned_paths:
            for other_domain, other_pattern in owners:
                if patterns_overlap(pattern, other_pattern):
                    fail(
                        "duplicate development path ownership: "
                        f"{other_domain}:{other_pattern} overlaps {domain.id}:{pattern}"
                    )
            owners.append((domain.id, pattern))
    return Manifest(manifest_path, domains)


def command_text(command: tuple[str, ...]) -> str:
    return shlex.join(command)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--manifest", type=pathlib.Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    show = subparsers.add_parser("show")
    show.add_argument("--domain", required=True)
    show.add_argument("--claim")
    args = parser.parse_args()
    try:
        manifest = load_manifest(args.root.resolve(), args.manifest)
        if args.command == "validate":
            print(f"Validated {len(manifest.domains)} development domain(s)")
            return 0
        domain = manifest.domain(args.domain)
        claim = domain.claim(args.claim) if args.claim else None
        print(
            json.dumps(
                {
                    "id": domain.id,
                    "claim": claim.id if claim else None,
                    "paths": list(claim.paths if claim else domain.owned_paths),
                    "focused_tests": [command_text(command) for command in domain.focused_tests],
                    "ci_flags": domain.ci_flags,
                    "durable_document": domain.durable_document,
                },
                indent=2,
                sort_keys=True,
            )
        )
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"development-domains: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
