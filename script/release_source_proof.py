#!/usr/bin/env python3
"""Create and validate source proof reused by the GitHub Release workflow."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA_VERSION = "apc.release-source-proof.v1"
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
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
TAG_PATTERN = re.compile(r"v[0-9]+[.][0-9]+[.][0-9]+")


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


def read_json_regular(path: pathlib.Path) -> dict[str, Any]:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as error:
        raise ValueError(f"proof input must be a regular, non-symlink file: {path.name}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 1024 * 1024:
            raise ValueError(f"proof input is not a bounded regular file: {path.name}")
        with os.fdopen(descriptor, encoding="utf-8") as handle:
            descriptor = -1
            payload = json.load(handle)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(payload, dict):
        raise ValueError(f"proof input must contain one JSON object: {path.name}")
    return payload


def require_identity(repository: str, commit: str, previous_release_tag: str) -> None:
    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise ValueError("repository must be owner/name")
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValueError("commit must be a full lowercase Git commit")
    if TAG_PATTERN.fullmatch(previous_release_tag) is None:
        raise ValueError("previous release tag must be vX.Y.Z")


def validate_attestation(
    root: pathlib.Path, attestation: pathlib.Path, commit: str
) -> dict[str, Any]:
    subprocess.run(
        [
            str(root / "script/validate_interaction_attestation.py"),
            str(attestation),
            "--root",
            str(root),
            "--expected-build-id",
            f"source.{commit}",
        ],
        cwd=root,
        check=True,
    )
    return read_json_regular(attestation)


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


def atomic_write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
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


def create(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    require_identity(args.repository, args.commit, args.previous_release_tag)
    if args.run_id <= 0 or args.run_attempt <= 0:
        raise ValueError("run id and run attempt must be positive")
    if run(root, "git", "rev-parse", "HEAD") != args.commit:
        raise ValueError("proof checkout does not match the requested commit")
    if run(root, "git", "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("proof checkout contains tracked modifications")
    attestation = args.attestation.resolve()
    attestation_payload = validate_attestation(root, attestation, args.commit)
    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "repository": args.repository,
        "commit": args.commit,
        "source_tree": run(root, "git", "rev-parse", "HEAD^{tree}"),
        "previous_release_tag": args.previous_release_tag,
        "workflow_path": WORKFLOW_PATH,
        "workflow_event": "push",
        "workflow_ref": "refs/heads/main",
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
    atomic_write_json(args.output.resolve(), payload)


def validate(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    require_identity(args.repository, args.commit, args.previous_release_tag)
    if run(root, "git", "rev-parse", "HEAD") != args.commit:
        raise ValueError("proof validation checkout does not match the requested commit")
    if run(root, "git", "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("proof validation checkout contains tracked modifications")
    proof = read_json_regular(args.proof.resolve())
    expected_keys = {
        "schema_version",
        "repository",
        "commit",
        "source_tree",
        "previous_release_tag",
        "workflow_path",
        "workflow_event",
        "workflow_ref",
        "run_id",
        "run_attempt",
        "gates",
        "toolchain_contract_digest",
        "observed_toolchains",
        "interaction_attestation_sha256",
        "interaction_contract_digest",
        "ok",
    }
    if set(proof) != expected_keys:
        raise ValueError("source proof field inventory is invalid")
    checks = {
        "schema_version": SCHEMA_VERSION,
        "repository": args.repository,
        "commit": args.commit,
        "source_tree": run(root, "git", "rev-parse", "HEAD^{tree}"),
        "previous_release_tag": args.previous_release_tag,
        "workflow_path": WORKFLOW_PATH,
        "workflow_event": "push",
        "workflow_ref": "refs/heads/main",
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "gates": EXPECTED_GATES,
        "toolchain_contract_digest": contract_digest(root),
        "ok": True,
    }
    for key, expected in checks.items():
        if proof.get(key) != expected:
            raise ValueError(f"source proof {key} does not match the release request")
    observed = proof.get("observed_toolchains")
    if not isinstance(observed, dict) or set(observed) != {"rustc", "swift", "python", "sdk"}:
        raise ValueError("source proof observed toolchain inventory is invalid")
    if any(not isinstance(value, str) or not value or len(value) > 4096 for value in observed.values()):
        raise ValueError("source proof contains an invalid observed toolchain identity")
    attestation = args.attestation.resolve()
    proof_path = args.proof.resolve()
    if proof_path.parent != attestation.parent:
        raise ValueError("source proof files must share one artifact directory")
    inventory = []
    for child in proof_path.parent.iterdir():
        metadata = child.lstat()
        if not stat.S_ISREG(metadata.st_mode) or child.is_symlink():
            raise ValueError("source proof artifact contains a non-regular entry")
        inventory.append(child.name)
    if sorted(inventory) != ["interaction-attestation.json", "source-proof.json"]:
        raise ValueError("source proof artifact inventory must contain exactly two files")
    attestation_payload = validate_attestation(root, attestation, args.commit)
    if proof.get("interaction_attestation_sha256") != sha256(attestation):
        raise ValueError("source proof interaction attestation digest is invalid")
    if proof.get("interaction_contract_digest") != attestation_payload.get(
        "interaction_contract_digest"
    ):
        raise ValueError("source proof interaction contract digest is invalid")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("create", "validate"):
        command = subparsers.add_parser(name)
        command.add_argument("--repository", required=True)
        command.add_argument("--commit", required=True)
        command.add_argument("--previous-release-tag", required=True)
        command.add_argument("--run-id", required=True, type=int)
        command.add_argument("--run-attempt", required=True, type=int)
        command.add_argument("--attestation", required=True, type=pathlib.Path)
        if name == "create":
            command.add_argument("--output", required=True, type=pathlib.Path)
        else:
            command.add_argument("--proof", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "create":
            create(args)
        else:
            validate(args)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"release source proof error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
