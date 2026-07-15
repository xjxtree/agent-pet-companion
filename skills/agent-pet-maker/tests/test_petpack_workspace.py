#!/usr/bin/env python3
"""Focused contract tests for the portable pet maker helper."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "petpack_workspace.py"
SPEC = importlib.util.spec_from_file_location("petpack_workspace", HELPER)
assert SPEC and SPEC.loader
workspace_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workspace_helper)


FAKE_CLI = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["FAKE_CLI_STATE"])
calls_path = Path(os.environ["FAKE_CLI_CALLS"])
state = json.loads(state_path.read_text()) if state_path.exists() else {"pets": []}
args = sys.argv[1:]
calls = json.loads(calls_path.read_text()) if calls_path.exists() else []
calls.append(args)
calls_path.write_text(json.dumps(calls))

pet_id = os.environ.get("FAKE_MANIFEST_ID", "pet_test")
manifest = {
    "schema_version": "apc.petpack.v1",
    "id": pet_id,
    "name": "Test Pet",
    "style": "storybook",
    "quality": "standard",
    "render_size": {"width": 192, "height": 208},
}

if args[:2] == ["petpack", "validate"]:
    print(json.dumps({"ok": True, "manifest": manifest, "frame_count": 14, "warnings": []}))
elif args[:2] == ["pet", "list"]:
    print(json.dumps(state["pets"]))
elif args[:2] == ["petpack", "import"]:
    returned_id = os.environ.get("FAKE_IMPORT_ID", pet_id)
    existing = next((item for item in state["pets"] if item["id"] == returned_id), None)
    active = bool(existing and existing.get("active"))
    state["pets"] = [item for item in state["pets"] if item["id"] != returned_id]
    imported = {**manifest, "id": returned_id, "active": active}
    state["pets"].append(imported)
    state_path.write_text(json.dumps(state))
    print(json.dumps(imported))
elif args[:2] == ["pet", "activate"]:
    if os.environ.get("FAKE_FAIL_ACTIVATE") == "1":
        print("activation failed", file=sys.stderr)
        raise SystemExit(1)
    requested = args[args.index("--id") + 1]
    for item in state["pets"]:
        item["active"] = item["id"] == requested
    state_path.write_text(json.dumps(state))
    print(json.dumps({"ok": True}))
elif args[:2] == ["state", "snapshot"]:
    print(json.dumps({
        "pets": state["pets"],
        "behavior": {"enabled": os.environ.get("FAKE_BEHAVIOR_ENABLED") == "1"},
        "overlay_visibility": {
            "pet_visible": os.environ.get("FAKE_OVERLAY_VISIBLE") == "1",
            "status_bubble_visible": False,
        },
    }))
else:
    print("unexpected command: " + repr(args), file=sys.stderr)
    raise SystemExit(2)
'''


class InstallTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="agent-pet-maker-tests-")
        self.root = Path(self.temporary.name)
        self.cli = self.root / "petcore-cli"
        self.cli.write_text(FAKE_CLI, encoding="utf-8")
        self.cli.chmod(0o755)
        self.package = self.root / "pet.petpack"
        self.package.write_bytes(b"test-petpack-content")
        self.state = self.root / "state.json"
        self.calls = self.root / "calls.json"
        self.result = self.root / "result.json"
        self.environment = {
            **os.environ,
            "FAKE_CLI_STATE": str(self.state),
            "FAKE_CLI_CALLS": str(self.calls),
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_install(self, *extra: str, explicit_cli: bool = True) -> tuple[subprocess.CompletedProcess[str], dict]:
        arguments = [
            sys.executable,
            str(HELPER),
            "install",
            "--input",
            str(self.package),
            "--result",
            str(self.result),
        ]
        if explicit_cli:
            arguments.extend(["--cli", str(self.cli)])
        arguments.extend(extra)
        completed = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
            env=self.environment,
        )
        return completed, json.loads(self.result.read_text(encoding="utf-8"))

    def calls_made(self) -> list[list[str]]:
        return json.loads(self.calls.read_text(encoding="utf-8"))

    def test_online_install_does_not_activate_or_enable_behavior_implicitly(self) -> None:
        completed, result = self.run_install()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["status"], "completed")
        self.assertFalse(result["install"]["activation"]["attempted"])
        verification = result["install"]["verification"]
        self.assertFalse(verification["active"])
        self.assertFalse(verification["behavior_enabled"])
        self.assertFalse(verification["overlay_visibility"]["pet_visible"])
        self.assertTrue(all("--offline" not in call for call in self.calls_made()))
        self.assertEqual(
            [call[:2] for call in self.calls_made()].count(["petpack", "validate"]), 2
        )

    def test_existing_id_is_rejected_before_import_by_default(self) -> None:
        self.state.write_text(json.dumps({"pets": [{"id": "pet_test", "active": False}]}))
        completed, result = self.run_install()
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["error"]["code"], "existing_pet_id")
        self.assertNotIn(["petpack", "import"], [call[:2] for call in self.calls_made()])

    def test_install_rejects_a_symlinked_input_before_cli_mutation(self) -> None:
        link = self.root / "linked.petpack"
        link.symlink_to(self.package)
        self.package = link
        completed, result = self.run_install()
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["error"]["code"], "invalid_input")
        self.assertFalse(self.calls.exists())

    def test_explicit_revision_can_import_and_activate(self) -> None:
        self.state.write_text(json.dumps({"pets": [{"id": "pet_test", "active": False}]}))
        completed, result = self.run_install("--allow-existing-id-revision", "--activate")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["status"], "completed")
        self.assertTrue(result["install"]["activation"]["succeeded"])
        self.assertTrue(result["install"]["verification"]["active"])

    def test_activation_failure_writes_partial_success_with_verification(self) -> None:
        self.environment["FAKE_FAIL_ACTIVATE"] = "1"
        completed, result = self.run_install("--activate")
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(result["status"], "partial_success")
        self.assertTrue(result["install"]["import"]["succeeded"])
        self.assertFalse(result["install"]["verification"]["active"])
        self.assertEqual(result["error"]["code"], "install_activation_failed")

    def test_install_prefers_app_runtime_current_over_path(self) -> None:
        app_home = self.root / "app-home"
        runtime_cli = app_home / "runtime" / "current" / "petcore-cli"
        runtime_cli.parent.mkdir(parents=True)
        runtime_cli.write_text(FAKE_CLI, encoding="utf-8")
        runtime_cli.chmod(0o755)
        path_bin = self.root / "path-bin"
        path_bin.mkdir()
        path_cli = path_bin / "petcore-cli"
        path_cli.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
        path_cli.chmod(0o755)
        self.environment["APC_HOME"] = str(app_home)
        self.environment["PATH"] = f"{path_bin}:{self.environment.get('PATH', '')}"
        completed, result = self.run_install(explicit_cli=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["install"]["cli_path"], str(runtime_cli.resolve()))


class MetadataContractTests(unittest.TestCase):
    def test_installed_cli_candidates_include_runtime_bundle_and_real_app_name(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-discovery-") as temporary:
            root = Path(temporary)
            app_home = root / "app-home"
            fake_helper = (
                root
                / "AgentPetCompanion.app"
                / "Contents"
                / "Resources"
                / "skills"
                / "agent-pet-maker"
                / "scripts"
                / "petpack_workspace.py"
            )
            with mock.patch.dict(os.environ, {"APC_HOME": str(app_home)}), mock.patch.object(
                workspace_helper.Path, "home", return_value=root / "user-home"
            ), mock.patch.object(workspace_helper, "__file__", str(fake_helper)):
                candidates = workspace_helper.installed_cli_candidates()

            self.assertEqual(
                candidates[0], app_home / "runtime" / "current" / "petcore-cli"
            )
            self.assertEqual(
                candidates[1],
                (
                    root
                    / "AgentPetCompanion.app"
                    / "Contents"
                    / "Resources"
                    / "bin"
                    / "petcore-cli"
                ).resolve(),
            )
            self.assertIn(
                Path("/Applications/AgentPetCompanion.app/Contents/Resources/bin/petcore-cli"),
                candidates,
            )
            self.assertIn(
                Path("/Applications/Agent Pet Companion.app/Contents/Resources/bin/petcore-cli"),
                candidates,
            )

    def test_online_cli_discovery_prefers_runtime_current_over_bundled_cli(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-discovery-") as temporary:
            root = Path(temporary)
            app_home = root / "app-home"
            runtime_cli = app_home / "runtime" / "current" / "petcore-cli"
            bundled_cli = (
                root
                / "AgentPetCompanion.app"
                / "Contents"
                / "Resources"
                / "bin"
                / "petcore-cli"
            )
            fake_helper = (
                root
                / "AgentPetCompanion.app"
                / "Contents"
                / "Resources"
                / "skills"
                / "agent-pet-maker"
                / "scripts"
                / "petpack_workspace.py"
            )
            for cli in (runtime_cli, bundled_cli):
                cli.parent.mkdir(parents=True, exist_ok=True)
                cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                cli.chmod(0o755)

            with mock.patch.dict(
                os.environ,
                {"APC_HOME": str(app_home), "APC_PETCORE_CLI": ""},
            ), mock.patch.object(
                workspace_helper.Path, "home", return_value=root / "user-home"
            ), mock.patch.object(workspace_helper, "__file__", str(fake_helper)):
                self.assertEqual(workspace_helper.locate_install_cli(), runtime_cli.resolve())
                runtime_cli.unlink()
                self.assertEqual(workspace_helper.locate_install_cli(), bundled_cli.resolve())

    def test_missing_pillow_is_a_clean_capability_failure(self) -> None:
        real_import = __import__

        def reject_pillow(name: str, *args: object, **kwargs: object) -> object:
            if name == "PIL":
                raise ImportError("Pillow unavailable")
            return real_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=reject_pillow):
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.verify_image_codecs()
        self.assertEqual(raised.exception.code, "capability_missing")

    def test_canonical_source_normalization_uses_only_schema_fields(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-source-") as temporary:
            source = Path(temporary)
            (source / "source" / "references").mkdir(parents=True)
            metadata = {
                "schema_version": "apc.pet-source.v1",
                "generator": "image-tool",
                "provenance": "skill-full-source",
                "runner": "host-agent",
                "visual_source": "image-generation",
                "frames_per_state": 2,
                "preview_only": False,
                "reference_files": [],
            }
            (source / "source" / "source.json").write_text(
                json.dumps(metadata), encoding="utf-8"
            )
            normalized = workspace_helper.normalize_source_metadata(
                source,
                "modify",
                {"base": {"pet_id": "pet_test"}},
                ["tool"],
                {state: 2 for state in workspace_helper.STATES},
                {
                    "id": "pet_test",
                    "name": "Test",
                    "style": "storybook",
                    "quality": "standard",
                },
            )
            self.assertFalse(set(normalized) - workspace_helper.SOURCE_ALLOWED_KEYS)
            self.assertEqual(normalized["provenance"], "skill-full-source")
            self.assertEqual(normalized["base_manifest_id"], "pet_test")
            self.assertEqual(normalized["changed_states"], ["tool"])
            self.assertNotIn("producer", normalized)
            self.assertNotIn("operation", normalized)
            self.assertNotIn("frame_counts", normalized)

    def test_source_and_events_reject_undeclared_forward_test_fields(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-metadata-") as temporary:
            source = Path(temporary)
            (source / "source" / "references").mkdir(parents=True)
            (source / "source" / "source.json").write_text(
                json.dumps(
                    {
                        "schema_version": "apc.pet-source.v1",
                        "generator": "image-tool",
                        "provenance": "skill-full-source",
                        "runner": "host-agent",
                        "visual_source": "image-generation",
                        "frames_per_state": 2,
                        "preview_only": False,
                        "reference_files": [],
                        "producer": {"agent": "host-agent"},
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(workspace_helper.MakerError):
                workspace_helper.normalize_source_metadata(
                    source,
                    "create",
                    {},
                    [],
                    {state: 2 for state in workspace_helper.STATES},
                    {
                        "id": "pet_test",
                        "name": "Test",
                        "style": "storybook",
                        "quality": "standard",
                    },
                )

            workspace_helper.write_session(
                source,
                {
                    "schema_version": "apc.pet-source-event.v1",
                    "event": "workspace.prepared",
                    "operation": "create",
                },
            )
            with self.assertRaises(workspace_helper.MakerError):
                workspace_helper.validate_session(source)


class PrivacyHelpersTests(unittest.TestCase):
    def test_embedded_private_locations_are_classified_without_echoing_values(self) -> None:
        self.assertEqual(
            workspace_helper.contains_sensitive_string(
                {"note": "reference(/Users/private-user/embedded-secret.png)"}
            ),
            "absolute_local_path",
        )
        self.assertEqual(
            workspace_helper.contains_sensitive_string(
                {"note": "路径/Users/private-user/embedded-secret.png"}
            ),
            "absolute_local_path",
        )
        self.assertEqual(
            workspace_helper.contains_sensitive_string(
                {"note": "reference(https://private.example.invalid/embedded-secret.png)"}
            ),
            "external_locator",
        )

    def test_namespaced_and_affixed_private_keys_return_only_the_category(self) -> None:
        for key, category in (
            ("dev.example/thread_id", "thread_id"),
            ("dev.example/api_key_backup", "credential"),
            ("metadata_thread_id", "thread_id"),
            ("thread_id_backup", "thread_id"),
            ("metadataThreadId", "thread_id"),
            ("threadIdBackup", "thread_id"),
            ("metadataSessionIdBackup", "session_id"),
            ("threadidbackup", "thread_id"),
            ("backupsessionid", "session_id"),
            ("dev.example/threadidbackup", "thread_id"),
            ("backupapikey", "credential"),
        ):
            with self.subTest(key=key):
                self.assertEqual(
                    workspace_helper.contains_forbidden_key({key: "private-session-value"}),
                    category,
                )

    def test_path_like_prose_and_non_private_words_remain_allowed(self) -> None:
        value = {
            "note": "Animate idle/start/tool at 12/20 fps; use / as a separator and (https-inspired) highlights.",
            "reference_note": "reference(images/moon.png) and assets/frames/idle/frame_000.png",
            "authentic_style": "storybook",
            "commanding_motion": "confident pose",
            "environmental_lighting": "soft rim light",
            "secretary_note": "friendly expression",
            "threadlike_pattern": "fine silver embroidery",
            "tokenized_palette": "violet and pearl",
        }
        self.assertIsNone(workspace_helper.contains_sensitive_string(value))
        self.assertIsNone(workspace_helper.contains_forbidden_key(value))

    def test_source_normalization_reports_only_privacy_categories(self) -> None:
        cases = (
            ({"note": "reference(/Users/private-user/embedded-secret.png)"}, "absolute paths or URLs"),
            ({"note": "路径/Users/private-user/embedded-secret.png"}, "absolute paths or URLs"),
            ({"note": "reference(https://private.example.invalid/secret.png)"}, "absolute paths or URLs"),
            ({"dev.example/thread_id": "private-session-value"}, "thread_id"),
            ({"threadidbackup": "private-session-value"}, "thread_id"),
        )
        for ai_brief, category in cases:
            with self.subTest(ai_brief=ai_brief):
                with tempfile.TemporaryDirectory(prefix="agent-pet-maker-privacy-") as temporary:
                    source = Path(temporary)
                    (source / "source" / "references").mkdir(parents=True)
                    (source / "source" / "source.json").write_text(
                        json.dumps(
                            {
                                "schema_version": "apc.pet-source.v1",
                                "generator": "image-tool",
                                "provenance": "skill-full-source",
                                "runner": "host-agent",
                                "visual_source": "image-generation",
                                "frames_per_state": 2,
                                "preview_only": False,
                                "reference_files": [],
                                "ai_brief": ai_brief,
                            }
                        ),
                        encoding="utf-8",
                    )
                    with self.assertRaises(workspace_helper.MakerError) as raised:
                        workspace_helper.normalize_source_metadata(
                            source,
                            "create",
                            {},
                            [],
                            {state: 2 for state in workspace_helper.STATES},
                            {
                                "id": "pet_test",
                                "name": "Test",
                                "style": "storybook",
                                "quality": "standard",
                            },
                        )
                    self.assertEqual(raised.exception.code, "privacy_violation")
                    self.assertIn(category, raised.exception.message)
                    self.assertNotIn("private-user", raised.exception.message)
                    self.assertNotIn("private.example.invalid", raised.exception.message)
                    self.assertNotIn("private-session-value", raised.exception.message)


if __name__ == "__main__":
    unittest.main()
