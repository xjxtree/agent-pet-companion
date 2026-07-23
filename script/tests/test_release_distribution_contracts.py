#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import plistlib
import re
import stat
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


zip_safety = load_module("apc_zip_safety", "script/validate_release_zip.py")
artifact_metadata = load_module(
    "apc_artifact_metadata", "script/validate_release_artifact_metadata.py"
)
release_identity = load_module(
    "apc_release_identity", "script/validate_release_identity.py"
)


def add_directory(archive: zipfile.ZipFile, name: str) -> None:
    info = zipfile.ZipInfo(name.rstrip("/") + "/")
    info.external_attr = (stat.S_IFDIR | 0o755) << 16
    archive.writestr(info, b"")


def add_file(
    archive: zipfile.ZipFile,
    name: str,
    data: bytes = b"payload",
    mode: int = stat.S_IFREG | 0o644,
) -> None:
    info = zipfile.ZipInfo(name)
    info.external_attr = mode << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    archive.writestr(info, data)


class ReleaseZipSafetyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_zip(self, mutator=None) -> pathlib.Path:
        path = self.root / "candidate.zip"
        with zipfile.ZipFile(path, "w") as archive:
            add_directory(archive, "AgentPetCompanion.app")
            add_directory(archive, "AgentPetCompanion.app/Contents")
            add_file(
                archive,
                "AgentPetCompanion.app/Contents/Info.plist",
                b"plist",
            )
            if mutator is not None:
                mutator(archive)
        return path

    def assert_unsafe(self, mutator) -> None:
        with self.assertRaises(zip_safety.UnsafeArchive):
            zip_safety.validate_archive(self.make_zip(mutator))

    def test_valid_release_shape_is_accepted(self) -> None:
        zip_safety.validate_archive(self.make_zip())

    def test_zip_slip_absolute_backslash_and_extra_top_level_are_rejected(self) -> None:
        for path in (
            "AgentPetCompanion.app/../escape",
            "/AgentPetCompanion.app/escape",
            r"AgentPetCompanion.app\Contents\escape",
            "unexpected/escape",
        ):
            with self.subTest(path=path):
                self.assert_unsafe(lambda archive, path=path: add_file(archive, path))

    def test_duplicate_casefold_and_unicode_normalized_paths_are_rejected(self) -> None:
        self.assert_unsafe(
            lambda archive: (
                add_file(archive, "AgentPetCompanion.app/Contents/ReadMe"),
                add_file(archive, "AgentPetCompanion.app/contents/readme"),
            )
        )
        self.assert_unsafe(
            lambda archive: (
                add_file(archive, "AgentPetCompanion.app/Contents/caf\u00e9"),
                add_file(archive, "AgentPetCompanion.app/Contents/cafe\u0301"),
            )
        )

    def test_any_symlink_and_special_entry_are_rejected(self) -> None:
        self.assert_unsafe(
            lambda archive: add_file(
                archive,
                "AgentPetCompanion.app/Contents/link",
                b"../../outside",
                stat.S_IFLNK | 0o777,
            )
        )
        self.assert_unsafe(
            lambda archive: add_file(
                archive,
                "AgentPetCompanion.app/Contents/fifo",
                b"",
                stat.S_IFIFO | 0o600,
            )
        )

    def test_ratio_entry_count_and_uncompressed_limits_are_enforced(self) -> None:
        self.assert_unsafe(
            lambda archive: add_file(
                archive,
                "AgentPetCompanion.app/Contents/bomb",
                b"\0" * (2 * 1024 * 1024),
            )
        )
        original_count = zip_safety.MAX_ENTRY_COUNT
        original_entry = zip_safety.MAX_ENTRY_UNCOMPRESSED_BYTES
        original_total = zip_safety.MAX_TOTAL_UNCOMPRESSED_BYTES
        try:
            zip_safety.MAX_ENTRY_COUNT = 2
            self.assert_unsafe(None)
            zip_safety.MAX_ENTRY_COUNT = original_count
            zip_safety.MAX_ENTRY_UNCOMPRESSED_BYTES = 3
            self.assert_unsafe(
                lambda archive: add_file(
                    archive, "AgentPetCompanion.app/Contents/large", b"four"
                )
            )
            zip_safety.MAX_ENTRY_UNCOMPRESSED_BYTES = original_entry
            zip_safety.MAX_TOTAL_UNCOMPRESSED_BYTES = 4
            self.assert_unsafe(None)
        finally:
            zip_safety.MAX_ENTRY_COUNT = original_count
            zip_safety.MAX_ENTRY_UNCOMPRESSED_BYTES = original_entry
            zip_safety.MAX_TOTAL_UNCOMPRESSED_BYTES = original_total


class ReleaseMetadataAndIdentityTests(unittest.TestCase):
    VERSION = "1.2.3"
    BUILD = "45"
    COMMIT = "a" * 40
    BUILD_ID = f"{VERSION}.{BUILD}.{COMMIT}"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / "AppFixture/AgentPetCompanion.app"
        self.artifact_dir = self.root / "Artifacts"
        self.artifact_dir.mkdir()
        (self.app / "Contents/Resources").mkdir(parents=True)
        info = {
            "CFBundleShortVersionString": self.VERSION,
            "CFBundleVersion": self.BUILD,
            "APCBuildID": self.BUILD_ID,
            "APCReleaseChannel": "release",
            "APCRuntimeManifestSchemaVersion": "apc.runtime-manifest.v1",
        }
        with (self.app / "Contents/Info.plist").open("wb") as output:
            plistlib.dump(info, output)
        manifest = {
            "schema_version": "apc.runtime-manifest.v1",
            "release_channel": "release",
            "app_version": self.VERSION,
            "app_build": self.BUILD,
            "build_id": self.BUILD_ID,
            "petcore_build_id": self.BUILD_ID,
            "petcore_cli_build_id": self.BUILD_ID,
        }
        (self.app / "Contents/Resources/runtime-manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_identity_binds_full_commit_build_and_both_architectures(self) -> None:
        for architecture in ("arm64", "x86_64"):
            with self.subTest(architecture=architecture):
                value = release_identity.validate(
                    self.app,
                    architecture,
                    self.VERSION,
                    self.BUILD,
                    self.COMMIT,
                )
                self.assertEqual(value, self.BUILD_ID)
                self.assertTrue(value.endswith(self.COMMIT))

    def test_identity_mismatch_and_truncated_commit_build_id_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            release_identity.validate(
                self.app,
                "arm64",
                self.VERSION,
                "46",
                self.COMMIT,
            )
        with self.assertRaises(ValueError):
            release_identity.validate(
                self.app,
                "arm64",
                self.VERSION,
                self.BUILD,
                "e" * 40,
            )

        info_path = self.app / "Contents/Info.plist"
        with info_path.open("rb") as source:
            info = plistlib.load(source)
        info["APCBuildID"] = f"{self.VERSION}.{self.BUILD}.{self.COMMIT[:12]}"
        with info_path.open("wb") as output:
            plistlib.dump(info, output)
        with self.assertRaises(ValueError):
            release_identity.validate(
                self.app,
                "arm64",
                self.VERSION,
                self.BUILD,
                self.COMMIT,
            )

    def create_artifact_set(self) -> tuple[list[str], str]:
        archive_names, checksum_name = artifact_metadata.expected_names(self.VERSION)
        lines = []
        for index, name in enumerate(archive_names):
            data = f"asset-{index}".encode()
            (self.artifact_dir / name).write_bytes(data)
            lines.append(f"{hashlib.sha256(data).hexdigest()}  {name}")
        (self.artifact_dir / checksum_name).write_text(
            "\n".join(lines) + "\n", encoding="ascii"
        )
        return archive_names, checksum_name

    def test_exact_three_files_and_two_checksum_entries_are_required(self) -> None:
        archive_names, checksum_name = self.create_artifact_set()
        self.assertEqual(len(archive_names), 2)
        artifact_metadata.validate(self.artifact_dir, self.VERSION)

        (self.artifact_dir / "extra.txt").write_text("unexpected", encoding="utf-8")
        with self.assertRaises(ValueError):
            artifact_metadata.validate(self.artifact_dir, self.VERSION)
        (self.artifact_dir / "extra.txt").unlink()

        checksum = self.artifact_dir / checksum_name
        checksum.write_text(
            checksum.read_text(encoding="ascii")
            + f"{hashlib.sha256(b'self').hexdigest()}  {checksum_name}\n",
            encoding="ascii",
        )
        with self.assertRaises(ValueError):
            artifact_metadata.validate(self.artifact_dir, self.VERSION)


class ValidationOrderTests(unittest.TestCase):
    def test_adhoc_signature_gate_precedes_packaged_code_execution(self) -> None:
        source = (ROOT / "script/validate_app_bundle.sh").read_text(encoding="utf-8")
        self.assertIn("grep -Fx 'Signature=adhoc'", source)
        gate_call = source.index(
            "  validate_github_release_signature_before_runtime\n"
        )
        packaged_executions = (
            '"$PETCORE_CLI" petpack validate',
            '"$APP_BINARY" --run-ui-validation',
            '"$PETCORE" preflight',
            '"$PETCORE" init',
            '"$PETCORE_CLI" renderer budget',
            '"$PETCORE" serve',
            '"$PETCORE_CLI" health',
            '"$PETCORE_CLI" petpack seed-bundled',
            '"$PETCORE_CLI" pet list',
            '"$PETCORE_CLI" connections repair',
        )
        for invocation in packaged_executions:
            with self.subTest(invocation=invocation):
                self.assertLess(gate_call, source.index(invocation))

    def test_every_release_extraction_has_a_preceding_zip_preflight(self) -> None:
        for relative_path in (
            "script/build_release.sh",
            "script/validate_github_release_artifacts.sh",
        ):
            source = (ROOT / relative_path).read_text(encoding="utf-8")
            cursor = 0
            extraction_count = 0
            while True:
                extraction = source.find("ditto -x -k", cursor)
                if extraction == -1:
                    break
                preflight = source.rfind("validate_release_zip.py", cursor, extraction)
                self.assertNotEqual(
                    preflight,
                    -1,
                    f"{relative_path} extracts a ZIP without a preceding safety preflight",
                )
                extraction_count += 1
                cursor = extraction + 1
            self.assertGreater(extraction_count, 0)


class ReleaseWorkflowContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        build_end = self.source.index("\n  validate_arm64:")
        arm_end = self.source.index("\n  validate_x86_64:")
        x86_end = self.source.index("\n  publish:")
        self.build = self.source[:build_end]
        self.arm = self.source[build_end:arm_end]
        self.x86 = self.source[arm_end:x86_end]
        self.publish = self.source[x86_end:]

    def test_workflow_has_no_signing_environment_or_apple_trust_pipeline(self) -> None:
        self.assertNotRegex(self.source, r"(?m)^\s*environment:")
        self.assertNotIn("${{ vars.", self.source)
        self.assertNotIn("${{ secrets.", self.source)
        for forbidden in (
            "Developer ID Application",
            "APC_CODESIGN_IDENTITY",
            "APC_NOTARY",
            "notarytool",
            "stapler",
            "spctl",
            "create-keychain",
            "delete-keychain",
            "find-identity",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, self.source)

    def test_release_notes_disclose_adhoc_signing_and_both_first_open_paths(self) -> None:
        self.assertIn("ad-hoc signed", self.publish)
        self.assertIn("not Developer ID signed", self.publish)
        self.assertIn("没有 Developer ID 签名", self.publish)
        self.assertIn("Control-click", self.publish)
        self.assertIn("System Settings → Privacy & Security → Open Anyway", self.publish)
        self.assertIn("按住 Control 点按", self.publish)
        self.assertIn("系统设置 → 隐私与安全性 → 仍要打开", self.publish)

    def test_official_build_and_exact_three_file_candidate_are_explicit(self) -> None:
        self.assertIn("Prepare pinned Python validation environment", self.build)
        self.assertIn("Pillow==11.3.0", self.build)
        self.assertIn('Image.__version__ != "11.3.0"', self.build)
        self.assertIn('features.check("webp_anim")', self.build)
        self.assertIn('>>"$GITHUB_PATH"', self.build)
        self.assertIn("run: ./script/test_all.sh", self.build)
        self.assertLess(
            self.build.index("Prepare pinned Python validation environment"),
            self.build.index("run: ./script/test_all.sh"),
        )
        self.assertIn(
            "run: ./script/build_release.sh --github-release --arch all",
            self.build,
        )
        stage_index = self.build.index(
            "- name: Stage exact three-file release candidate"
        )
        revalidate_index = self.build.index(
            "- name: Revalidate final local artifact set"
        )
        self.assertLess(stage_index, revalidate_index)
        stage_block = self.build[stage_index:revalidate_index]
        self.assertIn("test ! -e release-assets", stage_block)
        self.assertEqual(stage_block.count('mv "dist/$asset" "release-assets/$asset"'), 1)
        self.assertIn("--directory release-assets", self.build)
        self.assertNotIn("--directory dist", self.build)
        self.assertIn("validate_github_release_artifacts.sh", self.source)
        upload_start = self.build.index("- name: Upload immutable release candidate")
        upload_block = self.build[upload_start:]
        expected_assets = (
            "macos-arm64.zip",
            "macos-x86_64.zip",
            "SHA256SUMS.txt",
        )
        for suffix in expected_assets:
            self.assertEqual(upload_block.count(suffix), 1)
        self.assertEqual(self.publish.count('"release-assets/AgentPetCompanion-'), 3)

    def test_only_publish_job_can_write_repository_contents(self) -> None:
        self.assertEqual(self.source.count("contents: write"), 1)
        self.assertNotIn("contents: write", self.build)
        self.assertNotIn("contents: write", self.arm)
        self.assertNotIn("contents: write", self.x86)
        self.assertIn("contents: write", self.publish)

    def test_downstream_jobs_use_proven_commit_and_recheck_remote_tag(self) -> None:
        self.assertNotIn("ref: ${{ needs.build.outputs.tag }}", self.source)
        self.assertEqual(
            self.source.count("ref: ${{ needs.build.outputs.commit }}"),
            3,
        )
        self.assertGreaterEqual(
            self.source.count("./script/verify_remote_release_tag.sh"),
            3,
        )
        self.assertIn(
            'git merge-base --is-ancestor "$commit" refs/remotes/origin/main',
            self.build,
        )

    def test_native_architecture_jobs_and_download_revalidation_are_mandatory(self) -> None:
        self.assertNotIn("self-hosted", self.source)
        self.assertIn("runs-on: macos-15\n", self.arm)
        self.assertIn("runs-on: macos-15-intel\n", self.x86)
        self.assertIn('run: test "$(uname -m)" = "arm64"', self.arm)
        self.assertNotIn('= "x86_64"', self.arm)
        self.assertIn('run: test "$(uname -m)" = "x86_64"', self.x86)
        self.assertNotIn('= "arm64"', self.x86)

        release_download = self.publish.index('gh release download "$RELEASE_TAG"')
        digest_recheck = self.publish.index(
            "./script/verify_release_candidate_digests.sh", release_download
        )
        package_recheck = self.publish.index(
            "./script/validate_github_release_artifacts.sh", digest_recheck
        )
        tag_recheck = self.publish.index(
            "./script/verify_remote_release_tag.sh", package_recheck
        )
        publish_release = self.publish.index(
            'gh release edit "$RELEASE_TAG" --draft=false', tag_recheck
        )
        self.assertLess(release_download, digest_recheck)
        self.assertLess(digest_recheck, package_recheck)
        self.assertLess(package_recheck, tag_recheck)
        self.assertLess(tag_recheck, publish_release)

    def test_every_action_is_pinned_to_a_full_commit(self) -> None:
        uses = re.findall(r"(?m)^\s*-\s+uses:\s+([^#\s]+)", self.source)
        self.assertTrue(uses)
        for action in uses:
            with self.subTest(action=action):
                self.assertRegex(action, r"^[^@]+@[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
