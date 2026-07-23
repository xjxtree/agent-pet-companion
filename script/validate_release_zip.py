#!/usr/bin/env python3
"""Fail-closed structural preflight for Agent Pet Companion release ZIPs."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import stat
import sys
import unicodedata
import zipfile


EXPECTED_TOP_LEVEL = "AgentPetCompanion.app"
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_ENTRY_COUNT = 20_000
MAX_ENTRY_UNCOMPRESSED_BYTES = 512 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
MIN_RATIO_CHECK_BYTES = 1024 * 1024
ALLOWED_COMPRESSION = {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
WINDOWS_DRIVE = re.compile(r"^[A-Za-z]:")


class UnsafeArchive(ValueError):
    """Raised when a ZIP cannot be extracted as a bounded release App."""


def _canonical_member_name(name: str) -> tuple[str, bool]:
    if not name or "\x00" in name:
        raise UnsafeArchive("ZIP contains an empty or NUL-containing path")
    if "\\" in name:
        raise UnsafeArchive(f"ZIP path uses a backslash: {name!r}")
    if name.startswith("/") or WINDOWS_DRIVE.match(name):
        raise UnsafeArchive(f"ZIP path is absolute: {name!r}")
    if any(unicodedata.category(character) == "Cc" for character in name):
        raise UnsafeArchive(f"ZIP path contains a control character: {name!r}")

    is_directory = name.endswith("/")
    without_trailing_slash = name[:-1] if is_directory else name
    parts = without_trailing_slash.split("/")
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise UnsafeArchive(f"ZIP path is not canonical: {name!r}")
    canonical = "/".join(parts)
    if canonical != without_trailing_slash:
        raise UnsafeArchive(f"ZIP path changes when normalized: {name!r}")
    if parts[0] != EXPECTED_TOP_LEVEL:
        raise UnsafeArchive(f"ZIP contains an unexpected top-level entry: {name!r}")
    return canonical, is_directory


def _member_kind(info: zipfile.ZipInfo, path_says_directory: bool) -> str:
    unix_mode = info.external_attr >> 16
    file_type = stat.S_IFMT(unix_mode)
    if file_type == stat.S_IFLNK:
        raise UnsafeArchive(f"ZIP symlinks are not permitted: {info.filename!r}")
    if file_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
        raise UnsafeArchive(f"ZIP contains a special filesystem entry: {info.filename!r}")
    if path_says_directory or info.is_dir():
        if file_type not in {0, stat.S_IFDIR}:
            raise UnsafeArchive(f"ZIP directory metadata is inconsistent: {info.filename!r}")
        return "directory"
    if file_type == stat.S_IFDIR:
        raise UnsafeArchive(f"ZIP file metadata is inconsistent: {info.filename!r}")
    return "file"


def validate_archive(path: pathlib.Path) -> None:
    if not path.is_file() or path.is_symlink():
        raise UnsafeArchive("release ZIP must be a regular, non-symlink file")
    if path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise UnsafeArchive("release ZIP exceeds the compressed-size limit")

    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            if not members:
                raise UnsafeArchive("release ZIP is empty")
            if len(members) > MAX_ENTRY_COUNT:
                raise UnsafeArchive("release ZIP exceeds the entry-count limit")

            seen: dict[str, tuple[str, str]] = {}
            total_uncompressed = 0
            for info in members:
                canonical, path_says_directory = _canonical_member_name(info.filename)
                normalized = unicodedata.normalize("NFC", canonical).casefold()
                if normalized in seen:
                    previous = seen[normalized][0]
                    raise UnsafeArchive(
                        "ZIP contains duplicate normalized/case-folded paths: "
                        f"{previous!r} and {info.filename!r}"
                    )

                kind = _member_kind(info, path_says_directory)
                seen[normalized] = (info.filename, kind)
                if info.flag_bits & 0x1:
                    raise UnsafeArchive(f"ZIP contains an encrypted entry: {info.filename!r}")
                if info.compress_type not in ALLOWED_COMPRESSION:
                    raise UnsafeArchive(
                        f"ZIP uses an unsupported compression method: {info.filename!r}"
                    )
                if kind == "directory":
                    if info.file_size != 0:
                        raise UnsafeArchive(
                            f"ZIP directory has an unexpected payload: {info.filename!r}"
                        )
                    continue

                if info.file_size > MAX_ENTRY_UNCOMPRESSED_BYTES:
                    raise UnsafeArchive(
                        f"ZIP entry exceeds the uncompressed-size limit: {info.filename!r}"
                    )
                total_uncompressed += info.file_size
                if total_uncompressed > MAX_TOTAL_UNCOMPRESSED_BYTES:
                    raise UnsafeArchive("release ZIP exceeds the total uncompressed-size limit")
                if info.file_size >= MIN_RATIO_CHECK_BYTES:
                    if info.compress_size <= 0:
                        raise UnsafeArchive(
                            f"ZIP entry has an invalid compressed size: {info.filename!r}"
                        )
                    ratio = info.file_size / info.compress_size
                    if ratio > MAX_COMPRESSION_RATIO:
                        raise UnsafeArchive(
                            f"ZIP entry exceeds the compression-ratio limit: {info.filename!r}"
                        )

            root_key = unicodedata.normalize("NFC", EXPECTED_TOP_LEVEL).casefold()
            root = seen.get(root_key)
            if root is None or root[1] != "directory":
                raise UnsafeArchive(
                    f"ZIP must contain the {EXPECTED_TOP_LEVEL!r} directory entry"
                )

            # A declared file may not be used as the parent of a later member.
            for normalized, (original, _) in seen.items():
                parts = normalized.split("/")
                for index in range(1, len(parts)):
                    parent = "/".join(parts[:index])
                    parent_entry = seen.get(parent)
                    if parent_entry is not None and parent_entry[1] != "directory":
                        raise UnsafeArchive(
                            f"ZIP member is nested below a file: {original!r}"
                        )

            bad_member = archive.testzip()
            if bad_member is not None:
                raise UnsafeArchive(f"ZIP entry fails CRC validation: {bad_member!r}")
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise UnsafeArchive(f"release ZIP is unreadable: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate a release ZIP before any filesystem extraction."
    )
    parser.add_argument("--archive", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    try:
        validate_archive(arguments.archive)
    except UnsafeArchive as error:
        print(f"release ZIP safety validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Release ZIP safety validation ok: {os.fspath(arguments.archive)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
