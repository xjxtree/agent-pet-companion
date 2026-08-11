#!/usr/bin/env python3
"""Create, validate, render, and consume parallel changelog fragments."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, NoReturn


SCHEMA_VERSION = "apc.changelog-fragment.v1"
CATEGORIES = ("Added", "Changed", "Fixed", "Deprecated", "Removed", "Security")
FRAGMENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}[.]json")
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

    def markdown(self) -> str:
        return f"- {self.summary_en}\n\n  {self.summary_zh}\n"


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


def fragments(root: pathlib.Path) -> list[Fragment]:
    directory = root / "changes/unreleased"
    if not directory.is_dir():
        fail("changes/unreleased directory is missing")
    return [parse_fragment(path) for path in sorted(directory.glob("*.json"))]


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

    create = subparsers.add_parser("create")
    create.add_argument("--id", required=True)
    create.add_argument("--kind", choices=CATEGORIES, required=True)
    create.add_argument("--scope", required=True)
    create.add_argument("--summary-en", required=True)
    create.add_argument("--summary-zh", required=True)
    create.add_argument("--apply", action="store_true")

    consume = subparsers.add_parser("consume")
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
    elif args.command == "consume":
        if not args.apply:
            print(render(items), end="")
            return 0
        if not items:
            print("Consumed 0 changelog fragment(s) into CHANGELOG.md")
            return 0
        changelog = root / "CHANGELOG.md"
        updated = insert_fragments(changelog.read_text(encoding="utf-8"), items)
        atomic_write(changelog, updated)
        for item in items:
            item.path.unlink()
        print(f"Consumed {len(items)} changelog fragment(s) into CHANGELOG.md")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"changelog-fragments: {error}", file=sys.stderr)
        raise SystemExit(1)
