#!/usr/bin/env python3
"""Compute source-scoped fingerprints for resumable local validation."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import subprocess
import sys


SCOPES: dict[str, tuple[str, ...]] = {
    "all": (),
    "localization": (
        "apps/macos/Sources/AgentPetCompanion/Resources",
        "script/validate_localizations.py",
    ),
    "schemas": ("schemas", "fixtures", "script/validate_schema_fixtures.sh", "script/validate_petpack_spec_schemas.sh"),
    "scripts": ("script", "skills", "schemas", "fixtures", "plugins", ".github"),
    "producer": ("Cargo.toml", "Cargo.lock", "crates", "skills", "schemas", "fixtures", "script"),
    "rust": (
        "Cargo.toml",
        "Cargo.lock",
        "rust-toolchain.toml",
        "crates",
        "schemas",
        "fixtures",
        "plugins",
        "skills",
    ),
    "swift": ("apps/macos",),
    "connectors": ("Cargo.toml", "Cargo.lock", "crates", "plugins", "schemas", "fixtures", "script"),
    "security": ("Cargo.toml", "Cargo.lock", "crates", "plugins", "schemas", "fixtures", "script"),
    "bundle": ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "apps/macos", "crates", "plugins", "skills", "schemas", "fixtures", "script"),
}


def git_files(root: pathlib.Path, paths: tuple[str, ...]) -> list[pathlib.Path]:
    command = ["git", "ls-files", "-co", "--exclude-standard", "-z"]
    if paths:
        command.extend(["--", *paths])
    result = subprocess.run(command, cwd=root, check=True, capture_output=True)
    relative_paths = sorted({item for item in result.stdout.split(b"\0") if item})
    return [root / os.fsdecode(item) for item in relative_paths]


def interaction_files(root: pathlib.Path) -> list[pathlib.Path]:
    list_path = root / "script/interaction-contract-files.txt"
    entries = [line for line in list_path.read_text(encoding="utf-8").splitlines() if line]
    if not entries or entries != sorted(set(entries)):
        raise ValueError("interaction contract file list must be sorted, unique, and non-empty")
    return [list_path, *(root / entry for entry in entries)]


def fingerprint(root: pathlib.Path, scope: str, extra: str) -> str:
    files = interaction_files(root) if scope == "interaction" else git_files(root, SCOPES[scope])
    if scope == "rust":
        files = sorted(set((*files, *interaction_files(root))))
    digest = hashlib.sha256()
    digest.update(b"apc.validation-fingerprint.v1\0")
    digest.update(scope.encode("utf-8"))
    digest.update(b"\0")
    digest.update(extra.encode("utf-8"))
    digest.update(b"\0")
    for path in files:
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(stat.S_IMODE(metadata.st_mode)).encode("ascii"))
        digest.update(b"\0")
        if path.is_symlink():
            digest.update(b"link\0")
            digest.update(os.readlink(path).encode("utf-8", errors="surrogateescape"))
        elif path.is_file():
            digest.update(b"file\0")
            with path.open("rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            raise ValueError(f"validation input is not a regular file or symlink: {relative}")
        digest.update(b"\0")
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--scope", choices=sorted((*SCOPES.keys(), "interaction")), required=True)
    parser.add_argument("--extra", default="")
    args = parser.parse_args()
    try:
        print(fingerprint(args.root.resolve(), args.scope, args.extra))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"could not fingerprint validation inputs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
