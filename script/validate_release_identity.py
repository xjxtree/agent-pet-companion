#!/usr/bin/env python3
"""Bind one extracted public App and its evidence to one release identity."""

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
    evidence_path: pathlib.Path,
    architecture: str,
    version: str,
    build: str,
    commit: str,
    archive_name: str,
    archive_sha256: str,
) -> str:
    expected_build_id = f"{version}.{build}.{commit[:12]}"
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    manifest = load_json_object(app / "Contents/Resources/runtime-manifest.json")
    evidence = load_json_object(evidence_path)

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

    expected_evidence = {
        "schema_version": "apc.public-distribution-evidence.v1",
        "architecture": architecture,
        "version": version,
        "build": build,
        "commit": commit,
        "build_id": expected_build_id,
    }
    for key, expected in expected_evidence.items():
        if evidence.get(key) != expected:
            raise ValueError(
                f"distribution evidence {key}={evidence.get(key)!r}, expected {expected!r}"
            )

    if set(evidence) != {
        "schema_version",
        "architecture",
        "version",
        "build",
        "commit",
        "build_id",
        "notarization",
        "published_artifact",
    }:
        raise ValueError("distribution evidence has missing or unknown top-level fields")
    notarization = evidence.get("notarization")
    published = evidence.get("published_artifact")
    if not isinstance(notarization, dict) or set(notarization) != {
        "submission_id",
        "status",
        "submission_archive_sha256",
    }:
        raise ValueError("distribution evidence notarization object is invalid")
    if notarization.get("status") != "Accepted":
        raise ValueError("distribution evidence does not record accepted notarization")
    if not isinstance(notarization.get("submission_id"), str) or not notarization[
        "submission_id"
    ]:
        raise ValueError("distribution evidence has no notarization submission ID")
    submission_sha256 = notarization.get("submission_archive_sha256")
    if not isinstance(submission_sha256, str) or not re.fullmatch(
        r"[0-9a-f]{64}", submission_sha256
    ):
        raise ValueError("distribution evidence has an invalid submission digest")
    if not isinstance(published, dict) or set(published) != {
        "filename",
        "sha256",
        "stapled",
        "gatekeeper_accepted",
    }:
        raise ValueError("distribution evidence published-artifact object is invalid")
    if published.get("filename") != archive_name:
        raise ValueError("distribution evidence archive filename mismatch")
    if published.get("sha256") != archive_sha256:
        raise ValueError("distribution evidence final archive digest mismatch")
    if published.get("stapled") is not True:
        raise ValueError("distribution evidence does not record stapling")
    if published.get("gatekeeper_accepted") is not True:
        raise ValueError("distribution evidence does not record Gatekeeper acceptance")
    if submission_sha256 == archive_sha256:
        raise ValueError("submission and final archive digests must be distinct")
    return expected_build_id


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--evidence", required=True, type=pathlib.Path)
    parser.add_argument("--architecture", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--archive-name", required=True)
    parser.add_argument("--archive-sha256", required=True)
    arguments = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:[.][0-9]+){2}", arguments.version):
        parser.error("--version must be a three-component semantic version")
    if not re.fullmatch(r"[1-9][0-9]*", arguments.build):
        parser.error("--build must be a positive integer")
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.commit):
        parser.error("--commit must be a full lowercase Git commit")
    if not re.fullmatch(r"[0-9a-f]{64}", arguments.archive_sha256):
        parser.error("--archive-sha256 must be a lowercase SHA-256 digest")
    try:
        build_id = validate(
            arguments.app,
            arguments.evidence,
            arguments.architecture,
            arguments.version,
            arguments.build,
            arguments.commit,
            arguments.archive_name,
            arguments.archive_sha256,
        )
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(f"release identity validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Release identity validation ok ({build_id}, {arguments.architecture})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
