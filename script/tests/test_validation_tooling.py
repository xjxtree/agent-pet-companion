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
from argparse import Namespace
from datetime import datetime, timezone
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
LOCALIZATION_VALIDATOR = ROOT / "script/validate_localizations.py"
FINGERPRINT = ROOT / "script/validation_fingerprint.py"
INTERACTION_VALIDATOR = ROOT / "script/validate_interaction_attestation.py"
OVERLAY_INTERACTION = ROOT / "script/validate_overlay_interaction.sh"
VALIDATION_SCOPE_PATH = ROOT / "script/validation_scope.py"
RELEASE_SOURCE_PROOF_PATH = ROOT / "script/release_source_proof.py"
RESOLVE_SOURCE_PROOF_PATH = ROOT / "script/resolve_release_source_proof.py"
RUST_TEST_SHARDS_PATH = ROOT / "script/validate_rust_test_shards.py"
MAIN_BRANCH_RULESET_PATH = ROOT / "script/configure_main_branch_ruleset.py"
DEVELOPMENT_FLOW_PATH = ROOT / "script/development_flow.py"
DEVELOPMENT_DOMAINS_PATH = ROOT / "script/development_domains.py"
CHANGELOG_FRAGMENTS_PATH = ROOT / "script/changelog_fragments.py"
LOCAL_TESTS_PATH = ROOT / "script/validate_local_tests.py"
ENGINEERING_METRICS_PATH = ROOT / "script/engineering_metrics.py"
SWIFT_BUILD_ARTIFACT_PATH = ROOT / "script/swift_build_artifact.py"
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
release_source_proof = load_module("apc_release_source_proof", RELEASE_SOURCE_PROOF_PATH)
resolve_source_proof = load_module("apc_resolve_source_proof", RESOLVE_SOURCE_PROOF_PATH)
rust_test_shards = load_module("apc_rust_test_shards", RUST_TEST_SHARDS_PATH)
main_branch_ruleset = load_module("apc_main_branch_ruleset", MAIN_BRANCH_RULESET_PATH)
development_flow = load_module("apc_development_flow", DEVELOPMENT_FLOW_PATH)
development_domains = load_module("apc_development_domains", DEVELOPMENT_DOMAINS_PATH)
sys.modules["development_domains"] = development_domains
changelog_fragments = load_module("apc_changelog_fragments", CHANGELOG_FRAGMENTS_PATH)
local_tests = load_module("apc_local_tests", LOCAL_TESTS_PATH)
engineering_metrics = load_module("apc_engineering_metrics", ENGINEERING_METRICS_PATH)
swift_build_artifact = load_module(
    "apc_swift_build_artifact", SWIFT_BUILD_ARTIFACT_PATH
)


class EngineeringMetricsTests(unittest.TestCase):
    def test_job_metrics_report_platform_minutes_without_source_content(self) -> None:
        metrics = engineering_metrics.job_metrics(
            {
                "jobs": [
                    {
                        "name": "Linux gate",
                        "startedAt": "2026-08-12T00:00:00Z",
                        "completedAt": "2026-08-12T00:01:00Z",
                        "labels": ["ubuntu-24.04"],
                        "conclusion": "success",
                        "steps": [
                            {
                                "name": "Restore exact Cargo cache",
                                "startedAt": "2026-08-12T00:00:05Z",
                                "completedAt": "2026-08-12T00:00:12Z",
                            },
                            {
                                "name": "Post Restore exact Cargo cache",
                                "startedAt": "2026-08-12T00:00:55Z",
                                "completedAt": "2026-08-12T00:01:00Z",
                            },
                        ],
                    },
                    {
                        "name": "macOS gate",
                        "startedAt": "2026-08-12T00:00:30Z",
                        "completedAt": "2026-08-12T00:02:00Z",
                        "labels": ["macos-26"],
                        "conclusion": "success",
                        "steps": [],
                    },
                ]
            }
        )
        self.assertEqual(metrics["workflow_wall_seconds"], 120)
        self.assertEqual(metrics["critical_path_seconds"], 120)
        self.assertEqual(metrics["execution_seconds"], 120)
        self.assertEqual(metrics["linux_job_seconds"], 60)
        self.assertEqual(metrics["macos_job_seconds"], 90)
        self.assertEqual(metrics["cache_restore_seconds"], 7)
        self.assertEqual(metrics["cache_save_seconds"], 5)

    def test_cache_and_lifecycle_metrics_have_bounded_stable_definitions(self) -> None:
        observed = datetime(2026, 8, 12, 12, tzinfo=timezone.utc)
        caches = engineering_metrics.cache_metrics(
            {
                "actions_caches": [
                    {
                        "size_in_bytes": 1_024,
                        "created_at": "2026-08-12T11:00:00Z",
                    },
                    {
                        "size_in_bytes": 2_048,
                        "created_at": "2026-08-10T11:00:00Z",
                    },
                ]
            },
            observed,
        )
        self.assertEqual(caches["listed_size_bytes"], 3_072)
        self.assertEqual(caches["created_last_24h_bytes"], 1_024)
        lifecycle = engineering_metrics.lifecycle_metrics(
            [
                "2026-08-12T10:00:00Z",
                "2026-08-12T11:00:00Z",
                "2026-08-12T11:15:00Z",
            ]
        )
        self.assertEqual(lifecycle["task_to_ready_seconds"], 3_600)
        self.assertEqual(lifecycle["ready_to_merged_seconds"], 900)

    def test_summary_exposes_proof_cache_and_coordination_outcomes(self) -> None:
        summary = engineering_metrics.render_summary(
            {
                "change": {
                    "changed_path_count": 4,
                    "amber_path_count": 1,
                    "red_path_count": 1,
                },
                "proof": {
                    "outcome": "full-validation",
                    "fallback_category": "control-plane-change",
                },
                "coordination": {
                    "claim_overlap_rejections": 2,
                    "merge_tree_conflicts": 1,
                    "train_conflict_resolutions": 0,
                },
                "lifecycle": {
                    "task_to_ready_seconds": 360,
                    "ready_to_merged_seconds": None,
                },
                "cache_exact_hits": {"cargo-source": "true"},
            }
        )
        self.assertIn("| proof outcome | full-validation |", summary)
        self.assertIn("| promotion fallback | control-plane-change |", summary)
        self.assertIn("| exact cache `cargo-source` | true |", summary)
        self.assertIn("| claim-overlap rejections | 2 |", summary)
        self.assertIn("| ready-to-merged seconds | n/a |", summary)


class SwiftBuildArtifactTests(unittest.TestCase):
    def test_checkout_identity_requires_the_exact_clean_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "artifact-test@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Artifact Test"],
                cwd=root,
                check=True,
            )
            tracked = root / "Package.swift"
            tracked.write_text("// fixture\n", encoding="utf-8")
            subprocess.run(["git", "add", "Package.swift"], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-q", "-m", "fixture"], cwd=root, check=True
            )
            commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=root, text=True
            ).strip()

            self.assertEqual(
                swift_build_artifact.checkout_identity(
                    root, commit, require_clean=True
                ),
                commit,
            )
            with self.assertRaisesRegex(ValueError, "does not match"):
                swift_build_artifact.checkout_identity(
                    root, "0" * 40, require_clean=False
                )
            tracked.write_text("// changed\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "clean checkout"):
                swift_build_artifact.checkout_identity(
                    root, commit, require_clean=True
                )


def write_localizations(root: pathlib.Path, *, chinese_value: str = "宠物库") -> None:
    resources = root / "apps/macos/Sources/AgentPetCompanion/Resources"
    key_files = {
        "Common": "apps/macos/Sources/AgentPetCompanion/App/LocalizationKeys/CommonLocalizationKeys.swift",
        "PetLibrary": "apps/macos/Sources/AgentPetCompanion/Features/PetLibrary/PetLibraryLocalizationKeys.swift",
        "Maker": "apps/macos/Sources/AgentPetCompanion/Features/Maker/MakerLocalizationKeys.swift",
        "Connections": "apps/macos/Sources/AgentPetCompanion/Features/Connections/ConnectionsLocalizationKeys.swift",
        "Overlay": "apps/macos/Sources/AgentPetCompanion/Overlay/OverlayLocalizationKeys.swift",
        "Settings": "apps/macos/Sources/AgentPetCompanion/Features/Settings/SettingsLocalizationKeys.swift",
        "Diagnostics": "apps/macos/Sources/AgentPetCompanion/Features/Diagnostics/DiagnosticsLocalizationKeys.swift",
    }
    table_cases = {
        "Common": "common",
        "PetLibrary": "petLibrary",
        "Maker": "maker",
        "Connections": "connections",
        "Overlay": "overlay",
        "Settings": "settings",
        "Diagnostics": "diagnostics",
    }
    for table, key_relative in key_files.items():
        directory = resources / "Localization" / table
        (directory / "en.lproj").mkdir(parents=True)
        (directory / "zh-Hans.lproj").mkdir(parents=True)
        strings = {}
        if table == "Common":
            strings["nav.library"] = {
                "localizations": {
                    "en": {"stringUnit": {"state": "translated", "value": "Pet Library"}},
                    "zh-Hans": {"stringUnit": {"state": "translated", "value": "宠物库"}},
                }
            }
            english = '"nav.library" = "Pet Library";\n'
            chinese = f'"nav.library" = "{chinese_value}";\n'
            typed = (
                'extension APCLocalizationKey {\n'
                '    static let navigationLibrary = APCLocalizationKey('
                f'"nav.library", table: .{table_cases[table]})\n'
                '}\n'
            )
        else:
            english = chinese = "/* empty feature table */\n"
            typed = "extension APCLocalizationKey {}\n"
        (directory / f"en.lproj/{table}.strings").write_text(english, encoding="utf-8")
        (directory / f"zh-Hans.lproj/{table}.strings").write_text(chinese, encoding="utf-8")
        (directory / f"{table}.xcstrings").write_text(
            json.dumps(
                {"sourceLanguage": "en", "strings": strings, "version": "1.0"},
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        key_path = root / key_relative
        key_path.parent.mkdir(parents=True, exist_ok=True)
        key_path.write_text(typed, encoding="utf-8")


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

    def test_changelog_fragment_only_is_documentation_scope(self) -> None:
        scope = validation_scope.classify(["changes/unreleased/task-42.json"])
        self.assertTrue(scope.docs_only)
        self.assertEqual(scope.rust_mode, "none")
        self.assertFalse(scope.bundle)

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
                "apps/macos/Sources/AgentPetCompanion/Resources/Localization/Common/Common.xcstrings",
                "apps/macos/Sources/AgentPetCompanion/Resources/Localization/Common/en.lproj/Common.strings",
                "apps/macos/Sources/AgentPetCompanion/App/LocalizationKeys/CommonLocalizationKeys.swift",
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


class LocalTestPlanTests(unittest.TestCase):
    def test_documentation_only_plan_runs_no_toolchain(self) -> None:
        selected = local_tests.plan(ROOT, ["docs/architecture/overview.md"])
        self.assertEqual(selected.reason, "documentation-only")
        self.assertEqual(selected.commands, ())

    def test_single_swift_feature_uses_its_domain_focused_test(self) -> None:
        selected = local_tests.plan(
            ROOT,
            ["apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"],
        )
        self.assertFalse(selected.fallback)
        self.assertEqual(selected.domains, ("overlay-sessions",))
        self.assertIn(
            ("./script/validate_swift_tests.sh", "--scope", "overlay"),
            selected.commands,
        )

    def test_shared_contract_conservatively_expands(self) -> None:
        selected = local_tests.plan(
            ROOT,
            ["apps/macos/Sources/AgentPetCompanion/App/AppStore.swift"],
        )
        self.assertTrue(selected.fallback)
        self.assertIn(
            ("./script/validate_swift_tests.sh", "--scope", "all"),
            selected.commands,
        )

    def test_unknown_rust_surface_runs_every_inventory_shard(self) -> None:
        selected = local_tests.plan(ROOT, ["crates/petcore/src/unknown_future.rs"])
        self.assertTrue(selected.fallback)
        shard_commands = [
            command
            for command in selected.commands
            if command[:2] == ("./script/validate_rust_test_shards.py", "--shard")
        ]
        self.assertEqual(len(shard_commands), 5)


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


class RustTestShardTests(unittest.TestCase):
    def test_current_integration_inventory_is_assigned_exactly_once(self) -> None:
        rust_test_shards.validate_inventory(ROOT)
        assigned = [
            (target.package, target.binary, leaf)
            for shard in rust_test_shards.SHARDS.values()
            for target in shard
            for leaf in target.leaf_modules
        ]
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertEqual(set(assigned), rust_test_shards.discovered_tests(ROOT))

    def test_every_shard_has_a_bounded_explicit_plan(self) -> None:
        for shard in rust_test_shards.ALL_SHARDS:
            with self.subTest(shard=shard):
                commands = rust_test_shards.commands(ROOT, shard)
                self.assertTrue(commands)
                self.assertTrue(all(command[:2] == ["cargo", "test"] for command in commands))
                self.assertTrue(all("--locked" in command for command in commands))

    def test_completion_proof_requires_every_exact_shard(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            proof_dir = pathlib.Path(temp_dir)
            for shard in rust_test_shards.ALL_SHARDS:
                rust_test_shards.write_completion(proof_dir, shard)

            rust_test_shards.validate_completions(proof_dir)

    def test_completion_proof_rejects_a_missing_shard(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            proof_dir = pathlib.Path(temp_dir)
            for shard in rust_test_shards.ALL_SHARDS[:-1]:
                rust_test_shards.write_completion(proof_dir, shard)

            with self.assertRaisesRegex(ValueError, "completion set mismatch"):
                rust_test_shards.validate_completions(proof_dir)

    def test_completion_proof_rejects_extra_or_malformed_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            proof_dir = pathlib.Path(temp_dir)
            for shard in rust_test_shards.ALL_SHARDS:
                rust_test_shards.write_completion(proof_dir, shard)
            (proof_dir / "unexpected.json").write_text("{}", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "completion set mismatch"):
                rust_test_shards.validate_completions(proof_dir)

            (proof_dir / "unexpected.json").unlink()
            marker = proof_dir / f"{rust_test_shards.ALL_SHARDS[0]}.json"
            marker.write_text('{"schema_version":"wrong"}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "invalid Rust shard completion"):
                rust_test_shards.validate_completions(proof_dir)


class MainBranchRulesetTests(unittest.TestCase):
    def test_ruleset_requires_pull_requests_and_the_github_actions_check(self) -> None:
        payload = main_branch_ruleset.ruleset_payload(15368)
        self.assertEqual(payload["enforcement"], "active")
        self.assertEqual(
            payload["conditions"]["ref_name"]["include"], ["~DEFAULT_BRANCH"]
        )
        rules = {rule["type"]: rule for rule in payload["rules"]}
        self.assertIn("pull_request", rules)
        self.assertIn("deletion", rules)
        self.assertIn("non_fast_forward", rules)
        required = rules["required_status_checks"]["parameters"]
        self.assertTrue(required["strict_required_status_checks_policy"])
        self.assertEqual(
            required["required_status_checks"],
            [{"context": "Required CI", "integration_id": 15368}],
        )
        pull_requests = rules["pull_request"]["parameters"]
        self.assertEqual(pull_requests["allowed_merge_methods"], ["squash"])

    def test_train_ruleset_is_non_strict_and_allows_post_merge_deletion(self) -> None:
        payload = main_branch_ruleset.ruleset_payload(15368, train=True)
        self.assertEqual(
            payload["conditions"]["ref_name"]["include"],
            ["refs/heads/gd-ops/train/*"],
        )
        rules = {rule["type"]: rule for rule in payload["rules"]}
        self.assertNotIn("deletion", rules)
        self.assertNotIn("required_linear_history", rules)
        self.assertFalse(
            rules["required_status_checks"]["parameters"]
            ["strict_required_status_checks_policy"]
        )

    def test_repository_settings_enable_auto_merge_and_squash_only(self) -> None:
        self.assertEqual(
            main_branch_ruleset.repository_settings_payload(),
            {
                "allow_auto_merge": True,
                "delete_branch_on_merge": True,
                "allow_merge_commit": False,
                "allow_rebase_merge": False,
                "allow_squash_merge": True,
                "allow_update_branch": True,
                "squash_merge_commit_title": "PR_TITLE",
                "squash_merge_commit_message": "PR_BODY",
            },
        )

    def test_only_accepts_a_successful_completed_github_actions_check(self) -> None:
        valid = {
            "id": 42,
            "name": "Required CI",
            "status": "completed",
            "conclusion": "success",
            "completed_at": "2026-08-11T10:00:00Z",
            "details_url": "https://github.com/owner/repo/actions/runs/99/job/42",
            "app": {"id": 15368, "slug": "github-actions"},
        }
        selected = main_branch_ruleset.select_required_check(
            {
                "check_runs": [
                    dict(valid, id=1, conclusion="failure"),
                    dict(valid, id=2, app={"id": 7, "slug": "foreign-app"}),
                    valid,
                ]
            },
            "owner/repo",
        )
        self.assertEqual(selected["check_run_id"], 42)
        self.assertEqual(selected["integration_id"], 15368)
        self.assertEqual(selected["workflow_run_id"], 99)
        with self.assertRaisesRegex(ValueError, "no successful"):
            main_branch_ruleset.select_required_check({"check_runs": []}, "owner/repo")

    def test_required_check_must_belong_to_the_exact_trusted_workflow_run(self) -> None:
        commit = "a" * 40
        trusted = {
            "path": ".github/workflows/ci.yml",
            "event": "push",
            "head_branch": "main",
            "head_sha": commit,
            "status": "completed",
            "conclusion": "success",
            "head_repository": {"full_name": "owner/repo"},
        }
        main_branch_ruleset.validate_workflow_run(
            trusted, "owner/repo", "main", commit
        )
        main_branch_ruleset.validate_workflow_run(
            dict(trusted, event="workflow_dispatch"), "owner/repo", "main", commit
        )
        with self.assertRaisesRegex(ValueError, "does not belong"):
            main_branch_ruleset.validate_workflow_run(
                dict(trusted, event="pull_request"), "owner/repo", "main", commit
            )

    def test_existing_ruleset_selection_rejects_ambiguous_ownership(self) -> None:
        self.assertEqual(
            main_branch_ruleset.existing_ruleset_id(
                [{"id": 9, "name": main_branch_ruleset.RULESET_NAME, "target": "branch"}]
            ),
            9,
        )
        with self.assertRaisesRegex(ValueError, "multiple"):
            main_branch_ruleset.existing_ruleset_id(
                [
                    {"id": 9, "name": main_branch_ruleset.RULESET_NAME, "target": "branch"},
                    {"id": 10, "name": main_branch_ruleset.RULESET_NAME, "target": "branch"},
                ]
            )


class DevelopmentFlowTests(unittest.TestCase):
    def test_current_domain_manifest_is_strict_sorted_and_disjoint(self) -> None:
        manifest = development_domains.load_manifest(ROOT)
        self.assertEqual(
            [domain.id for domain in manifest.domains],
            sorted(domain.id for domain in manifest.domains),
        )
        self.assertEqual(manifest.domain("overlay-sessions").claim("session-bubble").id, "session-bubble")

    def test_domain_manifest_rejects_unknown_fields_and_unsafe_paths(self) -> None:
        payload = json.loads((ROOT / "development/domains.json").read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = root / "domains.json"
            invalid = json.loads(json.dumps(payload))
            invalid["domains"][0]["unknown"] = True
            manifest_path.write_text(json.dumps(invalid), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "field inventory"):
                development_domains.load_manifest(root, manifest_path)

            invalid = json.loads(json.dumps(payload))
            invalid["domains"][0]["owned_paths"][0] = "../outside/**"
            manifest_path.write_text(json.dumps(invalid), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsafe or unbounded"):
                development_domains.load_manifest(root, manifest_path)

    def test_overlapping_exclusive_claim_is_rejected(self) -> None:
        manifest = development_domains.load_manifest(ROOT)
        domain = manifest.domain("overlay-sessions")
        first = {
            "base": "main",
            "base_commit": "a" * 40,
            "domain": domain.id,
            "claim": "overlay-runtime",
            "claimed_paths": list(domain.claim("overlay-runtime").paths),
            "approved_shared_paths": [],
            "created_at": "2026-08-12T00:00:00Z",
            "worktree": "/tmp/first",
            "release_preparation": False,
            "control_plane_owner": False,
        }
        second = dict(
            first,
            claim="session-bubble",
            claimed_paths=list(domain.claim("session-bubble").paths),
            worktree="/tmp/second",
        )
        state = development_flow.empty_state()
        state["branches"]["gd-ops/task/1-overlay"] = first
        with self.assertRaisesRegex(ValueError, "overlaps active branch"):
            development_flow.ensure_claim_available(
                manifest,
                state,
                "gd-ops/task/2-bubble",
                second,
            )

    def test_red_shared_path_requires_control_plane_owner(self) -> None:
        manifest = development_domains.load_manifest(ROOT)
        with self.assertRaisesRegex(ValueError, "Red path"):
            development_flow.selected_claim_context(
                manifest,
                domain_id="storage-migrations",
                claim_id="settings-queries",
                approved_shared_paths=["crates/petcore/src/storage/migrations.rs"],
                control_plane_owner=False,
                release_preparation=False,
                base="main",
                base_commit="a" * 40,
                worktree=pathlib.Path("/tmp/control-plane"),
            )

    def test_agent_chooses_direct_or_shared_train_lane(self) -> None:
        direct = development_flow.choose_lane(
            "auto",
            hotfix=True,
            small=False,
            agents=3,
            cross_component=True,
            active_train="gd-ops/train/release-1",
        )
        self.assertEqual((direct.lane, direct.base_branch), ("direct", "main"))

        train = development_flow.choose_lane(
            "auto",
            hotfix=False,
            small=False,
            agents=3,
            cross_component=True,
            active_train="gd-ops/train/release-1",
        )
        self.assertEqual(
            (train.lane, train.base_branch),
            ("train", "gd-ops/train/release-1"),
        )

        missing = development_flow.choose_lane(
            "auto",
            hotfix=False,
            small=False,
            agents=2,
            cross_component=False,
            active_train=None,
        )
        self.assertEqual((missing.lane, missing.base_branch), ("train", None))

    def test_ci_context_makes_every_ready_main_pr_a_full_candidate(self) -> None:
        direct = development_flow.ci_context(
            "pull_request", "main", "gd-ops/fix/42-bubble", False
        )
        self.assertEqual(
            (direct.lane, direct.full_candidate, direct.release_source),
            ("direct-to-main", True, False),
        )
        train = development_flow.ci_context(
            "pull_request", "main", "gd-ops/train/release-1", False
        )
        self.assertEqual(
            (train.lane, train.full_candidate), ("train-to-main", True)
        )
        draft = development_flow.ci_context(
            "pull_request", "main", "gd-ops/task/42-feature", True
        )
        self.assertFalse(draft.full_candidate)
        release = development_flow.ci_context(
            "pull_request", "main", "gd-ops/release/500-0.5.0", False
        )
        self.assertEqual(
            (release.lane, release.full_candidate, release.release_preparation),
            ("release-preparation-to-main", True, True),
        )

    def test_task_pr_is_scoped_and_main_push_is_release_source(self) -> None:
        task = development_flow.ci_context(
            "pull_request",
            "gd-ops/train/release-1",
            "gd-ops/task/42-feature",
            False,
        )
        self.assertEqual(
            (task.lane, task.full_candidate, task.release_source),
            ("task-to-train", False, False),
        )
        push = development_flow.ci_context("push", "main", "", False)
        self.assertEqual(
            (push.lane, push.full_candidate, push.release_source),
            ("main-push", True, True),
        )


class ChangelogFragmentTests(unittest.TestCase):
    def test_policy_boolean_values_accept_cli_and_workflow_forms(self) -> None:
        self.assertEqual(
            changelog_fragments.POLICY_BOOLEAN_VALUES,
            {"true": True, "false": False, "1": True, "0": False},
        )

    def test_fragment_roundtrip_renders_and_consumes_bilingual_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fragments = root / "changes/unreleased"
            fragments.mkdir(parents=True)
            (root / "CHANGELOG.md").write_text(
                "# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n",
                encoding="utf-8",
            )
            path = fragments / "task-42.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": changelog_fragments.SCHEMA_VERSION,
                        "kind": "Changed",
                        "scope": "workflow",
                        "summary_en": "Use train PRs for parallel work.",
                        "summary_zh": "并行工作使用 train PR。",
                    },
                    ensure_ascii=False,
                )
                + "\n",
                encoding="utf-8",
            )
            items = changelog_fragments.fragments(root)
            rendered = changelog_fragments.render(items)
            self.assertIn("### Changed / 变更", rendered)
            self.assertIn("Use train PRs", rendered)
            self.assertIn("apc-fragment:task-42", rendered)
            updated = changelog_fragments.insert_fragments(
                "# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n",
                items,
            )
            self.assertIn("并行工作使用 train PR。", updated)
            self.assertLess(
                updated.index("Use train PRs"), updated.index("## [1.0.0]")
            )

    def test_release_freeze_keeps_a_new_empty_unreleased_section(self) -> None:
        changelog = (
            "# Changelog\n\n## [Unreleased]\n\n### Added / 新增\n\n"
            "<!-- apc-fragment:feature-1 -->\n- Feature.\n\n  功能。\n\n"
            "## [1.0.0] - 2026-01-01\n"
        )
        frozen = changelog_fragments.freeze_release(changelog, "1.1.0", "2026-08-12")
        self.assertIn("## [Unreleased]\n\n## [1.1.0] - 2026-08-12", frozen)
        self.assertEqual(frozen.count("apc-fragment:feature-1"), 1)

    def test_consumed_fragment_id_cannot_be_reused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fragments = root / "changes/unreleased"
            fragments.mkdir(parents=True)
            (root / "CHANGELOG.md").write_text(
                "# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n"
                "<!-- apc-fragment:task-42 -->\n- Existing.\n",
                encoding="utf-8",
            )
            (fragments / "task-42.json").write_text(
                json.dumps(
                    {
                        "schema_version": changelog_fragments.SCHEMA_VERSION,
                        "kind": "Fixed",
                        "scope": "workflow",
                        "summary_en": "Duplicate.",
                        "summary_zh": "重复。",
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "already consumed"):
                changelog_fragments.fragments(root)

class ReleaseSourceProofResolutionTests(unittest.TestCase):
    def test_selects_only_successful_main_validation_from_same_repository(self) -> None:
        commit = "a" * 40
        trusted = {
            "id": 42,
            "run_attempt": 2,
            "head_sha": commit,
            "event": "push",
            "head_branch": "main",
            "conclusion": "success",
            "path": ".github/workflows/ci.yml",
            "head_repository": {"full_name": "owner/repo"},
        }
        dispatched = dict(trusted, id=43, run_attempt=1, event="workflow_dispatch")
        rejected = dict(trusted, id=99, event="pull_request")
        selected = resolve_source_proof.select_run(
            {"workflow_runs": [rejected, trusted, dispatched]}, "owner/repo", commit
        )
        self.assertEqual(
            selected,
            {"run_id": 43, "run_attempt": 1, "workflow_event": "workflow_dispatch"},
        )

    def test_rejects_missing_or_duplicate_source_proof_artifact(self) -> None:
        valid = {
            "id": 7,
            "name": "release-source-proof-abc",
            "expired": False,
            "size_in_bytes": 4096,
            "workflow_run": {"id": 42},
        }
        selected = resolve_source_proof.select_artifact(
            {"artifacts": [valid]}, 42, "release-source-proof-abc"
        )
        self.assertEqual(selected["artifact_id"], 7)
        with self.assertRaisesRegex(ValueError, "exactly one"):
            resolve_source_proof.select_artifact(
                {"artifacts": [valid, dict(valid, id=8)]},
                42,
                "release-source-proof-abc",
            )


class ReleaseSourceProofTests(unittest.TestCase):
    def make_fixture(self, root: pathlib.Path) -> tuple[str, pathlib.Path]:
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "tests@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Tests"], cwd=root, check=True)
        for relative in release_source_proof.TOOLCHAIN_CONTRACT_FILES:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"contract:{relative}\n", encoding="utf-8")
        script = root / "script/validate_interaction_attestation.py"
        script.write_text("#!/usr/bin/env python3\nraise SystemExit(0)\n", encoding="utf-8")
        script.chmod(0o755)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        artifact = root.parent / "artifact"
        artifact.mkdir()
        attestation = artifact / "interaction-attestation.json"
        attestation.write_text(
            json.dumps(
                {
                    "build_id": f"source.{commit}",
                    "interaction_contract_digest": "b" * 64,
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        return commit, attestation

    def test_roundtrip_is_bound_to_commit_run_and_attestation_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            root = temporary / "repo"
            root.mkdir()
            commit, attestation = self.make_fixture(root)
            output = attestation.parent / "source-proof.json"
            common = dict(
                root=root,
                repository="owner/repo",
                commit=commit,
                previous_release_tag="v1.2.3",
                run_id=42,
                run_attempt=2,
                workflow_event="workflow_dispatch",
                validation_mode="promoted",
                validation_commit="c" * 40,
                validation_run_id=41,
                validation_run_attempt=3,
                validation_ref="refs/pull/17/merge",
                validation_proof_sha256="d" * 64,
                attestation=attestation,
            )
            attestation_payload = json.loads(attestation.read_text(encoding="utf-8"))
            with mock.patch.object(
                release_source_proof,
                "validate_attestation",
                return_value=attestation_payload,
            ), mock.patch.object(
                release_source_proof,
                "observed_toolchains",
                return_value={
                    "rustc": "rustc fixture",
                    "swift": "swift fixture",
                    "python": "python fixture",
                    "sdk": "26.0",
                },
            ):
                release_source_proof.create(Namespace(**common, output=output))
                release_source_proof.validate(Namespace(**common, proof=output))
                proof_payload = json.loads(output.read_text(encoding="utf-8"))
                self.assertEqual(proof_payload["gates"], release_source_proof.EXPECTED_GATES)
                self.assertIn("bundle", proof_payload["gates"])
                self.assertEqual(proof_payload["workflow_event"], "workflow_dispatch")
                self.assertEqual(
                    proof_payload["validation"],
                    {
                        "commit": "c" * 40,
                        "mode": "promoted",
                        "run_attempt": 3,
                        "run_id": 41,
                        "source_tree": proof_payload["source_tree"],
                        "proof_sha256": "d" * 64,
                        "workflow_event": "pull_request",
                        "workflow_ref": "refs/pull/17/merge",
                    },
                )
                attestation.write_text(attestation.read_text(encoding="utf-8") + " ", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "attestation digest"):
                    release_source_proof.validate(Namespace(**common, proof=output))


if __name__ == "__main__":
    unittest.main()
