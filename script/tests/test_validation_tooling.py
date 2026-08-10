#!/usr/bin/env python3

from __future__ import annotations

import json
import hashlib
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
LOCALIZATION_VALIDATOR = ROOT / "script/validate_localizations.py"
FINGERPRINT = ROOT / "script/validation_fingerprint.py"
INTERACTION_VALIDATOR = ROOT / "script/validate_interaction_attestation.py"
OVERLAY_INTERACTION = ROOT / "script/validate_overlay_interaction.sh"
VALIDATION_SCOPE_PATH = ROOT / "script/validation_scope.py"
INTERACTION_SUITES = [
    "OverlayPlacementAuthorityTests",
    "AppStoreOverlaySnapshotTests",
    "OverlayGeometryTests",
    "OverlayDisplayWidthTests",
    "OverlayInteractionTelemetryTests",
]


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


validation_scope = load_module("apc_validation_scope", VALIDATION_SCOPE_PATH)


def write_localizations(root: pathlib.Path, *, chinese_value: str = "宠物库") -> None:
    resources = root / "apps/macos/Sources/AgentPetCompanion/Resources"
    (resources / "en.lproj").mkdir(parents=True)
    (resources / "zh-Hans.lproj").mkdir(parents=True)
    (resources / "en.lproj/Localizable.strings").write_text(
        '/* navigation */\n"nav.library" = "Pet Library";\n', encoding="utf-8"
    )
    (resources / "zh-Hans.lproj/Localizable.strings").write_text(
        f'"nav.library" = "{chinese_value}";\n', encoding="utf-8"
    )
    catalog = {
        "sourceLanguage": "en",
        "strings": {
            "nav.library": {
                "localizations": {
                    "en": {"stringUnit": {"state": "translated", "value": "Pet Library"}},
                    "zh-Hans": {"stringUnit": {"state": "translated", "value": "宠物库"}},
                }
            }
        },
        "version": "1.0",
    }
    (resources / "Localizable.xcstrings").write_text(
        json.dumps(catalog, ensure_ascii=False), encoding="utf-8"
    )


class LocalizationValidationTests(unittest.TestCase):
    def test_matching_catalog_and_strings_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_localizations(root)
            result = subprocess.run(
                [str(LOCALIZATION_VALIDATOR), "--root", str(root)],
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_value_drift_fails_with_the_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_localizations(root, chinese_value="错误翻译")
            result = subprocess.run(
                [str(LOCALIZATION_VALIDATOR), "--root", str(root)],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("nav.library", result.stderr)


class ValidationFingerprintTests(unittest.TestCase):
    def test_scope_changes_only_when_its_inputs_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            (root / "crates/example").mkdir(parents=True)
            (root / "docs").mkdir()
            (root / "script").mkdir()
            (root / "crates/example/lib.rs").write_text("pub fn value() -> u8 { 1 }\n", encoding="utf-8")
            (root / "crates/example/other.rs").write_text("pub fn other() {}\n", encoding="utf-8")
            (root / "Cargo.toml").write_text("[workspace]\nmembers = []\n", encoding="utf-8")
            (root / "Cargo.lock").write_text("", encoding="utf-8")
            (root / "docs/note.md").write_text("one\n", encoding="utf-8")
            (root / "script/interaction-contract-files.txt").write_text(
                "crates/example/lib.rs\n", encoding="utf-8"
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)

            def digest() -> str:
                return subprocess.check_output(
                    [str(FINGERPRINT), "--root", str(root), "--scope", "rust"],
                    text=True,
                ).strip()

            original = digest()
            (root / "docs/note.md").write_text("two\n", encoding="utf-8")
            self.assertEqual(digest(), original)
            (root / "crates/example/lib.rs").write_text("pub fn value() -> u8 { 2 }\n", encoding="utf-8")
            modified = digest()
            self.assertNotEqual(modified, original)
            (root / "crates/example/other.rs").unlink()
            self.assertNotEqual(digest(), modified)


class ValidationScopeTests(unittest.TestCase):
    def test_docs_only_does_not_schedule_builds_or_computer_use(self) -> None:
        scope = validation_scope.classify(["docs/architecture/overview.md"])
        self.assertTrue(scope.docs_only)
        self.assertEqual(scope.rust_mode, "none")
        self.assertEqual(scope.swift_mode, "none")
        self.assertFalse(scope.bundle)
        self.assertEqual(scope.computer_use, "not_required")

    def test_overlay_change_uses_focused_swift_and_recommends_live_ui(self) -> None:
        scope = validation_scope.classify(
            ["apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"]
        )
        self.assertEqual(scope.swift_mode, "overlay")
        self.assertTrue(scope.bundle)
        self.assertEqual(scope.computer_use, "recommended")

    def test_localization_does_not_expand_to_all_swift_tests(self) -> None:
        scope = validation_scope.classify(
            [
                "apps/macos/Sources/AgentPetCompanion/Resources/Localizable.xcstrings",
                "apps/macos/Sources/AgentPetCompanion/Resources/en.lproj/Localizable.strings",
            ]
        )
        self.assertTrue(scope.localization)
        self.assertEqual(scope.swift_mode, "none")
        self.assertFalse(scope.bundle)

    def test_shared_contract_expands_to_workspace_and_bundle(self) -> None:
        scope = validation_scope.classify(["crates/petcore-types/src/lib.rs"])
        self.assertEqual(scope.rust_mode, "workspace")
        self.assertTrue(scope.bundle)

    def test_skill_change_selects_producer_connector_version_and_bundle(self) -> None:
        scope = validation_scope.classify(["skills/agent-pet-maker/SKILL.md"])
        self.assertTrue(scope.producer)
        self.assertTrue(scope.plugin_version)
        self.assertTrue(scope.bundle)

    def test_connector_document_runs_contract_smoke_without_building_app(self) -> None:
        scope = validation_scope.classify(["docs/integrations/agent-connectors.md"])
        self.assertTrue(scope.connectors)
        self.assertFalse(scope.docs_only)
        self.assertFalse(scope.bundle)

    def test_workflow_change_runs_script_contracts_without_product_build(self) -> None:
        scope = validation_scope.classify([".github/workflows/ci.yml"])
        self.assertTrue(scope.scripts)
        self.assertFalse(scope.bundle)

    def test_macos_build_contract_change_rebuilds_the_app_bundle(self) -> None:
        scope = validation_scope.classify(
            ["script/validate_macos_build_contract.py"]
        )
        self.assertTrue(scope.scripts)
        self.assertTrue(scope.bundle)


class InteractionProofTests(unittest.TestCase):
    def test_current_proof_can_be_rebound_without_repeating_swift_tests(self) -> None:
        entries = [
            line
            for line in (ROOT / "script/interaction-contract-files.txt")
            .read_text(encoding="utf-8")
            .splitlines()
            if line
        ]
        digest = hashlib.sha256()
        for entry in entries:
            digest.update(entry.encode("utf-8"))
            digest.update(b"\0")
            digest.update((ROOT / entry).read_bytes())
            digest.update(b"\0")

        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            proof = temporary / "proof.json"
            rebound = temporary / "rebound.json"
            proof.write_text(
                json.dumps(
                    {
                        "schema_version": "apc.overlay-interaction-attestation.v1",
                        "build_id": "old-build",
                        "interaction_contract_digest": digest.hexdigest(),
                        "passed_suites": INTERACTION_SUITES,
                        "ok": True,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            subprocess.run([str(INTERACTION_VALIDATOR), str(proof)], check=True)
            proof_link = temporary / "proof-link.json"
            proof_link.symlink_to(proof)
            linked = subprocess.run(
                [str(INTERACTION_VALIDATOR), str(proof_link)],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(linked.returncode, 0)
            self.assertIn("non-symlink", linked.stderr)
            subprocess.run(
                [
                    str(OVERLAY_INTERACTION),
                    "--proof-in",
                    str(proof),
                    "--attestation-out",
                    str(rebound),
                    "--build-id",
                    "new-build",
                ],
                check=True,
                text=True,
                capture_output=True,
            )
            payload = json.loads(rebound.read_text(encoding="utf-8"))
            self.assertEqual(payload["build_id"], "new-build")
            self.assertEqual(payload["interaction_contract_digest"], digest.hexdigest())


if __name__ == "__main__":
    unittest.main()
