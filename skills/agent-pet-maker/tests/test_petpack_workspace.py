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
    "schema_version": "apc.petpack.v1",
    "id": pet_id,
    "name": "Test Pet",
    "style": "storybook",
    "quality": "standard",
    "render_size": {"width": 192, "height": 208},
}

if args[:2] == ["petpack", "validate"]:
    print(json.dumps({"ok": True, "manifest": manifest, "frame_count": 120, "warnings": []}))
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

    def test_visual_contract_accepts_transparency_and_real_animation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            workspace_helper.validate_portable_visual_assets(source, manifest)

    def test_visual_contract_rejects_an_opaque_frame(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            Image.new("RGBA", (8, 8), (20, 40, 60, 255)).save(
                source / "assets" / "frames" / "idle" / "frame-000.png"
            )
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_portable_visual_assets(source, manifest)
            self.assertEqual(raised.exception.code, "invalid_assets")
            self.assertIn("transparent surroundings", raised.exception.message)

    def test_visual_contract_rejects_a_frame_without_visible_pet_pixels(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            Image.new("RGBA", (8, 8), (255, 0, 0, 0)).save(
                source / "assets" / "frames" / "idle" / "frame-000.png"
            )
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_portable_visual_assets(source, manifest)
            self.assertEqual(raised.exception.code, "invalid_assets")
            self.assertIn("visible pet content", raised.exception.message)

    def test_visual_contract_uses_one_percent_alpha_thresholds(self) -> None:
        from PIL import Image

        total = 100 * 100
        required = workspace_helper.minimum_visual_pixel_count(total)
        self.assertEqual(required, 100)

        almost_invisible = Image.new("RGBA", (100, 100), (0, 0, 0, 0))
        for index in range(required - 1):
            almost_invisible.putpixel((index % 100, index // 100), (30, 60, 90, 255))
        _, visible, transparent = workspace_helper.visual_pixel_counts(almost_invisible)
        self.assertEqual(visible, required - 1)
        self.assertGreaterEqual(transparent, required)

        almost_opaque = Image.new("RGBA", (100, 100), (30, 60, 90, 255))
        for index in range(required - 1):
            almost_opaque.putpixel((index % 100, index // 100), (0, 0, 0, 0))
        _, visible, transparent = workspace_helper.visual_pixel_counts(almost_opaque)
        self.assertGreaterEqual(visible, required)
        self.assertEqual(transparent, required - 1)

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
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_generated_motion(state_files, ["idle"])
            self.assertIn("copied adjacent frames", raised.exception.message)

    def test_visual_contract_rejects_an_invisible_cover(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            Image.new("RGBA", (8, 8), (255, 0, 0, 0)).save(
                source / "assets" / "preview" / "cover.png"
            )
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_portable_visual_assets(source, manifest)
            self.assertEqual(raised.exception.code, "invalid_assets")
            self.assertIn("cover.png lacks visible pet content", raised.exception.message)

    def test_visual_contract_rejects_an_invisible_animated_frame(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            invisible = Image.new("RGBA", (8, 8), (255, 0, 0, 0))
            visible = self.visible_frame((40, 80, 120, 255))
            invisible.save(
                source / "assets" / "preview" / "animated_preview.webp",
                format="WEBP",
                save_all=True,
                append_images=[visible],
                duration=[80, 80],
                loop=0,
                lossless=True,
                exact=True,
            )
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_portable_visual_assets(source, manifest)
            self.assertEqual(raised.exception.code, "invalid_assets")
            self.assertIn("lacks visible pet content", raised.exception.message)

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

    def test_animated_preview_cannot_fake_motion_with_hidden_rgb(self) -> None:
        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            first = self.visible_frame((40, 80, 120, 255), hidden_rgb=(255, 0, 0))
            second = self.visible_frame((40, 80, 120, 255), hidden_rgb=(0, 255, 0))
            first.save(
                source / "assets" / "preview" / "animated_preview.webp",
                format="WEBP",
                save_all=True,
                append_images=[second],
                duration=[80, 80],
                loop=0,
                lossless=True,
                exact=True,
            )
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_portable_visual_assets(source, manifest)
            self.assertEqual(raised.exception.code, "invalid_assets")
            self.assertIn("no pixel-distinct frames", raised.exception.message)

    def test_visual_contract_rejects_a_static_preview(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="agent-pet-maker-visual-") as temporary:
            source, manifest = self.make_visual_source(Path(temporary))
            Image.new("RGBA", (8, 8), (20, 40, 60, 0)).save(
                source / "assets" / "preview" / "animated_preview.webp",
                format="WEBP",
            )
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_portable_visual_assets(source, manifest)
            self.assertEqual(raised.exception.code, "invalid_assets")
            self.assertIn("at least two frames", raised.exception.message)

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
                "native_fps": 10,
                "state_durations_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS,
                "state_frame_counts": {
                    state: 10 * duration // 1000
                    for state, duration in workspace_helper.DEFAULT_STATE_DURATIONS_MS.items()
                },
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
                {
                    state: 10 * workspace_helper.DEFAULT_STATE_DURATIONS_MS[state] // 1000
                    for state in workspace_helper.STATES
                },
                {
                    "id": "pet_test",
                    "name": "Test",
                    "style": "storybook",
                    "quality": "standard",
                    "native_fps": 10,
                    "states": [
                        {
                            "name": state,
                            "frames_dir": f"assets/frames/{state}",
                            "loop": state not in {"start", "done"},
                            "duration_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS[state],
                        }
                        for state in workspace_helper.STATES
                    ],
                },
            )
            self.assertFalse(set(normalized) - workspace_helper.SOURCE_ALLOWED_KEYS)
            self.assertEqual(normalized["provenance"], "skill-full-source")
            self.assertEqual(normalized["base_manifest_id"], "pet_test")
            self.assertEqual(normalized["changed_states"], ["tool"])
            self.assertNotIn("producer", normalized)
            self.assertNotIn("operation", normalized)
            self.assertNotIn("frame_counts", normalized)
            self.assertNotIn("frames_per_state", normalized)
            self.assertNotIn("fps_profiles", normalized)
            self.assertEqual(normalized["native_fps"], 10)

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
                        "native_fps": 10,
                        "state_durations_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS,
                        "state_frame_counts": {
                            state: 10 * duration // 1000
                            for state, duration in workspace_helper.DEFAULT_STATE_DURATIONS_MS.items()
                        },
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
                        "native_fps": 10,
                        "states": [
                            {
                                "name": state,
                                "frames_dir": f"assets/frames/{state}",
                                "loop": state not in {"start", "done"},
                                "duration_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS[state],
                            }
                            for state in workspace_helper.STATES
                        ],
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


class TimingContractTests(unittest.TestCase):
    @staticmethod
    def timing(native_fps: int, durations: dict[str, int] | None = None) -> dict:
        durations = dict(durations or workspace_helper.DEFAULT_STATE_DURATIONS_MS)
        return {
            "native_fps": native_fps,
            "state_durations_ms": durations,
            "state_frame_counts": {
                state: native_fps * durations[state] // 1000
                for state in workspace_helper.STATES
            },
        }

    @staticmethod
    def state_files(timing: dict, prefix: str) -> dict[str, dict[str, str]]:
        return {
            state: {
                f"{index:04d}.png": f"{prefix}-{state}-{index}"
                for index in range(timing["state_frame_counts"][state])
            }
            for state in workspace_helper.STATES
        }

    def test_exact_state_counts_cover_both_native_fps_tiers_and_durations(self) -> None:
        for native_fps, expected_total in ((10, 120), (20, 240)):
            with self.subTest(native_fps=native_fps):
                timing = self.timing(native_fps)
                self.assertEqual(sum(timing["state_frame_counts"].values()), expected_total)
                workspace_helper.validate_exact_state_counts(
                    timing["state_frame_counts"], timing
                )
                invalid = dict(timing["state_frame_counts"])
                invalid["start"] -= 1
                with self.assertRaises(workspace_helper.MakerError) as raised:
                    workspace_helper.validate_exact_state_counts(invalid, timing)
                self.assertEqual(raised.exception.code, "invalid_assets")
                self.assertIn("expected exactly", raised.exception.message)

    def test_frame_digests_follow_petcore_natural_filename_order(self) -> None:
        state_files = {
            "idle": {
                "10.png": "ten",
                "02.png": "two-padded",
                "002.png": "two-more-padded",
                "2.png": "two",
                "1.png": "one",
                "A2.png": "uppercase",
                "a2.png": "lowercase",
            }
        }
        self.assertEqual(
            workspace_helper.ordered_state_digests(state_files, "idle"),
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

    def test_native_fps_change_requires_all_seven_states(self) -> None:
        base = self.timing(10)
        current = self.timing(20)
        base_files = self.state_files(base, "base")
        current_files = self.state_files(current, "current")
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                base_files, current_files, base, current, ["tool"]
            )
        self.assertEqual(raised.exception.code, "timing_change_incomplete")

    def test_native_20_rejects_duplicate_canonical_10_fps_poses(self) -> None:
        timing = self.timing(20)
        state_files = self.state_files(timing, "frame")
        state_files["idle"]["0002.png"] = state_files["idle"]["0000.png"]
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_native_frame_semantics(
                state_files, ["idle"], timing
            )
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("canonical 10 FPS", raised.exception.message)

    def test_native_20_one_shot_canonical_sample_preserves_the_final_pose(self) -> None:
        timing = self.timing(20)
        state_files = self.state_files(timing, "frame")
        indices = workspace_helper.standard_sample_indices("done", 20, 1000)
        self.assertEqual(indices, [0, 2, 4, 6, 8, 11, 13, 15, 17, 19])
        state_files["done"]["0019.png"] = state_files["done"]["0017.png"]
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_native_frame_semantics(
                state_files, ["done"], timing
            )
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("indices 17 and 19", raised.exception.message)

    def test_native_20_loop_rejects_duplicate_standard_wrap_pose(self) -> None:
        timing = self.timing(20)
        state_files = self.state_files(timing, "frame")
        indices = workspace_helper.standard_sample_indices("idle", 40, 2000)
        self.assertEqual(indices[-1], 38)
        state_files["idle"]["0038.png"] = state_files["idle"]["0000.png"]
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_native_frame_semantics(
                state_files, ["idle"], timing
            )
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("wrap boundary", raised.exception.message)
        self.assertIn("indices 38 and 0", raised.exception.message)

    def test_10_to_20_preserves_runtime_sample_poses_and_real_intermediates(self) -> None:
        base = self.timing(10)
        current = self.timing(20)
        base_files = self.state_files(base, "base")
        converted: dict[str, dict[str, str]] = {}
        for state in workspace_helper.STATES:
            source = workspace_helper.ordered_state_digests(base_files, state)
            sequence = [f"mid-{state}-{index}" for index in range(len(source) * 2)]
            preserved_indices = workspace_helper.standard_sample_indices(
                state,
                len(sequence),
                current["state_durations_ms"][state],
            )
            for index, digest in zip(preserved_indices, source):
                sequence[index] = digest
            converted[state] = {
                f"{index:04d}.png": digest for index, digest in enumerate(sequence)
            }
        workspace_helper.validate_timing_revision(
            base_files,
            converted,
            base,
            current,
            list(workspace_helper.STATES),
        )

        copied = {state: dict(files) for state, files in converted.items()}
        copied["idle"]["0001.png"] = copied["idle"]["0000.png"]
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                base_files,
                copied,
                base,
                current,
                list(workspace_helper.STATES),
            )
        self.assertEqual(raised.exception.code, "invalid_frame_interpolation")

        distant_copy = {state: dict(files) for state, files in converted.items()}
        distant_copy["idle"]["0001.png"] = base_files["idle"]["0005.png"]
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                base_files,
                distant_copy,
                base,
                current,
                list(workspace_helper.STATES),
            )
        self.assertEqual(raised.exception.code, "invalid_frame_interpolation")
        self.assertIn("copied source pose", raised.exception.message)

    def test_20_to_10_matches_loop_and_one_shot_runtime_sampling(self) -> None:
        base = self.timing(20)
        current = self.timing(10)
        base_files = self.state_files(base, "base")
        sampled = {
            state: {
                f"{index:04d}.png": digest
                for index, digest in enumerate(
                    [
                        workspace_helper.ordered_state_digests(base_files, state)[
                            source_index
                        ]
                        for source_index in workspace_helper.standard_sample_indices(
                            state,
                            len(workspace_helper.ordered_state_digests(base_files, state)),
                            base["state_durations_ms"][state],
                        )
                    ]
                )
            }
            for state in workspace_helper.STATES
        }
        self.assertEqual(
            list(sampled["idle"].values()),
            workspace_helper.ordered_state_digests(base_files, "idle")[::2],
        )
        self.assertEqual(list(sampled["done"].values())[-1], "base-done-19")
        workspace_helper.validate_timing_revision(
            base_files,
            sampled,
            base,
            current,
            list(workspace_helper.STATES),
        )
        sampled["done"]["0001.png"] = "recomposed-instead-of-even-sample"
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                base_files,
                sampled,
                base,
                current,
                list(workspace_helper.STATES),
            )
        self.assertEqual(raised.exception.code, "invalid_frame_downsample")

    def test_duration_shortening_rejects_one_shot_endpoint_sampling(self) -> None:
        base_durations = dict(workspace_helper.DEFAULT_STATE_DURATIONS_MS)
        base_durations["start"] = 2000
        base = self.timing(10, base_durations)
        current = self.timing(10)
        base_files = self.state_files(base, "base")
        current_files = {state: dict(files) for state, files in base_files.items()}
        before = workspace_helper.ordered_state_digests(base_files, "start")
        sampled = [
            before[index]
            for index in workspace_helper.runtime_sample_indices(
                len(before),
                current["state_frame_counts"]["start"],
                False,
            )
        ]
        current_files["start"] = {
            f"{index:04d}.png": digest for index, digest in enumerate(sampled)
        }
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                base_files, current_files, base, current, ["start"]
            )
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("re-storyboard", raised.exception.message)

    def test_duration_change_rejects_repeated_old_action(self) -> None:
        base = self.timing(10)
        durations = dict(workspace_helper.DEFAULT_STATE_DURATIONS_MS)
        durations["start"] = 2000
        current = self.timing(10, durations)
        base_files = self.state_files(base, "base")
        current_files = {state: dict(files) for state, files in base_files.items()}
        before = workspace_helper.ordered_state_digests(base_files, "start")
        current_files["start"] = {
            f"{index:04d}.png": digest
            for index, digest in enumerate(before * 2)
        }
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                base_files, current_files, base, current, ["start"]
            )
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("re-storyboard", raised.exception.message)

    def test_duration_change_rejects_rotated_repeat_and_middle_slice(self) -> None:
        expanded_durations = dict(workspace_helper.DEFAULT_STATE_DURATIONS_MS)
        expanded_durations["start"] = 2000
        short_timing = self.timing(10)
        expanded_timing = self.timing(10, expanded_durations)
        short_files = self.state_files(short_timing, "base")
        expanded_files = {state: dict(files) for state, files in short_files.items()}
        before = workspace_helper.ordered_state_digests(short_files, "start")
        rotated = before[1:] + before[:1]
        expanded_files["start"] = {
            f"{index:04d}.png": digest
            for index, digest in enumerate(rotated * 2)
        }
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                short_files,
                expanded_files,
                short_timing,
                expanded_timing,
                ["start"],
            )
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("re-storyboard", raised.exception.message)

        long_files = self.state_files(expanded_timing, "base")
        shortened_files = {state: dict(files) for state, files in long_files.items()}
        long_before = workspace_helper.ordered_state_digests(long_files, "start")
        shortened_files["start"] = {
            f"{index:04d}.png": digest
            for index, digest in enumerate(long_before[5:15])
        }
        with self.assertRaises(workspace_helper.MakerError) as raised:
            workspace_helper.validate_timing_revision(
                long_files,
                shortened_files,
                expanded_timing,
                short_timing,
                ["start"],
            )
        self.assertEqual(raised.exception.code, "invalid_assets")
        self.assertIn("re-storyboard", raised.exception.message)

    def test_duration_change_accepts_a_recomposed_action(self) -> None:
        base = self.timing(10)
        durations = dict(workspace_helper.DEFAULT_STATE_DURATIONS_MS)
        durations["start"] = 2000
        current = self.timing(10, durations)
        base_files = self.state_files(base, "base")
        current_files = {state: dict(files) for state, files in base_files.items()}
        current_files["start"] = {
            f"{index:04d}.png": f"recomposed-start-{index}"
            for index in range(current["state_frame_counts"]["start"])
        }
        workspace_helper.validate_timing_revision(
            base_files, current_files, base, current, ["start"]
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
        manifest = {
            "schema_version": workspace_helper.PETPACK_SCHEMA,
            "id": "pet_test",
            "name": "Test Pet",
            "style": "storybook",
            "quality": "standard",
            "render_size": {"width": 8, "height": 8},
            "native_fps": 10,
            "states": [
                {
                    "name": state,
                    "frames_dir": f"assets/frames/{state}",
                    "loop": state not in {"start", "done"},
                    "duration_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS[state],
                }
                for state in workspace_helper.STATES
            ],
        }
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
        counts = {
            state: 10 * workspace_helper.DEFAULT_STATE_DURATIONS_MS[state] // 1000
            for state in workspace_helper.STATES
        }
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
            mock.patch.object(workspace_helper, "validate_generated_motion"),
            mock.patch.object(workspace_helper, "validate_portable_visual_assets"),
            mock.patch.object(
                workspace_helper,
                "normalize_source_metadata",
                return_value={"generator": "image-tool", "provenance": "skill-full-source"},
            ),
            mock.patch.object(workspace_helper, "validate_text_metadata"),
            mock.patch.object(workspace_helper, "validate_session"),
            mock.patch.object(workspace_helper, "append_session_event"),
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
                return {"ok": True, "frame_count": 120, "warnings": []}

            patches = self.finalize_patches()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], mock.patch.object(
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
                return {"ok": True, "frame_count": 120, "warnings": []}

            patches = self.finalize_patches()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], mock.patch.object(
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
                        self.assertEqual(validation["frame_count"], 120)
                        self.assertEqual(validation["native_fps"], 10)
                        self.assertEqual(
                            validation["state_durations_ms"],
                            workspace_helper.DEFAULT_STATE_DURATIONS_MS,
                        )
                        self.assertEqual(
                            validation["state_frame_counts"],
                            {
                                state: 10
                                * workspace_helper.DEFAULT_STATE_DURATIONS_MS[state]
                                // 1000
                                for state in workspace_helper.STATES
                            },
                        )
                    else:
                        self.assertEqual(candidate.read_bytes(), b"validated-new-package")
                        self.assertEqual(output.read_bytes(), b"known-good-old-package")
                        calls.append(("validate-staged", candidate))
                return {"ok": True, "frame_count": 120, "warnings": []}

            patches = self.finalize_patches()
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], mock.patch.object(
                workspace_helper, "run_cli", side_effect=successful_cli
            ):
                result = workspace_helper.finalize(args)

            self.assertEqual(result["status"], "completed")
            self.assertEqual(output.read_bytes(), b"validated-new-package")
            self.assertEqual([name for name, _ in calls], ["build", "validate-staged"])


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
        manifest = {
            "name": "Test Pet",
            "style": "storybook",
            "quality": "standard",
            "render_size": {"width": 8, "height": 8},
            "native_fps": 10,
            "states": [
                {
                    "name": state,
                    "duration_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS[state],
                }
                for state in workspace_helper.STATES
            ],
        }
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
                            "quality": "standard",
                            "states": list(workspace_helper.STATES),
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
                        {state: 2 for state in workspace_helper.STATES},
                        source_metadata,
                    )
                self.assertEqual(raised.exception.code, "privacy_violation")
                self.assertNotIn(locator, raised.exception.message)

    def test_brief_object_state_duration_must_match_manifest(self) -> None:
        manifest = {
            "name": "Test Pet",
            "style": "storybook",
            "quality": "standard",
            "render_size": {"width": 8, "height": 8},
            "native_fps": 10,
            "states": [
                {
                    "name": state,
                    "duration_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS[state],
                }
                for state in workspace_helper.STATES
            ],
        }
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
                "quality": "standard",
                "states": [
                    {
                        "name": state,
                        "motion": f"A clear {state} motion.",
                        "duration_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS[state],
                    }
                    for state in workspace_helper.STATES
                ],
            }
            (source / "brief.json").write_text(json.dumps(brief), encoding="utf-8")
            workspace_helper.validate_text_metadata(
                source,
                manifest,
                {
                    state: 10 * workspace_helper.DEFAULT_STATE_DURATIONS_MS[state] // 1000
                    for state in workspace_helper.STATES
                },
                source_metadata,
            )

            brief["states"][0]["duration_ms"] = 1000
            (source / "brief.json").write_text(json.dumps(brief), encoding="utf-8")
            with self.assertRaises(workspace_helper.MakerError) as raised:
                workspace_helper.validate_text_metadata(
                    source,
                    manifest,
                    {},
                    source_metadata,
                )
            self.assertEqual(raised.exception.code, "invalid_metadata")
            self.assertIn("duration_ms", raised.exception.message)

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
            "note": "Animate idle/start/tool at 10/20 fps; use / as a separator and (https-inspired) highlights.",
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
                                "native_fps": 10,
                                "state_durations_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS,
                                "state_frame_counts": {
                                    state: 10 * duration // 1000
                                    for state, duration in workspace_helper.DEFAULT_STATE_DURATIONS_MS.items()
                                },
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
                            {
                                state: 10 * workspace_helper.DEFAULT_STATE_DURATIONS_MS[state] // 1000
                                for state in workspace_helper.STATES
                            },
                            {
                                "id": "pet_test",
                                "name": "Test",
                                "style": "storybook",
                                "quality": "standard",
                                "native_fps": 10,
                                "states": [
                                    {
                                        "name": state,
                                        "frames_dir": f"assets/frames/{state}",
                                        "loop": state not in {"start", "done"},
                                        "duration_ms": workspace_helper.DEFAULT_STATE_DURATIONS_MS[state],
                                    }
                                    for state in workspace_helper.STATES
                                ],
                            },
                        )
                    self.assertEqual(raised.exception.code, "privacy_violation")
                    self.assertIn(category, raised.exception.message)
                    self.assertNotIn("private-user", raised.exception.message)
                    self.assertNotIn("private.example.invalid", raised.exception.message)
                    self.assertNotIn("private-session-value", raised.exception.message)


if __name__ == "__main__":
    unittest.main()
