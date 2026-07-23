#!/usr/bin/env python3
"""Bind one extracted App to one exact GitHub Release source identity."""

from __future__ import annotations

import argparse
import json
import pathlib
import plistlib
import re
import sys


def load_json_object(path: pathlib.Path) -> dict:
    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key {key!r}")
            result[key] = value
        return result

    with path.open(encoding="utf-8") as source:
        value = json.load(source, object_pairs_hook=reject_duplicates)
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value is not an object")
    return value


def validate(
    app: pathlib.Path,
    architecture: str,
    version: str,
    build: str,
    commit: str,
) -> str:
    expected_build_id = f"{version}.{build}.{commit}"
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    manifest = load_json_object(app / "Contents/Resources/runtime-manifest.json")

    expected_info = {
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "APCBuildID": expected_build_id,
        "APCReleaseChannel": "release",
        "APCRuntimeManifestSchemaVersion": "apc.runtime-manifest.v1",
    }
    for key, expected in expected_info.items():
        if info.get(key) != expected:
            raise ValueError(
                f"Info.plist {key}={info.get(key)!r}, expected {expected!r}"
            )

    expected_manifest = {
        "schema_version": "apc.runtime-manifest.v1",
        "release_channel": "release",
        "app_version": version,
        "app_build": build,
        "build_id": expected_build_id,
        "petcore_build_id": expected_build_id,
        "petcore_cli_build_id": expected_build_id,
    }
    for key, expected in expected_manifest.items():
        if manifest.get(key) != expected:
            raise ValueError(
                f"runtime manifest {key}={manifest.get(key)!r}, expected {expected!r}"
            )

    if architecture not in ("arm64", "x86_64"):
        raise ValueError(f"unsupported architecture {architecture!r}")
    return expected_build_id


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--architecture", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    arguments = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:[.][0-9]+){2}", arguments.version):
        parser.error("--version must be a three-component semantic version")
    if not re.fullmatch(r"[1-9][0-9]*", arguments.build):
        parser.error("--build must be a positive integer")
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.commit):
        parser.error("--commit must be a full lowercase Git commit")
    if not arguments.app.is_dir() or arguments.app.is_symlink():
        parser.error("--app must be a regular App bundle directory")
    try:
        build_id = validate(
            arguments.app,
            arguments.architecture,
            arguments.version,
            arguments.build,
            arguments.commit,
        )
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(f"release identity validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Release identity validation ok ({build_id}, {arguments.architecture})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
