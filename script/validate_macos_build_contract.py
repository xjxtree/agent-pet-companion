#!/usr/bin/env python3
"""Validate the macOS build host and the App's SDK/deployment contract."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys


DEFAULT_MINIMUM_SWIFT = "6.2"
DEFAULT_MINIMUM_SDK = "26.0"
DEFAULT_DEPLOYMENT_TARGET = "14.0"
LIQUID_GLASS_SYMBOLS = (
    "SwiftUI4ViewPAAE11glassEffect_2in",
    "_OBJC_CLASS_$_NSGlassEffectView",
)


def parse_version(value: str, label: str) -> tuple[int, ...]:
    match = re.fullmatch(r"([0-9]+(?:[.][0-9]+)*)", value.strip())
    if match is None:
        raise ValueError(f"{label} is not a dotted numeric version: {value!r}")
    return tuple(int(component) for component in match.group(1).split("."))


def version_at_least(actual: tuple[int, ...], minimum: tuple[int, ...]) -> bool:
    width = max(len(actual), len(minimum))
    return actual + (0,) * (width - len(actual)) >= minimum + (0,) * (
        width - len(minimum)
    )


def parse_swift_version(output: str) -> tuple[int, ...]:
    match = re.search(r"Apple Swift version ([0-9]+(?:[.][0-9]+)+)", output)
    if match is None:
        raise ValueError("swift --version did not report an Apple Swift version")
    return parse_version(match.group(1), "Swift version")


def parse_macho_build_versions(output: str) -> list[tuple[str, str]]:
    results: list[tuple[str, str]] = []
    blocks = output.split("cmd LC_BUILD_VERSION")
    for block in blocks[1:]:
        platform = re.search(r"(?m)^\s*platform\s+([0-9]+)\s*$", block)
        minos = re.search(r"(?m)^\s*minos\s+([^\s]+)\s*$", block)
        sdk = re.search(r"(?m)^\s*sdk\s+([^\s]+)\s*$", block)
        if platform is None or minos is None or sdk is None:
            raise ValueError("Mach-O LC_BUILD_VERSION is incomplete")
        if platform.group(1) != "1":
            continue
        results.append((minos.group(1), sdk.group(1)))
    if not results:
        raise ValueError("Mach-O has no macOS LC_BUILD_VERSION command")
    return results


def validate_toolchain_outputs(
    swift_output: str,
    sdk_output: str,
    minimum_swift: str,
    minimum_sdk: str,
) -> tuple[str, str]:
    swift = parse_swift_version(swift_output)
    sdk_text = sdk_output.strip()
    sdk = parse_version(sdk_text, "macOS SDK version")
    required_swift = parse_version(minimum_swift, "minimum Swift version")
    required_sdk = parse_version(minimum_sdk, "minimum macOS SDK version")
    if not version_at_least(swift, required_swift):
        raise ValueError(
            f"Apple Swift {'.'.join(map(str, swift))} is older than required {minimum_swift}"
        )
    if not version_at_least(sdk, required_sdk):
        raise ValueError(
            f"macOS SDK {sdk_text} is older than required {minimum_sdk}"
        )
    return ".".join(map(str, swift)), sdk_text


def validate_artifact_outputs(
    otool_output: str,
    nm_output: str,
    deployment_target: str,
    minimum_sdk: str,
) -> list[tuple[str, str]]:
    required_deployment = parse_version(
        deployment_target, "required deployment target"
    )
    required_sdk = parse_version(minimum_sdk, "minimum macOS SDK version")
    build_versions = parse_macho_build_versions(otool_output)
    for minos_text, sdk_text in build_versions:
        minos = parse_version(minos_text, "Mach-O deployment target")
        sdk = parse_version(sdk_text, "Mach-O SDK version")
        if minos != required_deployment:
            raise ValueError(
                f"Mach-O deployment target is {minos_text}, expected {deployment_target}"
            )
        if not version_at_least(sdk, required_sdk):
            raise ValueError(
                f"Mach-O SDK is {sdk_text}, older than required {minimum_sdk}"
            )

    weak_lines = [
        line
        for line in nm_output.splitlines()
        if "(undefined) weak external" in line
    ]
    for symbol in LIQUID_GLASS_SYMBOLS:
        if not any(symbol in line for line in weak_lines):
            raise ValueError(
                f"Liquid Glass symbol is absent or not weak-linked: {symbol}"
            )
    return build_versions


def run(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout


def validate_toolchain(arguments: argparse.Namespace) -> None:
    swift_output = run(["swift", "--version"])
    sdk_output = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    swift, sdk = validate_toolchain_outputs(
        swift_output,
        sdk_output,
        arguments.minimum_swift,
        arguments.minimum_sdk,
    )
    print(
        "macOS build toolchain contract ok: "
        f"Apple Swift {swift}, macOS SDK {sdk}"
    )


def validate_artifact(arguments: argparse.Namespace) -> None:
    binary = arguments.binary
    if binary.is_symlink() or not binary.is_file():
        raise ValueError("--binary must be a regular file")
    otool_output = run(["/usr/bin/otool", "-l", str(binary)])
    nm_output = run(["/usr/bin/nm", "-m", "-u", str(binary)])
    build_versions = validate_artifact_outputs(
        otool_output,
        nm_output,
        arguments.deployment_target,
        arguments.minimum_sdk,
    )
    summary = ", ".join(
        f"minos {minos} / sdk {sdk}" for minos, sdk in build_versions
    )
    print(
        "macOS App compatibility contract ok: "
        f"{summary}; Liquid Glass symbols are weak-linked"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    toolchain = subparsers.add_parser("toolchain")
    toolchain.add_argument("--minimum-swift", default=DEFAULT_MINIMUM_SWIFT)
    toolchain.add_argument("--minimum-sdk", default=DEFAULT_MINIMUM_SDK)
    toolchain.set_defaults(handler=validate_toolchain)

    artifact = subparsers.add_parser("artifact")
    artifact.add_argument("--binary", required=True, type=pathlib.Path)
    artifact.add_argument(
        "--deployment-target", default=DEFAULT_DEPLOYMENT_TARGET
    )
    artifact.add_argument("--minimum-sdk", default=DEFAULT_MINIMUM_SDK)
    artifact.set_defaults(handler=validate_artifact)

    arguments = parser.parse_args()
    try:
        arguments.handler(arguments)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"macOS build contract validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
