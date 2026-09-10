#!/usr/bin/env python3
"""Executed-call evidence, continuation, and per-object fallback regression tests."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from PIL import Image

SPEC = importlib.util.spec_from_file_location("generation_evidence", Path(__file__).resolve().parents[1] / "scripts/generation_evidence.py")
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class GenerationEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "raw.png"
        self.prompt = self.root / "prompt.txt"
        self.counter = 0

    def tearDown(self):
        self.temporary.cleanup()

    def record(self, object="tool", mode="native_alpha", outcome="rejected", provider="codex_imagegen", prompt=None, call_id=None):
        self.counter += 1
        frame = Image.new("RGBA", (192, 208), (0, 255, 0, 255) if mode == "flat_chroma" else (55, 20, 10, 0))
        frame.putpixel((96, 104), (240, 180, 100, 255))
        frame.save(self.source)
        self.prompt.write_text(prompt or f"Synthetic test prompt {self.counter}; correct the prior failure.")
        return evidence.record(argparse.Namespace(
            workspace=str(self.root), object=object, provider=provider, mode=mode,
            source=str(self.source), prompt_file=str(self.prompt), outcome=outcome,
            call_id=call_id or f"fixture-{self.counter}", reason="Synthetic test inspection records the actual Alpha result.",
        ))

    def test_fallback_requires_three_calls_and_survives_reload(self):
        for count in range(3):
            ledger = evidence.read_ledger(self.root, missing=True)
            with self.assertRaisesRegex(evidence.EvidenceError, "at least 3"):
                evidence.check_next(ledger["attempts"], "tool", "codex_imagegen", "flat_chroma")
            self.record()
        self.record(mode="flat_chroma", outcome="accepted")
        self.assertEqual(len(evidence.binding(self.root, ["tool"])), 64)

    def test_other_action_and_old_cycle_cannot_authorize_fallback(self):
        for _ in range(3):
            self.record(object="base")
        with self.assertRaisesRegex(evidence.EvidenceError, "at least 3"):
            self.record(mode="flat_chroma")
        self.record(object="base", outcome="accepted")
        with self.assertRaisesRegex(evidence.EvidenceError, "at least 3"):
            self.record(object="base", mode="flat_chroma")

    def test_changed_prompt_and_unique_call_required(self):
        self.record(prompt="Synthetic unchanged prompt.", call_id="same-call")
        with self.assertRaisesRegex(evidence.EvidenceError, "changed prompt"):
            self.record(prompt="Synthetic unchanged prompt.")
        with self.assertRaisesRegex(evidence.EvidenceError, "unique bounded call_id"):
            self.record(call_id="same-call")
        self.assertEqual(len(evidence.read_ledger(self.root)["attempts"]), 1)

    def test_native_success_stops_early_and_unfinished_latest_fails(self):
        self.record(outcome="accepted")
        evidence.binding(self.root, ["tool"])
        self.record()
        with self.assertRaisesRegex(evidence.EvidenceError, "latest.*not been accepted"):
            evidence.binding(self.root, ["tool"])

    def test_changed_retained_output_or_prompt_rejected(self):
        self.record(outcome="accepted")
        ledger = evidence.read_ledger(self.root)
        path = self.root / ledger["attempts"][0]["prompt"]
        path.write_text("Changed later")
        with self.assertRaisesRegex(evidence.EvidenceError, "changed after recording"):
            evidence.binding(self.root, ["tool"])

    def test_select_earlier_processed_source_preserves_retry_history(self):
        for _ in range(3):
            self.record()
        self.record(mode="flat_chroma")
        before = evidence.read_ledger(self.root)["attempts"]
        evidence.select(argparse.Namespace(workspace=str(self.root), call_id="fixture-1", reason="Earlier genuine Alpha artwork passes after proportional placement and visual review."))
        self.assertEqual(evidence.read_ledger(self.root)["attempts"], before)
        self.assertEqual(len(evidence.binding(self.root, ["tool"])), 64)
        with self.assertRaisesRegex(evidence.EvidenceError, "unrecorded"):
            evidence.select(argparse.Namespace(workspace=str(self.root), call_id="unknown", reason="Unknown source must never pass selection."))
        self.record()
        with self.assertRaisesRegex(evidence.EvidenceError, "latest"):
            evidence.binding(self.root, ["tool"])

    def test_selection_rejects_alpha_mismatch_and_wrong_object(self):
        self.record()
        ledger = evidence.read_ledger(self.root)
        source = self.root / ledger["attempts"][0]["source"]
        Image.new("RGB", (192, 208), "white").save(source)
        ledger["attempts"][0]["source_sha256"] = evidence.digest(source.read_bytes())
        ledger["selections"] = {"tool": {"call_id": "fixture-1", "reason": "Opaque output cannot be selected as genuine Alpha."}}
        with self.assertRaisesRegex(evidence.EvidenceError, "transparent and visible"):
            evidence.validate_ledger(self.root, ledger, ["tool"])
        ledger["selections"] = {"idle": ledger["selections"]["tool"]}
        with self.assertRaisesRegex(evidence.EvidenceError, "mismatched"):
            evidence.validate_ledger(self.root, ledger, ["idle"])

    def test_other_provider_chroma_and_source_retention(self):
        self.record(provider="other", mode="flat_chroma", outcome="accepted")
        ledger = evidence.read_ledger(self.root)
        retained = self.root / ledger["attempts"][0]["source"]
        self.assertEqual(retained.read_bytes(), self.source.read_bytes())
        self.source.unlink()
        evidence.binding(self.root, ["tool"])

    def test_reassessment_reuses_call_and_retains_original_review(self):
        self.record()
        old = evidence.read_ledger(self.root)["attempts"][0]
        result = evidence.reassess(argparse.Namespace(
            workspace=str(self.root), call_id=old["call_id"], outcome="accepted",
            reason="Proportional layout correction passed final-size image and motion review."))
        self.assertEqual(result["attempt_count"], 1)
        current = evidence.read_ledger(self.root)["attempts"][0]
        self.assertEqual(current["source_sha256"], old["source_sha256"])
        self.assertEqual(current["prompt_sha256"], old["prompt_sha256"])
        receipt = json.loads(Path(result["receipt"]).read_text())
        self.assertEqual(receipt["previous"], old)
        self.assertEqual(receipt["current"], current)
        evidence.binding(self.root, ["tool"])
        with self.assertRaisesRegex(evidence.EvidenceError, "at least 3"):
            evidence.check_next([current], "tool", "codex_imagegen", "flat_chroma")

    def test_reassessment_cannot_rewrite_historical_cycle_or_modified_source(self):
        self.record()
        self.record()
        args = argparse.Namespace(workspace=str(self.root), call_id="fixture-1",
                                  outcome="accepted", reason="A concrete review of a retained source.")
        with self.assertRaisesRegex(evidence.EvidenceError, "latest call"):
            evidence.reassess(args)
        last = evidence.read_ledger(self.root)["attempts"][-1]
        (self.root / last["source"]).write_bytes(b"changed")
        args.call_id = last["call_id"]
        with self.assertRaisesRegex(evidence.EvidenceError, "changed after recording"):
            evidence.reassess(args)

    def test_symlink_and_duplicate_json_keys_rejected(self):
        self.record(outcome="accepted")
        ledger = evidence.read_ledger(self.root)
        retained = self.root / ledger["attempts"][0]["source"]
        retained.unlink()
        retained.symlink_to(self.source)
        with self.assertRaisesRegex(evidence.EvidenceError, "symlink"):
            evidence.binding(self.root, ["tool"])
        (self.root / evidence.FILENAME).write_text('{"attempts":[],"attempts":[]}')
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate JSON key"):
            evidence.read_ledger(self.root)

    def test_declared_accepted_opaque_native_is_rejected(self):
        self.record(mode="flat_chroma", outcome="accepted", provider="other")
        ledger = evidence.read_ledger(self.root)
        ledger["attempts"][0]["mode"] = "native_alpha"
        with self.assertRaisesRegex(evidence.EvidenceError, "actual transparent"):
            evidence.validate_ledger(self.root, ledger, ["tool"])

if __name__ == "__main__":
    unittest.main()
