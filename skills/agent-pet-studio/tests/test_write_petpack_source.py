import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "write_petpack_source.py"
SPEC = importlib.util.spec_from_file_location("agent_pet_studio_source_helper", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
studio_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(studio_helper)


class StudioTimingTests(unittest.TestCase):
    def test_skill_explains_why_portable_high_is_not_a_studio_option(self) -> None:
        skill = (SCRIPT_PATH.parents[1] / "SKILL.md").read_text(encoding="utf-8")
        skill = " ".join(skill.split())
        self.assertIn("portable package and App", skill)
        self.assertIn("ChatGPT/Codex built-in `imagegen`", skill)
        self.assertIn("Reject `high` before image generation", skill)
        self.assertIn("image model to return the selected runtime dimensions exactly", skill)
        self.assertIn("stable equal-size", skill)
        self.assertIn("exact-tier runtime PNGs", skill)

    def test_quality_contract_has_only_low_and_standard(self) -> None:
        self.assertEqual(
            studio_helper.RENDER_SIZES,
            {"low": (192, 208), "standard": (384, 416)},
        )
        self.assertEqual(studio_helper.quality_from_form({}), "standard")
        self.assertEqual(studio_helper.quality_from_form({"quality": None}), "standard")
        self.assertEqual(studio_helper.quality_from_form({"quality": "low"}), "low")

    def test_rejects_high_quality_instead_of_silently_falling_back(self) -> None:
        with self.assertRaisesRegex(SystemExit, "unsupported quality 'high'"):
            studio_helper.quality_from_form({"quality": "high"})
        with self.assertRaisesRegex(SystemExit, "unsupported quality 'high'"):
            studio_helper.build_source({"quality": "high"})

    def test_rejects_every_other_unsupported_quality(self) -> None:
        for quality in ("ultra", "original", "HIGH", "", 384):
            with self.subTest(quality=quality), self.assertRaises(SystemExit):
                studio_helper.quality_from_form({"quality": quality})

    def test_defaults_use_the_v3_authored_timing_contract(self) -> None:
        timings, counts = studio_helper.timing_from_form({})
        self.assertEqual(timings, studio_helper.DEFAULT_STATE_TIMINGS)
        self.assertEqual(counts["idle"], 4)
        self.assertEqual(counts["waiting"], 6)
        self.assertEqual(counts["thinking"], 4)
        self.assertEqual(counts["acknowledge"], 4)
        self.assertEqual(counts["drag_left"], 6)
        self.assertEqual(counts["drag_right"], 6)
        self.assertEqual(sum(counts.values()), 42)

    def test_v3_timing_flows_to_all_artifacts(self) -> None:
        expected_counts = {
            state: len(timing["frame_durations_ms"])
            for state, timing in studio_helper.DEFAULT_STATE_TIMINGS.items()
        }

        def write_fake_png(path, *_args, **_kwargs):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"test-png")

        with tempfile.TemporaryDirectory(prefix="agent-pet-studio-timing-") as temporary:
            output = Path(temporary) / "petpack-source"
            with mock.patch.object(studio_helper, "OUTPUT_DIR", output), mock.patch.object(
                studio_helper, "write_png", side_effect=write_fake_png
            ):
                manifest = studio_helper.build_source(
                    {
                        "description": "A timing contract test pet",
                        "style": "storybook",
                        "quality": "standard",
                        "reference_images": [],
                    }
                )

            brief = json.loads((output / "brief.json").read_text(encoding="utf-8"))
            source = json.loads(
                (output / "source" / "source.json").read_text(encoding="utf-8")
            )
            validation = json.loads(
                (output / "build" / "validation.json").read_text(encoding="utf-8")
            )

            self.assertEqual(manifest["schema_version"], "apc.petpack.v3")
            self.assertEqual(manifest["quality"], "standard")
            self.assertEqual(
                manifest["render_size"], {"width": 384, "height": 416}
            )
            self.assertEqual(
                {
                    state["name"]: state["frame_durations_ms"]
                    for state in manifest["states"]
                },
                {
                    state: timing["frame_durations_ms"]
                    for state, timing in studio_helper.DEFAULT_STATE_TIMINGS.items()
                },
            )
            self.assertEqual(brief["runtime"]["state_frame_counts"], expected_counts)
            self.assertEqual(
                brief["runtime"]["states"],
                manifest["states"],
            )
            self.assertEqual(source["states"], manifest["states"])
            self.assertEqual(source["state_frame_counts"], expected_counts)
            self.assertEqual(source["form"]["quality"], "standard")
            self.assertEqual(validation["states"], manifest["states"])
            self.assertEqual(validation["state_frame_counts"], expected_counts)
            for state, expected in expected_counts.items():
                self.assertEqual(
                    len(list((output / "assets" / "frames" / state).glob("*.png"))),
                    expected,
                )

    def test_low_quality_uses_exact_runtime_render_size(self) -> None:
        def write_fake_png(path, *_args, **_kwargs):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"test-png")

        with tempfile.TemporaryDirectory(prefix="agent-pet-studio-low-") as temporary:
            output = Path(temporary) / "petpack-source"
            with mock.patch.object(studio_helper, "OUTPUT_DIR", output), mock.patch.object(
                studio_helper, "write_png", side_effect=write_fake_png
            ):
                manifest = studio_helper.build_source(
                    {
                        "description": "A low quality contract test pet",
                        "quality": "low",
                    }
                )

            self.assertEqual(manifest["quality"], "low")
            self.assertEqual(manifest["render_size"], {"width": 192, "height": 208})
            brief = json.loads((output / "brief.json").read_text(encoding="utf-8"))
            source = json.loads(
                (output / "source" / "source.json").read_text(encoding="utf-8")
            )
            self.assertEqual(brief["quality"], "low")
            self.assertEqual(brief["runtime"]["render_size"], manifest["render_size"])
            self.assertEqual(source["form"]["quality"], "low")

    def test_rejects_removed_v1_timing_fields(self) -> None:
        with self.assertRaises(SystemExit):
            studio_helper.timing_from_form({"native_fps": 10})
        with self.assertRaises(SystemExit):
            studio_helper.timing_from_form({"state_durations_ms": {}})

    def test_cli_validation_result_keeps_manifest_timing_contract(self) -> None:
        counts = {
            state: len(timing["frame_durations_ms"])
            for state, timing in studio_helper.DEFAULT_STATE_TIMINGS.items()
        }
        manifest_states = [
            {
                "name": state,
                "frames_dir": f"assets/frames/{state}",
                **studio_helper.DEFAULT_STATE_TIMINGS[state],
            }
            for state in studio_helper.STATES
        ]
        cli_result = mock.Mock(
            returncode=0,
            stdout=json.dumps(
                {
                    "ok": True,
                    "frame_count": 1,
                    "state_frame_counts": {state: 1 for state in studio_helper.STATES},
                    "warnings": [],
                }
            ),
            stderr="",
        )
        with tempfile.TemporaryDirectory(prefix="agent-pet-studio-validation-") as temporary:
            output = Path(temporary) / "petpack-source"
            output.mkdir(parents=True)
            (output / "manifest.json").write_text(
                json.dumps(
                    {
                        "schema_version": "apc.petpack.v3",
                        "states": manifest_states,
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch.object(studio_helper, "OUTPUT_DIR", output), mock.patch.dict(
                studio_helper.os.environ,
                {"APC_PETCORE_CLI": "/fake/petcore-cli"},
            ), mock.patch.object(studio_helper.subprocess, "run", return_value=cli_result):
                validation = studio_helper.validate_source()

            persisted = json.loads(
                (output / "build" / "validation.json").read_text(encoding="utf-8")
            )
            self.assertEqual(validation["frame_count"], 42)
            self.assertEqual(validation["states"], manifest_states)
            self.assertEqual(validation["state_frame_counts"], counts)
            self.assertEqual(persisted, validation)


if __name__ == "__main__":
    unittest.main()
