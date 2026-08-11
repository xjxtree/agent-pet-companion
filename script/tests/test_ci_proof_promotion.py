#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from argparse import Namespace
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "script/ci_proof_promotion.py"


def load_module():
    spec = importlib.util.spec_from_file_location("apc_ci_proof_promotion", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ci_proof = load_module()


class PromotionSelectionTests(unittest.TestCase):
    def merged_pull(self, head_ref: str) -> dict[str, object]:
        return {
            "number": 17,
            "state": "closed",
            "merged_at": "2026-08-11T12:28:00Z",
            "merge_commit_sha": "c" * 40,
            "base": {"ref": "main", "repo": {"full_name": "owner/repo"}},
            "head": {
                "ref": head_ref,
                "sha": "b" * 40,
                "repo": {"full_name": "owner/repo"},
            },
        }

    def test_selects_direct_and_train_prs_merged_to_the_exact_main_commit(self) -> None:
        for head_ref in ("gd-ops/task/17-small", "gd-ops/train/august"):
            with self.subTest(head_ref=head_ref):
                selected = ci_proof.select_merged_pull(
                    [self.merged_pull(head_ref)], "owner/repo", "c" * 40
                )
                self.assertEqual(selected["number"], 17)
                self.assertEqual(selected["head_sha"], "b" * 40)
                self.assertEqual(selected["head_ref"], head_ref)

    def test_rejects_external_or_non_managed_pull_request_heads(self) -> None:
        external = self.merged_pull("gd-ops/task/17-small")
        external["head"] = dict(external["head"], repo={"full_name": "fork/repo"})
        unmanaged = self.merged_pull("feature/unmanaged")
        for payload in ([external], [unmanaged]):
            with self.subTest(payload=payload):
                with self.assertRaisesRegex(ValueError, "trusted merged pull request"):
                    ci_proof.select_merged_pull(payload, "owner/repo", "c" * 40)

    def test_requires_successful_pr_run_required_gate_and_one_live_artifact(self) -> None:
        run = {
            "id": 42,
            "run_attempt": 2,
            "status": "completed",
            "conclusion": "success",
            "event": "pull_request",
            "head_sha": "b" * 40,
            "head_branch": "gd-ops/train/august",
            "path": ".github/workflows/ci.yml",
            "head_repository": {"full_name": "owner/repo"},
            "pull_requests": [],
        }
        selected = ci_proof.select_successful_run(
            {"workflow_runs": [run]},
            "owner/repo",
            "b" * 40,
            "gd-ops/train/august",
        )
        self.assertEqual(selected, {"run_id": 42, "run_attempt": 2})
        ci_proof.require_required_gate(
            {"jobs": [{"name": "Required CI", "conclusion": "success"}]}
        )
        artifact = {
            "id": 7,
            "name": f"ci-candidate-proof-{'d' * 40}",
            "expired": False,
            "size_in_bytes": 4096,
            "workflow_run": {"id": 42},
        }
        self.assertEqual(
            ci_proof.select_candidate_artifact({"artifacts": [artifact]}, 42)["id"],
            7,
        )

    def test_rejects_failed_gate_and_expired_or_duplicate_artifacts(self) -> None:
        with self.assertRaisesRegex(ValueError, "Required CI"):
            ci_proof.require_required_gate(
                {"jobs": [{"name": "Required CI", "conclusion": "failure"}]}
            )
        artifact = {
            "id": 7,
            "name": f"ci-candidate-proof-{'d' * 40}",
            "expired": False,
            "size_in_bytes": 4096,
            "workflow_run": {"id": 42},
        }
        for artifacts in (
            [dict(artifact, expired=True)],
            [artifact, dict(artifact, id=8)],
        ):
            with self.subTest(artifacts=artifacts):
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    ci_proof.select_candidate_artifact({"artifacts": artifacts}, 42)

    def test_candidate_artifact_presence_must_match_the_current_base_lane(self) -> None:
        artifact = {
            "id": 7,
            "name": f"ci-candidate-proof-{'d' * 40}",
            "expired": False,
            "size_in_bytes": 4096,
            "workflow_run": {"id": 42},
        }
        selected = ci_proof.require_candidate_lane(
            {"artifacts": [artifact]}, 42, "main"
        )
        self.assertEqual(selected["id"], 7)
        self.assertIsNone(
            ci_proof.require_candidate_lane({"artifacts": []}, 42, "gd-ops/train/august")
        )
        with self.assertRaisesRegex(ValueError, "train run must not contain"):
            ci_proof.require_candidate_lane(
                {"artifacts": [artifact]}, 42, "gd-ops/train/august"
            )

    def test_train_merge_source_binds_run_ticket_and_tested_parents(self) -> None:
        base = "a" * 40
        head = "b" * 40
        tested = "d" * 40
        ticket = {
            "schema_version": ci_proof.MERGE_TICKET_SCHEMA_VERSION,
            "repository": "owner/repo",
            "pull_request_number": 17,
            "base_ref": "gd-ops/train/august",
            "base_commit": base,
            "head_ref": "gd-ops/task/17-small",
            "head_commit": head,
            "tested_commit": tested,
            "workflow_path": ci_proof.WORKFLOW_PATH,
            "workflow_event": "pull_request",
            "workflow_ref": "refs/pull/17/merge",
            "run_id": 42,
            "run_attempt": 2,
            "lane": "task-to-train",
            "full_candidate": False,
            "ok": True,
        }
        archive_buffer = io.BytesIO()
        with zipfile.ZipFile(archive_buffer, "w") as archive:
            archive.writestr("merge-ticket.json", json.dumps(ticket))
        run_payload = {
            "id": 42,
            "run_attempt": 2,
            "status": "completed",
            "conclusion": "success",
            "event": "pull_request",
            "head_sha": head,
            "head_branch": "gd-ops/task/17-small",
            "path": ci_proof.WORKFLOW_PATH,
            "head_repository": {"full_name": "owner/repo"},
        }
        jobs_payload = {"jobs": [{"name": "Required CI", "conclusion": "success"}]}
        artifacts_payload = {
            "artifacts": [
                {
                    "id": 9,
                    "name": "ci-merge-ticket-42-2",
                    "expired": False,
                    "size_in_bytes": len(archive_buffer.getvalue()),
                    "workflow_run": {"id": 42},
                }
            ]
        }
        tested_payload = {
            "sha": tested,
            "tree": {"sha": "e" * 40},
            "parents": [{"sha": base}, {"sha": head}],
        }

        def api_fixture(endpoint: str, **_fields: str):
            if endpoint.endswith("/pulls/17/files"):
                return []
            if endpoint.endswith("/actions/runs/42"):
                return run_payload
            if endpoint.endswith("/actions/runs/42/jobs"):
                return jobs_payload
            if endpoint.endswith("/actions/runs/42/artifacts"):
                return artifacts_payload
            if endpoint.endswith(f"/git/commits/{tested}"):
                return tested_payload
            raise AssertionError(endpoint)

        args = Namespace(
            repository="owner/repo",
            pull_request_number=17,
            base_ref="gd-ops/train/august",
            base_commit=base,
            head_ref="gd-ops/task/17-small",
            head_commit=head,
            run_id=42,
            run_attempt=2,
        )
        with mock.patch.object(ci_proof, "api_json", side_effect=api_fixture), mock.patch.object(
            ci_proof, "api_bytes", return_value=archive_buffer.getvalue()
        ):
            verified = ci_proof.verify_merge_source(args)
            self.assertEqual(verified["lane"], "task-to-train")
            tested_payload["parents"] = [{"sha": "f" * 40}, {"sha": head}]
            with self.assertRaisesRegex(ValueError, "bind current base and head"):
                ci_proof.verify_merge_source(args)

        with mock.patch.object(
            ci_proof,
            "api_json",
            return_value=[
                {
                    "filename": ".github/workflows/renamed-ci.yml",
                    "previous_filename": ".github/workflows/ci.yml",
                }
            ],
        ), self.assertRaisesRegex(ValueError, "trusted manual merge"):
            ci_proof.require_no_control_plane_change("owner/repo", 17)


class MergedHeadCleanupTests(unittest.TestCase):
    def args(self) -> Namespace:
        return Namespace(
            root=ROOT,
            repository="owner/repo",
            pull_request_number=17,
            head_ref="gd-ops/task/17-small",
            head_commit="b" * 40,
        )

    def merged_pull(self) -> dict[str, object]:
        return {
            "number": 17,
            "merged": True,
            "head": {
                "ref": "gd-ops/task/17-small",
                "sha": "b" * 40,
                "repo": {"full_name": "owner/repo"},
            },
        }

    def test_deletes_only_the_exact_verified_merged_head_with_an_atomic_lease(self) -> None:
        observed = iter(["b" * 40, None])
        with mock.patch.object(
            ci_proof, "api_json", return_value=self.merged_pull()
        ), mock.patch.object(
            ci_proof, "require_origin_repository"
        ), mock.patch.object(
            ci_proof, "remote_ref_sha", side_effect=lambda *_args: next(observed)
        ), mock.patch.object(ci_proof.subprocess, "run") as run_process:
            result = ci_proof.delete_merged_head(self.args())

        self.assertEqual(
            result,
            {
                "deleted": True,
                "head_ref": "gd-ops/task/17-small",
                "head_commit": "b" * 40,
            },
        )
        run_process.assert_has_calls(
            [
                mock.call(["gh", "auth", "setup-git"], check=True),
                mock.call(
                    [
                        "git",
                        "push",
                        "--force-with-lease=refs/heads/gd-ops/task/17-small:"
                        + "b" * 40,
                        "origin",
                        ":refs/heads/gd-ops/task/17-small",
                    ],
                    cwd=ROOT,
                    check=True,
                ),
            ]
        )

    def test_replay_accepts_an_absent_head_but_rejects_a_reused_branch(self) -> None:
        with mock.patch.object(
            ci_proof, "api_json", return_value=self.merged_pull()
        ), mock.patch.object(
            ci_proof, "require_origin_repository"
        ), mock.patch.object(
            ci_proof, "remote_ref_sha", return_value=None
        ), mock.patch.object(ci_proof.subprocess, "run") as run_process:
            result = ci_proof.delete_merged_head(self.args())
        self.assertFalse(result["deleted"])
        run_process.assert_not_called()

        with mock.patch.object(
            ci_proof, "api_json", return_value=self.merged_pull()
        ), mock.patch.object(
            ci_proof, "require_origin_repository"
        ), mock.patch.object(
            ci_proof, "remote_ref_sha", return_value="c" * 40
        ), self.assertRaisesRegex(ValueError, "advanced or was reused"):
            ci_proof.delete_merged_head(self.args())


class CandidateProofTests(unittest.TestCase):
    def git(self, root: pathlib.Path, *args: str) -> str:
        return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

    def make_history(self, root: pathlib.Path) -> dict[str, str]:
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "tests@example.com"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Tests"], cwd=root, check=True)
        for relative in ci_proof.TOOLCHAIN_CONTRACT_FILES:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"contract:{relative}\n", encoding="utf-8")
        (root / "payload.txt").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=root, check=True)
        base = self.git(root, "rev-parse", "HEAD")
        (root / "payload.txt").write_text("candidate\n", encoding="utf-8")
        subprocess.run(["git", "commit", "-qam", "candidate"], cwd=root, check=True)
        head = self.git(root, "rev-parse", "HEAD")
        tree = self.git(root, "rev-parse", "HEAD^{tree}")
        tested = self.git(root, "commit-tree", tree, "-p", base, "-p", head, "-m", "test merge")
        main = self.git(root, "commit-tree", tree, "-p", base, "-m", "squash merge")
        return {"base": base, "head": head, "tree": tree, "tested": tested, "main": main}

    def test_rejects_promotion_when_the_ci_proof_control_plane_changed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "tests@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Tests"], cwd=root, check=True)
            workflow = root / ".github/workflows/ci.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("name: trusted\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "trusted control"], cwd=root, check=True)
            base = self.git(root, "rev-parse", "HEAD")
            workflow.write_text("name: changed\n", encoding="utf-8")
            subprocess.run(["git", "commit", "-qam", "change control"], cwd=root, check=True)
            main = self.git(root, "rev-parse", "HEAD")
            with self.assertRaisesRegex(ValueError, "control plane changed"):
                ci_proof.require_unchanged_control_plane(root, base, main)

    def test_candidate_roundtrip_binds_exact_tree_parents_run_and_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            root = temporary / "repo"
            root.mkdir()
            history = self.make_history(root)
            artifact = temporary / "artifact"
            artifact.mkdir()
            attestation = artifact / "interaction-attestation.json"
            attestation.write_text(
                json.dumps(
                    {
                        "build_id": f"source.{history['tested']}",
                        "interaction_contract_digest": "e" * 64,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            proof = artifact / "candidate-proof.json"
            subprocess.run(["git", "checkout", "-q", history["tested"]], cwd=root, check=True)
            create_args = Namespace(
                root=root,
                repository="owner/repo",
                pull_request_number=17,
                base_commit=history["base"],
                head_commit=history["head"],
                tested_commit=history["tested"],
                run_id=42,
                run_attempt=2,
                attestation=attestation,
                output=proof,
            )
            attestation_payload = json.loads(attestation.read_text(encoding="utf-8"))
            toolchains = {
                "rustc": "rustc fixture",
                "swift": "swift fixture",
                "python": "python fixture",
                "sdk": "26.0",
            }
            with mock.patch.object(
                ci_proof, "validate_attestation", return_value=attestation_payload
            ), mock.patch.object(ci_proof, "observed_toolchains", return_value=toolchains):
                ci_proof.create_candidate(create_args)

            ticket_dir = temporary / "ticket"
            ticket_dir.mkdir()
            ticket_path = ticket_dir / "merge-ticket.json"
            ci_proof.create_merge_ticket(
                Namespace(
                    root=root,
                    repository="owner/repo",
                    pull_request_number=17,
                    base_ref="main",
                    base_commit=history["base"],
                    head_ref="gd-ops/task/17-small",
                    head_commit=history["head"],
                    tested_commit=history["tested"],
                    run_id=42,
                    run_attempt=2,
                    lane="direct-to-main",
                    full_candidate=True,
                    output=ticket_path,
                )
            )
            ticket = ci_proof.validate_merge_ticket(
                Namespace(
                    repository="owner/repo",
                    pull_request_number=17,
                    base_ref="main",
                    base_commit=history["base"],
                    head_ref="gd-ops/task/17-small",
                    head_commit=history["head"],
                    run_id=42,
                    run_attempt=2,
                    ticket=ticket_path,
                )
            )
            self.assertEqual(ticket["tested_commit"], history["tested"])
            draft_ticket_path = ticket_dir / "draft-merge-ticket.json"
            ci_proof.create_merge_ticket(
                Namespace(
                    root=root,
                    repository="owner/repo",
                    pull_request_number=17,
                    base_ref="main",
                    base_commit=history["base"],
                    head_ref="gd-ops/task/17-small",
                    head_commit=history["head"],
                    tested_commit=history["tested"],
                    run_id=43,
                    run_attempt=1,
                    lane="direct-to-main",
                    full_candidate=False,
                    output=draft_ticket_path,
                )
            )
            self.assertFalse(
                json.loads(draft_ticket_path.read_text(encoding="utf-8"))["full_candidate"]
            )
            with self.assertRaisesRegex(ValueError, "base_commit"):
                ci_proof.validate_merge_ticket(
                    Namespace(
                        repository="owner/repo",
                        pull_request_number=17,
                        base_ref="main",
                        base_commit="f" * 40,
                        head_ref="gd-ops/task/17-small",
                        head_commit=history["head"],
                        run_id=42,
                        run_attempt=2,
                        ticket=ticket_path,
                    )
                )

            tested_payload = {
                "sha": history["tested"],
                "tree": {"sha": history["tree"]},
                "parents": [
                    {"sha": history["base"]},
                    {"sha": history["head"]},
                ],
            }
            merge_metadata = ci_proof.validate_merge_candidate(
                Namespace(
                    repository="owner/repo",
                    pull_request_number=17,
                    base_commit=history["base"],
                    head_commit=history["head"],
                    run_id=42,
                    run_attempt=2,
                    tested_payload=tested_payload,
                    attestation=attestation,
                    proof=proof,
                )
            )
            self.assertEqual(merge_metadata["tested_commit"], history["tested"])
            with self.assertRaisesRegex(ValueError, "pull_request_number"):
                ci_proof.validate_merge_candidate(
                    Namespace(
                        repository="owner/repo",
                        pull_request_number=18,
                        base_commit=history["base"],
                        head_commit=history["head"],
                        run_id=42,
                        run_attempt=2,
                        tested_payload=tested_payload,
                        attestation=attestation,
                        proof=proof,
                    )
                )

            subprocess.run(["git", "checkout", "-q", history["main"]], cwd=root, check=True)
            tested_commit = temporary / "tested-commit.json"
            tested_commit.write_text(
                json.dumps(
                    {
                        "sha": history["tested"],
                        "tree": {"sha": history["tree"]},
                        "parents": [
                            {"sha": history["base"]},
                            {"sha": history["head"]},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            validate_args = Namespace(
                root=root,
                repository="owner/repo",
                main_commit=history["main"],
                main_parent=history["base"],
                pull_request_number=17,
                head_commit=history["head"],
                run_id=42,
                run_attempt=2,
                tested_commit_json=tested_commit,
                attestation=attestation,
                proof=proof,
            )
            with mock.patch.object(
                ci_proof, "validate_attestation", return_value=attestation_payload
            ):
                metadata = ci_proof.validate_candidate(validate_args)
            self.assertEqual(metadata["validation_commit"], history["tested"])
            self.assertEqual(metadata["validation_ref"], "refs/pull/17/merge")
            self.assertEqual(metadata["candidate_proof_sha256"], ci_proof.sha256(proof))

            wrong_commit = json.loads(tested_commit.read_text(encoding="utf-8"))
            wrong_commit["parents"][0]["sha"] = "f" * 40
            tested_commit.write_text(json.dumps(wrong_commit), encoding="utf-8")
            with mock.patch.object(
                ci_proof, "validate_attestation", return_value=attestation_payload
            ), self.assertRaisesRegex(ValueError, "tested merge parents"):
                ci_proof.validate_candidate(validate_args)

            wrong_commit["parents"][0]["sha"] = history["base"]
            wrong_commit["tree"]["sha"] = "a" * 40
            tested_commit.write_text(json.dumps(wrong_commit), encoding="utf-8")
            with mock.patch.object(
                ci_proof, "validate_attestation", return_value=attestation_payload
            ), self.assertRaisesRegex(ValueError, "tested merge tree"):
                ci_proof.validate_candidate(validate_args)


if __name__ == "__main__":
    unittest.main()
