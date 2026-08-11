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
CHANGELOG_FRAGMENTS_PATH = ROOT / "script/changelog_fragments.py"
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
changelog_fragments = load_module("apc_changelog_fragments", CHANGELOG_FRAGMENTS_PATH)


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


class RustTestShardTests(unittest.TestCase):
    def test_current_integration_inventory_is_assigned_exactly_once(self) -> None:
        rust_test_shards.validate_inventory(ROOT)
        assigned = [
            target
            for shard in rust_test_shards.SHARDS.values()
            for target in shard
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
    def test_fragment_roundtrip_renders_and_consumes_bilingual_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fragments = root / "changes/unreleased"
            fragments.mkdir(parents=True)
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
            updated = changelog_fragments.insert_fragments(
                "# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n",
                items,
            )
            self.assertIn("并行工作使用 train PR。", updated)
            self.assertLess(
                updated.index("Use train PRs"), updated.index("## [1.0.0]")
            )

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
