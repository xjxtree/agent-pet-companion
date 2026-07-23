#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import plistlib
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
    BUILD_ID = "1.2.3.45." + "a" * 12

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

    def create_evidence(
        self, architecture: str, archive_name: str, archive_sha256: str
    ) -> pathlib.Path:
        path = self.root / f"{architecture}.json"
        path.write_text(
            json.dumps(
                {
                    "schema_version": "apc.public-distribution-evidence.v1",
                    "architecture": architecture,
                    "version": self.VERSION,
                    "build": self.BUILD,
                    "commit": self.COMMIT,
                    "build_id": self.BUILD_ID,
                    "notarization": {
                        "submission_id": "submission",
                        "status": "Accepted",
                        "submission_archive_sha256": "b" * 64,
                    },
                    "published_artifact": {
                        "filename": archive_name,
                        "sha256": archive_sha256,
                        "stapled": True,
                        "gatekeeper_accepted": True,
                    },
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_identity_binds_expected_commit_build_and_both_architectures(self) -> None:
        for architecture in ("arm64", "x86_64"):
            archive_name = (
                f"AgentPetCompanion-{self.VERSION}-macos-{architecture}.zip"
            )
            archive_sha256 = ("c" if architecture == "arm64" else "d") * 64
            evidence = self.create_evidence(
                architecture, archive_name, archive_sha256
            )
            value = release_identity.validate(
                self.app,
                evidence,
                architecture,
                self.VERSION,
                self.BUILD,
                self.COMMIT,
                archive_name,
                archive_sha256,
            )
            self.assertEqual(value, self.BUILD_ID)

    def test_identity_mismatch_fails_closed(self) -> None:
        archive_name = f"AgentPetCompanion-{self.VERSION}-macos-arm64.zip"
        evidence = self.create_evidence("arm64", archive_name, "c" * 64)
        with self.assertRaises(ValueError):
            release_identity.validate(
                self.app,
                evidence,
                "arm64",
                self.VERSION,
                "46",
                self.COMMIT,
                archive_name,
                "c" * 64,
            )
        with self.assertRaises(ValueError):
            release_identity.validate(
                self.app,
                evidence,
                "arm64",
                self.VERSION,
                self.BUILD,
                "e" * 40,
                archive_name,
                "c" * 64,
            )

    def create_artifact_set(self) -> tuple[list[str], str]:
        data_names, checksum_name = artifact_metadata.expected_names(self.VERSION)
        lines = []
        for index, name in enumerate(data_names):
            data = f"asset-{index}".encode()
            (self.artifact_dir / name).write_bytes(data)
            lines.append(f"{hashlib.sha256(data).hexdigest()}  {name}")
        (self.artifact_dir / checksum_name).write_text(
            "\n".join(lines) + "\n", encoding="ascii"
        )
        return data_names, checksum_name

    def test_exact_five_files_and_four_checksum_entries_are_required(self) -> None:
        data_names, checksum_name = self.create_artifact_set()
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
    def test_public_trust_gate_precedes_packaged_code_execution(self) -> None:
        source = (ROOT / "script/validate_app_bundle.sh").read_text(encoding="utf-8")
        gate_call = source.index("  validate_public_trust_before_runtime\n")
        packaged_executions = (
            source.index('"$PETCORE_CLI" petpack validate'),
            source.index('"$APP_BINARY" --run-ui-validation'),
            source.index('"$PETCORE" preflight'),
            source.index('"$PETCORE_CLI" renderer budget'),
        )
        self.assertTrue(all(gate_call < execution for execution in packaged_executions))

    def test_every_release_extraction_has_a_preceding_zip_preflight(self) -> None:
        for relative_path in (
            "script/build_release.sh",
            "script/public_distribution_pipeline.sh",
            "script/validate_public_release_artifacts.sh",
        ):
            source = (ROOT / relative_path).read_text(encoding="utf-8")
            cursor = 0
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
                cursor = extraction + 1


class ReleaseWorkflowIdentityTests(unittest.TestCase):
    def test_downstream_jobs_use_proven_commit_and_recheck_remote_tag(self) -> None:
        source = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertNotIn("ref: ${{ needs.build.outputs.tag }}", source)
        self.assertEqual(
            source.count("ref: ${{ needs.build.outputs.commit }}"),
            3,
        )
        self.assertGreaterEqual(
            source.count("./script/verify_remote_release_tag.sh"),
            3,
        )


if __name__ == "__main__":
    unittest.main()
