#!/usr/bin/env python3
"""Select the trusted main validation run and source-proof artifact for a release."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import stat
import sys
from typing import Any


COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
WORKFLOW_PATH = ".github/workflows/ci.yml"
MAIN_WORKFLOW_EVENTS = {"push", "workflow_dispatch"}


def read_json_regular(path: pathlib.Path) -> dict[str, Any]:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 8 * 1024 * 1024:
            raise ValueError("GitHub API input must be a bounded regular file")
        with os.fdopen(descriptor, encoding="utf-8") as handle:
            descriptor = -1
            payload = json.load(handle)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(payload, dict):
        raise ValueError("GitHub API input must contain one JSON object")
    return payload


def validate_identity(repository: str, commit: str) -> None:
    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise ValueError("repository must be owner/name")
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValueError("commit must be a full lowercase Git commit")


def select_run(payload: dict[str, Any], repository: str, commit: str) -> dict[str, int]:
    runs = payload.get("workflow_runs")
    if not isinstance(runs, list):
        raise ValueError("workflow run response is missing workflow_runs")
    matches = []
    for run in runs:
        if not isinstance(run, dict):
            continue
        head_repository = run.get("head_repository")
        head_name = head_repository.get("full_name") if isinstance(head_repository, dict) else None
        if (
            run.get("head_sha") == commit
            and run.get("event") in MAIN_WORKFLOW_EVENTS
            and run.get("head_branch") == "main"
            and run.get("conclusion") == "success"
            and run.get("path") == WORKFLOW_PATH
            and head_name == repository
            and isinstance(run.get("id"), int)
            and isinstance(run.get("run_attempt"), int)
        ):
            matches.append(run)
    if not matches:
        raise ValueError("no successful trusted main CI run exists for the release commit")
    selected = max(matches, key=lambda value: (value["id"], value["run_attempt"]))
    return {
        "run_id": selected["id"],
        "run_attempt": selected["run_attempt"],
        "workflow_event": selected["event"],
    }


def select_artifact(payload: dict[str, Any], run_id: int, artifact_name: str) -> dict[str, int | str]:
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("artifact response is missing artifacts")
    matches = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        workflow_run = artifact.get("workflow_run")
        artifact_run_id = workflow_run.get("id") if isinstance(workflow_run, dict) else run_id
        if (
            artifact.get("name") == artifact_name
            and artifact.get("expired") is False
            and artifact_run_id == run_id
            and isinstance(artifact.get("id"), int)
            and isinstance(artifact.get("size_in_bytes"), int)
            and 0 < artifact["size_in_bytes"] <= 1024 * 1024
        ):
            matches.append(artifact)
    if len(matches) != 1:
        raise ValueError("trusted CI run must contain exactly one bounded source-proof artifact")
    selected = matches[0]
    return {
        "artifact_id": selected["id"],
        "artifact_name": artifact_name,
        "size_in_bytes": selected["size_in_bytes"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--runs-json", required=True, type=pathlib.Path)
    run_parser.add_argument("--repository", required=True)
    run_parser.add_argument("--commit", required=True)
    artifact_parser = subparsers.add_parser("artifact")
    artifact_parser.add_argument("--artifacts-json", required=True, type=pathlib.Path)
    artifact_parser.add_argument("--run-id", required=True, type=int)
    artifact_parser.add_argument("--artifact-name", required=True)
    args = parser.parse_args()
    try:
        if args.command == "run":
            validate_identity(args.repository, args.commit)
            result = select_run(
                read_json_regular(args.runs_json), args.repository, args.commit
            )
        else:
            if args.run_id <= 0 or not args.artifact_name:
                raise ValueError("run id and artifact name must be valid")
            result = select_artifact(
                read_json_regular(args.artifacts_json), args.run_id, args.artifact_name
            )
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"release source proof resolution error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
