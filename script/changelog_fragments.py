#!/usr/bin/env python3
"""Create, validate, render, and consume parallel changelog fragments."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, NoReturn


SCHEMA_VERSION = "apc.changelog-fragment.v1"
POLICY_BOOLEAN_VALUES = {"true": True, "false": False, "1": True, "0": False}
CATEGORIES = ("Added", "Changed", "Fixed", "Deprecated", "Removed", "Security")
FRAGMENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}[.]json")
FRAGMENT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
FRAGMENT_MARKER = re.compile(r"<!--[ ]apc-fragment:([A-Za-z0-9][A-Za-z0-9._-]{0,79})[ ]-->")
VERSION = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")
RELEASE_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
SCOPE = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
HEADINGS = {
    "Added": "### Added / 新增",
    "Changed": "### Changed / 变更",
    "Fixed": "### Fixed / 修复",
    "Deprecated": "### Deprecated / 弃用",
    "Removed": "### Removed / 移除",
    "Security": "### Security / 安全",
}


def fail(message: str) -> NoReturn:
    raise ValueError(message)


@dataclass(frozen=True)
class Fragment:
    path: pathlib.Path
    kind: str
    scope: str
    summary_en: str
    summary_zh: str

    @property
    def id(self) -> str:
        return self.path.stem

    def markdown(self) -> str:
        return (
            f"<!-- apc-fragment:{self.id} -->\n"
            f"- {self.summary_en}\n\n  {self.summary_zh}\n"
        )


def bounded_sentence(value: Any, field: str) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or value != value.strip()
        or "\n" in value
        or len(value) > 1200
    ):
        fail(f"fragment {field} must be one bounded non-empty paragraph")
    return value


def parse_fragment(path: pathlib.Path) -> Fragment:
    if FRAGMENT_NAME.fullmatch(path.name) is None:
        fail(f"invalid changelog fragment filename: {path.name}")
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_size > 16 * 1024:
        fail(f"changelog fragment must be a bounded regular file: {path.name}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or set(payload) != {
        "schema_version",
        "kind",
        "scope",
        "summary_en",
        "summary_zh",
    }:
        fail(f"changelog fragment field inventory is invalid: {path.name}")
    if payload["schema_version"] != SCHEMA_VERSION:
        fail(f"changelog fragment schema is unsupported: {path.name}")
    if payload["kind"] not in CATEGORIES:
        fail(f"changelog fragment kind is invalid: {path.name}")
    if not isinstance(payload["scope"], str) or SCOPE.fullmatch(payload["scope"]) is None:
        fail(f"changelog fragment scope is invalid: {path.name}")
    return Fragment(
        path=path,
        kind=payload["kind"],
        scope=payload["scope"],
        summary_en=bounded_sentence(payload["summary_en"], "summary_en"),
        summary_zh=bounded_sentence(payload["summary_zh"], "summary_zh"),
    )


def consumed_fragment_ids(root: pathlib.Path) -> set[str]:
    changelog = root / "CHANGELOG.md"
    if not changelog.is_file() or changelog.is_symlink() or changelog.stat().st_size > 4 * 1024 * 1024:
        fail("CHANGELOG.md must be a bounded regular file")
    ids = FRAGMENT_MARKER.findall(changelog.read_text(encoding="utf-8"))
    if len(ids) != len(set(ids)):
        fail("CHANGELOG.md contains duplicate changelog fragment ids")
    return set(ids)


def fragments(root: pathlib.Path) -> list[Fragment]:
    directory = root / "changes/unreleased"
    if not directory.is_dir():
        fail("changes/unreleased directory is missing")
    items = [parse_fragment(path) for path in sorted(directory.glob("*.json"))]
    consumed = consumed_fragment_ids(root)
    duplicate = sorted(item.id for item in items if item.id in consumed)
    if duplicate:
        fail("changelog fragment id was already consumed: " + ", ".join(duplicate))
    return items


def render(items: list[Fragment]) -> str:
    blocks = []
    for kind in CATEGORIES:
        group = [item for item in items if item.kind == kind]
        if not group:
            continue
        body = "\n".join(item.markdown().rstrip() for item in group)
        blocks.append(f"{HEADINGS[kind]}\n\n{body}")
    return "\n\n".join(blocks) + ("\n" if blocks else "")


def insert_fragments(changelog: str, items: list[Fragment]) -> str:
    unreleased = changelog.find("## [Unreleased]")
    if unreleased < 0:
        fail("CHANGELOG is missing [Unreleased]")
    next_version = changelog.find("\n## [", unreleased + len("## [Unreleased]"))
    if next_version < 0:
        next_version = len(changelog)
    section = changelog[unreleased:next_version]
    for item in items:
        if item.summary_en in section or item.summary_zh in section:
            fail(f"fragment is already present in CHANGELOG: {item.path.name}")

    grouped: dict[str, list[Fragment]] = {kind: [] for kind in CATEGORIES}
    for item in items:
        grouped[item.kind].append(item)

    for kind in CATEGORIES:
        group = grouped[kind]
        if not group:
            continue
        heading = HEADINGS[kind]
        heading_at = section.find(heading)
        addition = "\n".join(item.markdown().rstrip() for item in group)
        if heading_at < 0:
            section = section.rstrip() + f"\n\n{heading}\n\n{addition}\n"
            continue
        body_start = heading_at + len(heading)
        next_heading = section.find("\n### ", body_start)
        body_end = len(section) if next_heading < 0 else next_heading
        before = section[:body_end].rstrip()
        after = section[body_end:]
        section = before + f"\n\n{addition}\n" + after

    return changelog[:unreleased] + section.rstrip() + "\n" + changelog[next_version:]


def freeze_release(changelog: str, version: str, release_date: str) -> str:
    if VERSION.fullmatch(version) is None:
        fail("release version must be semantic X.Y.Z")
    if RELEASE_DATE.fullmatch(release_date) is None:
        fail("release date must be YYYY-MM-DD")
    if f"## [{version}] - " in changelog:
        fail(f"CHANGELOG already contains release version {version}")
    heading = "## [Unreleased]"
    start = changelog.find(heading)
    if start < 0:
        fail("CHANGELOG is missing [Unreleased]")
    body_start = start + len(heading)
    next_version = changelog.find("\n## [", body_start)
    if next_version < 0:
        next_version = len(changelog)
    body = changelog[body_start:next_version].strip()
    if not body:
        fail("release preparation cannot freeze an empty [Unreleased] section")
    released = f"## [{version}] - {release_date}\n\n{body}"
    return (
        changelog[:start]
        + "## [Unreleased]\n\n"
        + released
        + changelog[next_version:]
    )


def git_changed_paths(root: pathlib.Path, base_ref: str) -> set[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", base_ref, "HEAD", "--"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return {
        os.fsdecode(item)
        for item in result.stdout.split(b"\0")
        if item
    }


def validate_pr_policy(
    root: pathlib.Path,
    *,
    base_ref: str,
    release_preparation: bool,
) -> None:
    items = fragments(root)
    changed = git_changed_paths(root, base_ref)
    root_changed = "CHANGELOG.md" in changed
    fragment_changes = sorted(
        path for path in changed if path.startswith("changes/unreleased/") and path.endswith(".json")
    )
    deleted_fragments = []
    if fragment_changes:
        result = subprocess.run(
            ["git", "diff", "--name-status", "-z", base_ref, "HEAD", "--", "changes/unreleased"],
            cwd=root,
            check=True,
            capture_output=True,
        )
        fields = [os.fsdecode(item) for item in result.stdout.split(b"\0") if item]
        deleted_fragments = [fields[index + 1] for index in range(0, len(fields) - 1, 2) if fields[index].startswith("D")]

    if release_preparation:
        if not root_changed:
            fail("release preparation must update CHANGELOG.md")
        if items:
            fail("release preparation must consume every unreleased fragment")
        version_sections = re.findall(
            r"^## \[([0-9]+[.][0-9]+[.][0-9]+)\] - ([0-9]{4}-[0-9]{2}-[0-9]{2})$",
            (root / "CHANGELOG.md").read_text(encoding="utf-8"),
            flags=re.MULTILINE,
        )
        if not version_sections:
            fail("release preparation must contain one versioned changelog section")
        return

    if root_changed:
        fail(
            "ordinary development PRs must not edit CHANGELOG.md; create a fragment with "
            "./script/changelog_fragments.py create ... --apply"
        )
    if deleted_fragments:
        fail("only a release preparation PR may consume changelog fragments")


def atomic_write(path: pathlib.Path, content: str) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")
    subparsers.add_parser("render")
    subparsers.add_parser("require-consumed")

    policy = subparsers.add_parser("policy")
    policy.add_argument("--base-ref", required=True)
    policy.add_argument(
        "--release-preparation",
        choices=tuple(POLICY_BOOLEAN_VALUES),
        required=True,
    )

    create = subparsers.add_parser("create")
    create.add_argument("--id", required=True)
    create.add_argument("--kind", choices=CATEGORIES, required=True)
    create.add_argument("--scope", required=True)
    create.add_argument("--summary-en", required=True)
    create.add_argument("--summary-zh", required=True)
    create.add_argument("--apply", action="store_true")

    consume = subparsers.add_parser("consume")
    consume.add_argument("--release-preparation", action="store_true")
    consume.add_argument("--version")
    consume.add_argument("--date")
    consume.add_argument("--apply", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    if args.command == "create":
        if FRAGMENT_NAME.fullmatch(f"{args.id}.json") is None:
            fail("fragment id is invalid")
        bounded_sentence(args.summary_en, "summary_en")
        bounded_sentence(args.summary_zh, "summary_zh")
        if SCOPE.fullmatch(args.scope) is None:
            fail("fragment scope is invalid")
        payload = {
            "schema_version": SCHEMA_VERSION,
            "kind": args.kind,
            "scope": args.scope,
            "summary_en": args.summary_en,
            "summary_zh": args.summary_zh,
        }
        target = root / "changes/unreleased" / f"{args.id}.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        if not args.apply:
            print(json.dumps({"apply": False, "path": str(target), "content": payload}, indent=2))
            return 0
        if target.exists():
            fail(f"fragment already exists: {target.name}")
        if args.id in consumed_fragment_ids(root):
            fail(f"fragment id was already consumed: {args.id}")
        atomic_write(target, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        parse_fragment(target)
        print(target)
        return 0

    items = fragments(root)
    if args.command == "validate":
        print(f"Validated {len(items)} changelog fragment(s)")
    elif args.command == "render":
        print(render(items), end="")
    elif args.command == "require-consumed":
        if items:
            fail("main-bound changes must consume all changelog fragments: " + ", ".join(item.path.name for item in items))
    elif args.command == "policy":
        validate_pr_policy(
            root,
            base_ref=args.base_ref,
            release_preparation=POLICY_BOOLEAN_VALUES[args.release_preparation],
        )
        print("Changelog PR policy ok")
    elif args.command == "consume":
        if not args.release_preparation:
            fail("consume is restricted to an explicit release preparation")
        if not args.version or not args.date:
            fail("release preparation consume requires --version and --date")
        if not args.apply:
            print(render(items), end="")
            return 0
        changelog = root / "CHANGELOG.md"
        updated = insert_fragments(changelog.read_text(encoding="utf-8"), items)
        updated = freeze_release(updated, args.version, args.date)
        atomic_write(changelog, updated)
        for item in items:
            item.path.unlink()
        print(
            f"Consumed {len(items)} changelog fragment(s) into "
            f"CHANGELOG.md release {args.version}"
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"changelog-fragments: {error}", file=sys.stderr)
        raise SystemExit(1)
