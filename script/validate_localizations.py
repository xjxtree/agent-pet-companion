#!/usr/bin/env python3
"""Validate feature-owned localization tables, typed keys, and locale parity."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


TABLE_KEY_FILES = {
    "Common": "apps/macos/Sources/AgentPetCompanion/App/LocalizationKeys/CommonLocalizationKeys.swift",
    "PetLibrary": "apps/macos/Sources/AgentPetCompanion/Features/PetLibrary/PetLibraryLocalizationKeys.swift",
    "Maker": "apps/macos/Sources/AgentPetCompanion/Features/Maker/MakerLocalizationKeys.swift",
    "Connections": "apps/macos/Sources/AgentPetCompanion/Features/Connections/ConnectionsLocalizationKeys.swift",
    "Overlay": "apps/macos/Sources/AgentPetCompanion/Overlay/OverlayLocalizationKeys.swift",
    "Settings": "apps/macos/Sources/AgentPetCompanion/Features/Settings/SettingsLocalizationKeys.swift",
    "Diagnostics": "apps/macos/Sources/AgentPetCompanion/Features/Diagnostics/DiagnosticsLocalizationKeys.swift",
}
TABLE_CASES = {
    "Common": "common",
    "PetLibrary": "petLibrary",
    "Maker": "maker",
    "Connections": "connections",
    "Overlay": "overlay",
    "Settings": "settings",
    "Diagnostics": "diagnostics",
}
TYPED_KEY = re.compile(
    r'^\s*static let [A-Za-z0-9_]+ = APCLocalizationKey\('
    r'"(?P<key>[^"]+)", table: \.(?P<table>[A-Za-z0-9_]+)\)\s*$',
    re.MULTILINE,
)


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


def typed_keys(path: pathlib.Path, table_case: str) -> set[str]:
    source = path.read_text(encoding="utf-8")
    keys: set[str] = set()
    for match in TYPED_KEY.finditer(source):
        if match.group("table") != table_case:
            raise ValueError(
                f"{path}: key {match.group('key')!r} declares the wrong table "
                f"{match.group('table')!r}"
            )
        key = match.group("key")
        if key in keys:
            raise ValueError(f"{path}: duplicate typed localization key {key!r}")
        keys.add(key)
    return keys


def validate(root: pathlib.Path) -> list[str]:
    resources = root / "apps/macos/Sources/AgentPetCompanion/Resources"
    localization = resources / "Localization"
    legacy = (
        resources / "Localizable.xcstrings",
        resources / "en.lproj",
        resources / "zh-Hans.lproj",
    )
    if any(path.exists() or path.is_symlink() for path in legacy):
        raise ValueError("legacy global localization resources must not coexist with feature tables")
    observed_tables = {
        path.name for path in localization.iterdir() if path.is_dir() and not path.is_symlink()
    }
    if observed_tables != set(TABLE_KEY_FILES):
        raise ValueError(
            "localization table inventory differs: "
            f"expected {sorted(TABLE_KEY_FILES)}, observed {sorted(observed_tables)}"
        )

    errors: list[str] = []
    all_keys: dict[str, str] = {}
    for table, relative_key_file in TABLE_KEY_FILES.items():
        directory = localization / table
        expected_files = {
            f"{table}.xcstrings",
            f"en.lproj/{table}.strings",
            f"zh-Hans.lproj/{table}.strings",
        }
        observed_files = {
            path.relative_to(directory).as_posix()
            for path in directory.rglob("*")
            if path.is_file() and not path.is_symlink()
        }
        if observed_files != expected_files:
            errors.append(
                f"{table}: resource inventory differs: expected {sorted(expected_files)}, "
                f"observed {sorted(observed_files)}"
            )
            continue
        catalog_path = directory / f"{table}.xcstrings"
        english = parse_strings(directory / f"en.lproj/{table}.strings")
        chinese = parse_strings(directory / f"zh-Hans.lproj/{table}.strings")
        catalog_english = catalog_values(catalog_path, "en")
        catalog_chinese = catalog_values(catalog_path, "zh-Hans")
        errors.extend(compare(f"{table} English catalog parity", english, catalog_english))
        errors.extend(
            compare(f"{table} Simplified Chinese catalog parity", chinese, catalog_chinese)
        )
        if english.keys() != chinese.keys():
            errors.append(f"{table}: English and Simplified Chinese key sets differ")
        typed = typed_keys(root / relative_key_file, TABLE_CASES[table])
        if typed != set(english):
            missing = sorted(set(english) - typed)
            extra = sorted(typed - set(english))
            errors.append(
                f"{table}: typed key inventory differs; missing={missing}, extra={extra}"
            )
        for key in english:
            previous = all_keys.get(key)
            if previous is not None:
                errors.append(f"localization key {key!r} is owned by both {previous} and {table}")
            all_keys[key] = table
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
    print("Feature localization tables, typed keys, and locale parity ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
