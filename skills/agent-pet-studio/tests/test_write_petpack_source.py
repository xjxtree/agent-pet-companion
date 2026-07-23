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
    def test_defaults_are_native_10_with_one_or_two_second_actions(self) -> None:
        native_fps, durations, counts = studio_helper.timing_from_form({})
        self.assertEqual(native_fps, 10)
        self.assertEqual(durations, studio_helper.DEFAULT_STATE_DURATIONS_MS)
        self.assertEqual(counts["start"], 10)
        self.assertEqual(counts["done"], 10)
        self.assertEqual(counts["idle"], 20)
        self.assertEqual(sum(counts.values()), 120)

    def test_native_20_and_explicit_durations_flow_to_all_artifacts(self) -> None:
        durations = {
            state: 1000 if index % 2 == 0 else 2000
            for index, state in enumerate(studio_helper.STATES)
        }
        expected_counts = {
            state: 20 * durations[state] // 1000 for state in studio_helper.STATES
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
                        "native_fps": 20,
                        "state_durations_ms": durations,
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

            self.assertEqual(manifest["native_fps"], 20)
            self.assertEqual(
                {state["name"]: state["duration_ms"] for state in manifest["states"]},
                durations,
            )
            self.assertEqual(brief["runtime"]["state_frame_counts"], expected_counts)
            self.assertEqual(
                {state["name"]: state["duration_ms"] for state in brief["states"]},
                durations,
            )
            self.assertEqual(source["native_fps"], 20)
            self.assertEqual(source["state_durations_ms"], durations)
            self.assertEqual(source["state_frame_counts"], expected_counts)
            self.assertEqual(validation["state_frame_counts"], expected_counts)
            for state, expected in expected_counts.items():
                self.assertEqual(
                    len(list((output / "assets" / "frames" / state).glob("*.png"))),
                    expected,
                )

    def test_rejects_out_of_contract_timing(self) -> None:
        with self.assertRaises(SystemExit):
            studio_helper.timing_from_form({"native_fps": 12})
        with self.assertRaises(SystemExit):
            studio_helper.timing_from_form(
                {
                    "state_durations_ms": {
                        **studio_helper.DEFAULT_STATE_DURATIONS_MS,
                        "idle": 1500,
                    }
                }
            )

    def test_cli_validation_result_keeps_manifest_timing_contract(self) -> None:
        counts = {
            state: 10 * duration_ms // 1000
            for state, duration_ms in studio_helper.DEFAULT_STATE_DURATIONS_MS.items()
        }
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
                        "native_fps": 10,
                        "states": [
                            {
                                "name": state,
                                "duration_ms": studio_helper.DEFAULT_STATE_DURATIONS_MS[state],
                            }
                            for state in studio_helper.STATES
                        ],
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
            self.assertEqual(validation["frame_count"], 120)
            self.assertEqual(validation["native_fps"], 10)
            self.assertEqual(validation["state_durations_ms"], studio_helper.DEFAULT_STATE_DURATIONS_MS)
            self.assertEqual(validation["state_frame_counts"], counts)
            self.assertEqual(persisted, validation)


if __name__ == "__main__":
    unittest.main()
