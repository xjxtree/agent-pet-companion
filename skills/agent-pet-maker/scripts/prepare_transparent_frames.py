#!/usr/bin/env python3
"""Build exact-tier transparent pet frames from flat chroma-key source crops.

The pipeline is deliberately opinionated: agents provide crop geometry and an
optional sure-foreground mask, while matte thresholds, spatial connectivity,
edge RGB reconstruction, alpha-aware resizing, and QA stay deterministic. A
source crop may match or exceed any supported target tier; the pipeline never
requires an image model to emit the target dimensions exactly and never
upscales an undersized crop.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
import sys
import tempfile
from collections import deque
from pathlib import Path
from typing import Any, Iterable

from PIL import (
    Image,
    ImageFilter,
    UnidentifiedImageError,
    __version__ as PILLOW_VERSION,
)


JOBS_SCHEMA = "apc.transparent-frame-jobs.v1"
REPORT_SCHEMA = "apc.transparent-frame-report.v1"
PIPELINE_ID = "apc-spatial-chroma-matte-v3"
TARGET_TIERS = {
    (192, 208): "low",
    (384, 416): "standard",
    (576, 624): "high",
}
MAX_JOBS = 360
MAX_SOURCE_PIXELS = 32_000_000
MAX_BORDER_VARIATION = 28
OPAQUE_DISTANCE_THRESHOLD = 220
KEY_SIMILARITY_THRESHOLD = 0.92
KEY_DOMINANCE_THRESHOLD = 8.0
VISIBLE_ALPHA_THRESHOLD = 16
# A few isolated, barely visible chroma-like samples can be introduced by the
# one permitted downscale even after the source-resolution matte is clean.
# Keep this allowance deliberately small and alpha-weighted: it is review
# evidence, never permission for an opaque pixel or a continuous fringe.
MINOR_EDGE_FRINGE_MAX_ALPHA = 48
MINOR_EDGE_FRINGE_MAX_EQUIVALENT_OPAQUE_PIXELS = 0.5
MINOR_EDGE_FRINGE_MAX_COMPONENT_PIXELS = 2
JOB_ID = re.compile(r"^[a-z0-9][a-z0-9/_-]{0,127}$")
HEX_COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")
ALLOWED_TOP_LEVEL_KEYS = {"schema_version", "target_size", "key_color", "frames"}
ALLOWED_FRAME_KEYS = {
    "id",
    "source",
    "crop",
    "master",
    "output",
    "foreground_mask",
    "key_color",
}
ALLOWED_CROP_KEYS = {"x", "y", "width", "height"}
SRGB_TO_LINEAR = tuple(
    value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
    for value in (index / 255 for index in range(256))
)


class PipelineError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def fail(code: str, message: str) -> None:
    raise PipelineError(code, message)


def image_values(image: Image.Image) -> list[Any]:
    flattened = getattr(image, "get_flattened_data", None)
    return list(flattened() if flattened is not None else image.getdata())


def reject_unknown_keys(value: dict[str, Any], allowed: set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        fail("invalid_jobs", f"{label} contains unsupported keys: {', '.join(unknown)}")


def parse_json_strict(path: Path) -> dict[str, Any]:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                fail("invalid_jobs", f"jobs JSON contains duplicate key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=object_pairs)
    except PipelineError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail("invalid_jobs", f"could not read jobs JSON: {error}")
    if not isinstance(value, dict):
        fail("invalid_jobs", "jobs JSON root must be an object")
    return value


def absolute_path(raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw:
        fail("invalid_jobs", f"{label} must be a non-empty absolute path")
    path = Path(raw)
    if not path.is_absolute():
        fail("invalid_jobs", f"{label} must be an absolute path")
    return path


def require_regular_input(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail("invalid_input", f"{label} is unavailable: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail("invalid_input", f"{label} must be a regular non-symlink file")


def parse_target_size(value: Any) -> tuple[int, int]:
    if not isinstance(value, dict) or set(value) != {"width", "height"}:
        fail("invalid_jobs", "target_size must contain exactly width and height")
    width = value.get("width")
    height = value.get("height")
    if not isinstance(width, int) or isinstance(width, bool):
        fail("invalid_jobs", "target_size.width must be an integer")
    if not isinstance(height, int) or isinstance(height, bool):
        fail("invalid_jobs", "target_size.height must be an integer")
    if (width, height) not in TARGET_TIERS:
        fail("invalid_jobs", f"unsupported target size {width}x{height}")
    return width, height


def parse_key_color(value: Any, label: str) -> str | tuple[int, int, int]:
    if value is None or value == "auto":
        return "auto"
    if (
        isinstance(value, tuple)
        and len(value) == 3
        and all(isinstance(channel, int) and 0 <= channel <= 255 for channel in value)
    ):
        return value
    if not isinstance(value, str) or not HEX_COLOR.fullmatch(value):
        fail("invalid_jobs", f"{label} must be 'auto' or #RRGGBB")
    return tuple(int(value[index : index + 2], 16) for index in (1, 3, 5))


def parse_crop(value: Any) -> dict[str, int] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        fail("invalid_jobs", "frame crop must be an object")
    reject_unknown_keys(value, ALLOWED_CROP_KEYS, "frame crop")
    if set(value) != ALLOWED_CROP_KEYS:
        fail("invalid_jobs", "frame crop must contain exactly x, y, width, and height")
    crop: dict[str, int] = {}
    for key in ("x", "y", "width", "height"):
        item = value[key]
        if not isinstance(item, int) or isinstance(item, bool):
            fail("invalid_jobs", f"frame crop {key} must be an integer")
        crop[key] = item
    if crop["x"] < 0 or crop["y"] < 0 or crop["width"] <= 0 or crop["height"] <= 0:
        fail("invalid_jobs", "frame crop must have a non-negative origin and positive size")
    return crop


def parse_jobs(path: Path) -> tuple[tuple[int, int], list[dict[str, Any]]]:
    require_regular_input(path, "jobs file")
    root = parse_json_strict(path)
    reject_unknown_keys(root, ALLOWED_TOP_LEVEL_KEYS, "jobs JSON")
    if root.get("schema_version") != JOBS_SCHEMA:
        fail("invalid_jobs", f"jobs schema_version must be {JOBS_SCHEMA}")
    target_size = parse_target_size(root.get("target_size"))
    default_key = parse_key_color(root.get("key_color", "auto"), "key_color")
    frames = root.get("frames")
    if not isinstance(frames, list) or not 1 <= len(frames) <= MAX_JOBS:
        fail("invalid_jobs", f"frames must contain 1 to {MAX_JOBS} jobs")

    parsed: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_outputs: set[Path] = set()
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            fail("invalid_jobs", f"frames[{index}] must be an object")
        reject_unknown_keys(frame, ALLOWED_FRAME_KEYS, f"frames[{index}]")
        frame_id = frame.get("id")
        id_segments = frame_id.split("/") if isinstance(frame_id, str) else []
        if (
            not isinstance(frame_id, str)
            or not JOB_ID.fullmatch(frame_id)
            or any(segment in {"", ".", ".."} for segment in id_segments)
        ):
            fail("invalid_jobs", f"frames[{index}].id is invalid")
        if frame_id in seen_ids:
            fail("invalid_jobs", f"duplicate frame id {frame_id!r}")
        seen_ids.add(frame_id)

        source = absolute_path(frame.get("source"), f"frames[{index}].source")
        master = absolute_path(frame.get("master"), f"frames[{index}].master")
        output = absolute_path(frame.get("output"), f"frames[{index}].output")
        if source.suffix.lower() not in {".png", ".webp", ".jpg", ".jpeg"}:
            fail("invalid_jobs", f"frames[{index}].source uses an unsupported image format")
        if master.suffix.lower() != ".png" or output.suffix.lower() != ".png":
            fail("invalid_jobs", "transparent masters and runtime frames must be PNG")
        if master == output or master == source or output == source:
            fail("invalid_jobs", "source, master, and output paths must be distinct")
        for destination in (master, output):
            if destination in seen_outputs:
                fail("invalid_jobs", f"duplicate destination path {destination}")
            seen_outputs.add(destination)

        mask_value = frame.get("foreground_mask")
        mask = absolute_path(mask_value, f"frames[{index}].foreground_mask") if mask_value is not None else None
        key = parse_key_color(frame.get("key_color", default_key), f"frames[{index}].key_color")
        parsed.append(
            {
                "id": frame_id,
                "source": source,
                "crop": parse_crop(frame.get("crop")),
                "master": master,
                "output": output,
                "foreground_mask": mask,
                "key_color": key,
            }
        )
    return target_size, parsed


def channel_distance(color: tuple[int, int, int], key: tuple[int, int, int]) -> int:
    return max(abs(color[index] - key[index]) for index in range(3))


def spill_channels(key: tuple[int, int, int]) -> list[int]:
    maximum = max(key)
    if maximum < 128:
        return []
    return [index for index, value in enumerate(key) if value >= maximum - 16 and value >= 128]


def key_dominance(color: tuple[int, int, int], key: tuple[int, int, int]) -> float:
    spills = spill_channels(key)
    if not spills:
        return 0.0
    channels = [float(value) for value in color]
    non_spills = [index for index in range(3) if index not in spills]
    key_strength = min(channels[index] for index in spills)
    non_key_strength = max((channels[index] for index in non_spills), default=0.0)
    return key_strength - non_key_strength


def chroma_similarity(color: tuple[int, int, int], key: tuple[int, int, int]) -> float:
    color_mean = sum(color) / 3
    key_mean = sum(key) / 3
    color_chroma = tuple(value - color_mean for value in color)
    key_chroma = tuple(value - key_mean for value in key)
    denominator = math.sqrt(
        sum(value * value for value in color_chroma)
        * sum(value * value for value in key_chroma)
    )
    if denominator <= 1e-9:
        return -1.0
    return sum(left * right for left, right in zip(color_chroma, key_chroma)) / denominator


def color_saturation(color: tuple[int, int, int]) -> float:
    maximum = max(color)
    if maximum <= 0:
        return 0.0
    return (maximum - min(color)) / maximum


def smoothstep(value: float) -> float:
    bounded = max(0.0, min(1.0, value))
    return bounded * bounded * (3.0 - 2.0 * bounded)


def matte_alpha(
    color: tuple[int, int, int],
    key: tuple[int, int, int],
    transparent_threshold: int,
) -> tuple[int, bool]:
    distance = channel_distance(color, key)
    if distance <= transparent_threshold:
        distance_alpha = 0
    elif distance >= OPAQUE_DISTANCE_THRESHOLD:
        distance_alpha = 255
    else:
        distance_alpha = round(
            255
            * smoothstep(
                (distance - transparent_threshold)
                / (OPAQUE_DISTANCE_THRESHOLD - transparent_threshold)
            )
        )

    dominance = key_dominance(color, key)
    non_key_strength = max(
        (color[index] for index in range(3) if index not in spill_channels(key)),
        default=0,
    )
    denominator = max(1.0, float(max(key)) - non_key_strength)
    dominance_alpha = (
        255
        if dominance <= 0
        else round(255 * (1.0 - min(1.0, dominance / denominator)))
    )
    key_like = distance <= max(32, transparent_threshold) or (
        dominance >= KEY_DOMINANCE_THRESHOLD
        and color_saturation(color) >= 0.15
        and chroma_similarity(color, key) >= KEY_SIMILARITY_THRESHOLD
    )
    return (min(distance_alpha, dominance_alpha) if key_like else 255), key_like


def percentile(values: list[int], fraction: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)]


def border_indices(width: int, height: int, strip: int) -> Iterable[int]:
    for y in range(height):
        for x in range(width):
            if x < strip or x >= width - strip or y < strip or y >= height - strip:
                yield y * width + x


def estimate_key(
    pixels: list[tuple[int, int, int, int]],
    size: tuple[int, int],
    requested: str | tuple[int, int, int],
) -> tuple[tuple[int, int, int], dict[str, Any]]:
    width, height = size
    strip = max(1, min(16, round(min(width, height) * 0.02)))
    samples = [pixels[index][:3] for index in border_indices(width, height, strip)]
    if requested == "auto":
        key = tuple(sorted(color[channel] for color in samples)[len(samples) // 2] for channel in range(3))
    else:
        key = requested
    distances = [channel_distance(color, key) for color in samples]
    p95 = percentile(distances, 0.95)
    coverage = sum(distance <= MAX_BORDER_VARIATION for distance in distances) / len(distances)
    if max(key) < 180 or max(key) - min(key) < 100:
        fail("invalid_chroma_source", "sampled background is not a saturated chroma key")
    if p95 > MAX_BORDER_VARIATION or coverage < 0.95:
        fail(
            "invalid_chroma_source",
            "source border is not a sufficiently flat chroma background; regenerate instead of widening thresholds",
        )
    threshold = max(10, min(32, p95 + 4))
    return key, {
        "mode": "auto_border" if requested == "auto" else "explicit_with_border_validation",
        "rgb": list(key),
        "hex": f"#{key[0]:02X}{key[1]:02X}{key[2]:02X}",
        "border_strip_px": strip,
        "border_p95_channel_distance": p95,
        "border_flat_coverage": round(coverage, 6),
        "transparent_threshold": threshold,
        "opaque_threshold": OPAQUE_DISTANCE_THRESHOLD,
    }


def connected_key_region(key_like: list[bool], width: int, height: int) -> bytearray:
    connected = bytearray(width * height)
    pending: deque[int] = deque()
    for index in border_indices(width, height, 1):
        if key_like[index] and not connected[index]:
            connected[index] = 1
            pending.append(index)
    while pending:
        index = pending.popleft()
        x = index % width
        y = index // width
        for neighbor in (
            index - 1 if x > 0 else None,
            index + 1 if x + 1 < width else None,
            index - width if y > 0 else None,
            index + width if y + 1 < height else None,
        ):
            if neighbor is not None and key_like[neighbor] and not connected[neighbor]:
                connected[neighbor] = 1
                pending.append(neighbor)
    return connected


def load_crop(
    path: Path,
    crop: dict[str, int] | None,
) -> tuple[Image.Image, tuple[int, int, int, int], tuple[int, int]]:
    require_regular_input(path, "source image")
    try:
        with Image.open(path) as opened:
            if getattr(opened, "n_frames", 1) != 1:
                fail("invalid_input", "source image must contain exactly one still image")
            if opened.width * opened.height > MAX_SOURCE_PIXELS:
                fail("invalid_input", f"source image exceeds {MAX_SOURCE_PIXELS} decoded pixels")
            opened.load()
            rgba = opened.convert("RGBA")
    except PipelineError:
        raise
    except (OSError, ValueError, UnidentifiedImageError) as error:
        fail("invalid_input", f"could not decode source image: {error}")
    decoded_size = rgba.size
    if crop is None:
        bounds = (0, 0, rgba.width, rgba.height)
    else:
        bounds = (
            crop["x"],
            crop["y"],
            crop["x"] + crop["width"],
            crop["y"] + crop["height"],
        )
        if bounds[2] > rgba.width or bounds[3] > rgba.height:
            fail("invalid_crop", "frame crop extends outside the decoded source")
    result = rgba.crop(bounds)
    if result.width * 13 != result.height * 12:
        fail("invalid_crop", "frame crop must have the exact 12:13 pet canvas ratio")
    return result, bounds, decoded_size


def load_foreground_mask(
    path: Path | None,
    source_size: tuple[int, int],
    crop_bounds: tuple[int, int, int, int],
    crop_size: tuple[int, int],
) -> list[bool] | None:
    if path is None:
        return None
    require_regular_input(path, "foreground protection mask")
    try:
        with Image.open(path) as opened:
            if opened.width * opened.height > MAX_SOURCE_PIXELS:
                fail(
                    "invalid_input",
                    f"foreground protection mask exceeds {MAX_SOURCE_PIXELS} decoded pixels",
                )
            opened.load()
            mask = opened.convert("L")
    except (OSError, ValueError, UnidentifiedImageError) as error:
        fail("invalid_input", f"could not decode foreground protection mask: {error}")
    if mask.size == source_size:
        mask = mask.crop(crop_bounds)
    elif mask.size != crop_size:
        fail("invalid_input", "foreground protection mask must match the source or frame crop size")
    values = image_values(mask)
    if any(31 < value < 224 for value in values):
        fail(
            "invalid_input",
            "foreground protection mask must be hard black/white, without gray or antialiased edges",
        )
    sure_foreground = [value >= 224 for value in values]
    if not any(sure_foreground) or all(sure_foreground):
        fail("invalid_input", "foreground protection mask must contain both protected and unprotected pixels")
    return sure_foreground


def alpha_edge_band(alpha: Image.Image, radius: int) -> list[bool]:
    visible = [value > 0 for value in image_values(alpha)]
    transparent = Image.new("L", alpha.size)
    transparent.putdata([0 if value else 255 for value in visible])
    expanded = transparent.filter(ImageFilter.MaxFilter(radius * 2 + 1))
    return [
        is_visible and nearby > 0
        for is_visible, nearby in zip(visible, image_values(expanded))
    ]


def build_matte(
    source: Image.Image,
    key: tuple[int, int, int],
    transparent_threshold: int,
    sure_foreground: list[bool] | None,
) -> tuple[Image.Image, dict[str, Any]]:
    pixels = image_values(source)
    alphas_and_keys = [matte_alpha(pixel[:3], key, transparent_threshold) for pixel in pixels]
    proposed_alpha = [value[0] for value in alphas_and_keys]
    key_like = [value[1] for value in alphas_and_keys]
    connected = connected_key_region(key_like, source.width, source.height)
    output: list[tuple[int, int, int, int]] = []
    protected_key_pixels = 0
    for index, pixel in enumerate(pixels):
        protected = bool(sure_foreground and sure_foreground[index])
        if protected and key_like[index]:
            protected_key_pixels += 1
        process = key_like[index] and (bool(connected[index]) or (sure_foreground is not None and not protected))
        matte = proposed_alpha[index] if process else 255
        alpha = round(pixel[3] * matte / 255)
        output.append((0, 0, 0, 0) if alpha == 0 else (*pixel[:3], alpha))
    image = Image.new("RGBA", source.size)
    image.putdata(output)
    return image, {
        "connected_key_pixels": sum(connected),
        "protected_key_pixels": protected_key_pixels,
        "foreground_mask_used": sure_foreground is not None,
        "transparent_pixels": sum(pixel[3] == 0 for pixel in output),
        "translucent_pixels": sum(0 < pixel[3] < 255 for pixel in output),
    }


def linear_to_srgb(value: float) -> int:
    bounded = max(0.0, min(1.0, value))
    encoded = 12.92 * bounded if bounded <= 0.0031308 else 1.055 * bounded ** (1 / 2.4) - 0.055
    return max(0, min(255, round(encoded * 255)))


def nearest_clean_reference(
    index: int,
    pixels: list[tuple[int, int, int, int]],
    boundary: list[bool],
    key: tuple[int, int, int],
    width: int,
    height: int,
    radius: int,
) -> tuple[int, int, int] | None:
    x = index % width
    y = index // width
    candidates: list[tuple[int, tuple[int, int, int]]] = []
    for neighbor_y in range(max(0, y - radius), min(height, y + radius + 1)):
        for neighbor_x in range(max(0, x - radius), min(width, x + radius + 1)):
            neighbor = neighbor_y * width + neighbor_x
            pixel = pixels[neighbor]
            if pixel[3] == 255 and not boundary[neighbor] and chroma_similarity(pixel[:3], key) < 0.85:
                distance = abs(neighbor_x - x) + abs(neighbor_y - y)
                candidates.append((distance, pixel[:3]))
    if not candidates:
        return None
    nearest_distance = min(item[0] for item in candidates)
    nearest = [color for distance, color in candidates if distance == nearest_distance]
    return tuple(round(sum(color[channel] for color in nearest) / len(nearest)) for channel in range(3))


def reconstruct_edge_rgb(
    image: Image.Image,
    key: tuple[int, int, int],
    target_size: tuple[int, int],
) -> tuple[Image.Image, dict[str, Any]]:
    pixels = image_values(image)
    scale = max(image.width / target_size[0], image.height / target_size[1])
    edge_radius = max(2, min(12, math.ceil(3 * scale)))
    reference_radius = max(edge_radius + 1, min(16, math.ceil(5 * scale)))
    alpha = image.getchannel("A")
    boundary = alpha_edge_band(alpha, edge_radius)
    key_linear = tuple(SRGB_TO_LINEAR[value] for value in key)
    output = pixels.copy()
    reconstructed_translucent = 0
    reconstructed_opaque = 0

    for index, pixel in enumerate(pixels):
        if not boundary[index] or pixel[3] == 0:
            continue
        color = pixel[:3]
        if 0 < pixel[3] < 255 and (
            channel_distance(color, key) <= 96
            or (
                key_dominance(color, key) >= KEY_DOMINANCE_THRESHOLD
                and chroma_similarity(color, key) >= KEY_SIMILARITY_THRESHOLD
            )
        ):
            coverage = pixel[3] / 255
            observed = tuple(SRGB_TO_LINEAR[value] for value in color)
            foreground = tuple(
                (observed[channel] - (1.0 - coverage) * key_linear[channel])
                / max(coverage, 1 / 255)
                for channel in range(3)
            )
            output[index] = (*tuple(linear_to_srgb(value) for value in foreground), pixel[3])
            reconstructed_translucent += output[index] != pixel
            continue

        if pixel[3] != 255:
            continue
        reference = nearest_clean_reference(
            index,
            pixels,
            boundary,
            key,
            image.width,
            image.height,
            reference_radius,
        )
        if reference is None:
            continue
        observed_linear = tuple(SRGB_TO_LINEAR[value] for value in color)
        reference_linear = tuple(SRGB_TO_LINEAR[value] for value in reference)
        direction = tuple(key_linear[channel] - reference_linear[channel] for channel in range(3))
        denominator = sum(value * value for value in direction)
        if denominator <= 1e-9:
            continue
        spill = sum(
            (observed_linear[channel] - reference_linear[channel]) * direction[channel]
            for channel in range(3)
        ) / denominator
        if not 0.04 <= spill <= 0.45:
            continue
        predicted = tuple(
            reference_linear[channel] + spill * direction[channel] for channel in range(3)
        )
        residual = math.sqrt(
            sum((observed_linear[channel] - predicted[channel]) ** 2 for channel in range(3)) / 3
        )
        if residual > 0.035:
            continue
        output[index] = (*reference, 255)
        reconstructed_opaque += output[index] != pixel

    output = [(0, 0, 0, 0) if pixel[3] == 0 else pixel for pixel in output]
    result = Image.new("RGBA", image.size)
    result.putdata(output)
    return result, {
        "edge_radius_source_px": edge_radius,
        "alpha_preserved": image_values(result.getchannel("A")) == image_values(alpha),
        "reconstructed_translucent_pixels": reconstructed_translucent,
        "reconstructed_opaque_pixels": reconstructed_opaque,
    }


def resize_linear_premultiplied(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    if image.size == size:
        return image.copy()
    if image.width < size[0] or image.height < size[1]:
        fail("upscale_forbidden", "runtime frame cannot be larger than its transparent master")
    if image.width * size[1] != image.height * size[0]:
        fail("resize_forbidden", "transparent master and runtime target must share one aspect ratio")

    pixels = image_values(image)
    alpha_values = [pixel[3] / 255 for pixel in pixels]
    alpha_plane = Image.new("F", image.size)
    alpha_plane.putdata(alpha_values)
    premultiplied_planes: list[Image.Image] = []
    for channel in range(3):
        plane = Image.new("F", image.size)
        plane.putdata(
            [SRGB_TO_LINEAR[pixel[channel]] * alpha for pixel, alpha in zip(pixels, alpha_values)]
        )
        premultiplied_planes.append(plane.resize(size, Image.Resampling.LANCZOS))
    resized_alpha = alpha_plane.resize(size, Image.Resampling.LANCZOS)
    alpha_data = image_values(resized_alpha)
    channel_data = [image_values(plane) for plane in premultiplied_planes]
    output: list[tuple[int, int, int, int]] = []
    for index, raw_alpha in enumerate(alpha_data):
        alpha = max(0.0, min(1.0, raw_alpha))
        alpha_byte = max(0, min(255, round(alpha * 255)))
        if alpha_byte == 0 or alpha <= 1e-6:
            output.append((0, 0, 0, 0))
            continue
        rgb = tuple(
            linear_to_srgb(max(0.0, min(1.0, channel_data[channel][index] / alpha)))
            for channel in range(3)
        )
        output.append((*rgb, alpha_byte))
    resized = Image.new("RGBA", size)
    resized.putdata(output)
    return resized


def apply_edge_fallback(image: Image.Image, contract: int, feather: float) -> Image.Image:
    if contract == 0 and feather == 0:
        return image
    alpha = image.getchannel("A")
    if contract == 1:
        alpha = alpha.filter(ImageFilter.MinFilter(3))
    if feather:
        blurred = alpha.filter(ImageFilter.GaussianBlur(feather))
        alpha = Image.frombytes(
            "L",
            alpha.size,
            bytes(
                min(original, softened)
                for original, softened in zip(image_values(alpha), image_values(blurred))
            ),
        )
    output = image.copy()
    output.putalpha(alpha)
    pixels = [
        (0, 0, 0, 0) if pixel[3] == 0 else pixel for pixel in image_values(output)
    ]
    output.putdata(pixels)
    return output


def enclosed_transparent_components(image: Image.Image) -> list[int]:
    alpha = image_values(image.getchannel("A"))
    visible = [index for index, value in enumerate(alpha) if value >= VISIBLE_ALPHA_THRESHOLD]
    if not visible:
        return []
    width, height = image.size
    xs = [index % width for index in visible]
    ys = [index // width for index in visible]
    left, right = min(xs), max(xs)
    top, bottom = min(ys), max(ys)
    visited: set[int] = set()
    outside: deque[int] = deque()
    for y in range(top, bottom + 1):
        for x in range(left, right + 1):
            if x not in {left, right} and y not in {top, bottom}:
                continue
            index = y * width + x
            if alpha[index] < VISIBLE_ALPHA_THRESHOLD and index not in visited:
                visited.add(index)
                outside.append(index)
    while outside:
        index = outside.popleft()
        x = index % width
        y = index // width
        for neighbor in (
            index - 1 if x > left else None,
            index + 1 if x < right else None,
            index - width if y > top else None,
            index + width if y < bottom else None,
        ):
            if (
                neighbor is not None
                and alpha[neighbor] < VISIBLE_ALPHA_THRESHOLD
                and neighbor not in visited
            ):
                visited.add(neighbor)
                outside.append(neighbor)
    components: list[int] = []
    remaining = {
        y * width + x
        for y in range(top + 1, bottom)
        for x in range(left + 1, right)
        if alpha[y * width + x] < VISIBLE_ALPHA_THRESHOLD and y * width + x not in visited
    }
    while remaining:
        seed = remaining.pop()
        pending = [seed]
        area = 0
        while pending:
            index = pending.pop()
            area += 1
            x = index % width
            y = index // width
            for neighbor in (index - 1, index + 1, index - width, index + width):
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    pending.append(neighbor)
        components.append(area)
    return sorted(components, reverse=True)


def largest_connected_component(indices: set[int], width: int) -> int:
    largest = 0
    remaining = set(indices)
    while remaining:
        seed = remaining.pop()
        pending = [seed]
        area = 0
        while pending:
            index = pending.pop()
            area += 1
            x = index % width
            for neighbor in (
                index - 1 if x > 0 else None,
                index + 1 if x + 1 < width else None,
                index - width if index >= width else None,
                index + width,
            ):
                if neighbor is not None and neighbor in remaining:
                    remaining.remove(neighbor)
                    pending.append(neighbor)
        largest = max(largest, area)
    return largest


def edge_fringe_report(
    indices: list[int],
    pixels: list[tuple[int, int, int, int]],
    size: tuple[int, int],
) -> dict[str, Any]:
    alpha_sum = sum(pixels[index][3] for index in indices)
    max_alpha = max((pixels[index][3] for index in indices), default=0)
    max_component = largest_connected_component(set(indices), size[0]) if indices else 0
    raw_pixel_limit = max(2, round(min(size) / 48))
    equivalent_opaque_pixels = alpha_sum / 255
    review_only = bool(indices) and (
        len(indices) <= raw_pixel_limit
        and max_alpha <= MINOR_EDGE_FRINGE_MAX_ALPHA
        and equivalent_opaque_pixels <= MINOR_EDGE_FRINGE_MAX_EQUIVALENT_OPAQUE_PIXELS
        and max_component <= MINOR_EDGE_FRINGE_MAX_COMPONENT_PIXELS
    )
    return {
        "pixels": len(indices),
        "alpha_sum": alpha_sum,
        "equivalent_opaque_pixels": round(equivalent_opaque_pixels, 6),
        "max_alpha": max_alpha,
        "max_component_pixels": max_component,
        "raw_pixel_limit": raw_pixel_limit,
        "max_alpha_limit": MINOR_EDGE_FRINGE_MAX_ALPHA,
        "equivalent_opaque_pixel_limit": MINOR_EDGE_FRINGE_MAX_EQUIVALENT_OPAQUE_PIXELS,
        "max_component_pixel_limit": MINOR_EDGE_FRINGE_MAX_COMPONENT_PIXELS,
        "disposition": (
            "review_warning" if review_only else "hard_failure" if indices else "none"
        ),
    }


def validate_transparent_frame(
    image: Image.Image,
    key: tuple[int, int, int],
) -> tuple[dict[str, Any], list[str], list[str]]:
    pixels = image_values(image)
    width, height = image.size
    alpha = image.getchannel("A")
    boundary = alpha_edge_band(alpha, 3)
    visible_count = sum(pixel[3] >= VISIBLE_ALPHA_THRESHOLD for pixel in pixels)
    transparent_count = sum(pixel[3] == 0 for pixel in pixels)
    border_visible = sum(
        pixels[index][3] >= VISIBLE_ALPHA_THRESHOLD for index in border_indices(width, height, 1)
    )
    transparent_rgb = sum(pixel[3] == 0 and any(pixel[:3]) for pixel in pixels)
    visible_key = sum(
        pixel[3] >= VISIBLE_ALPHA_THRESHOLD and channel_distance(pixel[:3], key) <= 32
        for pixel in pixels
    )
    edge_fringe_indices = [
        index
        for index, pixel in enumerate(pixels)
        if (
            boundary[index]
            and pixel[3] >= VISIBLE_ALPHA_THRESHOLD
            and (
                channel_distance(pixel[:3], key) <= 64
                or (
                    key_dominance(pixel[:3], key) >= 48
                    and chroma_similarity(pixel[:3], key) >= 0.97
                )
            )
        )
    ]
    edge_fringe = edge_fringe_report(edge_fringe_indices, pixels, image.size)
    holes = enclosed_transparent_components(image)
    errors: list[str] = []
    warnings: list[str] = []
    if visible_count == 0:
        errors.append("frame has no visible subject pixels")
    if transparent_count == 0:
        errors.append("frame has no transparent background pixels")
    if border_visible:
        errors.append("visible subject pixels touch the frame edge")
    if transparent_rgb:
        errors.append("fully transparent pixels contain non-zero RGB")
    if visible_key:
        warnings.append(
            "visible pixels close to the chroma key are diagnostic only; "
            "inspect all five preview backgrounds for actual contamination"
        )
    if edge_fringe["disposition"] == "hard_failure":
        errors.append("visible silhouette-edge pixels retain chroma contamination")
    elif edge_fringe["disposition"] == "review_warning":
        warnings.append(
            "isolated low-alpha silhouette-edge chroma evidence is within the bounded "
            "review allowance; inspect all five preview backgrounds for actual contamination"
        )
    if holes:
        warnings.append("frame contains enclosed transparent regions that require visual review")
    return (
        {
            "visible_pixels": visible_count,
            "transparent_pixels": transparent_count,
            "border_visible_pixels": border_visible,
            "transparent_rgb_residue_pixels": transparent_rgb,
            "visible_key_pixels": visible_key,
            "edge_chroma_fringe_pixels": edge_fringe["pixels"],
            "edge_chroma_fringe": edge_fringe,
            "enclosed_transparent_component_areas": holes,
        },
        errors,
        warnings,
    )


def checkerboard(size: tuple[int, int]) -> Image.Image:
    width, height = size
    square = max(8, round(min(width, height) / 20))
    image = Image.new("RGBA", size, (224, 224, 224, 255))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            value = 248 if (x // square + y // square) % 2 == 0 else 200
            pixels[x, y] = (value, value, value, 255)
    return image


def qa_preview(image: Image.Image, key: tuple[int, int, int]) -> Image.Image:
    backgrounds = [
        checkerboard(image.size),
        Image.new("RGBA", image.size, (255, 255, 255, 255)),
        Image.new("RGBA", image.size, (128, 128, 128, 255)),
        Image.new("RGBA", image.size, (0, 0, 0, 255)),
        Image.new("RGBA", image.size, tuple(255 - value for value in key) + (255,)),
    ]
    for background in backgrounds:
        background.alpha_composite(image)
    sheet = Image.new("RGBA", (image.width * len(backgrounds), image.height), (0, 0, 0, 255))
    for index, panel in enumerate(backgrounds):
        sheet.paste(panel, (index * image.width, 0))
    return sheet


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_save_image(image: Image.Image, path: Path, replace: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not replace:
        fail("destination_exists", f"destination already exists: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".png", dir=path.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        image.save(temporary, format="PNG", optimize=False)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def atomic_write_json(value: dict[str, Any], path: Path, replace: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not replace:
        fail("destination_exists", f"destination already exists: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".json", dir=path.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        temporary.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def preflight_destinations(
    jobs: list[dict[str, Any]],
    report_path: Path,
    preview_dir: Path,
    replace: bool,
) -> None:
    try:
        preview_metadata = preview_dir.lstat()
    except FileNotFoundError:
        preview_metadata = None
    except OSError as error:
        fail("invalid_destination", f"could not inspect preview directory: {error}")
    if preview_metadata is not None and (
        stat.S_ISLNK(preview_metadata.st_mode) or not stat.S_ISDIR(preview_metadata.st_mode)
    ):
        fail(
            "invalid_destination",
            f"preview directory must be a non-symlink directory when it exists: {preview_dir}",
        )
    destinations: list[Path] = [report_path]
    destinations.extend(job["master"] for job in jobs)
    destinations.extend(job["output"] for job in jobs)
    destinations.extend(
        preview_dir / f"{job['id'].replace('/', '__')}.png" for job in jobs
    )
    seen: set[Path] = set()
    for destination in destinations:
        if destination in seen:
            fail("invalid_jobs", f"duplicate destination path {destination}")
        seen.add(destination)
        try:
            metadata = destination.lstat()
        except FileNotFoundError:
            continue
        except OSError as error:
            fail("invalid_destination", f"could not inspect destination: {error}")
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            fail(
                "invalid_destination",
                f"destination must be a regular non-symlink file when it exists: {destination}",
            )
        if not replace:
            fail("destination_exists", f"destination already exists: {destination}")


def process_job(
    job: dict[str, Any],
    target_size: tuple[int, int],
    preview_dir: Path,
    edge_contract: int,
    edge_feather: float,
    replace: bool,
) -> dict[str, Any]:
    source, crop_bounds, decoded_size = load_crop(job["source"], job["crop"])
    if source.width < target_size[0] or source.height < target_size[1]:
        fail(
            "source_capacity_missing",
            "source crop is smaller than the selected runtime target; generate or select a larger source crop because downscaling is allowed but upscaling is not",
        )
    sure_foreground = load_foreground_mask(
        job["foreground_mask"],
        source_size=decoded_size,
        crop_bounds=crop_bounds,
        crop_size=source.size,
    )
    pixels = image_values(source)
    if any(pixel[3] != 255 for pixel in pixels):
        fail(
            "invalid_chroma_source",
            "source crop must be fully opaque flat-background artwork; do not request model-native transparency",
        )
    key, key_report = estimate_key(pixels, source.size, job["key_color"])
    matte, matte_report = build_matte(
        source,
        key,
        key_report["transparent_threshold"],
        sure_foreground,
    )
    cleaned, cleanup_report = reconstruct_edge_rgb(matte, key, target_size)
    if not cleanup_report["alpha_preserved"]:
        fail("alpha_changed", "source-resolution RGB reconstruction changed Alpha")

    source_pixels = image_values(source)
    cleaned_pixels = image_values(cleaned)
    master_boundary = alpha_edge_band(cleaned.getchannel("A"), cleanup_report["edge_radius_source_px"])
    interior_rgb_changes = sum(
        source_pixel[:3] != cleaned_pixel[:3]
        for index, (source_pixel, cleaned_pixel) in enumerate(zip(source_pixels, cleaned_pixels))
        if cleaned_pixel[3] == 255 and not master_boundary[index]
    )
    if interior_rgb_changes:
        fail("interior_rgb_changed", "pipeline changed opaque RGB outside the alpha edge band")

    runtime_before_reconstruction = resize_linear_premultiplied(cleaned, target_size)
    runtime_before_reconstruction = apply_edge_fallback(
        runtime_before_reconstruction,
        edge_contract,
        edge_feather,
    )
    runtime_repair_needed = cleaned.size != target_size or bool(edge_contract or edge_feather)
    if runtime_repair_needed:
        runtime, runtime_cleanup_report = reconstruct_edge_rgb(
            runtime_before_reconstruction,
            key,
            target_size,
        )
        runtime_radius = runtime_cleanup_report.pop("edge_radius_source_px")
        runtime_cleanup_report.update(
            {
                "applied": True,
                "edge_radius_runtime_px": runtime_radius,
            }
        )
        if not runtime_cleanup_report["alpha_preserved"]:
            fail("alpha_changed", "runtime-size RGB reconstruction changed Alpha")
        runtime_boundary = alpha_edge_band(runtime.getchannel("A"), runtime_radius)
        runtime_interior_rgb_changes = sum(
            before[:3] != after[:3]
            for index, (before, after) in enumerate(
                zip(
                    image_values(runtime_before_reconstruction),
                    image_values(runtime),
                )
            )
            if after[3] == 255 and not runtime_boundary[index]
        )
    else:
        runtime = runtime_before_reconstruction
        runtime_cleanup_report = {
            "applied": False,
            "reason": "source_resolution_repair_already_matches_final_size",
            "edge_radius_runtime_px": 0,
            "alpha_preserved": True,
            "reconstructed_translucent_pixels": 0,
            "reconstructed_opaque_pixels": 0,
        }
        runtime_interior_rgb_changes = 0
    if runtime_interior_rgb_changes:
        fail(
            "interior_rgb_changed",
            "runtime edge repair changed opaque RGB outside the alpha edge band",
        )
    master_qa, master_errors, master_warnings = validate_transparent_frame(cleaned, key)
    runtime_qa, runtime_errors, runtime_warnings = validate_transparent_frame(runtime, key)
    preview_path = preview_dir / f"{job['id'].replace('/', '__')}.png"
    atomic_save_image(cleaned, job["master"], replace)
    atomic_save_image(runtime, job["output"], replace)
    atomic_save_image(qa_preview(runtime, key), preview_path, replace)

    errors = sorted(set([*master_errors, *runtime_errors]))
    warnings = [*master_warnings, *runtime_warnings]
    if edge_contract:
        warnings.append("edge contraction fallback was applied at one final output pixel")
    if edge_feather:
        warnings.append(f"inward-only alpha feather fallback was applied at {edge_feather} final pixels")
    return {
        "id": job["id"],
        "ok": not errors,
        "errors": errors,
        "warnings": sorted(set(warnings)),
        "source": {
            "path": str(job["source"]),
            "sha256": sha256(job["source"]),
            "decoded_size": {"width": decoded_size[0], "height": decoded_size[1]},
            "crop": {
                "x": crop_bounds[0],
                "y": crop_bounds[1],
                "width": crop_bounds[2] - crop_bounds[0],
                "height": crop_bounds[3] - crop_bounds[1],
            },
        },
        "foreground_mask": (
            {
                "path": str(job["foreground_mask"]),
                "sha256": sha256(job["foreground_mask"]),
                "semantics": "white_sure_foreground_black_unrestricted",
            }
            if job["foreground_mask"] is not None
            else None
        ),
        "key": key_report,
        "matte": matte_report,
        "edge_rgb_reconstruction": cleanup_report,
        "runtime_edge_rgb_reconstruction": runtime_cleanup_report,
        "interior_opaque_rgb_changed_pixels": interior_rgb_changes,
        "runtime_interior_opaque_rgb_changed_pixels": runtime_interior_rgb_changes,
        "resize_count": 0 if cleaned.size == target_size else 1,
        "size_normalization": {
            "mode": "exact_copy" if cleaned.size == target_size else "single_downscale",
            "source_size": {"width": cleaned.width, "height": cleaned.height},
            "target_size": {"width": target_size[0], "height": target_size[1]},
            "filter": (
                "none"
                if cleaned.size == target_size
                else "linear_light_premultiplied_alpha_lanczos"
            ),
        },
        "edge_contract_final_px": edge_contract,
        "edge_feather_final_px": edge_feather,
        "master": {
            "path": str(job["master"]),
            "size": {"width": cleaned.width, "height": cleaned.height},
            "sha256": sha256(job["master"]),
            "qa": master_qa,
        },
        "output": {
            "path": str(job["output"]),
            "size": {"width": runtime.width, "height": runtime.height},
            "sha256": sha256(job["output"]),
            "qa": runtime_qa,
        },
        "preview": {
            "path": str(preview_path),
            "sha256": sha256(preview_path),
            "panels": ["checkerboard", "white", "gray", "black", "key_complement"],
        },
    }


def run(args: argparse.Namespace) -> dict[str, Any]:
    jobs_path = absolute_path(args.jobs, "--jobs")
    report_path = absolute_path(args.report, "--report")
    preview_dir = absolute_path(args.preview_dir, "--preview-dir")
    target_size, jobs = parse_jobs(jobs_path)
    preflight_destinations(jobs, report_path, preview_dir, args.replace)
    results: list[dict[str, Any]] = []
    for job in jobs:
        try:
            results.append(
                process_job(
                    job,
                    target_size,
                    preview_dir,
                    args.edge_contract,
                    args.edge_feather,
                    args.replace,
                )
            )
        except PipelineError as error:
            results.append(
                {
                    "id": job["id"],
                    "ok": False,
                    "errors": [error.message],
                    "warnings": [],
                    "error_code": error.code,
                }
            )
    report = {
        "schema_version": REPORT_SCHEMA,
        "ok": all(result["ok"] for result in results),
        "pipeline": PIPELINE_ID,
        "implementation_sha256": sha256(Path(__file__).resolve()),
        "runtime": {
            "python": ".".join(str(part) for part in sys.version_info[:3]),
            "pillow": PILLOW_VERSION,
        },
        "target_size": {"width": target_size[0], "height": target_size[1]},
        "target_tier": TARGET_TIERS[target_size],
        "configuration": {
            "spatial_background": "border_connected_key_candidates",
            "soft_matte": True,
            "edge_rgb_scope": "alpha_boundary_with_chroma_evidence",
            "alpha_preserved_during_edge_rgb_reconstruction": True,
            "runtime_edge_rgb_reconstruction": "after_final_resize_and_alpha_fallback",
            "visible_key_pixels": "diagnostic_only_requires_preview_review",
            "minor_edge_fringe": "bounded_alpha_weighted_review_warning",
            "resize": "linear_light_premultiplied_lanczos_once_or_exact_copy",
            "edge_contract_final_px": args.edge_contract,
            "edge_feather_final_px": args.edge_feather,
        },
        "frames": results,
    }
    atomic_write_json(report, report_path, args.replace)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", required=True, help="Absolute apc.transparent-frame-jobs.v1 JSON path")
    parser.add_argument("--report", required=True, help="Absolute output report path")
    parser.add_argument("--preview-dir", required=True, help="Absolute multi-background QA directory")
    parser.add_argument("--edge-contract", type=int, choices=(0, 1), default=0)
    parser.add_argument("--edge-feather", type=float, choices=(0.0, 0.25, 0.5), default=0.0)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    try:
        report = run(args)
    except PipelineError as error:
        print(json.dumps({"ok": False, "error": {"code": error.code, "message": error.message}}, indent=2))
        raise SystemExit(1) from error
    print(json.dumps({"ok": report["ok"], "report": args.report, "frame_count": len(report["frames"])}, indent=2))
    raise SystemExit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
