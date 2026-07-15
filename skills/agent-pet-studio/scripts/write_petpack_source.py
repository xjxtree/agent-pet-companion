#!/usr/bin/env python3
"""Write a validated Agent Pet Companion petpack-source for App Server turns.

This helper is intentionally self-contained so the Codex App Server can invoke a
small, auditable command instead of hand-authoring every petpack file.
"""

import base64
import binascii
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import zlib

HELPER_ID = "agent-pet-studio-preview-helper-v2"
FRAMES_PER_STATE = 12
FORM_PATH = Path("apc_skill_form.json")
OUTPUT_DIR = Path("petpack-source")
STATES = ["idle", "start", "tool", "waiting", "review", "done", "failed"]
RENDER_SIZES = {
    "standard": (192, 208),
    "high": (384, 416),
    "ultra": (768, 832),
    "original": (1536, 1664),
}
STATE_COLORS = {
    "idle": (96, 169, 232),
    "start": (129, 81, 247),
    "tool": (60, 189, 214),
    "waiting": (240, 176, 64),
    "review": (116, 113, 255),
    "done": (64, 196, 129),
    "failed": (232, 90, 110),
}
TINY_WEBP_BASE64 = "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"


def now_rfc3339():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_form():
    if not FORM_PATH.is_file():
        raise SystemExit(f"missing {FORM_PATH}")
    return json.loads(FORM_PATH.read_text(encoding="utf-8"))


def safe_pet_id(description):
    text = re.sub(r"[^a-z0-9]+", "", str(description).lower())
    suffix = text[:10] or "skillpet"
    millis = int(time.time() * 1000) % 100000000
    return f"pet_{suffix}{millis}"


def chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_png(path, width, height, state_name, frame_index=0):
    base = STATE_COLORS[state_name]
    cx = width // 2
    body_cy = int(height * 0.58)
    body_rx = max(10, int(width * 0.24))
    body_ry = max(12, int(height * 0.31))
    head_cy = int(height * 0.29)
    head_rx = max(8, int(width * 0.15))
    head_ry = max(8, int(height * 0.12))
    accent_cy = int(height * 0.64)
    accent_rx = max(8, int(width * 0.17))
    accent_ry = max(4, int(height * 0.05))

    body_limit = body_rx * body_rx * body_ry * body_ry
    head_limit = head_rx * head_rx * head_ry * head_ry
    accent_limit = accent_rx * accent_rx * accent_ry * accent_ry
    rows = []
    phase = frame_index % 2
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            r = g = b = a = 0
            dx = x - cx
            dy_body = y - body_cy
            dy_head = y - head_cy
            in_body = dx * dx * body_ry * body_ry + dy_body * dy_body * body_rx * body_rx <= body_limit
            in_head = dx * dx * head_ry * head_ry + dy_head * dy_head * head_rx * head_rx <= head_limit
            in_accent = dx * dx * accent_ry * accent_ry + (y - accent_cy) * (y - accent_cy) * accent_rx * accent_rx <= accent_limit
            if in_body:
                shade = max(0, min(42, int((y - body_cy) * 42 / max(1, body_ry))))
                r, g, b, a = max(0, base[0] - shade), max(0, base[1] - shade), max(0, base[2] - shade), 222
            if in_head:
                r, g, b, a = 255, 205, 176, 255
            if in_accent:
                r, g, b, a = 86, 184, 224, 230
            wing_left = int(width * 0.24) - phase <= x <= int(width * 0.42) and int(height * 0.54) <= y <= int(height * 0.83)
            wing_right = int(width * 0.58) <= x <= int(width * 0.76) + phase and int(height * 0.54) <= y <= int(height * 0.83)
            if wing_left and abs((x - int(width * 0.42)) * 2) + abs(y - int(height * 0.70)) < int(width * 0.22):
                r, g, b, a = 255, 193, 205, 150
            if wing_right and abs((x - int(width * 0.58)) * 2) + abs(y - int(height * 0.70)) < int(width * 0.22):
                r, g, b, a = 255, 193, 205, 150
            if in_head and y > head_cy and abs(dx) < max(2, width // 35):
                r, g, b, a = 42, 42, 42, 255
            row.extend((r, g, b, a))
        rows.append(bytes(row))

    raw = b"".join(rows)
    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def build_source(form):
    quality = str(form.get("quality") or "standard")
    width, height = RENDER_SIZES.get(quality, RENDER_SIZES["standard"])
    created_at = now_rfc3339()
    pet_id = safe_pet_id(form.get("description", "skillpet"))
    name = "Skill Studio Pet"
    style = str(form.get("style") or "不指定")
    manifest = {
        "schema_version": "apc.petpack.v1",
        "id": pet_id,
        "name": name,
        "style": style,
        "quality": quality if quality in RENDER_SIZES else "standard",
        "render_size": {"width": width, "height": height},
        "fps_profiles": {"standard": 12, "smooth": 20},
        "default_fps_profile": "standard",
        "states": [
            {
                "name": state,
                "frames_dir": f"assets/frames/{state}",
                "loop": state not in {"start", "done"},
            }
            for state in STATES
        ],
        "created_at": created_at,
    }
    write_json(OUTPUT_DIR / "manifest.json", manifest)
    write_json(
        OUTPUT_DIR / "brief.json",
        {
            "schema_version": "apc.pet-brief.v1",
            "name": name,
            "style": style,
            "quality": quality,
            "description": form.get("description"),
            "states": [
                {"name": state, "motion": f"{state} validation motion from App Server Skill helper"}
                for state in STATES
            ],
            "generation": {
                "generator": "agent-pet-studio-preview-helper",
                "provenance": "deterministic_preview",
                "skill_helper": HELPER_ID,
                "preview_only": True,
            },
        },
    )

    for state in STATES:
        for frame_index in range(FRAMES_PER_STATE):
            write_png(
                OUTPUT_DIR / "assets" / "frames" / state / f"{frame_index:04d}.png",
                width,
                height,
                state,
                frame_index,
            )
    write_png(OUTPUT_DIR / "assets" / "preview" / "cover.png", 384, 416, "idle")
    (OUTPUT_DIR / "assets" / "preview").mkdir(parents=True, exist_ok=True)
    (OUTPUT_DIR / "assets" / "preview" / "animated_preview.webp").write_bytes(
        base64.b64decode(TINY_WEBP_BASE64 + "=" * ((4 - len(TINY_WEBP_BASE64) % 4) % 4))
    )

    source_dir = OUTPUT_DIR / "source"
    references_dir = source_dir / "references"
    references_dir.mkdir(parents=True, exist_ok=True)
    reference_files = []
    for index, raw_path in enumerate(form.get("reference_images") or []):
        reference_path = Path(str(raw_path))
        suffix = reference_path.suffix.lower()
        if suffix not in {".png", ".webp"} or not reference_path.is_file():
            continue
        copied_name = f"reference-{index + 1}{suffix}"
        shutil.copyfile(reference_path, references_dir / copied_name)
        reference_files.append(copied_name)
    packaged_form = dict(form)
    packaged_form["reference_images"] = reference_files
    write_text(
        source_dir / "prompt.md",
        "# Agent Pet Studio Prompt\n\n"
        + json.dumps(packaged_form, ensure_ascii=False, indent=2)
        + "\n",
    )
    write_json(
        source_dir / "source.json",
        {
            "schema_version": "apc.pet-source.v1",
            "generator": "agent-pet-studio-preview-helper",
            "provenance": "deterministic_preview",
            "skill_helper": HELPER_ID,
            "runner": "codex-app-server",
            "created_at": created_at,
            "form": packaged_form,
            "reference_files": reference_files,
            "frames_per_state": FRAMES_PER_STATE,
            "visual_source": "deterministic-preview",
            "preview_only": True,
            "reference_visual_influence": False,
        },
    )
    write_text(
        source_dir / "skill_session.jsonl",
        json.dumps(
            {
                "schema_version": "apc.pet-source-event.v1",
                "event": "skill.loaded",
                "skill": "agent-pet-studio",
                "runner": "codex-app-server",
                "helper": HELPER_ID,
                "created_at": created_at,
            },
            ensure_ascii=False,
        )
        + "\n"
        + json.dumps(
            {
                "schema_version": "apc.pet-source-event.v1",
                "event": "skill.petpack_source.written",
                "petpack_source": "petpack-source",
                "runner": "codex-app-server",
                "helper": HELPER_ID,
                "created_at": now_rfc3339(),
            },
            ensure_ascii=False,
        )
        + "\n",
    )
    write_json(
        OUTPUT_DIR / "build" / "validation.json",
        {
            "schema_version": "apc.pet-validation.v1",
            "ok": True,
            "skill_helper": HELPER_ID,
            "preview_only": True,
            "frames_per_state": FRAMES_PER_STATE,
        },
    )
    return manifest


def validate_source():
    cli = os.environ.get("APC_PETCORE_CLI")
    if not cli:
        return {"ok": True, "skipped": "APC_PETCORE_CLI is unset"}
    result = subprocess.run(
        [cli, "petpack", "validate", str(OUTPUT_DIR)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        check=False,
    )
    if result.returncode != 0:
        write_json(
            OUTPUT_DIR / "build" / "validation.json",
            {
                "ok": False,
                "skill_helper": HELPER_ID,
                "stderr": result.stderr,
                "stdout": result.stdout,
            },
        )
        raise SystemExit(result.stderr or result.stdout or "petpack validate failed")
    validation = json.loads(result.stdout)
    validation["schema_version"] = "apc.pet-validation.v1"
    validation["skill_helper"] = HELPER_ID
    write_json(OUTPUT_DIR / "build" / "validation.json", validation)
    return validation


def main():
    form = load_form()
    manifest = build_source(form)
    validation = validate_source()
    print(
        json.dumps(
            {
                "petpack_source": "petpack-source",
            "mode": "deterministic_preview",
                "skill_helper": HELPER_ID,
                "manifest_id": manifest["id"],
                "validated": validation.get("ok") is True,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
