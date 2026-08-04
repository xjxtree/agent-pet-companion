#!/usr/bin/env python3
"""Contract tests for deterministic flat-chroma transparent-frame production."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
PIPELINE = ROOT / "scripts" / "prepare_transparent_frames.py"
TARGET_LOW = {"width": 192, "height": 208}
GREEN = (0, 255, 0, 255)
RED = (220, 40, 30, 255)


def image_values(image: Image.Image) -> list[object]:
    flattened = getattr(image, "get_flattened_data", None)
    return list(flattened() if flattened is not None else image.getdata())


class TransparentFramePipelineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="apc-transparent-frames-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_jobs(
        self,
        source: Path,
        *,
        target_size: dict[str, int] | None = None,
        foreground_mask: Path | None = None,
        extra_frame: dict[str, object] | None = None,
    ) -> tuple[Path, Path, Path, Path, Path]:
        master = self.root / "masters" / "idle-000.png"
        output = self.root / "petpack-source" / "assets" / "frames" / "idle" / "000.png"
        report = self.root / "transparency-report.json"
        previews = self.root / "transparency-previews"
        frame: dict[str, object] = {
            "id": "idle/000",
            "source": str(source),
            "master": str(master),
            "output": str(output),
        }
        if foreground_mask is not None:
            frame["foreground_mask"] = str(foreground_mask)
        if extra_frame:
            frame.update(extra_frame)
        jobs = self.root / "transparent-frame-jobs.json"
        jobs.write_text(
            json.dumps(
                {
                    "schema_version": "apc.transparent-frame-jobs.v1",
                    "target_size": target_size or TARGET_LOW,
                    "key_color": "auto",
                    "frames": [frame],
                }
            ),
            encoding="utf-8",
        )
        return jobs, report, previews, master, output

    def run_pipeline(
        self,
        jobs: Path,
        report: Path,
        previews: Path,
        *extra: str,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object] | None]:
        completed = subprocess.run(
            [
                sys.executable,
                str(PIPELINE),
                "--jobs",
                str(jobs),
                "--report",
                str(report),
                "--preview-dir",
                str(previews),
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        parsed = json.loads(report.read_text(encoding="utf-8")) if report.exists() else None
        return completed, parsed

    def test_builds_master_and_one_alpha_aware_runtime_resize(self) -> None:
        source = self.root / "source.png"
        image = Image.new("RGBA", (384, 416), GREEN)
        ImageDraw.Draw(image).ellipse((80, 70, 304, 350), fill=RED)
        image.save(source)
        jobs, report_path, previews, master, output = self.write_jobs(source)

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        self.assertTrue(report["ok"])
        self.assertEqual(len(report["implementation_sha256"]), 64)
        self.assertIn("python", report["runtime"])
        self.assertIn("pillow", report["runtime"])
        frame = report["frames"][0]
        self.assertEqual(frame["resize_count"], 1)
        self.assertEqual(frame["interior_opaque_rgb_changed_pixels"], 0)
        self.assertEqual(frame["edge_rgb_reconstruction"]["alpha_preserved"], True)
        with Image.open(master) as master_image:
            self.assertEqual(master_image.size, (384, 416))
            self.assertEqual(master_image.getpixel((192, 208)), RED)
            self.assertEqual(master_image.getpixel((0, 0)), (0, 0, 0, 0))
        with Image.open(output) as runtime_image:
            self.assertEqual(runtime_image.size, (192, 208))
            self.assertEqual(runtime_image.getpixel((0, 0)), (0, 0, 0, 0))
            alpha_values = image_values(runtime_image.getchannel("A"))
            self.assertTrue(any(0 < value < 255 for value in alpha_values))
        with Image.open(previews / "idle__000.png") as preview:
            self.assertEqual(preview.size, (192 * 5, 208))

    def test_reconstructs_antialiased_edge_without_changing_interior(self) -> None:
        large = Image.new("RGBA", (768, 832), GREEN)
        ImageDraw.Draw(large).ellipse((160, 160, 608, 704), fill=RED)
        source_image = large.resize((192, 208), Image.Resampling.LANCZOS)
        source = self.root / "antialiased-source.png"
        source_image.save(source)
        jobs, report_path, previews, master, _ = self.write_jobs(source)

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        frame = report["frames"][0]
        self.assertTrue(frame["ok"])
        self.assertGreater(
            frame["edge_rgb_reconstruction"]["reconstructed_translucent_pixels"],
            0,
        )
        self.assertEqual(frame["interior_opaque_rgb_changed_pixels"], 0)
        with Image.open(master) as transparent:
            self.assertEqual(transparent.getpixel((96, 104)), RED)
            translucent = [
                pixel for pixel in image_values(transparent) if 0 < pixel[3] < 255
            ]
            self.assertTrue(translucent)
            self.assertTrue(all(pixel[1] < 96 for pixel in translucent))

    def test_supports_an_exact_high_tier_runtime_without_resizing(self) -> None:
        source = self.root / "exact-high-source.png"
        image = Image.new("RGBA", (576, 624), GREEN)
        ImageDraw.Draw(image).rectangle((144, 120, 431, 503), fill=RED)
        image.save(source)
        jobs, report_path, previews, master, output = self.write_jobs(
            source,
            target_size={"width": 576, "height": 624},
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        self.assertTrue(report["ok"])
        self.assertEqual(report["target_tier"], "high")
        self.assertEqual(report["frames"][0]["resize_count"], 0)
        self.assertEqual(
            report["frames"][0]["size_normalization"],
            {
                "mode": "exact_copy",
                "source_size": {"width": 576, "height": 624},
                "target_size": {"width": 576, "height": 624},
                "filter": "none",
            },
        )
        with Image.open(master) as master_image, Image.open(output) as runtime_image:
            self.assertEqual(master_image.size, (576, 624))
            self.assertEqual(runtime_image.size, (576, 624))

    def test_all_three_tiers_accept_one_downscale_from_a_larger_source(self) -> None:
        cases = (
            ("low", (384, 416), {"width": 192, "height": 208}),
            ("standard", (576, 624), {"width": 384, "height": 416}),
            ("high", (768, 832), {"width": 576, "height": 624}),
        )
        for index, (tier, source_size, target_size) in enumerate(cases):
            with self.subTest(tier=tier):
                source = self.root / f"{tier}-larger-source.png"
                image = Image.new("RGBA", source_size, GREEN)
                margin_x = source_size[0] // 4
                margin_y = source_size[1] // 5
                ImageDraw.Draw(image).ellipse(
                    (
                        margin_x,
                        margin_y,
                        source_size[0] - margin_x - 1,
                        source_size[1] - margin_y - 1,
                    ),
                    fill=RED,
                )
                image.save(source)
                jobs, report_path, previews, master, output = self.write_jobs(
                    source,
                    target_size=target_size,
                )

                extra = ("--replace",) if index else ()
                completed, report = self.run_pipeline(
                    jobs,
                    report_path,
                    previews,
                    *extra,
                )

                self.assertEqual(
                    completed.returncode,
                    0,
                    completed.stderr or completed.stdout,
                )
                assert report is not None
                self.assertTrue(report["ok"])
                self.assertEqual(report["target_tier"], tier)
                frame = report["frames"][0]
                self.assertEqual(frame["resize_count"], 1)
                self.assertEqual(
                    frame["size_normalization"],
                    {
                        "mode": "single_downscale",
                        "source_size": {
                            "width": source_size[0],
                            "height": source_size[1],
                        },
                        "target_size": target_size,
                        "filter": "linear_light_premultiplied_alpha_lanczos",
                    },
                )
                with Image.open(master) as master_image:
                    self.assertEqual(master_image.size, source_size)
                with Image.open(output) as runtime_image:
                    self.assertEqual(
                        runtime_image.size,
                        (target_size["width"], target_size["height"]),
                    )

    def test_extracts_a_sheet_cell_by_source_pixel_crop(self) -> None:
        source = self.root / "two-cell-sheet.png"
        image = Image.new("RGBA", (384, 208), GREEN)
        draw = ImageDraw.Draw(image)
        draw.rectangle((40, 30, 151, 179), fill=(40, 80, 220, 255))
        draw.ellipse((232, 30, 343, 179), fill=RED)
        image.save(source)
        mask_path = self.root / "two-cell-sheet-mask.png"
        mask = Image.new("L", image.size, 0)
        ImageDraw.Draw(mask).ellipse((232, 30, 343, 179), fill=255)
        mask.save(mask_path)
        jobs, report_path, previews, master, _ = self.write_jobs(
            source,
            foreground_mask=mask_path,
            extra_frame={
                "crop": {"x": 192, "y": 0, "width": 192, "height": 208}
            },
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        frame = report["frames"][0]
        self.assertEqual(frame["source"]["decoded_size"], {"width": 384, "height": 208})
        self.assertEqual(
            frame["source"]["crop"],
            {"x": 192, "y": 0, "width": 192, "height": 208},
        )
        self.assertTrue(frame["matte"]["foreground_mask_used"])
        self.assertEqual(
            frame["foreground_mask"]["semantics"],
            "white_sure_foreground_black_unrestricted",
        )
        with Image.open(master) as transparent:
            self.assertEqual(transparent.getpixel((96, 104)), RED)

    def test_disconnected_key_colored_subject_detail_is_preserved_and_fails_safe(self) -> None:
        source = self.root / "key-conflict.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        draw = ImageDraw.Draw(image)
        draw.rectangle((40, 30, 151, 179), fill=RED)
        draw.rectangle((85, 90, 105, 110), fill=GREEN)
        image.save(source)
        jobs, report_path, previews, master, _ = self.write_jobs(source)

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertFalse(report["ok"])
        self.assertGreater(report["frames"][0]["master"]["qa"]["visible_key_pixels"], 0)
        with Image.open(master) as transparent:
            self.assertEqual(transparent.getpixel((95, 100)), GREEN)
        self.assertIn("use another key", " ".join(report["frames"][0]["errors"]))

    def test_edge_contraction_is_one_runtime_pixel_and_does_not_change_master(self) -> None:
        source = self.root / "source.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        ImageDraw.Draw(image).rectangle((40, 30, 151, 179), fill=RED)
        image.save(source)
        jobs, report_path, previews, master, output = self.write_jobs(source)
        completed, _ = self.run_pipeline(jobs, report_path, previews)
        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        with Image.open(master) as master_image, Image.open(output) as runtime_image:
            master_bbox = master_image.getchannel("A").getbbox()
            default_bbox = runtime_image.getchannel("A").getbbox()

        completed, report = self.run_pipeline(
            jobs,
            report_path,
            previews,
            "--replace",
            "--edge-contract",
            "1",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        with Image.open(master) as master_image, Image.open(output) as runtime_image:
            self.assertEqual(master_image.getchannel("A").getbbox(), master_bbox)
            contracted_bbox = runtime_image.getchannel("A").getbbox()
        assert default_bbox is not None and contracted_bbox is not None
        self.assertEqual(
            contracted_bbox,
            (
                default_bbox[0] + 1,
                default_bbox[1] + 1,
                default_bbox[2] - 1,
                default_bbox[3] - 1,
            ),
        )
        self.assertEqual(report["frames"][0]["edge_contract_final_px"], 1)

    def test_sure_foreground_mask_allows_an_enclosed_background_hole(self) -> None:
        source = self.root / "source-with-hole.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        draw = ImageDraw.Draw(image)
        draw.rectangle((40, 30, 151, 179), fill=RED)
        draw.rectangle((85, 90, 105, 110), fill=GREEN)
        image.save(source)
        mask_path = self.root / "sure-foreground-mask.png"
        mask = Image.new("L", image.size, 0)
        mask_draw = ImageDraw.Draw(mask)
        mask_draw.rectangle((40, 30, 151, 179), fill=255)
        mask_draw.rectangle((85, 90, 105, 110), fill=0)
        mask.save(mask_path)
        jobs, report_path, previews, master, _ = self.write_jobs(
            source,
            foreground_mask=mask_path,
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        self.assertTrue(report["ok"])
        self.assertTrue(report["frames"][0]["matte"]["foreground_mask_used"])
        self.assertIn(
            "frame contains enclosed transparent regions that require visual review",
            report["frames"][0]["warnings"],
        )
        with Image.open(master) as transparent:
            self.assertEqual(transparent.getpixel((95, 100)), (0, 0, 0, 0))
            self.assertEqual(transparent.getpixel((70, 70)), RED)

    def test_rejects_antialiased_foreground_masks(self) -> None:
        source = self.root / "source.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        ImageDraw.Draw(image).rectangle((40, 30, 151, 179), fill=RED)
        image.save(source)
        mask_path = self.root / "gray-mask.png"
        mask = Image.new("L", image.size, 0)
        ImageDraw.Draw(mask).rectangle((40, 30, 151, 179), fill=128)
        mask.putpixel((80, 80), 255)
        mask.save(mask_path)
        jobs, report_path, previews, _, output = self.write_jobs(
            source,
            foreground_mask=mask_path,
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertEqual(report["frames"][0]["error_code"], "invalid_input")
        self.assertIn("hard black/white", report["frames"][0]["errors"][0])
        self.assertFalse(output.exists())

    def test_rejects_a_nonuniform_source_border_instead_of_widening_thresholds(self) -> None:
        source = self.root / "nonuniform-background.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, 191, 8), fill=(255, 0, 255, 255))
        draw.rectangle((40, 30, 151, 179), fill=RED)
        image.save(source)
        jobs, report_path, previews, _, output = self.write_jobs(source)

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertEqual(report["frames"][0]["error_code"], "invalid_chroma_source")
        self.assertFalse(output.exists())

    def test_rejects_upscaling_and_model_native_alpha(self) -> None:
        small_source = self.root / "small.png"
        Image.new("RGBA", (192, 208), GREEN).save(small_source)
        jobs, report_path, previews, _, output = self.write_jobs(
            small_source,
            target_size={"width": 384, "height": 416},
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertEqual(report["frames"][0]["error_code"], "source_capacity_missing")
        self.assertFalse(output.exists())

        alpha_source = self.root / "native-alpha.png"
        alpha_image = Image.new("RGBA", (192, 208), GREEN)
        alpha_image.putpixel((0, 0), (0, 0, 0, 0))
        alpha_image.save(alpha_source)
        jobs, report_path, previews, _, output = self.write_jobs(alpha_source)
        completed, report = self.run_pipeline(jobs, report_path, previews, "--replace")
        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertEqual(report["frames"][0]["error_code"], "invalid_chroma_source")
        self.assertFalse(output.exists())

    def test_agents_cannot_override_pipeline_thresholds(self) -> None:
        source = self.root / "source.png"
        Image.new("RGBA", (192, 208), GREEN).save(source)
        jobs, report_path, previews, _, _ = self.write_jobs(
            source,
            extra_frame={"threshold": 80},
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        self.assertIsNone(report)
        error = json.loads(completed.stdout)
        self.assertEqual(error["error"]["code"], "invalid_jobs")
        self.assertIn("unsupported keys", error["error"]["message"])


class SharedSkillContractTests(unittest.TestCase):
    def test_both_skills_directly_require_the_shared_pipeline(self) -> None:
        maker = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        studio = (ROOT.parent / "agent-pet-studio" / "SKILL.md").read_text(
            encoding="utf-8"
        )
        for content in (maker, studio):
            normalized = " ".join(content.split())
            self.assertIn("transparent-frame-production.md", normalized)
            self.assertIn("prepare_transparent_frames.py", normalized)
            self.assertIn("model-native transparency", normalized)
            self.assertIn("dimensions exactly", normalized)
            self.assertIn("stable equal-size", normalized)
            self.assertIn("exact-tier runtime", normalized)

    def test_shared_reference_forbids_agent_specific_pixel_processing(self) -> None:
        contract = (ROOT / "references" / "transparent-frame-production.md").read_text(
            encoding="utf-8"
        )
        normalized = " ".join(contract.split())
        for required in (
            "Do not ask the image model for native transparency",
            "supersedes its general-purpose `remove_chroma_key.py` helper",
            "Do not tune matte thresholds",
            "linear-light premultiplied Alpha",
            "decoded source crop may be larger for any of the three tiers",
            "source_capacity_missing",
            "checkerboard, white, gray, black",
            "one final-size pixel",
            '"ok": true',
        ):
            self.assertIn(required, normalized)


if __name__ == "__main__":
    unittest.main()
