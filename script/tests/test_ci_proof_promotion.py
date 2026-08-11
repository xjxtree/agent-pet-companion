#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
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
