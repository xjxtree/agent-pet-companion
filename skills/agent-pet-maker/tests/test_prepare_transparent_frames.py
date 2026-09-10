#!/usr/bin/env python3
"""Contract tests for native Alpha and flat-chroma frame production."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
PIPELINE = ROOT / "scripts" / "prepare_transparent_frames.py"
TARGET_LOW = {"width": 192, "height": 208}
GREEN = (0, 255, 0, 255)
RED = (220, 40, 30, 255)


def load_pipeline_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("apc_transparent_frames", PIPELINE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PIPELINE_MODULE = load_pipeline_module()


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

    def test_replace_cannot_overwrite_any_batch_input_or_jobs(self) -> None:
        import os
        source_a = self.root / "source-a.png"
        source_b = self.root / "source-b.png"
        Image.new("RGBA", (192, 208), GREEN).save(source_a)
        Image.new("RGBA", (192, 208), RED).save(source_b)
        jobs, report, previews, _, _ = self.write_jobs(source_a)
        original = json.loads(jobs.read_text())
        original["frames"].append({"id": "idle/001", "source": str(source_b),
            "master": str(self.root / "masters/b.png"), "output": str(self.root / "output/b.png")})
        saved_a, saved_b = source_a.read_bytes(), source_b.read_bytes()
        alias = self.root / "hard-link.png"
        os.link(source_b, alias)
        parent_alias = self.root / "parent-alias"
        parent_alias.symlink_to(self.root, target_is_directory=True)
        for destination in (source_b, alias, parent_alias / "source-b.png", jobs):
            with self.subTest(destination=destination):
                data = json.loads(json.dumps(original))
                data["frames"][0]["master"] = str(destination)
                jobs.write_text(json.dumps(data))
                saved_jobs = jobs.read_bytes()
                result = subprocess.run([sys.executable, str(PIPELINE), "--jobs", str(jobs),
                    "--report", str(report), "--preview-dir", str(previews), "--replace"], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                if destination != jobs:
                    self.assertIn("input", result.stdout + result.stderr)
                self.assertEqual(source_a.read_bytes(), saved_a)
                self.assertEqual(source_b.read_bytes(), saved_b)
                self.assertEqual(jobs.read_bytes(), saved_jobs)
        # The report itself is also an output and cannot overwrite the jobs input.
        jobs.write_text(json.dumps(original))
        saved_jobs = jobs.read_bytes()
        result = subprocess.run([sys.executable, str(PIPELINE), "--jobs", str(jobs),
            "--report", str(jobs), "--preview-dir", str(previews), "--replace"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(jobs.read_bytes(), saved_jobs)

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
        self.assertEqual(
            frame["runtime_edge_rgb_reconstruction"]["alpha_preserved"],
            True,
        )
        self.assertTrue(frame["runtime_edge_rgb_reconstruction"]["applied"])
        self.assertEqual(frame["runtime_interior_opaque_rgb_changed_pixels"], 0)
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
        self.assertFalse(
            report["frames"][0]["runtime_edge_rgb_reconstruction"]["applied"]
        )
        self.assertEqual(
            {k: report["frames"][0]["size_normalization"][k] for k in ("mode", "source_size", "target_size", "filter")},
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
            self.assertEqual(image_values(master_image), image_values(runtime_image))

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
                    {k: frame["size_normalization"][k] for k in ("mode", "source_size", "target_size", "filter")},
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

    def test_nineteen_key_like_subject_pixels_are_preserved_as_review_evidence(self) -> None:
        source = self.root / "key-conflict.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        draw = ImageDraw.Draw(image)
        draw.rectangle((40, 30, 151, 179), fill=RED)
        for x in range(19):
            image.putpixel((86 + x, 100), GREEN)
        image.save(source)
        jobs, report_path, previews, master, _ = self.write_jobs(source)

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        self.assertTrue(report["ok"])
        self.assertEqual(
            report["configuration"]["visible_key_pixels"],
            "diagnostic_only_requires_preview_review",
        )
        self.assertEqual(report["frames"][0]["master"]["qa"]["visible_key_pixels"], 19)
        self.assertIn(
            "visible pixels close to the chroma key are diagnostic only; inspect all five preview backgrounds for actual contamination",
            report["frames"][0]["warnings"],
        )
        with Image.open(master) as transparent:
            self.assertEqual(transparent.getpixel((95, 100)), GREEN)

    def test_visible_key_on_the_silhouette_edge_remains_a_hard_failure(self) -> None:
        source = self.root / "edge-fringe.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        draw = ImageDraw.Draw(image)
        draw.rectangle((40, 30, 151, 179), fill=RED)
        image.putpixel((42, 100), GREEN)
        image.save(source)
        jobs, report_path, previews, _, _ = self.write_jobs(source)

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertFalse(report["ok"])
        self.assertGreater(
            report["frames"][0]["master"]["qa"]["edge_chroma_fringe_pixels"],
            0,
        )
        self.assertIn(
            "visible silhouette-edge pixels retain chroma contamination",
            report["frames"][0]["errors"],
        )

    def test_runtime_edge_repair_removes_low_alpha_resample_spill(self) -> None:
        image = Image.new("RGBA", (192, 208), (0, 0, 0, 0))
        ImageDraw.Draw(image).rectangle((40, 30, 151, 179), fill=RED)
        image.putpixel((40, 100), (60, 248, 3, 16))

        before, before_errors, before_warnings = (
            PIPELINE_MODULE.validate_transparent_frame(image, GREEN[:3])
        )
        repaired, repair = PIPELINE_MODULE.reconstruct_edge_rgb(
            image,
            GREEN[:3],
            image.size,
        )
        after, after_errors, _ = PIPELINE_MODULE.validate_transparent_frame(
            repaired,
            GREEN[:3],
        )

        self.assertEqual(before_errors, [])
        self.assertEqual(before["edge_chroma_fringe"]["disposition"], "review_warning")
        self.assertTrue(any("bounded review allowance" in item for item in before_warnings))
        self.assertGreater(repair["reconstructed_translucent_pixels"], 0)
        self.assertTrue(repair["alpha_preserved"])
        self.assertEqual(after_errors, [])
        self.assertEqual(after["edge_chroma_fringe"]["disposition"], "none")
        self.assertEqual(repaired.getpixel((40, 100))[3], 16)

    def test_minor_edge_allowance_rejects_a_contiguous_fringe(self) -> None:
        image = Image.new("RGBA", (192, 208), (0, 0, 0, 0))
        ImageDraw.Draw(image).rectangle((40, 30, 151, 179), fill=RED)
        for y in range(99, 102):
            image.putpixel((40, y), (0, 255, 0, 16))

        qa, errors, _ = PIPELINE_MODULE.validate_transparent_frame(
            image,
            GREEN[:3],
        )

        self.assertEqual(qa["edge_chroma_fringe_pixels"], 3)
        self.assertEqual(qa["edge_chroma_fringe"]["max_component_pixels"], 3)
        self.assertEqual(qa["edge_chroma_fringe"]["disposition"], "hard_failure")
        self.assertIn(
            "visible silhouette-edge pixels retain chroma contamination",
            errors,
        )

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

    def test_chroma_mode_rejects_native_alpha(self) -> None:
        alpha_source = self.root / "native-alpha.png"
        alpha_image = Image.new("RGBA", (192, 208), GREEN)
        alpha_image.putpixel((0, 0), (0, 0, 0, 0))
        alpha_image.save(alpha_source)
        jobs, report_path, previews, _, output = self.write_jobs(alpha_source)
        completed, report = self.run_pipeline(jobs, report_path, previews)
        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertEqual(report["frames"][0]["error_code"], "invalid_chroma_source")
        self.assertFalse(output.exists())

    def native_source(self, size=(192, 208)) -> Path:
        source = self.root / "native.png"
        image = Image.new("RGBA", size, (45, 230, 80, 0))
        draw = ImageDraw.Draw(image)
        w, h = size
        draw.rectangle((w // 4, h // 4, 3 * w // 4, 3 * h // 4), fill=(220, 40, 30, 253))
        draw.line((w // 4 - 1, h // 4, w // 4 - 1, 3 * h // 4), fill=(220, 40, 30, 60))
        image.save(source)
        return source

    def test_native_exact_copy_preserves_hidden_rgb_and_authored_alpha(self) -> None:
        source = self.native_source()
        jobs, report_path, previews, master, output = self.write_jobs(
            source, extra_frame={"source_mode": "native_alpha"})
        completed, report = self.run_pipeline(jobs, report_path, previews)
        self.assertEqual(completed.returncode, 0, completed.stdout)
        for path in (master, output):
            with Image.open(source) as original, Image.open(path) as actual:
                self.assertEqual(original.tobytes(), actual.tobytes())
        frame = report["frames"][0]
        self.assertEqual(frame["source_mode"], "native_alpha")
        self.assertEqual(frame["resize_count"], 0)
        self.assertIsNone(frame["key"])
        self.assertIsNone(frame["matte"])
        self.assertFalse(frame["edge_rgb_reconstruction"]["applied"])
        self.assertIsNone(frame["output"]["qa"]["edge_chroma_fringe"])
        self.assertGreater(frame["output"]["qa"]["transparent_rgb_residue_pixels"], 0)

    def test_native_downscale_ignores_hidden_rgb_without_edge_repair(self) -> None:
        source = self.native_source((384, 416))
        jobs, report_path, previews, master, output = self.write_jobs(
            source, extra_frame={"source_mode": "native_alpha"})
        target, parsed = PIPELINE_MODULE.parse_jobs(jobs)
        # Fail if native pixels ever enter chroma repair or Alpha fallback code.
        with patch.object(PIPELINE_MODULE, "estimate_key", side_effect=AssertionError), \
             patch.object(PIPELINE_MODULE, "build_matte", side_effect=AssertionError), \
             patch.object(PIPELINE_MODULE, "reconstruct_edge_rgb", side_effect=AssertionError), \
             patch.object(PIPELINE_MODULE, "apply_edge_fallback", side_effect=AssertionError):
            result = PIPELINE_MODULE.process_job(parsed[0], target, previews, 0, 0, False)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["resize_count"], 1)
        with Image.open(master) as actual, Image.open(source) as original:
            self.assertEqual(actual.tobytes(), original.tobytes())
        with Image.open(output) as actual:
            self.assertEqual(actual.size, (192, 208))
            for r, g, b, alpha in image_values(actual):
                if 16 <= alpha < 255:
                    self.assertLessEqual(abs(r - 220), 1)
                    self.assertLessEqual(abs(g - 40), 1)
                    self.assertLessEqual(abs(b - 30), 1)

    def test_native_rejects_fake_empty_and_negligible_alpha(self) -> None:
        for kind in ("opaque_grid", "empty", "one_transparent_pixel"):
            with self.subTest(kind=kind):
                source = self.root / f"{kind}.png"
                image = PIPELINE_MODULE.checkerboard((192, 208))
                if kind == "empty":
                    image.putalpha(0)
                elif kind == "one_transparent_pixel":
                    image.putpixel((0, 0), (0, 0, 0, 0))
                image.save(source)
                jobs, report_path, previews, _, _ = self.write_jobs(
                    source, extra_frame={"source_mode": "native_alpha"})
                completed, report = self.run_pipeline(jobs, report_path, previews, "--replace")
                self.assertEqual(completed.returncode, 1)
                self.assertFalse(report["frames"][0]["ok"])

    def test_native_rejects_chroma_options_and_unknown_mode(self) -> None:
        source = self.native_source()
        for options in ({"source_mode": "unknown"},
                        {"source_mode": "native_alpha", "key_color": "#00ff00"},
                        {"source_mode": "native_alpha", "foreground_mask": str(source)}):
            with self.subTest(options=options):
                jobs, *_ = self.write_jobs(source, extra_frame=options)
                with self.assertRaises(PIPELINE_MODULE.PipelineError):
                    PIPELINE_MODULE.parse_jobs(jobs)
        jobs, report_path, previews, _, _ = self.write_jobs(
            source, extra_frame={"source_mode": "native_alpha"})
        for flags in (("--edge-contract", "1"), ("--edge-feather", "0.25")):
            completed, report = self.run_pipeline(jobs, report_path, previews, *flags, "--replace")
            self.assertEqual(completed.returncode, 1)
            self.assertEqual(report["frames"][0]["error_code"], "invalid_native_alpha_options")

    def test_native_top_level_mode_enlargement_and_crop_bounds(self) -> None:
        source = self.native_source((384, 416))
        jobs, report_path, previews, master, output = self.write_jobs(source)
        value = json.loads(jobs.read_text())
        value["source_mode"] = "native_alpha"
        jobs.write_text(json.dumps(value))
        completed, report = self.run_pipeline(jobs, report_path, previews)
        self.assertEqual(completed.returncode, 0, completed.stdout)
        value["target_size"] = {"width": 576, "height": 624}
        jobs.write_text(json.dumps(value))
        completed, report = self.run_pipeline(jobs, report_path, previews, "--replace")
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertTrue(report["frames"][0]["size_normalization"]["requires_detail_review"])
        with Image.open(master) as image:
            self.assertEqual(image.size, (384, 416))
        with Image.open(output) as image:
            self.assertEqual(image.size, (576, 624))
        value["target_size"] = TARGET_LOW
        value["frames"][0]["crop"] = {"x": 300, "y": 0, "width": 192, "height": 208}
        jobs.write_text(json.dumps(value))
        completed, report = self.run_pipeline(jobs, report_path, previews, "--replace")
        self.assertEqual(completed.returncode, 1)
        self.assertFalse(report["frames"][0]["ok"])

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


    def test_nonmatching_source_canvas_is_fitted_without_stretching(self) -> None:
        source = self.native_source((384, 512))
        jobs, report_path, previews, master, output = self.write_jobs(
            source, target_size={"width": 384, "height": 416},
            extra_frame={"source_mode": "native_alpha"})
        completed, report = self.run_pipeline(jobs, report_path, previews)
        self.assertEqual(completed.returncode, 0, completed.stdout)
        normal = report["frames"][0]["size_normalization"]
        self.assertEqual(normal["scaled_size"], {"width": 312, "height": 416})
        self.assertEqual(normal["offset"], {"x": 36, "y": 0})
        with Image.open(source) as original, Image.open(master) as retained, Image.open(output) as runtime:
            self.assertEqual(original.tobytes(), retained.tobytes())
            self.assertEqual(runtime.size, (384, 416))
            self.assertEqual(runtime.getpixel((0, 208))[3], 0)
            self.assertGreater(runtime.getpixel((192, 208))[3], 240)

    def test_explicit_position_and_scale_keep_complete_subject_and_alpha(self) -> None:
        source = self.native_source((192, 208))
        jobs, report_path, previews, master, output = self.write_jobs(
            source, extra_frame={"source_mode": "native_alpha", "placement": {
                "scale": 1, "x": 20, "y": 15,
                "reason": "Correct model position while preserving authored translucent pixels."}})
        completed, report = self.run_pipeline(jobs, report_path, previews)
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertEqual(report["frames"][0]["resize_count"], 0)
        with Image.open(source) as original, Image.open(output) as actual:
            self.assertEqual(actual.getpixel((68, 67)), original.getpixel((48, 52)))
            self.assertEqual(actual.getpixel((67, 67)), original.getpixel((47, 52)))
        value = json.loads(jobs.read_text())
        value["frames"][0]["placement"]["x"] = 100
        jobs.write_text(json.dumps(value))
        before = output.read_bytes()
        completed, report = self.run_pipeline(jobs, report_path, previews, "--replace")
        self.assertEqual(report["frames"][0]["error_code"], "placement_clips_subject")
        self.assertEqual(output.read_bytes(), before)

    def test_placement_rejects_invalid_and_unbounded_transforms(self) -> None:
        source = self.native_source()
        for invalid in (True, -1, 0, float("inf"), float("nan")):
            with self.subTest(scale=invalid):
                jobs, *_ = self.write_jobs(source, extra_frame={"placement": {
                    "scale": invalid, "x": 0, "y": 0,
                    "reason": "Invalid transformation must fail before allocating output."}})
                with self.assertRaises(PIPELINE_MODULE.PipelineError):
                    PIPELINE_MODULE.parse_jobs(jobs)
        with self.assertRaises(PIPELINE_MODULE.PipelineError):
            PIPELINE_MODULE.normalize_runtime(Image.new("RGBA", (192, 208)), (192, 208),
                                              {"scale": 1000, "x": 0, "y": 0, "reason": "Too large"})


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
            self.assertIn("deterministic pose guide", normalized)
            self.assertIn("deterministic size-reference image", normalized)
            self.assertIn("enumerate adjacent crops", normalized)

    def test_shared_reference_forbids_agent_specific_pixel_processing(self) -> None:
        contract = (ROOT / "references" / "transparent-frame-production.md").read_text(
            encoding="utf-8"
        )
        normalized = " ".join(contract.split())
        for required in (
            "at least 3 actual native-transparency image calls for that same object",
            "Do not tune its thresholds",
            "linear-light premultiplied-Alpha",
            "placement_clips_subject",
            "checkerboard, white, gray, black",
            "--edge-contract 1",
            "0.25",
            '"ok": true',
            "visible_key_pixels",
            "review evidence only",
            "runtime Alpha boundary",
            "review_warning",
            "0.5 equivalent opaque pixel",
            "Do not stack fallback runs",
        ):
            self.assertIn(required, normalized)


if __name__ == "__main__":
    unittest.main()
