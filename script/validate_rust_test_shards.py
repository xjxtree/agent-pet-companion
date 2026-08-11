#!/usr/bin/env python3
"""Run complete, inventory-checked Rust test shards for CI and Release."""

from __future__ import annotations

import argparse
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument("--shard", choices=ALL_SHARDS)
    parser.add_argument("--list-shards", action="store_true")
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        validate_inventory(root)
        if args.list_shards:
            print("\n".join(ALL_SHARDS))
            return 0
        if args.shard is None:
            parser.error("--shard is required unless --list-shards is used")
        planned = commands(root, args.shard)
        if args.plan:
            for command in planned:
                print(" ".join(command))
            return 0
        for command in planned:
            subprocess.run(command, cwd=root, check=True)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Rust test shard error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
