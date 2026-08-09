#!/usr/bin/env python3
"""Validate a native interaction attestation against the current source contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import stat
import sys


EXPECTED_SUITES = [
    "OverlayPlacementAuthorityTests",
    "AppStoreOverlaySnapshotTests",
    "OverlayGeometryTests",
    "OverlayDisplayWidthTests",
    "OverlayInteractionTelemetryTests",
]


def contract_digest(root: pathlib.Path) -> str:
    list_path = root / "script/interaction-contract-files.txt"
    entries = [line for line in list_path.read_text(encoding="utf-8").splitlines() if line]
    if not entries or entries != sorted(set(entries)):
        raise ValueError("interaction contract file list must be sorted, unique, and non-empty")
    digest = hashlib.sha256()
    for entry in entries:
        relative = pathlib.PurePosixPath(entry)
        if relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            raise ValueError(f"unsafe interaction contract path: {entry}")
        path = root.joinpath(*relative.parts)
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            raise ValueError(f"interaction contract entry is not a regular file: {entry}")
        digest.update(entry.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def validate(root: pathlib.Path, attestation_path: pathlib.Path, expected_build_id: str | None) -> None:
    try:
        descriptor = os.open(attestation_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as error:
        raise ValueError("interaction attestation must be a regular, non-symlink file") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("interaction attestation must be a regular, non-symlink file")
        with os.fdopen(descriptor, encoding="utf-8") as file:
            descriptor = -1
            attestation = json.load(file)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if attestation.get("schema_version") != "apc.overlay-interaction-attestation.v1":
        raise ValueError("interaction attestation schema_version is invalid")
    if attestation.get("ok") is not True:
        raise ValueError("interaction attestation is not successful")
    if attestation.get("passed_suites") != EXPECTED_SUITES:
        raise ValueError("interaction attestation suite inventory is incomplete or reordered")
    if expected_build_id is not None and attestation.get("build_id") != expected_build_id:
        raise ValueError("interaction attestation build_id does not match the requested App build")
    if attestation.get("interaction_contract_digest") != contract_digest(root):
        raise ValueError("interaction attestation does not match the current source contract")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("attestation", type=pathlib.Path)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument("--expected-build-id")
    parser.add_argument("--print-digest", action="store_true")
    args = parser.parse_args()
    try:
        attestation_path = pathlib.Path(os.path.abspath(args.attestation))
        validate(args.root.resolve(), attestation_path, args.expected_build_id)
        if args.print_digest:
            print(contract_digest(args.root.resolve()))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"invalid interaction attestation: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
