#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "script/validate_macos_build_contract.py"
SPEC = importlib.util.spec_from_file_location("macos_build_contract", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contract)


class MacOSBuildContractTests(unittest.TestCase):
    def test_toolchain_accepts_swift_6_2_and_sdk_26(self) -> None:
        swift, sdk = contract.validate_toolchain_outputs(
            "Apple Swift version 6.2.0 (swiftlang-6.2.0 clang-1700.0.0.0)",
            "26.0\n",
            "6.2",
            "26.0",
        )
        self.assertEqual(swift, "6.2.0")
        self.assertEqual(sdk, "26.0")

    def test_toolchain_rejects_old_compiler_and_sdk(self) -> None:
        with self.assertRaisesRegex(ValueError, "older than required 6.2"):
            contract.validate_toolchain_outputs(
                "Apple Swift version 6.1.2",
                "26.0",
                "6.2",
                "26.0",
            )
        with self.assertRaisesRegex(ValueError, "older than required 26.0"):
            contract.validate_toolchain_outputs(
                "Apple Swift version 6.3.3",
                "15.5",
                "6.2",
                "26.0",
            )

    def test_artifact_accepts_minos_14_sdk_26_and_weak_glass(self) -> None:
        build_versions = contract.validate_artifact_outputs(
            """
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 14.0
      sdk 26.5
   ntools 1
""",
            """
                 (undefined) weak external _$s7SwiftUI4ViewPAAE11glassEffect_2inQr
                 (undefined) weak external _OBJC_CLASS_$_NSGlassEffectView
""",
            "14.0",
            "26.0",
        )
        self.assertEqual(build_versions, [("14.0", "26.5")])

    def test_artifact_rejects_raised_target_old_sdk_or_strong_glass(self) -> None:
        good_symbols = """
                 (undefined) weak external _$s7SwiftUI4ViewPAAE11glassEffect_2inQr
                 (undefined) weak external _OBJC_CLASS_$_NSGlassEffectView
"""
        with self.assertRaisesRegex(ValueError, "expected 14.0"):
            contract.validate_artifact_outputs(
                "cmd LC_BUILD_VERSION\n platform 1\n minos 26.0\n sdk 26.5\n",
                good_symbols,
                "14.0",
                "26.0",
            )
        with self.assertRaisesRegex(ValueError, "older than required 26.0"):
            contract.validate_artifact_outputs(
                "cmd LC_BUILD_VERSION\n platform 1\n minos 14.0\n sdk 15.5\n",
                good_symbols,
                "14.0",
                "26.0",
            )
        with self.assertRaisesRegex(ValueError, "absent or not weak-linked"):
            contract.validate_artifact_outputs(
                "cmd LC_BUILD_VERSION\n platform 1\n minos 14.0\n sdk 26.5\n",
                "(undefined) external _OBJC_CLASS_$_NSGlassEffectView\n",
                "14.0",
                "26.0",
            )


if __name__ == "__main__":
    unittest.main()
