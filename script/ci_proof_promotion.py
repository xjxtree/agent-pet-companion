#!/usr/bin/env python3
"""Manage trusted PR merge proofs and exact merged-head cleanup."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from argparse import Namespace
from typing import Any


SCHEMA_VERSION = "apc.ci-candidate-proof.v1"
MERGE_TICKET_SCHEMA_VERSION = "apc.ci-merge-ticket.v1"
WORKFLOW_PATH = ".github/workflows/ci.yml"
EXPECTED_GATES = [
    "bundle",
    "contracts",
    "overlay",
    "rust-lint",
    "rust-tests",
    "static",
    "stress",
    "swift-interaction",
]
TOOLCHAIN_CONTRACT_FILES = [
    "Cargo.lock",
    "apps/macos/Package.resolved",
    "apps/macos/Package.swift",
    "rust-toolchain.toml",
    "script/validate_macos_build_contract.py",
]
CONTROL_PLANE_FILES = [
    ".github/workflows/auto-merge.yml",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    "script/ci_proof_promotion.py",
    "script/configure_main_branch_ruleset.py",
    "script/development_flow.py",
    "script/interaction-contract-files.txt",
    "script/prepare_interaction_attestation.sh",
    "script/release_source_proof.py",
    "script/resolve_release_source_proof.py",
    "script/validate_build_scripts_safety.sh",
    "script/validate_interaction_attestation.py",
    "script/validate_macos_build_contract.py",
    "script/validate_overlay_interaction.sh",
    "script/validate_rust_test_shards.py",
    "script/validation_scope.py",
]
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
HEAD_PATTERN = re.compile(r"gd-ops/(?:task|fix|train)/[A-Za-z0-9._-]+")
ARTIFACT_PATTERN = re.compile(r"ci-candidate-proof-([0-9a-f]{40})")
MERGE_TICKET_ARTIFACT_PATTERN = re.compile(
    r"ci-merge-ticket-([1-9][0-9]*)-([1-9][0-9]*)"
)
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")


def run(root: pathlib.Path, *command: str) -> str:
    return subprocess.check_output(command, cwd=root, text=True).strip()


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def contract_digest(root: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for relative in TOOLCHAIN_CONTRACT_FILES:
        path = root / relative
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            raise ValueError(f"toolchain contract entry is not a regular file: {relative}")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def read_json_regular(path: pathlib.Path, *, limit: int = 1024 * 1024) -> Any:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as error:
        raise ValueError(f"input must be a regular, non-symlink file: {path.name}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
            raise ValueError(f"input is not a bounded regular file: {path.name}")
        with os.fdopen(descriptor, encoding="utf-8") as handle:
            descriptor = -1
            return json.load(handle)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def atomic_write_json(path: pathlib.Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def require_commit(value: str, name: str) -> None:
    if COMMIT_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{name} must be a full lowercase Git commit")


def require_identity(repository: str, commits: dict[str, str]) -> None:
    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise ValueError("repository must be owner/name")
    for name, value in commits.items():
        require_commit(value, name)


def require_origin_repository(root: pathlib.Path, repository: str) -> None:
    remote = run(root, "git", "remote", "get-url", "origin")
    accepted = {
        f"https://github.com/{repository}",
        f"https://github.com/{repository}.git",
        f"git@github.com:{repository}.git",
        f"ssh://git@github.com/{repository}.git",
    }
    if remote not in accepted:
        raise ValueError("origin does not match the verified pull-request repository")


def remote_ref_sha(root: pathlib.Path, head_ref: str) -> str | None:
    full_ref = f"refs/heads/{head_ref}"
    response = run(root, "git", "ls-remote", "--refs", "origin", full_ref)
    if not response:
        return None
    lines = response.splitlines()
    if len(lines) != 1:
        raise ValueError("remote head lookup is ambiguous")
    fields = lines[0].split("\t")
    if len(fields) != 2 or fields[1] != full_ref:
        raise ValueError("remote head lookup returned an invalid ref")
    require_commit(fields[0], "remote head commit")
    return fields[0]


def delete_merged_head(args: Namespace) -> dict[str, bool | str]:
    root = args.root.resolve()
    require_identity(args.repository, {"head commit": args.head_commit})
    if args.pull_request_number <= 0:
        raise ValueError("merged-head PR identity must be positive")
    if HEAD_PATTERN.fullmatch(args.head_ref) is None:
        raise ValueError("merged head is not a managed development branch")
    pull = api_json(
        f"repos/{args.repository}/pulls/{args.pull_request_number}"
    )
    head = pull.get("head") if isinstance(pull, dict) else None
    head_repository = head.get("repo") if isinstance(head, dict) else None
    if not (
        isinstance(pull, dict)
        and pull.get("number") == args.pull_request_number
        and pull.get("merged") is True
        and isinstance(head, dict)
        and head.get("ref") == args.head_ref
        and head.get("sha") == args.head_commit
        and isinstance(head_repository, dict)
        and head_repository.get("full_name") == args.repository
    ):
        raise ValueError("merged-head cleanup is not bound to the exact merged pull request")
    require_origin_repository(root, args.repository)
    if not isinstance(args.allow_delete, bool):
        raise ValueError("merged-head cleanup mode is invalid")
    subprocess.run(["gh", "auth", "setup-git"], check=True)
    observed = remote_ref_sha(root, args.head_ref)
    result: dict[str, bool | str] = {
        "deleted": False,
        "head_ref": args.head_ref,
        "head_commit": args.head_commit,
    }
    if observed is None:
        return result
    if not args.allow_delete:
        raise ValueError(
            "merged-head replay found an existing source ref; refusing deletion"
        )
    if observed != args.head_commit:
        raise ValueError("merged source branch advanced or was reused; refusing deletion")
    full_ref = f"refs/heads/{args.head_ref}"
    subprocess.run(
        [
            "git",
            "push",
            f"--force-with-lease={full_ref}:{args.head_commit}",
            "origin",
            f":{full_ref}",
        ],
        cwd=root,
        check=True,
    )
    if remote_ref_sha(root, args.head_ref) is not None:
        raise ValueError("merged source branch still exists after deletion")
    result["deleted"] = True
    return result


def require_unchanged_control_plane(
    root: pathlib.Path, base_commit: str, main_commit: str
) -> None:
    require_commit(base_commit, "control-plane base commit")
    require_commit(main_commit, "control-plane main commit")
    if CONTROL_PLANE_FILES != sorted(set(CONTROL_PLANE_FILES)):
        raise ValueError("CI proof control-plane inventory is invalid")
    changed = run(
        root,
        "git",
        "diff",
        "--name-only",
        "--no-renames",
        base_commit,
        main_commit,
        "--",
        *CONTROL_PLANE_FILES,
    )
    if changed:
        raise ValueError(f"CI proof control plane changed: {changed.replace(chr(10), ', ')}")


def validate_attestation(
    root: pathlib.Path, attestation: pathlib.Path, tested_commit: str
) -> dict[str, Any]:
    subprocess.run(
        [
            str(root / "script/validate_interaction_attestation.py"),
            str(attestation),
            "--root",
            str(root),
            "--expected-build-id",
            f"source.{tested_commit}",
        ],
        cwd=root,
        check=True,
    )
    payload = read_json_regular(attestation)
    if not isinstance(payload, dict):
        raise ValueError("interaction attestation must contain one JSON object")
    return payload


def observed_toolchains(root: pathlib.Path) -> dict[str, str]:
    commands = {
        "rustc": ("rustc", "-Vv"),
        "swift": ("swift", "--version"),
        "python": ("python3", "--version"),
        "sdk": ("xcrun", "--show-sdk-version"),
    }
    values: dict[str, str] = {}
    for name, command in commands.items():
        value = subprocess.check_output(
            command, cwd=root, text=True, stderr=subprocess.STDOUT
        ).strip()
        if not value or len(value) > 4096:
            raise ValueError(f"observed {name} toolchain identity is invalid")
        values[name] = value
    return values


def select_merged_pull(
    payload: Any, repository: str, main_commit: str
) -> dict[str, int | str]:
    require_identity(repository, {"main commit": main_commit})
    if not isinstance(payload, list):
        raise ValueError("pull request response must contain one list")
    matches: list[dict[str, Any]] = []
    for pull in payload:
        if not isinstance(pull, dict):
            continue
        base = pull.get("base")
        head = pull.get("head")
        base_repo = base.get("repo") if isinstance(base, dict) else None
        head_repo = head.get("repo") if isinstance(head, dict) else None
        head_ref = head.get("ref") if isinstance(head, dict) else None
        if (
            pull.get("state") == "closed"
            and isinstance(pull.get("merged_at"), str)
            and pull.get("merge_commit_sha") == main_commit
            and isinstance(pull.get("number"), int)
            and pull["number"] > 0
            and isinstance(base, dict)
            and base.get("ref") == "main"
            and isinstance(base_repo, dict)
            and base_repo.get("full_name") == repository
            and isinstance(head, dict)
            and isinstance(head_repo, dict)
            and head_repo.get("full_name") == repository
            and isinstance(head_ref, str)
            and HEAD_PATTERN.fullmatch(head_ref) is not None
            and isinstance(head.get("sha"), str)
            and COMMIT_PATTERN.fullmatch(head["sha"]) is not None
        ):
            matches.append(pull)
    if len(matches) != 1:
        raise ValueError("exactly one trusted merged pull request must own the main commit")
    selected = matches[0]
    head = selected["head"]
    return {
        "number": selected["number"],
        "head_sha": head["sha"],
        "head_ref": head["ref"],
    }


def select_successful_run(
    payload: dict[str, Any], repository: str, head_sha: str, head_ref: str
) -> dict[str, int]:
    require_identity(repository, {"head commit": head_sha})
    if HEAD_PATTERN.fullmatch(head_ref) is None:
        raise ValueError("head branch is not a managed development branch")
    runs = payload.get("workflow_runs")
    if not isinstance(runs, list):
        raise ValueError("workflow run response is missing workflow_runs")
    matches = []
    for workflow_run in runs:
        if not isinstance(workflow_run, dict):
            continue
        head_repository = workflow_run.get("head_repository")
        if (
            workflow_run.get("status") == "completed"
            and workflow_run.get("conclusion") == "success"
            and workflow_run.get("event") == "pull_request"
            and workflow_run.get("head_sha") == head_sha
            and workflow_run.get("head_branch") == head_ref
            and workflow_run.get("path") == WORKFLOW_PATH
            and isinstance(head_repository, dict)
            and head_repository.get("full_name") == repository
            and isinstance(workflow_run.get("id"), int)
            and isinstance(workflow_run.get("run_attempt"), int)
        ):
            matches.append(workflow_run)
    if not matches:
        raise ValueError("no successful trusted pull-request CI run exists")
    selected = max(matches, key=lambda item: (item["id"], item["run_attempt"]))
    return {"run_id": selected["id"], "run_attempt": selected["run_attempt"]}


def require_required_gate(payload: dict[str, Any]) -> None:
    jobs = payload.get("jobs")
    if not isinstance(jobs, list):
        raise ValueError("workflow job response is missing jobs")
    matches = [
        job
        for job in jobs
        if isinstance(job, dict)
        and job.get("name") == "Required CI"
        and job.get("conclusion") == "success"
    ]
    if len(matches) != 1:
        raise ValueError("trusted PR run must contain one successful Required CI job")


def select_candidate_artifact(
    payload: dict[str, Any], run_id: int
) -> dict[str, int | str]:
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("artifact response is missing artifacts")
    matches: list[dict[str, Any]] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        workflow_run = artifact.get("workflow_run")
        artifact_run_id = workflow_run.get("id") if isinstance(workflow_run, dict) else run_id
        name = artifact.get("name")
        if (
            isinstance(name, str)
            and ARTIFACT_PATTERN.fullmatch(name) is not None
            and artifact.get("expired") is False
            and artifact_run_id == run_id
            and isinstance(artifact.get("id"), int)
            and isinstance(artifact.get("size_in_bytes"), int)
            and 0 < artifact["size_in_bytes"] <= 1024 * 1024
        ):
            matches.append(artifact)
    if len(matches) != 1:
        raise ValueError("trusted PR run must contain exactly one live bounded candidate artifact")
    selected = matches[0]
    tested_commit = ARTIFACT_PATTERN.fullmatch(selected["name"]).group(1)
    return {
        "id": selected["id"],
        "name": selected["name"],
        "size_in_bytes": selected["size_in_bytes"],
        "tested_commit": tested_commit,
    }


def candidate_artifacts(payload: dict[str, Any], run_id: int) -> list[dict[str, Any]]:
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("artifact response is missing artifacts")
    matches = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        workflow_run = artifact.get("workflow_run")
        artifact_run_id = workflow_run.get("id") if isinstance(workflow_run, dict) else run_id
        name = artifact.get("name")
        if (
            isinstance(name, str)
            and ARTIFACT_PATTERN.fullmatch(name) is not None
            and artifact.get("expired") is False
            and artifact_run_id == run_id
            and isinstance(artifact.get("id"), int)
            and isinstance(artifact.get("size_in_bytes"), int)
            and 0 < artifact["size_in_bytes"] <= 1024 * 1024
        ):
            matches.append(artifact)
    return matches


def require_candidate_lane(
    payload: dict[str, Any], run_id: int, base_ref: str
) -> dict[str, int | str] | None:
    if base_ref == "main":
        return select_candidate_artifact(payload, run_id)
    if re.fullmatch(r"gd-ops/train/[A-Za-z0-9._-]+", base_ref) is None:
        raise ValueError("merge base is not main or a managed train")
    if candidate_artifacts(payload, run_id):
        raise ValueError("task-to-train run must not contain a Release candidate artifact")
    return None


def select_merge_ticket_artifact(
    payload: dict[str, Any], run_id: int, run_attempt: int
) -> dict[str, int | str]:
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("artifact response is missing artifacts")
    expected_name = f"ci-merge-ticket-{run_id}-{run_attempt}"
    matches = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        workflow_run = artifact.get("workflow_run")
        artifact_run_id = workflow_run.get("id") if isinstance(workflow_run, dict) else run_id
        if (
            artifact.get("name") == expected_name
            and artifact.get("expired") is False
            and artifact_run_id == run_id
            and isinstance(artifact.get("id"), int)
            and isinstance(artifact.get("size_in_bytes"), int)
            and 0 < artifact["size_in_bytes"] <= 256 * 1024
        ):
            matches.append(artifact)
    if len(matches) != 1:
        raise ValueError("trusted PR run must contain exactly one current merge ticket")
    selected = matches[0]
    return {
        "id": selected["id"],
        "name": expected_name,
        "size_in_bytes": selected["size_in_bytes"],
    }


def create_merge_ticket(args: Namespace) -> None:
    root = args.root.resolve()
    require_identity(
        args.repository,
        {
            "base commit": args.base_commit,
            "head commit": args.head_commit,
            "tested commit": args.tested_commit,
        },
    )
    if args.pull_request_number <= 0 or args.run_id <= 0 or args.run_attempt <= 0:
        raise ValueError("merge-ticket PR and run identities must be positive")
    if HEAD_PATTERN.fullmatch(args.head_ref) is None:
        raise ValueError("merge-ticket head is not a managed development branch")
    expected_lane = (
        "train-to-main"
        if args.base_ref == "main" and args.head_ref.startswith("gd-ops/train/")
        else "direct-to-main"
        if args.base_ref == "main"
        else "task-to-train"
        if re.fullmatch(r"gd-ops/train/[A-Za-z0-9._-]+", args.base_ref)
        else None
    )
    if expected_lane is None or args.lane != expected_lane:
        raise ValueError("merge-ticket lane does not match its base and head")
    if args.base_ref != "main" and args.full_candidate:
        raise ValueError("task-to-train merge ticket cannot be a full candidate")
    if run(root, "git", "rev-parse", "HEAD") != args.tested_commit:
        raise ValueError("merge-ticket checkout does not match the tested commit")
    payload = {
        "schema_version": MERGE_TICKET_SCHEMA_VERSION,
        "repository": args.repository,
        "pull_request_number": args.pull_request_number,
        "base_ref": args.base_ref,
        "base_commit": args.base_commit,
        "head_ref": args.head_ref,
        "head_commit": args.head_commit,
        "tested_commit": args.tested_commit,
        "workflow_path": WORKFLOW_PATH,
        "workflow_event": "pull_request",
        "workflow_ref": f"refs/pull/{args.pull_request_number}/merge",
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "lane": args.lane,
        "full_candidate": args.full_candidate,
        "ok": True,
    }
    atomic_write_json(args.output.resolve(), payload)


def validate_merge_ticket(args: Namespace) -> dict[str, Any]:
    require_identity(
        args.repository,
        {"base commit": args.base_commit, "head commit": args.head_commit},
    )
    ticket = read_json_regular(args.ticket.resolve(), limit=256 * 1024)
    if HEAD_PATTERN.fullmatch(args.head_ref) is None:
        raise ValueError("merge-ticket head is not a managed development branch")
    if args.base_ref != "main" and re.fullmatch(
        r"gd-ops/train/[A-Za-z0-9._-]+", args.base_ref
    ) is None:
        raise ValueError("merge-ticket base is not main or a managed train")
    expected_keys = {
        "schema_version", "repository", "pull_request_number", "base_ref",
        "base_commit", "head_ref", "head_commit", "tested_commit",
        "workflow_path", "workflow_event", "workflow_ref", "run_id",
        "run_attempt", "lane", "full_candidate", "ok",
    }
    if not isinstance(ticket, dict) or set(ticket) != expected_keys:
        raise ValueError("merge ticket field inventory is invalid")
    expected_lane = (
        "train-to-main"
        if args.base_ref == "main" and args.head_ref.startswith("gd-ops/train/")
        else "direct-to-main"
        if args.base_ref == "main"
        else "task-to-train"
    )
    checks = {
        "schema_version": MERGE_TICKET_SCHEMA_VERSION,
        "repository": args.repository,
        "pull_request_number": args.pull_request_number,
        "base_ref": args.base_ref,
        "base_commit": args.base_commit,
        "head_ref": args.head_ref,
        "head_commit": args.head_commit,
        "workflow_path": WORKFLOW_PATH,
        "workflow_event": "pull_request",
        "workflow_ref": f"refs/pull/{args.pull_request_number}/merge",
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "lane": expected_lane,
        "full_candidate": args.base_ref == "main",
        "ok": True,
    }
    for key, expected in checks.items():
        if ticket.get(key) != expected:
            raise ValueError(f"merge ticket {key} does not match the current PR")
    tested_commit = ticket.get("tested_commit")
    if not isinstance(tested_commit, str):
        raise ValueError("merge ticket tested commit is invalid")
    require_commit(tested_commit, "merge-ticket tested commit")
    return ticket


def create_candidate(args: Namespace) -> None:
    root = args.root.resolve()
    commits = {
        "base commit": args.base_commit,
        "head commit": args.head_commit,
        "tested commit": args.tested_commit,
    }
    require_identity(args.repository, commits)
    if args.pull_request_number <= 0 or args.run_id <= 0 or args.run_attempt <= 0:
        raise ValueError("pull request and run identities must be positive")
    if run(root, "git", "rev-parse", "HEAD") != args.tested_commit:
        raise ValueError("candidate checkout does not match the tested commit")
    parents = run(root, "git", "show", "-s", "--format=%P", "HEAD").split()
    if parents != [args.base_commit, args.head_commit]:
        raise ValueError("tested merge parents do not match PR base and head")
    if run(root, "git", "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("candidate checkout contains tracked modifications")
    attestation = args.attestation.resolve()
    output = args.output.resolve()
    if attestation.parent != output.parent:
        raise ValueError("candidate proof files must share one artifact directory")
    attestation_payload = validate_attestation(root, attestation, args.tested_commit)
    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "repository": args.repository,
        "pull_request_number": args.pull_request_number,
        "base_commit": args.base_commit,
        "head_commit": args.head_commit,
        "tested_commit": args.tested_commit,
        "source_tree": run(root, "git", "rev-parse", "HEAD^{tree}"),
        "workflow_path": WORKFLOW_PATH,
        "workflow_event": "pull_request",
        "workflow_ref": f"refs/pull/{args.pull_request_number}/merge",
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "gates": EXPECTED_GATES,
        "toolchain_contract_digest": contract_digest(root),
        "observed_toolchains": observed_toolchains(root),
        "interaction_attestation_sha256": sha256(attestation),
        "interaction_contract_digest": attestation_payload.get(
            "interaction_contract_digest"
        ),
        "ok": True,
    }
    atomic_write_json(output, payload)
    inventory = sorted(child.name for child in output.parent.iterdir())
    if inventory != ["candidate-proof.json", "interaction-attestation.json"]:
        output.unlink(missing_ok=True)
        raise ValueError("candidate proof artifact must contain exactly two files")


def validate_merge_candidate(args: Namespace) -> dict[str, str]:
    require_identity(
        args.repository,
        {"base commit": args.base_commit, "head commit": args.head_commit},
    )
    proof_path = args.proof.resolve()
    attestation_path = args.attestation.resolve()
    if proof_path.parent != attestation_path.parent:
        raise ValueError("candidate proof files must share one artifact directory")
    inventory = []
    for child in proof_path.parent.iterdir():
        metadata = child.lstat()
        if not stat.S_ISREG(metadata.st_mode) or child.is_symlink():
            raise ValueError("candidate proof artifact contains a non-regular entry")
        inventory.append(child.name)
    if sorted(inventory) != ["candidate-proof.json", "interaction-attestation.json"]:
        raise ValueError("candidate proof artifact must contain exactly two files")
    proof = read_json_regular(proof_path)
    expected_keys = {
        "schema_version", "repository", "pull_request_number", "base_commit",
        "head_commit", "tested_commit", "source_tree", "workflow_path",
        "workflow_event", "workflow_ref", "run_id", "run_attempt", "gates",
        "toolchain_contract_digest", "observed_toolchains",
        "interaction_attestation_sha256", "interaction_contract_digest", "ok",
    }
    if not isinstance(proof, dict) or set(proof) != expected_keys:
        raise ValueError("candidate proof field inventory is invalid")
    checks = {
        "schema_version": SCHEMA_VERSION,
        "repository": args.repository,
        "pull_request_number": args.pull_request_number,
        "base_commit": args.base_commit,
        "head_commit": args.head_commit,
        "workflow_path": WORKFLOW_PATH,
        "workflow_event": "pull_request",
        "workflow_ref": f"refs/pull/{args.pull_request_number}/merge",
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "gates": EXPECTED_GATES,
        "ok": True,
    }
    for key, expected in checks.items():
        if proof.get(key) != expected:
            raise ValueError(f"candidate proof {key} does not match the merge request")
    tested_commit = proof.get("tested_commit")
    source_tree = proof.get("source_tree")
    if not isinstance(tested_commit, str) or not isinstance(source_tree, str):
        raise ValueError("candidate proof commit or tree is invalid")
    require_commit(tested_commit, "candidate tested commit")
    require_commit(source_tree, "candidate source tree")
    tested_payload = args.tested_payload
    if not isinstance(tested_payload, dict):
        raise ValueError("tested commit API response must contain one object")
    parents = tested_payload.get("parents")
    parent_shas = [parent.get("sha") for parent in parents if isinstance(parent, dict)] \
        if isinstance(parents, list) else []
    tree = tested_payload.get("tree")
    if tested_payload.get("sha") != tested_commit:
        raise ValueError("tested merge commit does not match the candidate proof")
    if parent_shas != [args.base_commit, args.head_commit]:
        raise ValueError("tested merge parents do not match the current PR")
    if not isinstance(tree, dict) or tree.get("sha") != source_tree:
        raise ValueError("tested merge tree does not match the candidate proof")
    if (
        not isinstance(proof.get("toolchain_contract_digest"), str)
        or DIGEST_PATTERN.fullmatch(proof["toolchain_contract_digest"]) is None
        or not isinstance(proof.get("interaction_contract_digest"), str)
        or DIGEST_PATTERN.fullmatch(proof["interaction_contract_digest"]) is None
    ):
        raise ValueError("candidate proof contract digest is invalid")
    observed = proof.get("observed_toolchains")
    if not isinstance(observed, dict) or set(observed) != {"rustc", "swift", "python", "sdk"}:
        raise ValueError("candidate proof observed toolchain inventory is invalid")
    if any(not isinstance(value, str) or not value or len(value) > 4096 for value in observed.values()):
        raise ValueError("candidate proof contains an invalid observed toolchain identity")
    attestation = read_json_regular(attestation_path)
    if not isinstance(attestation, dict):
        raise ValueError("candidate interaction attestation is invalid")
    if proof.get("interaction_attestation_sha256") != sha256(attestation_path):
        raise ValueError("candidate interaction attestation digest is invalid")
    if (
        attestation.get("build_id") != f"source.{tested_commit}"
        or attestation.get("interaction_contract_digest")
        != proof.get("interaction_contract_digest")
    ):
        raise ValueError("candidate interaction attestation identity is invalid")
    return {"tested_commit": tested_commit, "source_tree": source_tree}


def validate_candidate(args: Namespace) -> dict[str, int | str]:
    root = args.root.resolve()
    commits = {
        "main commit": args.main_commit,
        "main parent": args.main_parent,
        "head commit": args.head_commit,
    }
    require_identity(args.repository, commits)
    if args.pull_request_number <= 0 or args.run_id <= 0 or args.run_attempt <= 0:
        raise ValueError("pull request and run identities must be positive")
    if run(root, "git", "rev-parse", "HEAD") != args.main_commit:
        raise ValueError("promotion checkout does not match the main commit")
    main_parents = run(root, "git", "show", "-s", "--format=%P", "HEAD").split()
    if main_parents != [args.main_parent]:
        raise ValueError("main commit must be one squash commit over the push base")
    require_unchanged_control_plane(root, args.main_parent, args.main_commit)
    if run(root, "git", "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("promotion checkout contains tracked modifications")
    main_tree = run(root, "git", "rev-parse", "HEAD^{tree}")

    proof = read_json_regular(args.proof.resolve())
    if not isinstance(proof, dict):
        raise ValueError("candidate proof must contain one JSON object")
    expected_keys = {
        "schema_version", "repository", "pull_request_number", "base_commit",
        "head_commit", "tested_commit", "source_tree", "workflow_path",
        "workflow_event", "workflow_ref", "run_id", "run_attempt", "gates",
        "toolchain_contract_digest", "observed_toolchains",
        "interaction_attestation_sha256", "interaction_contract_digest", "ok",
    }
    if set(proof) != expected_keys:
        raise ValueError("candidate proof field inventory is invalid")
    tested_commit = proof.get("tested_commit")
    if not isinstance(tested_commit, str):
        raise ValueError("candidate proof tested commit is invalid")
    require_commit(tested_commit, "tested commit")
    checks = {
        "schema_version": SCHEMA_VERSION,
        "repository": args.repository,
        "pull_request_number": args.pull_request_number,
        "base_commit": args.main_parent,
        "head_commit": args.head_commit,
        "source_tree": main_tree,
        "workflow_path": WORKFLOW_PATH,
        "workflow_event": "pull_request",
        "workflow_ref": f"refs/pull/{args.pull_request_number}/merge",
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "gates": EXPECTED_GATES,
        "toolchain_contract_digest": contract_digest(root),
        "ok": True,
    }
    for key, expected in checks.items():
        if proof.get(key) != expected:
            raise ValueError(f"candidate proof {key} does not match main promotion")

    tested_payload = read_json_regular(args.tested_commit_json.resolve(), limit=8 * 1024 * 1024)
    if not isinstance(tested_payload, dict):
        raise ValueError("tested commit API response must contain one object")
    tree = tested_payload.get("tree")
    parents = tested_payload.get("parents")
    parent_shas = [parent.get("sha") for parent in parents if isinstance(parent, dict)] \
        if isinstance(parents, list) else []
    if tested_payload.get("sha") != tested_commit:
        raise ValueError("tested merge commit does not match the candidate proof")
    if parent_shas != [args.main_parent, args.head_commit]:
        raise ValueError("tested merge parents do not match main parent and PR head")
    if not isinstance(tree, dict) or tree.get("sha") != main_tree:
        raise ValueError("tested merge tree does not match the main source tree")

    observed = proof.get("observed_toolchains")
    if not isinstance(observed, dict) or set(observed) != {"rustc", "swift", "python", "sdk"}:
        raise ValueError("candidate proof observed toolchain inventory is invalid")
    if any(not isinstance(value, str) or not value or len(value) > 4096 for value in observed.values()):
        raise ValueError("candidate proof contains an invalid observed toolchain identity")

    proof_path = args.proof.resolve()
    attestation = args.attestation.resolve()
    if proof_path.parent != attestation.parent:
        raise ValueError("candidate proof files must share one artifact directory")
    inventory = []
    for child in proof_path.parent.iterdir():
        metadata = child.lstat()
        if not stat.S_ISREG(metadata.st_mode) or child.is_symlink():
            raise ValueError("candidate proof artifact contains a non-regular entry")
        inventory.append(child.name)
    if sorted(inventory) != ["candidate-proof.json", "interaction-attestation.json"]:
        raise ValueError("candidate proof artifact must contain exactly two files")
    attestation_payload = validate_attestation(root, attestation, tested_commit)
    if proof.get("interaction_attestation_sha256") != sha256(attestation):
        raise ValueError("candidate proof interaction attestation digest is invalid")
    if proof.get("interaction_contract_digest") != attestation_payload.get(
        "interaction_contract_digest"
    ):
        raise ValueError("candidate proof interaction contract digest is invalid")
    return {
        "validation_commit": tested_commit,
        "validation_run_id": args.run_id,
        "validation_run_attempt": args.run_attempt,
        "validation_ref": f"refs/pull/{args.pull_request_number}/merge",
        "candidate_proof_sha256": sha256(proof_path),
    }


def api_json(endpoint: str, **fields: str) -> Any:
    command = [
        "gh", "api", "-X", "GET",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2022-11-28",
        endpoint,
    ]
    for key, value in fields.items():
        command.extend(["-f", f"{key}={value}"])
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if len(result.stdout) > 8 * 1024 * 1024:
        raise ValueError("GitHub API response exceeds the bounded input size")
    return json.loads(result.stdout)


def api_bytes(endpoint: str, expected_size: int) -> bytes:
    result = subprocess.run(
        [
            "gh", "api",
            "-H", "Accept: application/vnd.github+json",
            "-H", "X-GitHub-Api-Version: 2022-11-28",
            endpoint,
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if not result.stdout or len(result.stdout) > max(2 * 1024 * 1024, expected_size * 2):
        raise ValueError("candidate artifact download is empty or unexpectedly large")
    return result.stdout


def extract_archive(
    data: bytes, destination: pathlib.Path, expected: set[str], limit: int
) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if {entry.filename for entry in entries} != expected or len(entries) != len(expected):
            raise ValueError("proof artifact archive inventory is invalid")
        if sum(entry.file_size for entry in entries) > limit:
            raise ValueError("proof artifact archive expands beyond its limit")
        for entry in entries:
            mode = entry.external_attr >> 16
            if entry.is_dir() or (stat.S_IFMT(mode) not in (0, stat.S_IFREG)):
                raise ValueError("candidate artifact archive contains a non-regular entry")
            output = destination / entry.filename
            output.write_bytes(archive.read(entry))
            output.chmod(0o644)


def extract_candidate_archive(data: bytes, destination: pathlib.Path) -> None:
    extract_archive(
        data,
        destination,
        {"candidate-proof.json", "interaction-attestation.json"},
        1024 * 1024,
    )


def require_source_run(args: Namespace) -> None:
    run_payload = api_json(f"repos/{args.repository}/actions/runs/{args.run_id}")
    head_repository = run_payload.get("head_repository")
    if not (
        run_payload.get("id") == args.run_id
        and run_payload.get("run_attempt") == args.run_attempt
        and run_payload.get("status") == "completed"
        and run_payload.get("conclusion") == "success"
        and run_payload.get("event") == "pull_request"
        and run_payload.get("head_sha") == args.head_commit
        and run_payload.get("head_branch") == args.head_ref
        and run_payload.get("path") == WORKFLOW_PATH
        and isinstance(head_repository, dict)
        and head_repository.get("full_name") == args.repository
    ):
        raise ValueError("merge source is not the exact successful trusted PR CI run")
    require_required_gate(
        api_json(
            f"repos/{args.repository}/actions/runs/{args.run_id}/jobs",
            filter="latest",
            per_page="100",
        )
    )


def require_no_control_plane_change(repository: str, pull_request_number: int) -> None:
    if REPOSITORY_PATTERN.fullmatch(repository) is None or pull_request_number <= 0:
        raise ValueError("control-plane PR identity is invalid")
    if CONTROL_PLANE_FILES != sorted(set(CONTROL_PLANE_FILES)):
        raise ValueError("CI proof control-plane inventory is invalid")
    changed = []
    for page in range(1, 11):
        payload = api_json(
            f"repos/{repository}/pulls/{pull_request_number}/files",
            per_page="100",
            page=str(page),
        )
        if not isinstance(payload, list):
            raise ValueError("pull-request files response must contain one list")
        for entry in payload:
            if not isinstance(entry, dict):
                continue
            for key in ("filename", "previous_filename"):
                filename = entry.get(key)
                if isinstance(filename, str) and filename in CONTROL_PLANE_FILES:
                    changed.append(filename)
        if len(payload) < 100:
            break
    else:
        raise ValueError("pull request file inventory exceeds the trusted merge limit")
    if changed:
        raise ValueError(
            "CI proof control plane changes require trusted manual merge: "
            + ", ".join(sorted(set(changed)))
        )


def verify_merge_source(args: Namespace) -> dict[str, Any]:
    require_identity(
        args.repository,
        {"base commit": args.base_commit, "head commit": args.head_commit},
    )
    if args.pull_request_number <= 0 or args.run_id <= 0 or args.run_attempt <= 0:
        raise ValueError("merge source PR and run identities must be positive")
    if HEAD_PATTERN.fullmatch(args.head_ref) is None:
        raise ValueError("merge source head is not a managed development branch")
    if args.base_ref != "main" and re.fullmatch(
        r"gd-ops/train/[A-Za-z0-9._-]+", args.base_ref
    ) is None:
        raise ValueError("merge source base is not main or a managed train")
    require_no_control_plane_change(args.repository, args.pull_request_number)
    require_source_run(args)
    artifacts_payload = api_json(
        f"repos/{args.repository}/actions/runs/{args.run_id}/artifacts",
        per_page="100",
    )
    ticket_artifact = select_merge_ticket_artifact(
        artifacts_payload, args.run_id, args.run_attempt
    )
    candidate_artifact = require_candidate_lane(
        artifacts_payload, args.run_id, args.base_ref
    )
    with tempfile.TemporaryDirectory(prefix="apc-ci-merge-source-") as directory:
        temporary = pathlib.Path(directory)
        ticket_dir = temporary / "ticket"
        extract_archive(
            api_bytes(
                f"repos/{args.repository}/actions/artifacts/{ticket_artifact['id']}/zip",
                int(ticket_artifact["size_in_bytes"]),
            ),
            ticket_dir,
            {"merge-ticket.json"},
            256 * 1024,
        )
        ticket = validate_merge_ticket(
            Namespace(
                repository=args.repository,
                pull_request_number=args.pull_request_number,
                base_ref=args.base_ref,
                base_commit=args.base_commit,
                head_ref=args.head_ref,
                head_commit=args.head_commit,
                run_id=args.run_id,
                run_attempt=args.run_attempt,
                ticket=ticket_dir / "merge-ticket.json",
            )
        )
        ticket_tested_payload = api_json(
            f"repos/{args.repository}/git/commits/{ticket['tested_commit']}"
        )
        ticket_parents = ticket_tested_payload.get("parents")
        ticket_parent_shas = [
            parent.get("sha") for parent in ticket_parents if isinstance(parent, dict)
        ] if isinstance(ticket_parents, list) else []
        if (
            ticket_tested_payload.get("sha") != ticket["tested_commit"]
            or ticket_parent_shas != [args.base_commit, args.head_commit]
        ):
            raise ValueError("merge-ticket tested commit does not bind current base and head")
        if candidate_artifact is not None:
            candidate_dir = temporary / "candidate"
            extract_candidate_archive(
                api_bytes(
                    f"repos/{args.repository}/actions/artifacts/{candidate_artifact['id']}/zip",
                    int(candidate_artifact["size_in_bytes"]),
                ),
                candidate_dir,
            )
            tested_payload = api_json(
                f"repos/{args.repository}/git/commits/{candidate_artifact['tested_commit']}"
            )
            candidate = validate_merge_candidate(
                Namespace(
                    repository=args.repository,
                    pull_request_number=args.pull_request_number,
                    base_commit=args.base_commit,
                    head_commit=args.head_commit,
                    run_id=args.run_id,
                    run_attempt=args.run_attempt,
                    tested_payload=tested_payload,
                    attestation=candidate_dir / "interaction-attestation.json",
                    proof=candidate_dir / "candidate-proof.json",
                )
            )
            if ticket["tested_commit"] != candidate["tested_commit"]:
                raise ValueError("merge ticket and candidate proof tested commits differ")
    return {
        "lane": ticket["lane"],
        "tested_commit": ticket["tested_commit"],
        "full_candidate": ticket["full_candidate"],
    }


def promote(args: Namespace) -> dict[str, int | str]:
    root = args.root.resolve()
    require_identity(args.repository, {"main commit": args.main_commit, "main parent": args.main_parent})
    pull = select_merged_pull(
        api_json(f"repos/{args.repository}/commits/{args.main_commit}/pulls", per_page="100"),
        args.repository,
        args.main_commit,
    )
    selected_run = select_successful_run(
        api_json(
            f"repos/{args.repository}/actions/workflows/ci.yml/runs",
            event="pull_request",
            head_sha=str(pull["head_sha"]),
            per_page="100",
        ),
        args.repository,
        str(pull["head_sha"]),
        str(pull["head_ref"]),
    )
    run_id = selected_run["run_id"]
    require_required_gate(
        api_json(f"repos/{args.repository}/actions/runs/{run_id}/jobs", filter="latest", per_page="100")
    )
    artifact = select_candidate_artifact(
        api_json(f"repos/{args.repository}/actions/runs/{run_id}/artifacts", per_page="100"),
        run_id,
    )
    tested_payload = api_json(
        f"repos/{args.repository}/git/commits/{artifact['tested_commit']}"
    )
    with tempfile.TemporaryDirectory(prefix="apc-ci-promotion-") as directory:
        temporary = pathlib.Path(directory)
        artifact_dir = temporary / "candidate"
        extract_candidate_archive(
            api_bytes(
                f"repos/{args.repository}/actions/artifacts/{artifact['id']}/zip",
                int(artifact["size_in_bytes"]),
            ),
            artifact_dir,
        )
        tested_commit_json = temporary / "tested-commit.json"
        atomic_write_json(tested_commit_json, tested_payload)
        metadata = validate_candidate(
            Namespace(
                root=root,
                repository=args.repository,
                main_commit=args.main_commit,
                main_parent=args.main_parent,
                pull_request_number=int(pull["number"]),
                head_commit=str(pull["head_sha"]),
                run_id=run_id,
                run_attempt=selected_run["run_attempt"],
                tested_commit_json=tested_commit_json,
                attestation=artifact_dir / "interaction-attestation.json",
                proof=artifact_dir / "candidate-proof.json",
            )
        )
        candidate_attestation = args.candidate_attestation.resolve()
        candidate_attestation.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(artifact_dir / "interaction-attestation.json", candidate_attestation)
        candidate_attestation.chmod(0o644)
    atomic_write_json(args.metadata.resolve(), metadata)
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    create_parser = subparsers.add_parser("create-candidate")
    create_parser.add_argument("--repository", required=True)
    create_parser.add_argument("--pull-request-number", required=True, type=int)
    create_parser.add_argument("--base-commit", required=True)
    create_parser.add_argument("--head-commit", required=True)
    create_parser.add_argument("--tested-commit", required=True)
    create_parser.add_argument("--run-id", required=True, type=int)
    create_parser.add_argument("--run-attempt", required=True, type=int)
    create_parser.add_argument("--attestation", required=True, type=pathlib.Path)
    create_parser.add_argument("--output", required=True, type=pathlib.Path)
    ticket_parser = subparsers.add_parser("create-merge-ticket")
    ticket_parser.add_argument("--repository", required=True)
    ticket_parser.add_argument("--pull-request-number", required=True, type=int)
    ticket_parser.add_argument("--base-ref", required=True)
    ticket_parser.add_argument("--base-commit", required=True)
    ticket_parser.add_argument("--head-ref", required=True)
    ticket_parser.add_argument("--head-commit", required=True)
    ticket_parser.add_argument("--tested-commit", required=True)
    ticket_parser.add_argument("--run-id", required=True, type=int)
    ticket_parser.add_argument("--run-attempt", required=True, type=int)
    ticket_parser.add_argument(
        "--lane", required=True,
        choices=("direct-to-main", "task-to-train", "train-to-main"),
    )
    ticket_parser.add_argument("--full-candidate", required=True, choices=("0", "1"))
    ticket_parser.add_argument("--output", required=True, type=pathlib.Path)
    verify_parser = subparsers.add_parser("verify-merge-source")
    verify_parser.add_argument("--repository", required=True)
    verify_parser.add_argument("--pull-request-number", required=True, type=int)
    verify_parser.add_argument("--base-ref", required=True)
    verify_parser.add_argument("--base-commit", required=True)
    verify_parser.add_argument("--head-ref", required=True)
    verify_parser.add_argument("--head-commit", required=True)
    verify_parser.add_argument("--run-id", required=True, type=int)
    verify_parser.add_argument("--run-attempt", required=True, type=int)
    cleanup_parser = subparsers.add_parser("delete-merged-head")
    cleanup_parser.add_argument("--repository", required=True)
    cleanup_parser.add_argument("--pull-request-number", required=True, type=int)
    cleanup_parser.add_argument("--head-ref", required=True)
    cleanup_parser.add_argument("--head-commit", required=True)
    cleanup_parser.add_argument("--allow-delete", required=True, choices=("0", "1"))
    promote_parser = subparsers.add_parser("promote")
    promote_parser.add_argument("--repository", required=True)
    promote_parser.add_argument("--main-commit", required=True)
    promote_parser.add_argument("--main-parent", required=True)
    promote_parser.add_argument("--candidate-attestation", required=True, type=pathlib.Path)
    promote_parser.add_argument("--metadata", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "create-candidate":
            create_candidate(args)
        elif args.command == "create-merge-ticket":
            args.full_candidate = args.full_candidate == "1"
            create_merge_ticket(args)
        elif args.command == "verify-merge-source":
            print(json.dumps(verify_merge_source(args), sort_keys=True))
        elif args.command == "delete-merged-head":
            args.allow_delete = args.allow_delete == "1"
            print(json.dumps(delete_merged_head(args), sort_keys=True))
        else:
            promote(args)
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
        zipfile.BadZipFile,
    ) as error:
        print(f"CI proof promotion unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
