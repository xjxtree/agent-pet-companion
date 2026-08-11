#!/usr/bin/env python3
"""Run complete, inventory-checked Rust test shards for CI and Release."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys


SHARDS: dict[str, list[tuple[str, str]]] = {
    "integration-a": [
        ("petcore", "core_validation"),
        ("petcore", "daemon_http_security"),
        ("petcore", "petpack_resource_limits"),
        ("petcore", "schema_fixtures"),
    ],
    "integration-b": [
        ("petcore", "app_server_transport"),
        ("petcore", "generation_history_delete"),
        ("petcore", "generation_jsonl_recovery"),
        ("petcore", "generation_lifecycle"),
    ],
    "integration-c": [
        ("petcore", "generation_recovery"),
        ("petcore", "petpack_export"),
        ("petcore", "petpack_import_atomic"),
        ("petcore", "process_runner"),
        ("petcore", "reference_image_policy"),
    ],
    "integration-d": [
        ("petcore", "agent_state_arbitration"),
        ("petcore", "bundled_pets"),
        ("petcore", "connector_contracts"),
        ("petcore", "connector_ordering"),
        ("petcore", "daemon_lifecycle"),
        ("petcore", "event_envelope_security"),
        ("petcore", "generation_form_contract"),
        ("petcore", "onboarding"),
        ("petcore", "petpack_v3_contract"),
        ("petcore", "runtime_manifest"),
        ("petcore-cli", "claude_session_message_routing"),
        ("petcore-cli", "petpack_build_metadata"),
        ("petcore-cli", "petpack_export_routing"),
        ("petcore-cli", "petpack_import_routing"),
    ],
}
ALL_SHARDS = ["core", *SHARDS]
COMPLETION_SCHEMA = "apc.rust-test-shard-completion.v1"


def discovered_tests(root: pathlib.Path) -> set[tuple[str, str]]:
    discovered: set[tuple[str, str]] = set()
    for crate in sorted((root / "crates").iterdir()):
        tests = crate / "tests"
        if not tests.is_dir():
            continue
        for path in tests.glob("*.rs"):
            discovered.add((crate.name, path.stem))
    return discovered


def validate_inventory(root: pathlib.Path) -> None:
    assigned = [target for shard in SHARDS.values() for target in shard]
    if len(assigned) != len(set(assigned)):
        raise ValueError("Rust integration test shard inventory contains duplicates")
    discovered = discovered_tests(root)
    assigned_set = set(assigned)
    missing = sorted(discovered - assigned_set)
    extra = sorted(assigned_set - discovered)
    if missing or extra:
        raise ValueError(f"Rust integration shard inventory mismatch: missing={missing} extra={extra}")


def commands(root: pathlib.Path, shard: str) -> list[list[str]]:
    manifest = str(root / "Cargo.toml")
    prefix = ["cargo", "test", "--manifest-path", manifest]
    if shard == "core":
        return [
            [*prefix, "-p", "petcore", "--lib", "--bins", "--locked"],
            [*prefix, "-p", "petcore-cli", "--bin", "petcore-cli", "--locked"],
            [*prefix, "-p", "petcore-types", "--lib", "--locked"],
            [*prefix, "--workspace", "--doc", "--locked"],
        ]
    return [
        [*prefix, "-p", package, "--test", target, "--locked"]
        for package, target in SHARDS[shard]
    ]


def write_completion(proof_dir: pathlib.Path, shard: str) -> pathlib.Path:
    if shard not in ALL_SHARDS:
        raise ValueError(f"unknown Rust test shard: {shard}")
    proof_dir.mkdir(parents=True, exist_ok=True)
    if not proof_dir.is_dir() or proof_dir.is_symlink():
        raise ValueError("Rust shard completion destination must be a directory")
    path = proof_dir / f"{shard}.json"
    path.write_text(
        json.dumps(
            {"schema_version": COMPLETION_SCHEMA, "shard": shard},
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    return path


def validate_completions(proof_dir: pathlib.Path) -> None:
    if not proof_dir.is_dir() or proof_dir.is_symlink():
        raise ValueError("Rust shard completion proof must be a directory")
    entries = sorted(proof_dir.iterdir())
    expected_names = sorted(f"{shard}.json" for shard in ALL_SHARDS)
    actual_names = [entry.name for entry in entries]
    if actual_names != expected_names:
        raise ValueError(
            "Rust shard completion set mismatch: "
            f"expected={expected_names} actual={actual_names}; "
            "rerun all workflow jobs because completion markers cannot cross run attempts"
        )
    for path in entries:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 4096:
            raise ValueError(f"invalid Rust shard completion file: {path.name}")
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError(f"invalid Rust shard completion file: {path.name}") from error
        shard = path.stem
        if payload != {"schema_version": COMPLETION_SCHEMA, "shard": shard}:
            raise ValueError(f"invalid Rust shard completion payload: {path.name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--shard", choices=ALL_SHARDS)
    operation.add_argument("--list-shards", action="store_true")
    operation.add_argument("--verify-completion-dir", type=pathlib.Path)
    parser.add_argument("--completion-dir", type=pathlib.Path)
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        validate_inventory(root)
        if args.list_shards:
            print("\n".join(ALL_SHARDS))
            return 0
        if args.verify_completion_dir is not None:
            if args.plan or args.completion_dir is not None:
                parser.error("completion verification cannot be combined with shard output options")
            validate_completions(args.verify_completion_dir)
            return 0
        if args.shard is None:
            parser.error("--shard is required")
        planned = commands(root, args.shard)
        if args.plan:
            if args.completion_dir is not None:
                parser.error("--completion-dir cannot be used with --plan")
            for command in planned:
                print(" ".join(command))
            return 0
        for command in planned:
            subprocess.run(command, cwd=root, check=True)
        if args.completion_dir is not None:
            write_completion(args.completion_dir, args.shard)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Rust test shard error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
