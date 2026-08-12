#!/usr/bin/env python3
"""Run complete, inventory-checked Rust test shards for CI and Release."""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import pathlib
import re
import subprocess
import sys


@dataclasses.dataclass(frozen=True)
class TestBinary:
    package: str
    binary: str
    leaf_modules: tuple[str, ...]


SHARDS: dict[str, list[TestBinary]] = {
    "integration-a": [
        TestBinary(
            "petcore",
            "integration_a",
            ("core_validation", "daemon_http_security", "petpack_resource_limits", "schema_fixtures"),
        ),
    ],
    "integration-b": [
        TestBinary(
            "petcore",
            "integration_b",
            ("app_server_transport", "generation_history_delete", "generation_jsonl_recovery", "generation_lifecycle"),
        ),
    ],
    "integration-c": [
        TestBinary(
            "petcore",
            "integration_c",
            ("generation_recovery", "petpack_export", "petpack_import_atomic", "process_runner", "reference_image_policy"),
        ),
    ],
    "integration-d": [
        TestBinary(
            "petcore",
            "integration_d",
            (
                "agent_state_arbitration",
                "bundled_pets",
                "connector_contracts",
                "connector_ordering",
                "daemon_lifecycle",
                "event_envelope_security",
                "generation_form_contract",
                "onboarding",
                "petpack_v3_contract",
                "runtime_manifest",
            ),
        ),
        TestBinary(
            "petcore-cli",
            "integration",
            (
                "claude_session_message_routing",
                "petpack_build_metadata",
                "petpack_export_routing",
                "petpack_import_routing",
            ),
        ),
    ],
}
ALL_SHARDS = ["core", *SHARDS]
COMPLETION_SCHEMA = "apc.rust-test-shard-completion.v1"
IDENTITY_SCHEMA = "apc.rust-test-identities.v1"


def discovered_tests(root: pathlib.Path) -> set[tuple[str, str, str]]:
    discovered: set[tuple[str, str, str]] = set()
    for crate in sorted((root / "crates").iterdir()):
        tests = crate / "tests"
        if not tests.is_dir():
            continue
        for directory in sorted(path for path in tests.iterdir() if path.is_dir()):
            if directory.name in {"fixtures", "test_support"}:
                continue
            aggregator = tests / f"{directory.name}.rs"
            if not aggregator.is_file():
                raise ValueError(
                    f"Rust integration leaf directory has no aggregator binary: {directory}"
                )
            for path in sorted(directory.glob("*.rs")):
                discovered.add((crate.name, aggregator.stem, path.stem))
    return discovered


def validate_inventory(root: pathlib.Path) -> None:
    assigned = [
        (target.package, target.binary, leaf)
        for shard in SHARDS.values()
        for target in shard
        for leaf in target.leaf_modules
    ]
    if len(assigned) != len(set(assigned)):
        raise ValueError("Rust integration test shard inventory contains duplicates")
    discovered = discovered_tests(root)
    assigned_set = set(assigned)
    missing = sorted(discovered - assigned_set)
    extra = sorted(assigned_set - discovered)
    if missing or extra:
        raise ValueError(f"Rust integration shard inventory mismatch: missing={missing} extra={extra}")
    module_pattern = re.compile(
        r'#\[path = "(?P<directory>[a-z0-9_]+)/(?P<file>[a-z0-9_]+)[.]rs"\]\s*mod (?P<module>[a-z0-9_]+);'
    )
    for shard in SHARDS.values():
        for target in shard:
            aggregator = root / "crates" / target.package / "tests" / f"{target.binary}.rs"
            source = aggregator.read_text(encoding="utf-8")
            declared = {
                match.group("module")
                for match in module_pattern.finditer(source)
                if match.group("file") == match.group("module")
            }
            expected = set(target.leaf_modules)
            if declared != expected:
                raise ValueError(
                    f"Rust integration aggregator mismatch for {target.package}/{target.binary}: "
                    f"missing={sorted(expected - declared)} extra={sorted(declared - expected)}"
                )


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
        [*prefix, "-p", target.package, "--test", target.binary, "--locked"]
        for target in SHARDS[shard]
    ]


def listed_test_names(root: pathlib.Path, package: str, binary: str) -> set[str]:
    result = subprocess.run(
        [
            "cargo",
            "test",
            "--manifest-path",
            str(root / "Cargo.toml"),
            "-p",
            package,
            "--test",
            binary,
            "--locked",
            "--",
            "--list",
            "--format",
            "terse",
        ],
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    names = {
        line.removesuffix(": test")
        for line in result.stdout.splitlines()
        if line.endswith(": test")
    }
    if not names:
        raise ValueError(f"Rust test binary listed no tests: {package}/{binary}")
    return names


def consolidated_test_identities(root: pathlib.Path) -> set[str]:
    identities: set[str] = set()
    for shard in SHARDS.values():
        for target in shard:
            leaves = set(target.leaf_modules)
            for name in listed_test_names(root, target.package, target.binary):
                leaf, separator, test_name = name.partition("::")
                if not separator or leaf not in leaves or not test_name:
                    raise ValueError(
                        f"Rust test identity is not owned by one declared leaf: "
                        f"{target.package}/{target.binary}/{name}"
                    )
                identity = f"{target.package}:{leaf}:{test_name}"
                if identity in identities:
                    raise ValueError(f"duplicate canonical Rust test identity: {identity}")
                identities.add(identity)
    return identities


def legacy_test_identities(root: pathlib.Path) -> set[str]:
    identities: set[str] = set()
    for package in ("petcore", "petcore-cli"):
        tests = root / "crates" / package / "tests"
        binaries = sorted(path.stem for path in tests.glob("*.rs"))
        if not binaries:
            raise ValueError(f"legacy Rust test inventory is empty: {package}")
        for binary in binaries:
            for name in listed_test_names(root, package, binary):
                identity = f"{package}:{binary}:{name}"
                if identity in identities:
                    raise ValueError(f"duplicate canonical Rust test identity: {identity}")
                identities.add(identity)
    return identities


def identity_digest(identities: set[str]) -> str:
    payload = "".join(f"{identity}\n" for identity in sorted(identities))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def compare_identities(root: pathlib.Path, legacy_root: pathlib.Path) -> None:
    current = consolidated_test_identities(root)
    legacy = legacy_test_identities(legacy_root)
    missing = sorted(legacy - current)
    extra = sorted(current - legacy)
    if missing or extra:
        raise ValueError(
            "Rust test identity mismatch after consolidation: "
            f"missing={missing[:20]} extra={extra[:20]}"
        )
    print(
        json.dumps(
            {
                "schema_version": IDENTITY_SCHEMA,
                "identity_count": len(current),
                "identity_sha256": identity_digest(current),
                "legacy_root_commit": subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    cwd=legacy_root,
                    check=True,
                    text=True,
                    stdout=subprocess.PIPE,
                ).stdout.strip(),
            },
            sort_keys=True,
        )
    )


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
    operation.add_argument("--list-leaves", action="store_true")
    operation.add_argument("--verify-completion-dir", type=pathlib.Path)
    operation.add_argument("--compare-identities", type=pathlib.Path)
    parser.add_argument("--completion-dir", type=pathlib.Path)
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        validate_inventory(root)
        if args.list_shards:
            print("\n".join(ALL_SHARDS))
            return 0
        if args.list_leaves:
            for package, binary, leaf in sorted(discovered_tests(root)):
                print(f"{package}:{binary}:{leaf}")
            return 0
        if args.verify_completion_dir is not None:
            if args.plan or args.completion_dir is not None:
                parser.error("completion verification cannot be combined with shard output options")
            validate_completions(args.verify_completion_dir)
            return 0
        if args.compare_identities is not None:
            if args.plan or args.completion_dir is not None:
                parser.error("identity comparison cannot be combined with shard output options")
            legacy_root = args.compare_identities.resolve()
            if legacy_root == root or not (legacy_root / "Cargo.toml").is_file():
                parser.error("identity comparison requires a distinct legacy repository root")
            compare_identities(root, legacy_root)
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
