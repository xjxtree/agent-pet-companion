#!/usr/bin/env python3
"""Validate exact parity between the String Catalog and shipped .strings files."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


TOKEN = re.compile(
    r"(?P<space>\s+)"
    r"|(?P<block>/\*.*?\*/)"
    r"|(?P<line>//[^\n]*(?:\n|$))"
    r'|(?P<entry>"(?:\\.|[^"\\])*"\s*=\s*"(?:\\.|[^"\\])*"\s*;)',
    re.DOTALL,
)
ENTRY = re.compile(
    r'^(?P<key>"(?:\\.|[^"\\])*")\s*=\s*'
    r'(?P<value>"(?:\\.|[^"\\])*")\s*;$',
    re.DOTALL,
)


def decode_apple_string(token: str) -> str:
    # Apple .strings permits uppercase \Uhhhh escapes; JSON uses \uhhhh.
    normalized = re.sub(r"\\U([0-9A-Fa-f]{4})", r"\\u\1", token)
    try:
        value = json.loads(normalized)
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid quoted string {token!r}: {error.msg}") from error
    if not isinstance(value, str):
        raise ValueError(f"expected quoted string, received {token!r}")
    return value


def parse_strings(path: pathlib.Path) -> dict[str, str]:
    source = path.read_text(encoding="utf-8")
    entries: dict[str, str] = {}
    position = 0
    while position < len(source):
        match = TOKEN.match(source, position)
        if match is None:
            line = source.count("\n", 0, position) + 1
            excerpt = source[position : position + 80].splitlines()[0]
            raise ValueError(f"{path}:{line}: unsupported .strings syntax near {excerpt!r}")
        position = match.end()
        entry = match.group("entry")
        if entry is None:
            continue
        parsed = ENTRY.match(entry)
        if parsed is None:  # Defensive: TOKEN and ENTRY intentionally mirror one another.
            raise ValueError(f"{path}: could not parse localization entry {entry!r}")
        key = decode_apple_string(parsed.group("key"))
        value = decode_apple_string(parsed.group("value"))
        if key in entries:
            raise ValueError(f"{path}: duplicate localization key {key!r}")
        entries[key] = value
    return entries


def catalog_values(path: pathlib.Path, locale: str) -> dict[str, str]:
    with path.open(encoding="utf-8") as file:
        catalog = json.load(file)
    if catalog.get("sourceLanguage") != "en":
        raise ValueError(f"{path}: sourceLanguage must be 'en'")
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        raise ValueError(f"{path}: strings must be an object")

    values: dict[str, str] = {}
    for key, entry in strings.items():
        try:
            value = entry["localizations"][locale]["stringUnit"]["value"]
        except (KeyError, TypeError) as error:
            raise ValueError(f"{path}: {key!r} is missing the {locale!r} stringUnit value") from error
        if not isinstance(value, str):
            raise ValueError(f"{path}: {key!r} has a non-string {locale!r} value")
        values[key] = value
    return values


def compare(label: str, expected: dict[str, str], actual: dict[str, str]) -> list[str]:
    errors: list[str] = []
    missing = sorted(expected.keys() - actual.keys())
    extra = sorted(actual.keys() - expected.keys())
    if missing:
        errors.append(f"{label}: missing keys: {', '.join(missing)}")
    if extra:
        errors.append(f"{label}: unexpected keys: {', '.join(extra)}")
    for key in sorted(expected.keys() & actual.keys()):
        if expected[key] != actual[key]:
            errors.append(
                f"{label}: {key!r} differs: .strings={expected[key]!r}, catalog={actual[key]!r}"
            )
    return errors


def validate(root: pathlib.Path) -> list[str]:
    resources = root / "apps/macos/Sources/AgentPetCompanion/Resources"
    catalog_path = resources / "Localizable.xcstrings"
    english_path = resources / "en.lproj/Localizable.strings"
    chinese_path = resources / "zh-Hans.lproj/Localizable.strings"

    english = parse_strings(english_path)
    chinese = parse_strings(chinese_path)
    catalog_english = catalog_values(catalog_path, "en")
    catalog_chinese = catalog_values(catalog_path, "zh-Hans")

    errors = compare("English catalog parity", english, catalog_english)
    errors.extend(compare("Simplified Chinese catalog parity", chinese, catalog_chinese))
    if english.keys() != chinese.keys():
        missing_chinese = sorted(english.keys() - chinese.keys())
        missing_english = sorted(chinese.keys() - english.keys())
        if missing_chinese:
            errors.append(f"Simplified Chinese .strings missing keys: {', '.join(missing_chinese)}")
        if missing_english:
            errors.append(f"English .strings missing keys: {', '.join(missing_english)}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
        help="repository root (defaults to this script's parent repository)",
    )
    args = parser.parse_args()
    try:
        errors = validate(args.root.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    if errors:
        print("Localization source parity failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Localization String Catalog and .strings parity ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
