#!/usr/bin/env python3
"""Validate the published/latest GitHub Release contract consumed by the App."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any


ARCHITECTURES = ("arm64", "x86_64")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
VERSION_PATTERN = re.compile(r"[0-9]+(?:[.][0-9]+){2}")
MAX_JSON_BYTES = 4 * 1024 * 1024
REQUIRED_GUIDANCE = (
    "1. Download and unzip the archive for this Mac.",
    "2. Quit Agent Pet Companion, move the new App to Applications, and choose Replace.",
    "3. Open the new App from Applications.",
    "1. 下载并解压适用于这台 Mac 的归档。",
    "2. 退出 Agent Pet Companion，将新版移入“应用程序”，并选择“替换”。",
    "3. 从“应用程序”打开新版。",
    "Your pets, settings, history, and active work stay on this Mac and are preserved.",
    "你的宠物、设置、历史和正在进行的工作会留在这台 Mac 上并保持不变。",
)


def read_json(path: pathlib.Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"JSON input is not a regular file: {path}")
    if path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError(f"JSON input exceeds {MAX_JSON_BYTES} bytes: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"could not decode GitHub Release JSON: {path}") from error
    if not isinstance(value, dict):
        raise ValueError("GitHub Release JSON must be an object")
    return value


def expected_assets(version: str) -> dict[str, str]:
    return {
        f"AgentPetCompanion-{version}-macos-arm64.zip": "arm64",
        f"AgentPetCompanion-{version}-macos-x86_64.zip": "x86_64",
        f"AgentPetCompanion-{version}-SHA256SUMS.txt": "checksums",
    }


def validate_release(
    release: dict[str, Any],
    *,
    repository: str,
    version: str,
    trusted_digests: dict[str, str],
) -> int:
    tag = f"v{version}"
    if release.get("tag_name") != tag:
        raise ValueError("published Release tag does not match the release version")
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("App updates require a published, non-prerelease Release")
    release_id = release.get("id")
    if not isinstance(release_id, int) or isinstance(release_id, bool) or release_id <= 0:
        raise ValueError("published Release has no stable positive ID")
    if not isinstance(release.get("published_at"), str) or not release["published_at"]:
        raise ValueError("published Release has no publication timestamp")

    body = release.get("body")
    if not isinstance(body, str):
        raise ValueError("published Release has no installation guidance")
    missing_guidance = [line for line in REQUIRED_GUIDANCE if line not in body]
    if missing_guidance:
        raise ValueError(
            "published Release is missing the bilingual three-step replacement guidance"
        )

    expected = expected_assets(version)
    assets = release.get("assets")
    if not isinstance(assets, list) or len(assets) != len(expected):
        raise ValueError("published Release must expose exactly three assets")
    actual: dict[str, dict[str, Any]] = {}
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            raise ValueError("published Release contains a malformed asset")
        name = asset["name"]
        if name in actual:
            raise ValueError("published Release contains a duplicate asset name")
        actual[name] = asset
    if set(actual) != set(expected):
        raise ValueError("published Release asset inventory does not match the App contract")

    for name, kind in expected.items():
        asset = actual[name]
        if asset.get("state") != "uploaded":
            raise ValueError(f"published Release asset is not uploaded: {name}")
        size = asset.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            raise ValueError(f"published Release asset has no positive size: {name}")
        digest = asset.get("digest")
        trusted = trusted_digests[kind]
        if digest != f"sha256:{trusted}":
            raise ValueError(f"published Release asset digest mismatch: {name}")
        expected_url = f"https://github.com/{repository}/releases/download/{tag}/{name}"
        if asset.get("browser_download_url") != expected_url:
            raise ValueError(f"published Release asset URL is outside the exact release: {name}")
    return release_id


def validate(
    release: dict[str, Any],
    latest: dict[str, Any],
    *,
    repository: str,
    version: str,
    trusted_digests: dict[str, str],
) -> None:
    release_id = validate_release(
        release,
        repository=repository,
        version=version,
        trusted_digests=trusted_digests,
    )
    latest_id = validate_release(
        latest,
        repository=repository,
        version=version,
        trusted_digests=trusted_digests,
    )
    if latest_id != release_id:
        raise ValueError("the newly published stable Release is not GitHub's latest Release")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-json", required=True, type=pathlib.Path)
    parser.add_argument("--latest-json", required=True, type=pathlib.Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arm64-zip-sha256", required=True)
    parser.add_argument("--x86-64-zip-sha256", required=True)
    parser.add_argument("--checksum-sha256", required=True)
    arguments = parser.parse_args()

    if REPOSITORY_PATTERN.fullmatch(arguments.repository) is None:
        parser.error("--repository must be an owner/name GitHub repository")
    if VERSION_PATTERN.fullmatch(arguments.version) is None:
        parser.error("--version must be a three-component semantic version")
    trusted_digests = {
        "arm64": arguments.arm64_zip_sha256,
        "x86_64": arguments.x86_64_zip_sha256,
        "checksums": arguments.checksum_sha256,
    }
    if any(SHA256_PATTERN.fullmatch(digest) is None for digest in trusted_digests.values()):
        parser.error("every trusted digest must be a lowercase SHA-256 value")
    try:
        validate(
            read_json(arguments.release_json),
            read_json(arguments.latest_json),
            repository=arguments.repository,
            version=arguments.version,
            trusted_digests=trusted_digests,
        )
    except (OSError, ValueError) as error:
        print(f"GitHub Release API validation failed: {error}", file=sys.stderr)
        return 1
    print("Published latest stable Release matches the exact App update contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
