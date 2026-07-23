#!/usr/bin/env python3
"""Validate the exact five-file public release inventory before extraction."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys


ARCHITECTURES = ("arm64", "x86_64")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_names(version: str) -> tuple[list[str], str]:
    data_names: list[str] = []
    for architecture in ARCHITECTURES:
        data_names.extend(
            (
                f"AgentPetCompanion-{version}-macos-{architecture}.zip",
                f"AgentPetCompanion-{version}-macos-{architecture}-distribution.json",
            )
        )
    return data_names, f"AgentPetCompanion-{version}-SHA256SUMS.txt"


def validate(directory: pathlib.Path, version: str) -> None:
    data_names, checksum_name = expected_names(version)
    expected = set(data_names) | {checksum_name}
    actual: set[str] = set()
    for item in directory.iterdir():
        if item.is_symlink() or not item.is_file():
            raise ValueError(f"artifact inventory contains a non-regular file: {item.name!r}")
        actual.add(item.name)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValueError(
            f"artifact inventory must contain exactly five files; missing={missing}, extra={extra}"
        )

    checksum_path = directory / checksum_name
    if checksum_path.stat().st_size > 16 * 1024:
        raise ValueError("checksum file exceeds its size bound")
    for name in data_names:
        if name.endswith("-distribution.json") and (directory / name).stat().st_size > 128 * 1024:
            raise ValueError(f"distribution evidence exceeds its size bound: {name}")
    lines = checksum_path.read_text(encoding="ascii").splitlines()
    if len(lines) != 4 or any(not line for line in lines):
        raise ValueError("checksum inventory must contain exactly four data-asset lines")
    parsed: dict[str, str] = {}
    pattern = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$")
    for line in lines:
        match = pattern.fullmatch(line)
        if match is None:
            raise ValueError("checksum inventory contains a malformed line")
        digest, name = match.groups()
        if name in parsed:
            raise ValueError("checksum inventory contains a duplicate filename")
        parsed[name] = digest
    if set(parsed) != set(data_names):
        raise ValueError(
            "checksum inventory must cover only the two ZIPs and two evidence files"
        )
    for name in data_names:
        if sha256(directory / name) != parsed[name]:
            raise ValueError(f"checksum mismatch: {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:[.][0-9]+){2}", arguments.version):
        parser.error("--version must be a three-component semantic version")
    if not arguments.directory.is_dir() or arguments.directory.is_symlink():
        parser.error("--directory must be a regular directory")
    try:
        validate(arguments.directory, arguments.version)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"public release metadata validation failed: {error}", file=sys.stderr)
        return 1
    print("Public release five-file inventory and four-entry checksum metadata ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
