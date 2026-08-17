#!/usr/bin/env python3
"""Reject calendar-dependent Rust fixtures that cross real retention clocks."""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re
from collections.abc import Iterable


RETENTION_API_RE = re.compile(
    r"\b(?:insert_event|upsert_codex_activity_event|prune_events)\s*\("
)
LOCAL_CALL_RE = re.compile(r"(?<![.:])\b([A-Za-z_][A-Za-z0-9_]*)\s*!?\s*\(")
FUNCTION_RE = re.compile(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\b")
RFC3339_RE = re.compile(
    r"\b[12][0-9]{3}-[01][0-9]-[0-3][0-9][Tt]"
    r"[0-2][0-9]:[0-5][0-9]:[0-6][0-9](?:\.[0-9]+)?"
    r"(?:[Zz]|[+-][0-2][0-9]:[0-5][0-9])\b"
)


@dataclasses.dataclass(frozen=True)
class RustFunction:
    name: str
    start: int
    body_start: int
    end: int


@dataclasses.dataclass(frozen=True)
class StringLiteral:
    start: int
    end: int


@dataclasses.dataclass(frozen=True)
class Violation:
    path: pathlib.Path
    line: int
    function: str
    timestamp: str


def _blank(mask: list[str], source: str, start: int, end: int) -> None:
    for index in range(start, end):
        if source[index] != "\n":
            mask[index] = " "


def _rust_code_and_strings(source: str) -> tuple[str, list[StringLiteral]]:
    """Return a position-preserving code mask and Rust string spans.

    Comments, strings, and character literals are blanked in the code mask so
    braces and call names inside fixture data cannot affect the function walk.
    """

    mask = list(source)
    strings: list[StringLiteral] = []
    index = 0
    length = len(source)
    while index < length:
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            if end < 0:
                end = length
            _blank(mask, source, index, end)
            index = end
            continue
        if source.startswith("/*", index):
            depth = 1
            end = index + 2
            while end < length and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            _blank(mask, source, index, end)
            index = end
            continue

        raw_prefix = None
        if source.startswith("br", index):
            raw_prefix = index + 1
        elif source[index] == "r":
            raw_prefix = index
        if raw_prefix is not None and (
            index == 0 or not (source[index - 1].isalnum() or source[index - 1] == "_")
        ):
            cursor = raw_prefix + 1
            while cursor < length and source[cursor] == "#":
                cursor += 1
            if cursor < length and source[cursor] == '"':
                hashes = source[raw_prefix + 1 : cursor]
                terminator = '"' + hashes
                end_marker = source.find(terminator, cursor + 1)
                end = length if end_marker < 0 else end_marker + len(terminator)
                strings.append(StringLiteral(index, end))
                _blank(mask, source, index, end)
                index = end
                continue

        if source[index] == '"':
            end = index + 1
            escaped = False
            while end < length:
                character = source[end]
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    end += 1
                    break
                end += 1
            strings.append(StringLiteral(index, end))
            _blank(mask, source, index, end)
            index = end
            continue

        if source[index] == "'":
            # Mask character literals but leave lifetimes such as `'a` intact.
            char_match = re.match(r"'(?:\\.|[^\\'\n])'", source[index:])
            if char_match:
                end = index + char_match.end()
                _blank(mask, source, index, end)
                index = end
                continue
        index += 1
    return "".join(mask), strings


def _matching_brace(code: str, opening: int) -> int | None:
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _rust_functions(code: str) -> list[RustFunction]:
    functions: list[RustFunction] = []
    for match in FUNCTION_RE.finditer(code):
        opening = code.find("{", match.end())
        terminator = code.find(";", match.end())
        if opening < 0 or (terminator >= 0 and terminator < opening):
            continue
        end = _matching_brace(code, opening)
        if end is None:
            continue
        functions.append(RustFunction(match.group(1), match.start(), opening + 1, end))
    return functions


def violations_in_source(path: pathlib.Path, source: str) -> list[Violation]:
    code, strings = _rust_code_and_strings(source)
    functions = _rust_functions(code)
    by_name: dict[str, list[int]] = {}
    for index, function in enumerate(functions):
        by_name.setdefault(function.name, []).append(index)

    marked = {
        index
        for index, function in enumerate(functions)
        if RETENTION_API_RE.search(code[function.body_start : function.end])
    }
    pending = list(marked)
    while pending:
        function_index = pending.pop()
        function = functions[function_index]
        body = code[function.body_start : function.end]
        for call in LOCAL_CALL_RE.finditer(body):
            for callee_index in by_name.get(call.group(1), []):
                if callee_index not in marked:
                    marked.add(callee_index)
                    pending.append(callee_index)

    violations: dict[tuple[int, str], Violation] = {}
    for literal in strings:
        literal_source = source[literal.start : literal.end]
        timestamp_match = RFC3339_RE.search(literal_source)
        if timestamp_match is None:
            continue
        owners = [
            functions[index]
            for index in marked
            if functions[index].start <= literal.start < functions[index].end
        ]
        if not owners:
            continue
        owner = min(owners, key=lambda function: function.end - function.start)
        timestamp_start = literal.start + timestamp_match.start()
        line = source.count("\n", 0, timestamp_start) + 1
        violation = Violation(
            path=path,
            line=line,
            function=owner.name,
            timestamp=timestamp_match.group(0),
        )
        violations[(line, violation.timestamp)] = violation
    return sorted(violations.values(), key=lambda item: (item.line, item.timestamp))


def scan(root: pathlib.Path, paths: Iterable[pathlib.Path] | None = None) -> list[Violation]:
    candidates = paths
    if candidates is None:
        candidates = sorted((root / "crates").rglob("*.rs"))
    violations: list[Violation] = []
    for path in candidates:
        source = path.read_text(encoding="utf-8")
        violations.extend(violations_in_source(path.relative_to(root), source))
    return violations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    violations = scan(root)
    if violations:
        details = "\n".join(
            f"{item.path}:{item.line}: {item.function} embeds {item.timestamp}"
            for item in violations
        )
        raise SystemExit(
            "retention-sensitive Rust fixtures must derive one current-time base and use "
            "relative offsets; fixed RFC3339 dates become calendar time bombs:\n" + details
        )
    print("Retention-sensitive Rust test fixtures are time-independent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
