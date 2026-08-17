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
MAX_NOTES_BYTES = 512 * 1024
SUMMARY_HEADING = "## What's new / 本版本更新"
INSTALL_HEADING = "## Install / 安装"
CATEGORY_HEADING = re.compile(
    r"^### (?:Added / 新增|Changed / 变更|Fixed / 修复|Deprecated / 弃用|Removed / 移除|Security / 安全)$",
    flags=re.MULTILINE,
)
REQUIRED_GUIDANCE = (
    "`macos-arm64`",
    "`macos-x86_64`",
    "replace the App in `/Applications`",
    "替换 `/Applications` 中的 App",
    "Your local pets, settings, history, and active work are preserved.",
    "本机宠物、设置、历史和正在进行的工作会保留。",
    "**First launch / 首次打开：**",
    "not Developer ID signed",
    "没有 Developer ID 签名",
    "Control-click",
    "System Settings → Privacy & Security → Open Anyway",
    "按住 Control 点按",
    "系统设置 → 隐私与安全性 → 仍要打开",
    "`SHA256SUMS.txt`",
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


def read_expected_notes(path: pathlib.Path) -> str:
    if (
        path.is_symlink()
        or not path.is_file()
        or path.stat().st_size > MAX_NOTES_BYTES
    ):
        raise ValueError(f"expected Release notes must be a bounded regular file: {path}")
    value = path.read_text(encoding="utf-8")
    if not value.strip():
        raise ValueError("expected Release notes are empty")
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
    expected_notes: str,
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
        raise ValueError("published Release has no notes")
    if body.rstrip("\n") != expected_notes.rstrip("\n"):
        raise ValueError("published Release notes differ from the generated changelog summary")
    if not body.startswith(f"# Agent Pet Companion {version}\n"):
        raise ValueError("published Release notes title does not match the release version")
    summary_at = body.find(SUMMARY_HEADING)
    install_at = body.find(INSTALL_HEADING)
    if summary_at < 0 or install_at < 0 or summary_at >= install_at:
        raise ValueError("published Release notes must put the version summary before installation")
    if CATEGORY_HEADING.search(body[summary_at:install_at]) is None:
        raise ValueError("published Release notes contain no categorized version changes")
    if "<!-- apc-fragment:" in body:
        raise ValueError("published Release notes expose an internal changelog marker")
    missing_guidance = [line for line in REQUIRED_GUIDANCE if line not in body]
    if missing_guidance:
        raise ValueError("published Release is missing concise bilingual installation guidance")

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
    expected_notes: str,
) -> None:
    release_id = validate_release(
        release,
        repository=repository,
        version=version,
        trusted_digests=trusted_digests,
        expected_notes=expected_notes,
    )
    latest_id = validate_release(
        latest,
        repository=repository,
        version=version,
        trusted_digests=trusted_digests,
        expected_notes=expected_notes,
    )
    if latest_id != release_id:
        raise ValueError("the newly published stable Release is not GitHub's latest Release")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-json", required=True, type=pathlib.Path)
    parser.add_argument("--latest-json", required=True, type=pathlib.Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--expected-notes", required=True, type=pathlib.Path)
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
            expected_notes=read_expected_notes(arguments.expected_notes),
        )
    except (OSError, ValueError) as error:
        print(f"GitHub Release API validation failed: {error}", file=sys.stderr)
        return 1
    print("Published latest stable Release matches the exact App update contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
