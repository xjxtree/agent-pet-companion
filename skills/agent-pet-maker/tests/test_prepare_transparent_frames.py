#!/usr/bin/env python3
"""Contract tests for deterministic native-Alpha and chroma frame production."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

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
        schema_version: str = "apc.transparent-frame-jobs.v1",
        source_mode: str | None = None,
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
        payload: dict[str, object] = {
            "schema_version": schema_version,
            "target_size": target_size or TARGET_LOW,
            "frames": [frame],
        }
        if source_mode is not None:
            payload["source_mode"] = source_mode
        if schema_version.endswith(".v1") or source_mode == "chroma_key":
            payload["key_color"] = "auto"
        jobs.write_text(json.dumps(payload), encoding="utf-8")
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

    def test_v2_defaults_to_native_alpha_and_preserves_authored_rgba(self) -> None:
        source = self.root / "native-alpha.png"
        image = Image.new("RGBA", (192, 208), (12, 34, 56, 0))
        ImageDraw.Draw(image).ellipse((40, 32, 151, 179), fill=(220, 40, 30, 253))
        image.putpixel((40, 104), (220, 40, 30, 96))
        image.save(source)
        jobs, report_path, previews, master, output = self.write_jobs(
            source,
            schema_version="apc.transparent-frame-jobs.v2",
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        self.assertEqual(report["schema_version"], "apc.transparent-frame-report.v2")
        self.assertEqual(
            report["input_schema_version"],
            "apc.transparent-frame-jobs.v2",
        )
        self.assertEqual(report["configuration"]["source_modes"], ["native_alpha"])
        frame = report["frames"][0]
        self.assertEqual(frame["source_mode"], "native_alpha")
        self.assertIsNone(frame["key"])
        self.assertIsNone(frame["matte"])
        self.assertTrue(frame["native_alpha"]["alpha_preserved"])
        self.assertEqual(frame["native_alpha"]["alpha_max"], 253)
        self.assertGreater(frame["native_alpha"]["transparent_rgb_cleared_pixels"], 0)
        self.assertEqual(frame["native_alpha"]["nontransparent_rgba_changed_pixels"], 0)
        self.assertFalse(frame["edge_rgb_reconstruction"]["applied"])
        self.assertFalse(frame["master"]["qa"]["chroma_key_qa_applied"])
        self.assertEqual(
            frame["master"]["qa"]["edge_chroma_fringe"]["disposition"],
            "not_applicable",
        )
        with Image.open(master) as master_image, Image.open(output) as runtime_image:
            self.assertEqual(master_image.getpixel((0, 0)), (0, 0, 0, 0))
            self.assertEqual(master_image.getpixel((96, 104)), (220, 40, 30, 253))
            self.assertEqual(image_values(master_image), image_values(runtime_image))

    def test_v2_native_alpha_performs_one_premultiplied_downscale(self) -> None:
        source = self.root / "native-alpha-large.png"
        image = Image.new("RGBA", (384, 416), (0, 0, 0, 0))
        ImageDraw.Draw(image).ellipse((80, 64, 303, 359), fill=(220, 40, 30, 253))
        image.save(source)
        jobs, report_path, previews, master, output = self.write_jobs(
            source,
            schema_version="apc.transparent-frame-jobs.v2",
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        frame = report["frames"][0]
        self.assertEqual(frame["resize_count"], 1)
        self.assertEqual(frame["size_normalization"]["mode"], "single_downscale")
        self.assertEqual(
            frame["size_normalization"]["filter"],
            "linear_light_premultiplied_alpha_lanczos",
        )
        self.assertFalse(frame["runtime_edge_rgb_reconstruction"]["applied"])
        with Image.open(master) as master_image, Image.open(output) as runtime_image:
            self.assertEqual(master_image.size, (384, 416))
            self.assertEqual(runtime_image.size, (192, 208))
            self.assertTrue(
                any(0 < value < 255 for value in image_values(runtime_image.getchannel("A")))
            )

    def test_v2_native_alpha_rejects_an_opaque_or_fake_transparency_source(self) -> None:
        source = self.root / "opaque-checkerboard.png"
        image = Image.new("RGBA", (192, 208), (220, 220, 220, 255))
        draw = ImageDraw.Draw(image)
        for y in range(0, 208, 16):
            for x in range(0, 192, 16):
                if (x // 16 + y // 16) % 2:
                    draw.rectangle((x, y, x + 15, y + 15), fill=(180, 180, 180, 255))
        draw.ellipse((40, 32, 151, 179), fill=RED)
        image.save(source)
        jobs, report_path, previews, _, output = self.write_jobs(
            source,
            schema_version="apc.transparent-frame-jobs.v2",
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        assert report is not None
        self.assertEqual(
            report["frames"][0]["error_code"],
            "invalid_native_alpha_source",
        )
        self.assertFalse(output.exists())

    def test_v2_native_alpha_requires_alpha_zero_canvas_gutters(self) -> None:
        source = self.root / "alpha-contact.png"
        image = Image.new("RGBA", (192, 208), (0, 0, 0, 0))
        ImageDraw.Draw(image).ellipse((40, 32, 151, 179), fill=RED)
        image.putpixel((0, 104), (220, 40, 30, 1))
        image.save(source)
        jobs, report_path, previews, _, _ = self.write_jobs(
            source,
            schema_version="apc.transparent-frame-jobs.v2",
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 1)
        assert report is not None
        frame = report["frames"][0]
        self.assertEqual(frame["master"]["qa"]["border_visible_pixels"], 1)
        self.assertIn("visible subject pixels touch the frame edge", frame["errors"])

    def test_v2_chroma_key_mode_remains_an_explicit_compatibility_path(self) -> None:
        source = self.root / "chroma-source.png"
        image = Image.new("RGBA", (192, 208), GREEN)
        ImageDraw.Draw(image).ellipse((40, 32, 151, 179), fill=RED)
        image.save(source)
        jobs, report_path, previews, _, _ = self.write_jobs(
            source,
            schema_version="apc.transparent-frame-jobs.v2",
            source_mode="chroma_key",
        )

        completed, report = self.run_pipeline(jobs, report_path, previews)

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        assert report is not None
        frame = report["frames"][0]
        self.assertEqual(frame["source_mode"], "chroma_key")
        self.assertIsNone(frame["native_alpha"])
        self.assertIsNotNone(frame["key"])
        self.assertIsNotNone(frame["matte"])
        self.assertTrue(frame["master"]["qa"]["chroma_key_qa_applied"])

    def test_native_alpha_rejects_chroma_only_edge_fallbacks(self) -> None:
        source = self.root / "native-alpha.png"
        image = Image.new("RGBA", (192, 208), (0, 0, 0, 0))
        ImageDraw.Draw(image).ellipse((40, 32, 151, 179), fill=RED)
        image.save(source)
        jobs, report_path, previews, _, _ = self.write_jobs(
            source,
            schema_version="apc.transparent-frame-jobs.v2",
        )

        completed, report = self.run_pipeline(
            jobs,
            report_path,
            previews,
            "--edge-contract",
            "1",
        )

        self.assertEqual(completed.returncode, 1)
        self.assertIsNone(report)
        error = json.loads(completed.stdout)
        self.assertEqual(error["error"]["code"], "invalid_fallback")

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

    def test_v1_compatibility_rejects_upscaling_and_native_alpha_input(self) -> None:
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
            self.assertIn("deterministic pose guide", normalized)
            self.assertIn("deterministic size-reference image", normalized)
            self.assertIn("native_alpha", normalized)
            self.assertIn("transparent PNG", normalized)
            self.assertIn("silently switch", normalized)

    def test_shared_reference_forbids_agent_specific_pixel_processing(self) -> None:
        contract = (ROOT / "references" / "transparent-frame-production.md").read_text(
            encoding="utf-8"
        )
        normalized = " ".join(contract.split())
        for required in (
            "ChatGPT/Codex built-in `imagegen` defaults",
            "apc.transparent-frame-jobs.v2",
            "native_alpha",
            "chroma_key",
            "preserves the complete authored Alpha plane",
            "invalid_native_alpha_source",
            "Do not tune its thresholds",
            "linear-light premultiplied-Alpha",
            "at least the runtime target",
            "source_capacity_missing",
            "checkerboard, white, gray, black",
            "--edge-contract 1",
            '"ok": true',
            "visible_key_pixels",
            "review evidence only",
            "review_warning",
            "0.5 equivalent opaque pixel",
            "Do not stack fallback runs",
        ):
            self.assertIn(required, normalized)


if __name__ == "__main__":
    unittest.main()
