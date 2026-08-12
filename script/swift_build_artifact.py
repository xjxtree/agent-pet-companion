#!/usr/bin/env python3
"""Create and restore a bounded, exact-identity Swift debug build artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tarfile
import time
from typing import Any, NoReturn


SCHEMA_VERSION = "apc.swift-build-artifact.v1"
FLAGS_IDENTITY = "strict-concurrency=complete,warnings-as-errors"
ARCHIVE_NAME = "swift-debug-products.tar.gz"
MANIFEST_NAME = "manifest.json"
MAX_ARCHIVE_BYTES = 1200 * 1024 * 1024
MAX_EXPANDED_BYTES = 3 * 1024 * 1024 * 1024
MAX_FILES = 120_000


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def package_digest(root: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for relative in ("apps/macos/Package.swift", "apps/macos/Package.resolved"):
        path = root / relative
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def swift_identity() -> str:
    value = subprocess.run(
        ["swift", "--version"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout
    if not value or len(value) > 64 * 1024:
        fail("Swift toolchain identity is unavailable or unbounded")
    return hashlib.sha256(value).hexdigest()


def validate_commit(value: str) -> str:
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        fail("Swift artifact commit must be a full lowercase Git SHA")
    return value


def checkout_identity(
    root: pathlib.Path,
    commit: str,
    *,
    require_clean: bool,
) -> str:
    expected = validate_commit(commit)
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    if head != expected:
        fail("Swift artifact commit does not match the current checkout")
    if require_clean:
        status = subprocess.run(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"],
            cwd=root,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout
        if status:
            fail("Swift artifact requires an exact clean checkout")
    return expected


def manifest_identity(root: pathlib.Path, commit: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "commit": validate_commit(commit),
        "swift_toolchain_sha256": swift_identity(),
        "package_sha256": package_digest(root),
        "flags": FLAGS_IDENTITY,
    }


def included(relative: pathlib.PurePosixPath) -> bool:
    parts = relative.parts
    if parts[:3] != ("apps", "macos", ".build"):
        return False
    build_parts = parts[3:]
    if not build_parts:
        return True
    if any(
        part in {"ModuleCache", "index", ".git"} or part.endswith(".dSYM")
        for part in build_parts
    ):
        return False
    first = build_parts[0]
    if first in {
        "workspace-state.json",
        "build.db",
        "debug.yaml",
        "plugin-tools.yaml",
    }:
        return True
    return (
        first.endswith("-apple-macosx")
        and len(build_parts) >= 2
        and build_parts[1] == "debug"
    )


def create(root: pathlib.Path, output_dir: pathlib.Path, commit: str) -> dict[str, Any]:
    commit = checkout_identity(root, commit, require_clean=True)
    build = root / "apps/macos/.build"
    if not build.is_dir() or build.is_symlink():
        fail("Swift .build directory is unavailable")
    output_dir.mkdir(parents=True, exist_ok=False)
    archive = output_dir / ARCHIVE_NAME
    started = time.monotonic()
    file_count = 0
    expanded_bytes = 0
    with tarfile.open(archive, "w:gz", compresslevel=6) as bundle:
        for path in sorted(build.rglob("*")):
            relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
            if not included(relative):
                continue
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"Swift build artifact refuses symlink: {relative}")
            if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
                fail(f"Swift build artifact refuses special file: {relative}")
            if stat.S_ISREG(metadata.st_mode):
                file_count += 1
                expanded_bytes += metadata.st_size
                if file_count > MAX_FILES or expanded_bytes > MAX_EXPANDED_BYTES:
                    fail("Swift build artifact exceeds its bounded inventory")
            bundle.add(path, arcname=relative.as_posix(), recursive=False)
    archive_bytes = archive.stat().st_size
    if archive_bytes <= 0 or archive_bytes > MAX_ARCHIVE_BYTES:
        fail("Swift build artifact archive is empty or too large")
    manifest = {
        **manifest_identity(root, commit),
        "archive": ARCHIVE_NAME,
        "archive_sha256": sha256(archive),
        "archive_bytes": archive_bytes,
        "expanded_bytes": expanded_bytes,
        "file_count": file_count,
        "create_seconds": round(time.monotonic() - started, 3),
    }
    (output_dir / MANIFEST_NAME).write_text(
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return manifest


def read_manifest(path: pathlib.Path) -> dict[str, Any]:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_size > 64 * 1024:
        fail("Swift artifact manifest must be a bounded regular file")
    payload = json.loads(path.read_text(encoding="utf-8"))
    expected_fields = {
        "schema_version",
        "commit",
        "swift_toolchain_sha256",
        "package_sha256",
        "flags",
        "archive",
        "archive_sha256",
        "archive_bytes",
        "expanded_bytes",
        "file_count",
        "create_seconds",
    }
    if not isinstance(payload, dict) or set(payload) != expected_fields:
        fail("Swift artifact manifest field inventory is invalid")
    return payload


def restore(root: pathlib.Path, input_dir: pathlib.Path, commit: str) -> dict[str, Any]:
    commit = checkout_identity(root, commit, require_clean=True)
    manifest = read_manifest(input_dir / MANIFEST_NAME)
    for key, value in manifest_identity(root, commit).items():
        if manifest.get(key) != value:
            fail(f"Swift artifact {key} does not match this checkout")
    archive = input_dir / ARCHIVE_NAME
    metadata = archive.lstat()
    if (
        not archive.is_file()
        or archive.is_symlink()
        or metadata.st_size != manifest["archive_bytes"]
        or metadata.st_size > MAX_ARCHIVE_BYTES
        or sha256(archive) != manifest["archive_sha256"]
    ):
        fail("Swift artifact archive identity is invalid")
    started = time.monotonic()
    members: list[tarfile.TarInfo] = []
    expanded = 0
    files = 0
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            pure = pathlib.PurePosixPath(member.name)
            if pure.is_absolute() or ".." in pure.parts or not included(pure):
                fail("Swift artifact archive contains an unsafe path")
            if not (member.isdir() or member.isfile()) or member.issym() or member.islnk():
                fail("Swift artifact archive contains a non-regular entry")
            if member.isfile():
                files += 1
                expanded += member.size
            if files > MAX_FILES or expanded > MAX_EXPANDED_BYTES:
                fail("Swift artifact expanded inventory exceeds its limit")
            members.append(member)
        if files != manifest["file_count"] or expanded != manifest["expanded_bytes"]:
            fail("Swift artifact expanded inventory does not match its manifest")
        for member in members:
            destination = root / pathlib.Path(member.name)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            if source is None:
                fail("Swift artifact member could not be read")
            temporary = destination.with_name(f".{destination.name}.apc-artifact")
            with temporary.open("wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            os.chmod(temporary, member.mode & 0o777)
            os.replace(temporary, destination)
    return {
        "restored": True,
        "archive_bytes": metadata.st_size,
        "expanded_bytes": expanded,
        "file_count": files,
        "restore_seconds": round(time.monotonic() - started, 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    subparsers = parser.add_subparsers(dest="command", required=True)
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    create_parser.add_argument("--commit", required=True)
    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("--input-dir", type=pathlib.Path, required=True)
    restore_parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        result = (
            create(root, args.output_dir.resolve(), args.commit)
            if args.command == "create"
            else restore(root, args.input_dir.resolve(), args.commit)
        )
        print(json.dumps(result, sort_keys=True))
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
        tarfile.TarError,
    ) as error:
        print(f"swift build artifact: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
