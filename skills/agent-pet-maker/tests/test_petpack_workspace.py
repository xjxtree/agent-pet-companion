#!/usr/bin/env python3
"""Focused contract tests for the portable pet maker helper."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "petpack_workspace.py"
SPEC = importlib.util.spec_from_file_location("petpack_workspace", HELPER)
assert SPEC and SPEC.loader
workspace_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workspace_helper)


def default_state_entries() -> list[dict]:
    return [
        {
            "name": state,
            "frames_dir": f"assets/frames/{state}",
            **json.loads(json.dumps(workspace_helper.DEFAULT_STATE_TIMINGS[state])),
        }
        for state in workspace_helper.STATES
    ]


def default_manifest(
    *,
    pet_id: str = "pet_test",
    name: str = "Test Pet",
    style: str = "storybook",
    quality: str = "low",
) -> dict:
    return {
        "schema_version": workspace_helper.PETPACK_SCHEMA,
        "id": pet_id,
        "name": name,
        "style": style,
        "quality": quality,
        "render_size": dict(workspace_helper.QUALITY_RENDER_SIZES[quality]),
        "states": default_state_entries(),
        "created_at": "2026-07-16T00:00:00Z",
    }


def default_brief_states() -> list[dict]:
    return [
        {
            "name": state,
            "motion": f"A clear {state} motion.",
            **json.loads(json.dumps(workspace_helper.DEFAULT_STATE_TIMINGS[state])),
        }
        for state in workspace_helper.STATES
    ]


DEFAULT_FRAME_COUNTS = {
    state: len(workspace_helper.DEFAULT_STATE_TIMINGS[state]["frame_durations_ms"])
    for state in workspace_helper.STATES
}


FAKE_CLI = r'''#!/usr/bin/env python3
import json
import os
import shutil
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
    "schema_version": "apc.petpack.v3",
    "id": pet_id,
    "name": "Test Pet",
    "style": "storybook",
    "quality": "standard",
    "render_size": {"width": 384, "height": 416},
}

if args[:2] == ["petpack", "validate"]:
    print(json.dumps({"ok": True, "manifest": manifest, "frame_count": 50, "warnings": []}))
elif args[:2] == ["pet", "list"]:
    print(json.dumps(state["pets"]))
elif args[:2] == ["petpack", "import"]:
    returned_id = os.environ.get("FAKE_IMPORT_ID", pet_id)
    existing = next((item for item in state["pets"] if item["id"] == returned_id), None)
    active = bool(existing and existing.get("active"))
    state["pets"] = [item for item in state["pets"] if item["id"] != returned_id]
    installed_archive = state_path.parent / "installed.petpack"
    shutil.copyfile(Path(args[-1]), installed_archive)
    imported = {
        **manifest,
        "id": returned_id,
        "active": active,
        "petpack_path": str(installed_archive),
    }
    state["pets"].append(imported)
    state_path.write_text(json.dumps(state))
    if os.environ.get("FAKE_IMPORT_COMMIT_THEN_FAIL") == "1":
        print("simulated transport failure after commit", file=sys.stderr)
        raise SystemExit(1)
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


class SkillDirectionContractTests(unittest.TestCase):
    def test_builtin_imagegen_limit_is_separate_from_portable_high_support(self) -> None:
        combined = " ".join("\n".join(
            path.read_text(encoding="utf-8")
            for path in (
                ROOT / "SKILL.md",
                ROOT / "references" / "create-modify.md",
                ROOT / "references" / "visual-production-and-native-resolution.md",
                ROOT / "references" / "dreamina-high-production.md",
            )
        ).split())
        for required in (
            "`high` 576×624",
            "ChatGPT/Codex built-in `imagegen`",
            "approximate 1K–2K",
            "Dreamina 5.0 Pro",
            "another source-capable provider",
            "actual dimensions",
            "exact-tier runtime",
        ):
            self.assertIn(required, combined)

    def test_shared_image_contract_contains_the_dreamina_high_workflow(self) -> None:
        contract = "\n".join(
            (
                (
                    ROOT
                    / "references"
                    / "visual-production-and-native-resolution.md"
                ).read_text(encoding="utf-8"),
                (ROOT / "references" / "dreamina-high-production.md").read_text(
                    encoding="utf-8"
                ),
            )
        )
        for required in (
            "--model_version=5.0Pro",
            "--resolution_type=4k",
            "--ratio=3:4",
            "--generate_num=1",
            "--poll=60",
            "6240×1536",
            "5760×1536",
            "3840×1536",
            "4096×1536",
            "slot_width = canvas_width / frame_count",
            "slot_center_x = (frame_index + 0.5) * slot_width",
            "Image 1 defines the exact character identity",
            "Image 2 is a script-generated frameless equal-scale pose guide",
            "CRITICAL SCALE LOCK",
            "contact -> settle -> passing -> advance",
            "gen_status=querying",
            "dreamina query_result --submit_id=<submit_id>",
        ):
            self.assertIn(required, contract)

        rows = re.findall(
            r"\| (\d+) \| (\d+)×1536 \| (\d+) \| (\d+)×(\d+) \|",
            contract,
        )
        self.assertEqual(len(rows), 4)
        for frame_count, canvas_width, slot_width, crop_width, crop_height in rows:
            frame_count = int(frame_count)
            canvas_width = int(canvas_width)
            slot_width = int(slot_width)
            crop_width = int(crop_width)
            crop_height = int(crop_height)
            with self.subTest(frame_count=frame_count):
                self.assertEqual(canvas_width // frame_count, slot_width)
                self.assertEqual(canvas_width % frame_count, 0)
                self.assertLessEqual(crop_width, slot_width)
                self.assertLessEqual(crop_height, 1536)
                self.assertEqual(crop_width * 13, crop_height * 12)
                self.assertGreaterEqual(crop_width, 576)
                self.assertGreaterEqual(crop_height, 624)
                self.assertLessEqual(canvas_width, 6240)
                self.assertLessEqual(canvas_width * 1536, 16_777_216)

    def test_portable_skill_requires_runtime_readable_motion_without_fixed_layers(
        self,
    ) -> None:
        combined = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (
                ROOT / "references" / "create-modify.md",
                ROOT / "references" / "visual-production-and-native-resolution.md",
            )
        )

        for required in (
            "Intentional translation",
            "deliberate spacing",
            "Runtime-size",
            "one action per call",
            "192×208",
            "reduced-motion",
            "Record the reason",
        ):
            self.assertIn(required, combined)

    def test_portable_skill_does_not_absorb_scenario_specific_workarounds(self) -> None:
        combined = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (
                ROOT / "SKILL.md",
                ROOT / "references" / "create-modify.md",
                ROOT / "references" / "petpack-v3.md",
            )
        )
        for scenario_specific in (
            "#00FF00",
            "chroma-key",
            "wooden stool",
            "UF_HIDDEN",
        ):
            self.assertNotIn(scenario_specific, combined)


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

    def test_import_error_reconciles_exact_committed_archive_without_retry(self) -> None:
        self.environment["FAKE_IMPORT_COMMIT_THEN_FAIL"] = "1"

        completed, result = self.run_install("--activate")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["status"], "completed")
        self.assertTrue(result["install"]["import"]["succeeded"])
        self.assertTrue(result["install"]["import"]["reconciled_after_error"])
        self.assertTrue(result["install"]["verification"]["archive_sha256_matches"])
        self.assertEqual(
            [call[:2] for call in self.calls_made()].count(["petpack", "import"]),
            1,
        )

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
    @staticmethod
    def visible_frame(
        color: tuple[int, int, int, int], offset: int = 0, hidden_rgb: tuple[int, int, int] = (0, 0, 0)
    ):
        from PIL import Image

        frame = Image.new("RGBA", (8, 8), (*hidden_rgb, 0))
        for y in range(2, 6):
            for x in range(2 + offset, 5 + offset):
                frame.putpixel((x, y), color)
        return frame

    def make_visual_source(self, root: Path) -> tuple[Path, dict]:
        source = root / "petpack-source"
        manifest = {
            "render_size": {"width": 8, "height": 8},
            "states": [
                {"name": state, "frames_dir": f"assets/frames/{state}"}
                for state in workspace_helper.STATES
            ],
        }
        for state in workspace_helper.STATES:
            state_dir = source / "assets" / "frames" / state
            state_dir.mkdir(parents=True, exist_ok=True)
            self.visible_frame((40, 80, 120, 255)).save(state_dir / "frame-000.png")
            self.visible_frame((80, 120, 160, 255), offset=1).save(
                state_dir / "frame-001.png"
            )
        preview_dir = source / "assets" / "preview"
        preview_dir.mkdir(parents=True)
        first = self.visible_frame((40, 80, 120, 255))
        second = self.visible_frame((80, 120, 160, 255), offset=1)
        first.save(preview_dir / "cover.png")
        first.save(
            preview_dir / "animated_preview.webp",
            format="WEBP",
            save_all=True,
            append_images=[second],
            duration=[80, 80],
            loop=0,
            lossless=True,
        )
        return source, manifest

    def test_state_motion_ignores_hidden_rgb_and_png_encoding(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            state_dir = source / "assets" / "frames" / "idle"
            first = self.visible_frame((40, 80, 120, 255), hidden_rgb=(255, 0, 0))
            second = self.visible_frame((40, 80, 120, 255), hidden_rgb=(0, 255, 0))
            first.save(state_dir / "frame-000.png", compress_level=0)
            second.save(state_dir / "frame-001.png", compress_level=9)

            state_files, _ = workspace_helper.collect_state_files(source, manifest)
            self.assertEqual(
                state_files["idle"]["frame-000.png"],
                state_files["idle"]["frame-001.png"],
            )

    def test_animated_motion_ignores_transparent_hidden_rgb(self) -> None:
        first = self.visible_frame((40, 80, 120, 255), hidden_rgb=(255, 0, 0))
        second = self.visible_frame((40, 80, 120, 255), hidden_rgb=(0, 255, 0))
        self.assertNotEqual(first.tobytes(), second.tobytes())
        self.assertEqual(
            workspace_helper.canonical_premultiplied_rgba(first),
            workspace_helper.canonical_premultiplied_rgba(second),
        )

    def test_motion_digest_ignores_rgb_below_the_visible_alpha_threshold(self) -> None:
        from PIL import Image

        first = Image.new("RGBA", (8, 8), (255, 0, 0, 15))
        second = Image.new("RGBA", (8, 8), (0, 255, 0, 1))
        first.putpixel((4, 4), (40, 80, 120, 255))
        second.putpixel((4, 4), (40, 80, 120, 255))

        self.assertEqual(
            workspace_helper.canonical_premultiplied_rgba(first),
            workspace_helper.canonical_premultiplied_rgba(second),
        )

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

    def test_pillow_runtime_locator_uses_only_a_verified_interpreter(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-python-") as temporary:
            missing = Path(temporary) / "missing-python"
            verified = Path(temporary) / "python3.12"
            verified.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            verified.chmod(0o755)
            with mock.patch.object(
                workspace_helper,
                "pillow_python_candidates",
                return_value=[missing, verified],
            ), mock.patch.object(
                workspace_helper,
                "interpreter_has_pillow",
                side_effect=lambda candidate: candidate == verified.resolve(),
            ):
                self.assertEqual(
                    workspace_helper.locate_pillow_python(),
                    verified.resolve(),
                )

    def test_pillow_runtime_refuses_to_create_a_local_shim(self) -> None:
        with mock.patch.object(
            workspace_helper,
            "current_interpreter_has_pillow",
            return_value=False,
        ), mock.patch.object(
            workspace_helper,
            "locate_pillow_python",
            return_value=None,
        ), mock.patch.dict(
            os.environ,
            {workspace_helper.PILLOW_REEXEC_MARKER: ""},
        ):
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.ensure_pillow_runtime(
                    "motion-qa",
                    ["motion-qa", "--source", "petpack-source"],
                )
        self.assertEqual(raised.exception.code, "capability_missing")

    def test_cli_contract_probe_reaches_petpack_validate(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-cli-contract-") as temporary:
            cli = Path(temporary) / "petcore-cli"
            cli.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = \"petpack validate\" ] && [ -f \"$3/manifest.json\" ]; then\n"
                "  echo 'json error: missing field schema_version' >&2\n"
                "  exit 1\n"
                "fi\n"
                "if [ \"$1 $2 $3\" = \"petpack build --input\" ] && [ -f \"$4/manifest.json\" ]; then\n"
                "  echo 'json error: missing field schema_version' >&2\n"
                "  exit 1\n"
                "fi\n"
                "if [ \"$1 $2\" = \"petpack verify-production\" ]; then\n"
                "  echo 'validation failed: visual production source manifest is invalid' >&2\n"
                "  exit 1\n"
                "fi\n"
                "echo 'invalid request: unknown command' >&2\n"
                "exit 1\n",
                encoding="utf-8",
            )
            cli.chmod(0o755)

            self.assertEqual(
                workspace_helper.verify_cli_contract(cli),
                {
                    "petpack_validate": True,
                    "petpack_build": True,
                    "petpack_verify_production": True,
                    "invalid_manifest_rejected": True,
                },
            )

    def test_cli_contract_probe_rejects_an_unrelated_executable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-cli-contract-") as temporary:
            cli = Path(temporary) / "petcore-cli"
            cli.write_text(
                "#!/bin/sh\necho 'invalid request: unknown petpack subcommand' >&2\nexit 1\n",
                encoding="utf-8",
            )
            cli.chmod(0o755)

            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.verify_cli_contract(cli)
            self.assertEqual(raised.exception.code, "capability_missing")

    def test_production_verification_missing_readiness_evidence_fails_closed(self) -> None:
        cli = Path("/opt/petcore-cli")
        source = Path("/private/workspace/petpack-source")
        report = Path("/private/workspace/motion-qa/report.json")
        review = Path("/private/workspace/motion-review.json")
        baseline = Path("/private/input/base.petpack")
        response = {
            "schema_version": "apc.pet-visual-production-verification.v1",
            "ok": False,
            "usable": False,
            "audited_states": ["tool"],
            "changed_states": ["tool"],
            "timing_digest": "1" * 64,
            "frame_set_digest": "0" * 64,
            "warning_codes": [],
        }
        with mock.patch.object(
            workspace_helper, "run_cli", return_value=response
        ) as run_cli:
            result = workspace_helper.run_production_verification(
                cli, source, report, review, baseline
            )

        self.assertEqual(
            result,
            {
                **response,
                "build_ok": False,
                "package_ok": False,
                "interaction_ok": False,
                "runtime_ok": False,
                "visual_ok": False,
                "missing_readiness_evidence": [
                    "build_ok",
                    "package_ok",
                    "interaction_ok",
                    "runtime_ok",
                    "visual_ok",
                ],
                "failed_readiness_evidence": [],
                "usable": False,
            },
        )
        run_cli.assert_called_once_with(
            cli,
            [
                "petpack",
                "verify-production",
                "--source",
                str(source),
                "--report",
                str(report),
                "--review",
                str(review),
                "--baseline",
                str(baseline),
            ],
            "production_validation_failed",
        )

    def test_production_verification_usable_is_exact_gate_conjunction(self) -> None:
        response = {
            "schema_version": "apc.pet-visual-production-verification.v1",
            "ok": False,
            "usable": False,
            "audited_states": ["tool"],
            "changed_states": ["tool"],
            "timing_digest": "1" * 64,
            "frame_set_digest": "0" * 64,
            "warning_codes": [],
            "build_ok": True,
            "package_ok": True,
            "interaction_ok": False,
            "runtime_ok": True,
            "visual_ok": True,
        }
        with mock.patch.object(workspace_helper, "run_cli", return_value=response):
            result = workspace_helper.run_production_verification(
                Path("/opt/petcore-cli"),
                Path("/private/workspace/petpack-source"),
                Path("/private/workspace/motion-qa/report.json"),
                Path("/private/workspace/motion-review.json"),
            )
        self.assertFalse(result["usable"])
        self.assertEqual(result["missing_readiness_evidence"], [])
        self.assertEqual(result["failed_readiness_evidence"], ["interaction_ok"])

    def test_production_verification_rejects_unproven_interaction_ok(self) -> None:
        base_response = {
            "schema_version": "apc.pet-visual-production-verification.v1",
            "ok": True,
            "usable": True,
            "audited_states": ["tool"],
            "changed_states": ["tool"],
            "timing_digest": "1" * 64,
            "frame_set_digest": "0" * 64,
            "warning_codes": [],
            "build_ok": True,
            "package_ok": True,
            "interaction_ok": True,
            "runtime_ok": True,
            "visual_ok": True,
        }
        invalid_evidence = (
            None,
            [],
            [workspace_helper.PRODUCTION_INTERACTION_EVIDENCE[0]],
            [*workspace_helper.PRODUCTION_INTERACTION_EVIDENCE, 7],
            [*workspace_helper.PRODUCTION_INTERACTION_EVIDENCE, "phase_b.unknown"],
            [
                *workspace_helper.PRODUCTION_INTERACTION_EVIDENCE,
                workspace_helper.PRODUCTION_INTERACTION_EVIDENCE[0],
            ],
        )
        for evidence in invalid_evidence:
            with self.subTest(evidence=evidence):
                response = dict(base_response)
                if evidence is not None:
                    response["interaction_evidence"] = evidence
                with mock.patch.object(
                    workspace_helper, "run_cli", return_value=response
                ):
                    with self.assertRaises(workspace_helper.MakerError) as raised:
                        workspace_helper.run_production_verification(
                            Path("/opt/petcore-cli"),
                            Path("/private/workspace/petpack-source"),
                            Path("/private/workspace/motion-qa/report.json"),
                            Path("/private/workspace/motion-review.json"),
                        )
                self.assertEqual(
                    raised.exception.code, "production_validation_failed"
                )

    def test_production_verification_accepts_only_the_closed_interaction_evidence(self) -> None:
        response = {
            "schema_version": "apc.pet-visual-production-verification.v1",
            "ok": True,
            "usable": True,
            "audited_states": ["tool"],
            "changed_states": ["tool"],
            "timing_digest": "1" * 64,
            "frame_set_digest": "0" * 64,
            "warning_codes": [],
            "build_ok": True,
            "package_ok": True,
            "interaction_ok": True,
            "interaction_evidence": list(
                reversed(workspace_helper.PRODUCTION_INTERACTION_EVIDENCE)
            ),
            "runtime_ok": True,
            "visual_ok": True,
        }
        with mock.patch.object(workspace_helper, "run_cli", return_value=response):
            result = workspace_helper.run_production_verification(
                Path("/opt/petcore-cli"),
                Path("/private/workspace/petpack-source"),
                Path("/private/workspace/motion-qa/report.json"),
                Path("/private/workspace/motion-review.json"),
            )
        self.assertTrue(result["interaction_ok"])
        self.assertTrue(result["usable"])

    def test_production_verification_rejects_inconsistent_summary_booleans(self) -> None:
        response = {
            "schema_version": "apc.pet-visual-production-verification.v1",
            "ok": False,
            "usable": True,
            "audited_states": ["tool"],
            "changed_states": ["tool"],
            "timing_digest": "1" * 64,
            "frame_set_digest": "0" * 64,
            "warning_codes": [],
            "build_ok": True,
            "package_ok": True,
            "interaction_ok": True,
            "interaction_evidence": list(
                workspace_helper.PRODUCTION_INTERACTION_EVIDENCE
            ),
            "runtime_ok": True,
            "visual_ok": True,
        }
        with mock.patch.object(workspace_helper, "run_cli", return_value=response):
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.run_production_verification(
                    Path("/opt/petcore-cli"),
                    Path("/private/workspace/petpack-source"),
                    Path("/private/workspace/motion-qa/report.json"),
                    Path("/private/workspace/motion-review.json"),
                )
        self.assertEqual(raised.exception.code, "production_validation_failed")

    def test_cli_contract_probe_rejects_validate_only_cli(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-cli-contract-") as temporary:
            cli = Path(temporary) / "petcore-cli"
            cli.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = \"petpack validate\" ]; then\n"
                "  echo 'json error: missing field schema_version' >&2\n"
                "else\n"
                "  echo 'invalid request: unknown petpack subcommand' >&2\n"
                "fi\n"
                "exit 1\n",
                encoding="utf-8",
            )
            cli.chmod(0o755)

            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.verify_cli_contract(cli)
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
                "states": default_state_entries(),
                "state_frame_counts": DEFAULT_FRAME_COUNTS,
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
                DEFAULT_FRAME_COUNTS,
                default_manifest(name="Test"),
            )
            self.assertFalse(set(normalized) - workspace_helper.SOURCE_ALLOWED_KEYS)
            self.assertEqual(normalized["provenance"], "skill-full-source")
            self.assertEqual(normalized["base_manifest_id"], "pet_test")
            self.assertEqual(normalized["changed_states"], ["tool"])
            self.assertNotIn("producer", normalized)
            self.assertNotIn("operation", normalized)
            self.assertNotIn("frame_counts", normalized)
            self.assertNotIn("frames_per_state", normalized)
            self.assertEqual(normalized["states"], default_state_entries())

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
                        "states": default_state_entries(),
                        "state_frame_counts": DEFAULT_FRAME_COUNTS,
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
                    DEFAULT_FRAME_COUNTS,
                    default_manifest(name="Test"),
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


class TimingContractTests(unittest.TestCase):
    def test_skill_treats_new_defaults_as_overrideable_and_non_migrating(self) -> None:
        skill = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        reference = (ROOT / "references" / "petpack-v3.md").read_text(
            encoding="utf-8"
        )
        compact_reference = " ".join(reference.split())
        self.assertIn("creation defaults in `petpack-v3.md`", skill)
        self.assertIn("another valid complete timing", skill)
        self.assertIn(
            "These are creation defaults, not extra validity rules",
            compact_reference,
        )
        self.assertIn(
            "Preserve the timing of an existing valid V3 package",
            compact_reference,
        )

    def test_default_authored_timing_matches_the_shared_nine_action_contract(self) -> None:
        self.assertEqual(
            workspace_helper.DEFAULT_STATE_TIMINGS,
            {
                "idle": {
                    "frame_durations_ms": [260, 220, 240, 260, 380, 640],
                    "playback": {
                        "mode": "periodic",
                        "cooldown_ms": [2500, 5000],
                    },
                    "reduced_motion_frame_index": 2,
                },
                "thinking": {
                    "frame_durations_ms": [120, 140, 160, 180],
                    "playback": {
                        "mode": "burst_then_idle",
                        "entry_repeat_count": 3,
                    },
                    "reduced_motion_frame_index": 2,
                },
                "tool": {
                    "frame_durations_ms": [150, 150, 170, 330],
                    "playback": {
                        "mode": "burst_then_idle",
                        "entry_repeat_count": 3,
                    },
                    "reduced_motion_frame_index": 2,
                },
                "waiting": {
                    "frame_durations_ms": [100, 100, 110, 110, 120, 130, 160, 230],
                    "playback": {
                        "mode": "burst_then_settle",
                        "entry_repeat_count": 3,
                        "settle_frame_index": 7,
                    },
                    "reduced_motion_frame_index": 4,
                },
                "done": {
                    "frame_durations_ms": [120, 140, 160, 230],
                    "playback": {
                        "mode": "burst_then_idle",
                        "entry_repeat_count": 3,
                    },
                    "reduced_motion_frame_index": 2,
                },
                "failed": {
                    "frame_durations_ms": [80, 80, 90, 100, 110, 120, 190, 290],
                    "playback": {
                        "mode": "burst_then_settle",
                        "entry_repeat_count": 3,
                        "settle_frame_index": 7,
                    },
                    "reduced_motion_frame_index": 2,
                },
                "acknowledge": {
                    "frame_durations_ms": [180, 140, 180, 300],
                    "playback": {"mode": "once_then_return"},
                    "reduced_motion_frame_index": 1,
                },
                "drag_left": {
                    "frame_durations_ms": [100, 90, 100, 110, 100, 200],
                    "playback": {"mode": "loop"},
                    "reduced_motion_frame_index": 2,
                },
                "drag_right": {
                    "frame_durations_ms": [100, 90, 100, 110, 100, 200],
                    "playback": {"mode": "loop"},
                    "reduced_motion_frame_index": 2,
                },
            },
        )

    def test_default_authored_timing_contains_50_frames_without_sampling(self) -> None:
        timing = workspace_helper.manifest_timing_contract(default_manifest())
        self.assertEqual(sum(timing["state_frame_counts"].values()), 50)
        self.assertEqual(
            {entry["playback"]["mode"] for entry in timing["states"]},
            {
                "loop",
                "periodic",
                "burst_then_settle",
                "burst_then_idle",
                "once_then_return",
            },
        )

    def test_prior_valid_v3_default_remains_accepted_without_migration(self) -> None:
        manifest = default_manifest()
        states = {state["name"]: state for state in manifest["states"]}
        states["idle"].update(
            frame_durations_ms=[300, 260, 300, 640],
            playback={"mode": "periodic", "cooldown_ms": [2500, 5000]},
            reduced_motion_frame_index=2,
        )
        states["waiting"].update(
            frame_durations_ms=[150, 150, 150, 150, 170, 230],
            playback={
                "mode": "burst_then_settle",
                "entry_repeat_count": 2,
                "settle_frame_index": 5,
            },
            reduced_motion_frame_index=4,
        )
        states["failed"].update(
            frame_durations_ms=[150, 170, 190, 290],
            playback={
                "mode": "burst_then_settle",
                "entry_repeat_count": 3,
                "settle_frame_index": 3,
            },
            reduced_motion_frame_index=2,
        )

        timing = workspace_helper.manifest_timing_contract(manifest)

        self.assertEqual(sum(timing["state_frame_counts"].values()), 42)
        self.assertEqual(timing["state_frame_counts"]["idle"], 4)
        self.assertEqual(timing["state_frame_counts"]["waiting"], 6)
        self.assertEqual(timing["state_frame_counts"]["failed"], 4)
        self.assertTrue(
            any(
                len(set(entry["frame_durations_ms"])) > 1
                for entry in timing["states"]
            )
        )

        self.assertEqual(
            {entry["playback"]["mode"] for entry in timing["states"]},
            workspace_helper.PLAYBACK_MODES,
        )

    def test_exact_state_counts_come_from_duration_array_lengths(self) -> None:
        timing = workspace_helper.manifest_timing_contract(default_manifest())
        workspace_helper.validate_exact_state_counts(DEFAULT_FRAME_COUNTS, timing)
        invalid = dict(DEFAULT_FRAME_COUNTS)
        invalid["thinking"] -= 1
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_exact_state_counts(invalid, timing)
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("frame_durations_ms", raised.exception.message)

    def test_manifest_timing_rejects_mode_specific_fields_and_bad_indices(self) -> None:
        manifest = default_manifest()
        manifest["states"][0]["playback"] = {
            "mode": "periodic",
            "cooldown_ms": [8000, 4000],
        }
        with self.assertRaises(workspace_helper.MakerError):
            workspace_helper.manifest_timing_contract(manifest)

        manifest = default_manifest()
        manifest["states"][1]["reduced_motion_frame_index"] = 99
        with self.assertRaises(workspace_helper.MakerError):
            workspace_helper.manifest_timing_contract(manifest)

    def test_three_quality_tiers_have_fixed_12_by_13_sizes(self) -> None:
        self.assertEqual(
            workspace_helper.QUALITY_RENDER_SIZES,
            {
                "low": {"width": 192, "height": 208},
                "standard": {"width": 384, "height": 416},
                "high": {"width": 576, "height": 624},
            },
        )
        for quality in workspace_helper.QUALITY_RENDER_SIZES:
            workspace_helper.manifest_timing_contract(
                default_manifest(quality=quality)
            )

    def test_high_quality_uses_the_exact_runtime_576_by_624_contract(self) -> None:
        manifest = default_manifest(quality="high")
        workspace_helper.manifest_timing_contract(manifest)
        self.assertEqual(
            manifest["render_size"],
            {"width": 576, "height": 624},
        )

    def test_unknown_quality_is_rejected_without_alias_or_shim(self) -> None:
        manifest = default_manifest()
        manifest["quality"] = "ultra"
        manifest["render_size"] = {"width": 576, "height": 624}
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.manifest_timing_contract(manifest)
        self.assertEqual(raised.exception.code, "invalid_manifest")
        self.assertEqual(
            raised.exception.message,
            "manifest.quality must be low, standard, or high",
        )

    def test_frame_digests_follow_petcore_natural_filename_order(self) -> None:
        state_files = {
            "10.png": "ten",
            "02.png": "two-padded",
            "002.png": "two-more-padded",
            "2.png": "two",
            "1.png": "one",
            "A2.png": "uppercase",
            "a2.png": "lowercase",
        }
        self.assertEqual(
            [
                state_files[name]
                for name in sorted(
                    state_files,
                    key=workspace_helper.NATURAL_FRAME_NAME_KEY,
                )
            ],
            [
                "one",
                "two",
                "two-padded",
                "two-more-padded",
                "ten",
                "uppercase",
                "lowercase",
            ],
        )


class MotionQualityTests(unittest.TestCase):
    def make_workspace(self, root: Path) -> tuple[Path, Path]:
        from PIL import Image, ImageDraw

        workspace = root / "workspace"
        source = workspace / "petpack-source"
        control = workspace / ".agent-pet-maker"
        control.mkdir(parents=True)
        durations = [70, 80, 90, 100, 110, 120, 130, 140, 150, 160]
        manifest = {
            "schema_version": workspace_helper.PETPACK_SCHEMA,
            "id": "pet_motion_test",
            "name": "Motion Test",
            "style": "storybook",
            "quality": "low",
            "render_size": {"width": 192, "height": 208},
            "states": [
                {
                    "name": state,
                    "frames_dir": f"assets/frames/{state}",
                    "frame_durations_ms": durations,
                    "playback": {
                        "idle": {"mode": "periodic", "cooldown_ms": [2500, 5000]},
                        "thinking": {"mode": "burst_then_idle", "entry_repeat_count": 1},
                        "tool": {"mode": "burst_then_idle", "entry_repeat_count": 1},
                        "waiting": {
                            "mode": "burst_then_settle",
                            "entry_repeat_count": 1,
                            "settle_frame_index": 9,
                        },
                        "done": {"mode": "burst_then_idle", "entry_repeat_count": 1},
                        "failed": {
                            "mode": "burst_then_settle",
                            "entry_repeat_count": 1,
                            "settle_frame_index": 9,
                        },
                        "acknowledge": {"mode": "once_then_return"},
                        "drag_left": {"mode": "loop"},
                        "drag_right": {"mode": "loop"},
                    }[state],
                    "reduced_motion_frame_index": 5,
                }
                for state in workspace_helper.STATES
            ],
        }
        (source / "manifest.json").parent.mkdir(parents=True)
        (source / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        for state_index, state in enumerate(workspace_helper.STATES):
            state_dir = source / "assets" / "frames" / state
            state_dir.mkdir(parents=True)
            for frame_index in range(10):
                frame = Image.new("RGBA", (192, 208), (0, 0, 0, 0))
                draw = ImageDraw.Draw(frame)
                offset = (frame_index if state == "thinking" else frame_index % 3) * 3
                draw.ellipse(
                    (48 + offset, 34, 136 + offset, 178),
                    fill=(40 + state_index * 10, 100, 160, 255),
                )
                frame.save(state_dir / f"frame-{frame_index:03d}.png")
        (control / "context.json").write_text(
            json.dumps(
                {
                    "schema_version": workspace_helper.WORKSPACE_SCHEMA,
                    "operation": "create",
                    "source_dir": str(source),
                    "base": None,
                }
            ),
            encoding="utf-8",
        )
        return workspace, source

    def test_motion_qa_writes_in_app_previews_and_bound_review(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, _ = self.make_workspace(Path(temporary))
            with mock.patch.object(
                workspace_helper,
                "save_motion_preview",
                wraps=workspace_helper.save_motion_preview,
            ) as save_preview:
                qa = workspace_helper.motion_qa(
                    workspace_helper.argparse.Namespace(
                        workspace=str(workspace),
                        source=None,
                        output_dir=None,
                        state=["idle"],
                    )
                )
            report_path = Path(qa["report_path"])
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["schema_version"], workspace_helper.MOTION_QA_SCHEMA)
            self.assertEqual(report["audited_states"], ["idle"])
            self.assertIn("intended whole-character trajectory", report["measurement_note"])
            self.assertIn("not failures by themselves", report["measurement_note"])
            self.assertEqual(
                set(report["states"]["idle"]["previews"]),
                {"authored_timing"},
            )
            self.assertEqual(
                report["states"]["idle"]["frame_durations_ms"],
                durations := [70, 80, 90, 100, 110, 120, 130, 140, 150, 160],
            )
            preview = (
                report_path.parent
                / report["states"]["idle"]["previews"]["authored_timing"]
            )
            with Image.open(preview) as decoded:
                self.assertEqual(decoded.size, workspace_helper.MOTION_PREVIEW_SIZE)
                self.assertEqual(decoded.n_frames, 10)
            self.assertEqual(save_preview.call_args.args[2], durations)

            review = workspace_helper.motion_review(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    report=None,
                    output=None,
                    state_note=[
                        "idle=The whole-form float has smooth easing, clear identity, and a clean loop."
                    ],
                )
            )
            self.assertTrue(Path(review["review_path"]).is_file())
            review_evidence = json.loads(
                Path(review["review_path"]).read_text(encoding="utf-8")
            )
            self.assertIn(
                "intended whole-character trajectory",
                review_evidence["review_contract"],
            )
            self.assertIn(
                "automatic failures",
                review_evidence["review_contract"],
            )
            self.assertEqual(
                review_evidence["report_sha256"],
                workspace_helper.sha256_file(report_path),
            )
            self.assertEqual(review_evidence["audited_states"], ["idle"])

    def test_motion_qa_can_audit_one_completed_state_incrementally(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            for state in workspace_helper.STATES:
                if state != "tool":
                    shutil.rmtree(source / "assets" / "frames" / state)

            qa = workspace_helper.motion_qa(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    source=None,
                    output_dir=None,
                    state=["tool"],
                )
            )

            report = json.loads(Path(qa["report_path"]).read_text(encoding="utf-8"))
            self.assertEqual(report["audited_states"], ["tool"])
            self.assertEqual(report["states"]["tool"]["frame_count"], 10)

    def test_combined_motion_qa_writes_an_eight_to_twelve_second_presence_preview(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-presence-") as temporary:
            workspace, _ = self.make_workspace(Path(temporary))
            qa = workspace_helper.motion_qa(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    source=None,
                    output_dir=None,
                    state=None,
                )
            )
            report_path = Path(qa["report_path"])
            report = json.loads(report_path.read_text(encoding="utf-8"))
            presence = report["presence_preview"]

            self.assertGreaterEqual(
                presence["duration_ms"],
                workspace_helper.PRESENCE_PREVIEW_MIN_MS,
            )
            self.assertLessEqual(
                presence["duration_ms"],
                workspace_helper.PRESENCE_PREVIEW_MAX_MS,
            )
            self.assertGreaterEqual(presence["late_motion_boundary_ms"], 1_000)
            self.assertGreaterEqual(presence["rest_phase_count"], 3)
            self.assertEqual(len(presence["frame_set_digest"]), 64)
            preview = report_path.parent / presence["path"]
            self.assertEqual(Path(qa["presence_preview_path"]), preview)
            with Image.open(preview) as decoded:
                self.assertEqual(decoded.size, workspace_helper.MOTION_PREVIEW_SIZE)
                self.assertGreater(decoded.n_frames, 2)

    def test_presence_preview_rejects_under_one_second_semantic_activity_and_looping(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-presence-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            manifest_path = source / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            thinking = next(
                state for state in manifest["states"] if state["name"] == "thinking"
            )
            thinking["frame_durations_ms"] = [50] * 10
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(
                workspace_helper.MakerError,
                "freezes in under a second",
            ):
                workspace_helper.motion_qa(
                    workspace_helper.argparse.Namespace(
                        workspace=str(workspace),
                        source=None,
                        output_dir=None,
                        state=None,
                    )
                )

            thinking["frame_durations_ms"] = [100] * 10
            thinking["playback"] = {"mode": "loop"}
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(
                workspace_helper.MakerError,
                "must be burst_then_idle",
            ):
                workspace_helper.motion_qa(
                    workspace_helper.argparse.Namespace(
                        workspace=str(workspace),
                        source=None,
                        output_dir=None,
                        state=None,
                    )
                )

    def test_motion_qa_rejects_an_unsupported_schema(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            manifest_path = source / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["schema_version"] = "apc.petpack.invalid"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.motion_qa(
                    workspace_helper.argparse.Namespace(
                        workspace=str(workspace),
                        source=None,
                        output_dir=None,
                        state=["idle"],
                    )
                )
            self.assertEqual(raised.exception.code, "invalid_manifest")
            self.assertEqual(
                raised.exception.message,
                "manifest.schema_version must be apc.petpack.v3",
            )

    def test_motion_qa_rejects_synthetic_crossfade_filler(self) -> None:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            state_dir = source / "assets" / "frames" / "thinking"
            first = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
            last = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
            ImageDraw.Draw(first).ellipse(
                (3, 8, 17, 25),
                fill=(40, 100, 160, 255),
            )
            ImageDraw.Draw(last).ellipse(
                (14, 8, 28, 25),
                fill=(220, 100, 80, 255),
            )
            for path in state_dir.glob("*.png"):
                path.unlink()
            for index in range(10):
                Image.blend(first, last, index / 9).save(
                    state_dir / f"frame-{index:03d}.png"
                )

            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.motion_qa(
                    workspace_helper.argparse.Namespace(
                        workspace=str(workspace),
                        source=None,
                        output_dir=None,
                        state=["thinking"],
                    )
                )

            self.assertEqual(
                raised.exception.code,
                "invalid_frame_interpolation",
            )
            self.assertIn("crossfade", raised.exception.message)

    def test_motion_qa_allows_whole_subject_motion_for_visual_review(self) -> None:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            state_dir = source / "assets" / "frames" / "thinking"
            for path in state_dir.glob("*.png"):
                path.unlink()
            for index in range(10):
                frame = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
                if index == 5:
                    bounds = (10, 14, 22, 28)
                else:
                    offset = index % 2
                    bounds = (5 + offset, 7, 26 + offset, 30)
                ImageDraw.Draw(frame).rounded_rectangle(
                    bounds,
                    radius=3,
                    fill=(40 + index, 100, 160, 255),
                )
                frame.save(state_dir / f"frame-{index:03d}.png")

            result = workspace_helper.motion_qa(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    source=None,
                    output_dir=None,
                    state=["thinking"],
                )
            )
            report = json.loads(Path(result["report_path"]).read_text())
            warning_codes = {
                warning["code"] for warning in report["states"]["thinking"]["warnings"]
            }
            self.assertIn("large_silhouette_or_scale_change", warning_codes)
            self.assertIn("large_subject_displacement", warning_codes)

    def test_motion_qa_rejects_action_clipped_at_runtime_frame_edge(self) -> None:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            state_dir = source / "assets" / "frames" / "thinking"
            for path in state_dir.glob("*.png"):
                path.unlink()
            for index in range(10):
                frame = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
                draw = ImageDraw.Draw(frame)
                draw.rounded_rectangle(
                    (8, 6, 31, 27),
                    radius=4,
                    fill=(70, 140, 220, 255),
                )
                draw.ellipse(
                    (11 + index % 3, 11, 15 + index % 3, 15),
                    fill=(245, 210, 80, 255),
                )
                frame.save(state_dir / f"frame-{index:03d}.png")

            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.motion_qa(
                    workspace_helper.argparse.Namespace(
                        workspace=str(workspace),
                        source=None,
                        output_dir=None,
                        state=["thinking"],
                    )
                )

            self.assertEqual(
                raised.exception.code,
                "invalid_motion_registration",
            )
            self.assertIn("action is clipped", raised.exception.message)
            self.assertIn("transparent pixel", raised.exception.message)

    def test_motion_qa_surfaces_attachment_and_loop_metrics_for_review(self) -> None:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            manifest_path = source / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            waiting = next(
                state for state in manifest["states"] if state["name"] == "waiting"
            )
            waiting["playback"]["entry_repeat_count"] = 2
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            state_dir = source / "assets" / "frames" / "waiting"
            for path in state_dir.glob("*.png"):
                path.unlink()
            for index in range(10):
                frame = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
                draw = ImageDraw.Draw(frame)
                draw.rounded_rectangle(
                    (18, 10, 44, 54),
                    radius=6,
                    fill=(80, 150, 220, 255),
                )
                if index < 5:
                    draw.rounded_rectangle(
                        (45, 31, 61, 39),
                        radius=4,
                        fill=(80, 150, 220, 255),
                    )
                frame.save(state_dir / f"frame-{index:03d}.png")

            result = workspace_helper.motion_qa(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    source=None,
                    output_dir=None,
                    state=["waiting"],
                )
            )
            report = json.loads(Path(result["report_path"]).read_text())
            warning_codes = {
                warning["code"] for warning in report["states"]["waiting"]["warnings"]
            }
            self.assertIn("large_silhouette_or_scale_change", warning_codes)
            self.assertIn("large_loop_boundary_delta", warning_codes)

    def test_motion_integrity_gate_allows_large_authored_whole_character_motion(
        self,
    ) -> None:
        metrics = {
            "edge_contact_frame_count": 0,
            "maximum_bbox_width_step": 0.18,
            "maximum_bbox_height_step": 0.16,
            "maximum_visible_area_step_ratio": 0.22,
            "maximum_centroid_step": 0.17,
            "maximum_baseline_step": 0.14,
            "loop_seam_delta": 0.09,
            "adjacent_delta": {"median": 0.056737},
        }

        workspace_helper.reject_objective_motion_integrity_failures("waiting", metrics)

    def test_motion_lock_preserves_explicit_non_moving_pixels(self) -> None:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            _, source = self.make_workspace(Path(temporary))
            moving_mask = Image.new("L", (192, 208), 0)
            ImageDraw.Draw(moving_mask).rectangle((0, 0, 191, 103), fill=255)
            mask_path = Path(temporary) / "thinking-moving-mask.png"
            moving_mask.save(mask_path)
            output_dir = Path(temporary) / "locked-thinking"

            result = workspace_helper.motion_lock(
                workspace_helper.argparse.Namespace(
                    source=str(source),
                    state="thinking",
                    moving_mask=str(mask_path),
                    output_dir=str(output_dir),
                    report=None,
                    reference_frame=0,
                    feather_px=0,
                )
            )

            self.assertEqual(result["frame_count"], 10)
            with Image.open(
                source / "assets" / "frames" / "thinking" / "frame-000.png"
            ) as reference, Image.open(
                source / "assets" / "frames" / "thinking" / "frame-005.png"
            ) as source_frame, Image.open(
                output_dir / "frame-005.png"
            ) as locked:
                self.assertEqual(
                    locked.crop((0, 104, 192, 208)).tobytes(),
                    reference.crop((0, 104, 192, 208)).tobytes(),
                )
                self.assertEqual(
                    locked.crop((0, 0, 192, 104)).tobytes(),
                    source_frame.crop((0, 0, 192, 104)).tobytes(),
                )
                self.assertNotEqual(
                    locked.crop((0, 0, 192, 104)).tobytes(),
                    reference.crop((0, 0, 192, 104)).tobytes(),
                )
            report = json.loads(
                Path(result["report_path"]).read_text(encoding="utf-8")
            )
            self.assertEqual(
                report["schema_version"], workspace_helper.MOTION_LOCK_SCHEMA
            )
            self.assertTrue(report["review_required"])

    def test_motion_lock_can_stabilize_a_local_action_without_unlocking_the_body(self) -> None:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            _, source = self.make_workspace(Path(temporary))
            state_dir = source / "assets" / "frames" / "thinking"
            for path in state_dir.glob("*.png"):
                path.unlink()
            for index in range(10):
                frame = Image.new("RGBA", (192, 208), (0, 0, 0, 0))
                bounds = (
                    (30, 28, 162, 190)
                    if index != 5
                    else (54, 60, 138, 174)
                )
                ImageDraw.Draw(frame).rounded_rectangle(
                    bounds,
                    radius=18,
                    fill=(40, 100, 160, 255),
                )
                ImageDraw.Draw(frame).rectangle(
                    (78, 70, 114, 108),
                    fill=(220, 120 + index, 80, 255),
                )
                frame.save(state_dir / f"frame-{index:03d}.png")

            mask = Image.new("L", (192, 208), 0)
            ImageDraw.Draw(mask).rectangle((72, 64, 120, 114), fill=255)
            mask_path = Path(temporary) / "local-action-mask.png"
            mask.save(mask_path)
            output_dir = Path(temporary) / "locked-local-action"

            workspace_helper.motion_lock(
                workspace_helper.argparse.Namespace(
                    source=str(source),
                    state="thinking",
                    moving_mask=str(mask_path),
                    output_dir=str(output_dir),
                    report=None,
                    reference_frame=0,
                    feather_px=0,
                )
            )

            frames = [
                workspace_helper.normalized_motion_frame(path)
                for path in sorted(output_dir.glob("*.png"))
            ]
            metrics, _ = workspace_helper.motion_metrics(frames, False)
            workspace_helper.reject_objective_motion_integrity_failures("thinking", metrics)
            self.assertLess(metrics["maximum_bbox_width_step"], 0.12)
            self.assertLess(metrics["maximum_bbox_height_step"], 0.12)

    def test_motion_review_requires_a_note_for_every_audited_state(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, _ = self.make_workspace(Path(temporary))
            workspace_helper.motion_qa(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    source=None,
                    output_dir=None,
                    state=["idle", "tool"],
                )
            )
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.motion_review(
                    workspace_helper.argparse.Namespace(
                        workspace=str(workspace),
                        report=None,
                        output=None,
                        state_note=[
                            "idle=The idle loop keeps the face and baseline stable throughout."
                        ],
                    )
                )
            self.assertEqual(raised.exception.code, "motion_review_incomplete")

    def test_frame_edit_after_review_is_rejected_as_stale(self) -> None:
        from PIL import Image, ImageDraw

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-motion-") as temporary:
            workspace, source = self.make_workspace(Path(temporary))
            workspace_helper.motion_qa(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    source=None,
                    output_dir=None,
                    state=["idle"],
                )
            )
            workspace_helper.motion_review(
                workspace_helper.argparse.Namespace(
                    workspace=str(workspace),
                    report=None,
                    output=None,
                    state_note=[
                        "idle=The inspected body remains stable and the loop seam is clean."
                    ],
                )
            )
            changed = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
            ImageDraw.Draw(changed).rectangle(
                (2, 2, 28, 30),
                fill=(220, 40, 80, 255),
            )
            changed.save(source / "assets" / "frames" / "idle" / "frame-004.png")
            manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
            report = json.loads(
                (
                    workspace / ".agent-pet-maker" / "motion-qa" / "report.json"
                ).read_text(encoding="utf-8")
            )
            self.assertNotEqual(
                report["states"]["idle"]["motion_digest"],
                workspace_helper.state_motion_digest(source, manifest, "idle"),
            )


class FinalizeSafetyTests(unittest.TestCase):
    def make_finalize_case(self, root: Path) -> tuple[Path, object]:
        workspace = root / "workspace"
        source = workspace / "petpack-source"
        (workspace / ".agent-pet-maker").mkdir(parents=True)
        (source / "build").mkdir(parents=True)
        (workspace / ".agent-pet-maker" / "context.json").write_text(
            json.dumps(
                {
                    "schema_version": workspace_helper.WORKSPACE_SCHEMA,
                    "operation": "create",
                    "source_dir": str(source),
                    "cli_path": str(root / "petcore-cli"),
                    "base": None,
                }
            ),
            encoding="utf-8",
        )
        manifest = default_manifest()
        (source / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        args = workspace_helper.argparse.Namespace(
            workspace=str(workspace),
            operation="create",
            output=str(root / "pet.petpack"),
            result=str(root / "result.json"),
            replace=True,
            changed_state=[],
            cli=str(root / "petcore-cli"),
        )
        return source, args

    def finalize_patches(self):
        counts = DEFAULT_FRAME_COUNTS
        hashes = {
            state: {
                f"frame-{index:03d}.png": f"{state}-{index}"
                for index in range(counts[state])
            }
            for state in workspace_helper.STATES
        }
        return (
            mock.patch.object(workspace_helper, "locate_cli", return_value=Path("/fake/petcore-cli")),
            mock.patch.object(workspace_helper, "collect_state_files", return_value=(hashes, counts)),
            mock.patch.object(
                workspace_helper,
                "manifest_timing_contract",
                wraps=workspace_helper.manifest_timing_contract,
            ),
            mock.patch.object(
                workspace_helper,
                "validate_exact_state_counts",
                wraps=workspace_helper.validate_exact_state_counts,
            ),
            mock.patch.object(
                workspace_helper,
                "normalize_source_metadata",
                return_value={"generator": "image-tool", "provenance": "skill-full-source"},
            ),
            mock.patch.object(workspace_helper, "validate_text_metadata"),
            mock.patch.object(workspace_helper, "validate_session"),
            mock.patch.object(workspace_helper, "append_session_event"),
            mock.patch.object(
                workspace_helper,
                "run_production_verification",
                return_value={
                    "schema_version": "apc.pet-visual-production-verification.v1",
                    "ok": True,
                    "audited_states": list(workspace_helper.STATES),
                    "changed_states": list(workspace_helper.STATES),
                    "timing_digest": "1" * 64,
                    "frame_set_digest": "0" * 64,
                    "warning_codes": [],
                    "build_ok": True,
                    "package_ok": True,
                    "interaction_ok": True,
                    "interaction_evidence": list(
                        workspace_helper.PRODUCTION_INTERACTION_EVIDENCE
                    ),
                    "runtime_ok": True,
                    "visual_ok": True,
                    "usable": True,
                },
            ),
        )

    def test_finalize_rejects_a_result_sidecar_symlink(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-finalize-") as temporary:
            root = Path(temporary)
            _, args = self.make_finalize_case(root)
            target = root / "sidecar-target.json"
            target.write_text("preserve me", encoding="utf-8")
            Path(args.result).symlink_to(target)

            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.finalize(args)

            self.assertEqual(raised.exception.code, "unsafe_output")
            self.assertIn("sidecar", raised.exception.message)
            self.assertEqual(target.read_text(encoding="utf-8"), "preserve me")

    def test_failed_replace_preserves_the_previous_package(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-finalize-") as temporary:
            root = Path(temporary)
            _, args = self.make_finalize_case(root)
            output = Path(args.output)
            output.write_bytes(b"known-good-old-package")
            build_destinations: list[Path] = []

            def fail_build(_cli: Path, arguments: list[str], _code: str) -> dict:
                if arguments[:2] == ["petpack", "build"]:
                    staged = Path(arguments[-1])
                    build_destinations.append(staged)
                    staged.write_bytes(b"partial-new-package")
                    raise workspace_helper.MakerError("build_failed", "simulated failure")
                return {"ok": True, "frame_count": 50, "warnings": []}

            patches = self.finalize_patches()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], mock.patch.object(
                workspace_helper, "run_cli", side_effect=fail_build
            ):
                with self.assertRaises(workspace_helper.MakerError):
                    workspace_helper.finalize(args)

            self.assertEqual(output.read_bytes(), b"known-good-old-package")
            self.assertEqual(len(build_destinations), 1)
            self.assertNotEqual(build_destinations[0], output)
            self.assertFalse(build_destinations[0].exists())

    def test_failed_staged_validation_preserves_the_previous_package(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-finalize-") as temporary:
            root = Path(temporary)
            _, args = self.make_finalize_case(root)
            output = Path(args.output)
            output.write_bytes(b"known-good-old-package")
            staged_outputs: list[Path] = []

            def reject_staged(_cli: Path, arguments: list[str], _code: str) -> dict:
                candidate = Path(arguments[-1])
                if arguments[:2] == ["petpack", "build"]:
                    candidate.write_bytes(b"built-but-invalid-package")
                    staged_outputs.append(candidate)
                elif arguments[:2] == ["petpack", "validate"] and candidate.is_file():
                    raise workspace_helper.MakerError(
                        "validation_failed", "simulated staged validation failure"
                    )
                return {"ok": True, "frame_count": 50, "warnings": []}

            patches = self.finalize_patches()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], mock.patch.object(
                workspace_helper, "run_cli", side_effect=reject_staged
            ):
                with self.assertRaises(workspace_helper.MakerError):
                    workspace_helper.finalize(args)

            self.assertEqual(output.read_bytes(), b"known-good-old-package")
            self.assertEqual(len(staged_outputs), 1)
            self.assertFalse(staged_outputs[0].exists())

    def test_successful_replace_publishes_only_after_staged_validation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-finalize-") as temporary:
            root = Path(temporary)
            _, args = self.make_finalize_case(root)
            output = Path(args.output)
            output.write_bytes(b"known-good-old-package")
            calls: list[tuple[str, Path]] = []

            def successful_cli(_cli: Path, arguments: list[str], _code: str) -> dict:
                if arguments[:2] == ["petpack", "build"]:
                    staged = Path(arguments[-1])
                    self.assertNotEqual(staged, output)
                    self.assertEqual(output.read_bytes(), b"known-good-old-package")
                    staged.write_bytes(b"validated-new-package")
                    calls.append(("build", staged))
                elif arguments[:2] == ["petpack", "validate"]:
                    candidate = Path(arguments[-1])
                    if candidate.is_dir():
                        validation = json.loads(
                            (candidate / "build" / "validation.json").read_text(
                                encoding="utf-8"
                            )
                        )
                        self.assertEqual(validation["frame_count"], 50)
                        self.assertEqual(
                            validation["states"],
                            default_state_entries(),
                        )
                        self.assertEqual(
                            validation["state_frame_counts"],
                            DEFAULT_FRAME_COUNTS,
                        )
                    else:
                        self.assertEqual(candidate.read_bytes(), b"validated-new-package")
                        self.assertEqual(output.read_bytes(), b"known-good-old-package")
                        calls.append(("validate-staged", candidate))
                return {"ok": True, "frame_count": 50, "warnings": []}

            patches = self.finalize_patches()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], mock.patch.object(
                workspace_helper, "run_cli", side_effect=successful_cli
            ):
                result = workspace_helper.finalize(args)

            self.assertEqual(result["status"], "completed")
            self.assertEqual(output.read_bytes(), b"validated-new-package")
            self.assertEqual([name for name, _ in calls], ["build", "validate-staged"])

    def test_atomic_publish_uses_a_normal_leaf_inside_a_private_stage(self) -> None:
        for replace in (False, True):
            with self.subTest(replace=replace), tempfile.TemporaryDirectory(
                prefix="agent-pet-maker-publish-"
            ) as temporary:
                root = Path(temporary)
                source = root / "petpack-source"
                source.mkdir()
                output = root / "pet.petpack"
                if replace:
                    output.write_bytes(b"known-good-old-package")

                def successful_cli(
                    _cli: Path, arguments: list[str], _code: str
                ) -> dict:
                    candidate = Path(arguments[-1])
                    if arguments[:2] == ["petpack", "build"]:
                        self.assertEqual(candidate.name, "package.petpack")
                        self.assertTrue(
                            candidate.parent.name.startswith(".apc-petpack-publish-")
                        )
                        self.assertFalse(candidate.name.startswith("."))
                        candidate.write_bytes(b"validated-new-package")
                    elif arguments[:2] == ["petpack", "validate"]:
                        self.assertEqual(candidate.read_bytes(), b"validated-new-package")
                    return {"ok": True, "frame_count": 50, "warnings": []}

                with mock.patch.object(
                    workspace_helper, "run_cli", side_effect=successful_cli
                ):
                    workspace_helper.build_petpack_atomically(
                        Path("/fake/petcore-cli"), source, output, replace
                    )

                self.assertEqual(output.read_bytes(), b"validated-new-package")
                self.assertEqual(list(root.glob(".apc-petpack-publish-*")), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS file flags only")
    def test_successful_publish_clears_the_finder_hidden_flag(self) -> None:
        for replace in (False, True):
            with self.subTest(replace=replace), tempfile.TemporaryDirectory(
                prefix="agent-pet-maker-finalize-"
            ) as temporary:
                root = Path(temporary)
                _, args = self.make_finalize_case(root)
                args.replace = replace
                output = Path(args.output)

                def hidden_staged_cli(_cli: Path, arguments: list[str], _code: str) -> dict:
                    if arguments[:2] == ["petpack", "build"]:
                        staged = Path(arguments[-1])
                        staged.write_bytes(b"validated-new-package")
                        os.chflags(staged, stat.UF_HIDDEN)
                    return {"ok": True, "frame_count": 50, "warnings": []}

                patches = self.finalize_patches()
                with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], mock.patch.object(
                    workspace_helper, "run_cli", side_effect=hidden_staged_cli
                ):
                    workspace_helper.finalize(args)

                self.assertEqual(os.stat(output).st_flags & stat.UF_HIDDEN, 0)

    @unittest.skipUnless(sys.platform == "darwin", "macOS file flags only")
    def test_successful_publish_clears_a_delayed_finder_hidden_flag(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="agent-pet-maker-finalize-"
        ) as temporary:
            root = Path(temporary)
            source = root / "petpack-source"
            source.mkdir()
            output = root / "pet.petpack"

            def successful_cli(
                _cli: Path, arguments: list[str], _code: str
            ) -> dict:
                candidate = Path(arguments[-1])
                if arguments[:2] == ["petpack", "build"]:
                    candidate.write_bytes(b"validated-new-package")
                return {"ok": True, "frame_count": 50, "warnings": []}

            def apply_delayed_hidden_flag() -> None:
                while not output.exists():
                    workspace_helper.time.sleep(0.005)
                workspace_helper.time.sleep(0.03)
                flags = os.stat(output).st_flags
                os.chflags(output, flags | stat.UF_HIDDEN)

            delayed_marker = threading.Thread(target=apply_delayed_hidden_flag)
            delayed_marker.start()
            with mock.patch.object(
                workspace_helper, "run_cli", side_effect=successful_cli
            ), mock.patch.object(
                workspace_helper, "FINDER_VISIBILITY_SETTLE_SECONDS", 0.2
            ), mock.patch.object(
                workspace_helper, "FINDER_VISIBILITY_POLL_SECONDS", 0.01
            ):
                workspace_helper.build_petpack_atomically(
                    Path("/fake/petcore-cli"), source, output, False
                )
            delayed_marker.join(timeout=1)

            self.assertFalse(delayed_marker.is_alive())
            self.assertEqual(os.stat(output).st_flags & stat.UF_HIDDEN, 0)


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

    def test_unix_macos_and_windows_absolute_paths_are_all_classified(self) -> None:
        absolute_paths = (
            "/tmp/pet.png",
            "/var/folders/cache/pet.png",
            "/Applications/AgentPetCompanion.app",
            "/Volumes/外置磁盘/宠物.png",
            "/用户/宠物.png",
            "~/Pictures/pet.png",
            r"C:\Users\private\pet.png",
            "D:/art/pet.png",
            r"\\server\share\pet.png",
            r"\\?\C:\very-long\pet.png",
        )
        for path in absolute_paths:
            with self.subTest(path=path):
                self.assertTrue(workspace_helper.contains_absolute_local_path(f"reference({path})"))

    def test_prompt_reuses_cross_platform_path_and_url_classification(self) -> None:
        manifest = default_manifest()
        source_metadata = {"generator": "image-tool", "provenance": "skill-full-source"}
        rejected = (
            "/private/tmp/pet.png",
            "/Volumes/外置磁盘/宠物.png",
            r"C:\Users\private\pet.png",
            r"\\server\share\pet.png",
            "https://private.example.invalid/pet.png",
        )
        for locator in rejected:
            with self.subTest(locator=locator), tempfile.TemporaryDirectory(
                prefix="agent-pet-maker-prompt-"
            ) as temporary:
                source = Path(temporary)
                (source / "source").mkdir()
                (source / "brief.json").write_text(
                    json.dumps(
                        {
                            "schema_version": "apc.pet-brief.v1",
                            "name": "Test Pet",
                            "style": "storybook",
                            "quality": "low",
                            "states": default_brief_states(),
                        }
                    ),
                    encoding="utf-8",
                )
                (source / "source" / "prompt.md").write_text(
                    f"Create a pet using reference({locator}).", encoding="utf-8"
                )
                with self.assertRaises(workspace_helper.MakerError) as raised:
                    workspace_helper.validate_text_metadata(
                        source,
                        manifest,
                        DEFAULT_FRAME_COUNTS,
                        source_metadata,
                    )
                self.assertEqual(raised.exception.code, "privacy_violation")
                self.assertNotIn(locator, raised.exception.message)

    def test_brief_object_state_timing_must_match_manifest(self) -> None:
        manifest = default_manifest()
        source_metadata = {"generator": "image-tool", "provenance": "skill-full-source"}
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-brief-") as temporary:
            source = Path(temporary)
            (source / "source").mkdir()
            (source / "source" / "prompt.md").write_text(
                "Create a compact storybook pet.", encoding="utf-8"
            )
            brief = {
                "schema_version": "apc.pet-brief.v1",
                "name": "Test Pet",
                "style": "storybook",
                "quality": "low",
                "states": default_brief_states(),
            }
            (source / "brief.json").write_text(json.dumps(brief), encoding="utf-8")
            workspace_helper.validate_text_metadata(
                source,
                manifest,
                DEFAULT_FRAME_COUNTS,
                source_metadata,
            )

            brief["states"][0]["frame_durations_ms"][0] += 1
            (source / "brief.json").write_text(json.dumps(brief), encoding="utf-8")
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_text_metadata(
                    source,
                    manifest,
                    {},
                    source_metadata,
                )
            self.assertEqual(raised.exception.code, "invalid_metadata")
            self.assertIn("frame_durations_ms", raised.exception.message)

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
            "note": "Animate idle/thinking/tool with variable holds; use / as a separator and (https-inspired) highlights.",
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
                                "states": default_state_entries(),
                                "state_frame_counts": DEFAULT_FRAME_COUNTS,
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
                            DEFAULT_FRAME_COUNTS,
                            default_manifest(name="Test"),
                        )
                    self.assertEqual(raised.exception.code, "privacy_violation")
                    self.assertIn(category, raised.exception.message)
                    self.assertNotIn("private-user", raised.exception.message)
                    self.assertNotIn("private.example.invalid", raised.exception.message)
                    self.assertNotIn("private-session-value", raised.exception.message)


if __name__ == "__main__":
    unittest.main()
