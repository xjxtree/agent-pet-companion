#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-portable-pet-maker.XXXXXX")"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"

PETCORE_PID=""
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPYCACHEPREFIX="$TMP_DIR/python-cache"

cleanup() {
  if [[ -n "$PETCORE_PID" ]]; then
    kill "$PETCORE_PID" >/dev/null 2>&1 || true
    wait "$PETCORE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_json() {
  local json="$1"
  local expression="$2"
  JSON="$json" python3 -B - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON"])
expression = sys.argv[1]
allowed = {
    "__builtins__": {},
    "all": all,
    "any": any,
    "data": data,
    "len": len,
    "set": set,
}
if not eval(expression, allowed, {}):
    raise SystemExit(
        f"assertion failed: {expression}\n{json.dumps(data, ensure_ascii=False, indent=2)}"
    )
PY
}

cd "$ROOT_DIR"
cargo build --locked -p petcore -p petcore-cli >/dev/null

HELPER="$ROOT_DIR/skills/agent-pet-maker/scripts/petpack_workspace.py"
CLI="$ROOT_DIR/target/debug/petcore-cli"
PETCORE="$ROOT_DIR/target/debug/petcore"

python3 -B -m unittest discover \
  -s "$ROOT_DIR/skills/agent-pet-maker/tests" \
  -p 'test_*.py' >/dev/null

PREFLIGHT="$(python3 -B "$HELPER" preflight --cli "$CLI")"
assert_json "$PREFLIGHT" 'data["ok"] is True and data["image_codecs"]["png"] is True and data["image_codecs"]["animated_webp"] is True'

CREATE_WORKSPACE="$TMP_DIR/create-workspace"
CREATE_OUTPUT="$TMP_DIR/portable-fixture.petpack"
CREATE_RESULT="$TMP_DIR/portable-fixture.result.json"
CREATE_PREPARE="$(python3 -B "$HELPER" prepare \
  --operation create \
  --workspace "$CREATE_WORKSPACE" \
  --cli "$CLI")"
assert_json "$CREATE_PREPARE" 'data["ok"] is True and data["status"] == "prepared" and data["operation"] == "create"'

python3 -B - "$CREATE_WORKSPACE/petpack-source" <<'PY'
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

root = Path(sys.argv[1])
states = ("idle", "start", "tool", "waiting", "review", "done", "failed")
state_colors = {
    "idle": (111, 92, 219, 235),
    "start": (72, 143, 235, 235),
    "tool": (35, 174, 132, 235),
    "waiting": (230, 168, 48, 235),
    "review": (190, 92, 217, 235),
    "done": (62, 184, 91, 235),
    "failed": (210, 72, 87, 235),
}


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def render_frame(state: str, index: int) -> Image.Image:
    image = Image.new("RGBA", (192, 208), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    color = state_colors[state]
    dx = index * 4
    dy = index * 2
    draw.ellipse((43 + dx, 49 - dy, 149 + dx, 169 - dy), fill=color)
    draw.polygon(
        [(58 + dx, 68 - dy), (70 + dx, 28 - dy), (91 + dx, 65 - dy)],
        fill=color,
    )
    draw.polygon(
        [(105 + dx, 65 - dy), (126 + dx, 28 - dy), (138 + dx, 68 - dy)],
        fill=color,
    )
    draw.ellipse((73 + dx, 91 - dy, 84 + dx, 102 - dy), fill=(255, 255, 255, 255))
    draw.ellipse((113 + dx, 91 - dy, 124 + dx, 102 - dy), fill=(255, 255, 255, 255))
    draw.ellipse((77 + dx, 95 - dy, 82 + dx, 100 - dy), fill=(25, 28, 45, 255))
    draw.ellipse((117 + dx, 95 - dy, 122 + dx, 100 - dy), fill=(25, 28, 45, 255))
    draw.arc((87 + dx, 105 - dy, 109 + dx, 126 - dy), 15, 165, fill=(255, 255, 255, 255), width=3)
    draw.ellipse((137 - dx, 131 + dy, 177 - dx, 163 + dy), fill=color)
    draw.rectangle((19 + index, 190, 34 + index, 197), fill=(*color[:3], 170))
    return image


frames: list[Image.Image] = []
for state in states:
    state_dir = root / "assets" / "frames" / state
    state_dir.mkdir(parents=True, exist_ok=True)
    for index in range(2):
        frame = render_frame(state, index)
        frame.save(state_dir / f"frame-{index:03d}.png", format="PNG", optimize=False)
        if state == "idle":
            frames.append(frame)

cover = frames[0].resize((384, 416), Image.Resampling.NEAREST)
cover.save(root / "assets" / "preview" / "cover.png", format="PNG", optimize=False)
frames[0].resize((384, 416), Image.Resampling.NEAREST).save(
    root / "assets" / "preview" / "animated_preview.webp",
    format="WEBP",
    save_all=True,
    append_images=[frames[1].resize((384, 416), Image.Resampling.NEAREST)],
    duration=[84, 84],
    loop=0,
    lossless=True,
)

created_at = "2026-07-16T00:00:00Z"
manifest = {
    "schema_version": "apc.petpack.v1",
    "id": "pet_portablefixture",
    "name": "Portable Validation Fixture",
    "style": "deterministic repository validation fixture",
    "quality": "standard",
    "render_size": {"width": 192, "height": 208},
    "fps_profiles": {"standard": 12, "smooth": 20},
    "default_fps_profile": "standard",
    "states": [
        {
            "name": state,
            "frames_dir": f"assets/frames/{state}",
            "loop": state not in {"start", "done"},
        }
        for state in states
    ],
    "created_at": created_at,
}
write_json(root / "manifest.json", manifest)
write_json(
    root / "brief.json",
    {
        "schema_version": "apc.pet-brief.v1",
        "name": manifest["name"],
        "style": manifest["style"],
        "quality": "standard",
        "description": "A deterministic isolated fixture used only to validate the portable workflow.",
        "generation": {
            "generator": "repository-fixture-renderer",
            "provenance": "skill-full-source",
            "skill_helper": "agent-pet-maker",
            "preview_only": False,
        },
        "states": [
            {"name": state, "motion": f"Deterministic {state} fixture motion."}
            for state in states
        ],
        "runtime": {
            "default_fps": 12,
            "smooth_fps": 20,
            "frames_per_state": 2,
            "render_size": {"width": 192, "height": 208},
        },
        "extensions": {"dev.agentpet.validation/fixture": True},
    },
)
write_json(
    root / "source" / "source.json",
    {
        "schema_version": "apc.pet-source.v1",
        "generator": "repository-fixture-renderer",
        "provenance": "skill-full-source",
        "created_at": created_at,
        "manifest_id": manifest["id"],
        "pet_name": manifest["name"],
        "style": manifest["style"],
        "quality": "standard",
        "visual_source": "image-generation",
        "frames_per_state": 2,
        "preview_only": False,
        "reference_files": [],
        "runner": "repository-validation",
        "skill_helper": "agent-pet-maker",
        "extensions": {"dev.agentpet.validation/fixture": True},
    },
)
(root / "source" / "prompt.md").write_text(
    "Create the deterministic repository validation fixture. This is test data, not a user pet.\n",
    encoding="utf-8",
)
session = root / "source" / "skill_session.jsonl"
with session.open("a", encoding="utf-8") as handle:
    handle.write(
        json.dumps(
            {
                "schema_version": "apc.pet-source-event.v1",
                "event": "states.rendered",
                "created_at": created_at,
                "skill": "agent-pet-maker",
                "runner": "repository-validation",
                "generator": "repository-fixture-renderer",
                "manifest_id": manifest["id"],
                "quality": "standard",
                "render_size": {"width": 192, "height": 208},
                "states": list(states),
                "frames_per_state": 2,
                "fps_profiles": {"standard": 12, "smooth": 20},
                "extensions": {"dev.agentpet.validation/fixture": True},
            },
            ensure_ascii=False,
            sort_keys=True,
        )
        + "\n"
    )
PY

CREATE_FINALIZE="$(python3 -B "$HELPER" finalize \
  --operation create \
  --workspace "$CREATE_WORKSPACE" \
  --output "$CREATE_OUTPUT" \
  --result "$CREATE_RESULT" \
  --cli "$CLI")"
assert_json "$CREATE_FINALIZE" 'data["status"] == "completed" and data["operation"] == "create" and data["manifest"]["id"] == "pet_portablefixture" and data["validation"]["ok"] is True and data["validation"]["frame_count"] == 14 and data["changed_states"] == []'

CREATE_VALIDATION="$("$CLI" petpack validate "$CREATE_OUTPUT")"
assert_json "$CREATE_VALIDATION" 'data["ok"] is True and data["manifest"]["id"] == "pet_portablefixture" and data["frame_count"] == 14 and data["warnings"] == []'

MODIFY_WORKSPACE="$TMP_DIR/modify-workspace"
MODIFY_OUTPUT="$TMP_DIR/portable-fixture-revised.petpack"
MODIFY_RESULT="$TMP_DIR/portable-fixture-revised.result.json"
MODIFY_PREPARE="$(python3 -B "$HELPER" prepare \
  --operation modify \
  --input "$CREATE_OUTPUT" \
  --workspace "$MODIFY_WORKSPACE" \
  --cli "$CLI")"
assert_json "$MODIFY_PREPARE" 'data["ok"] is True and data["status"] == "prepared" and data["operation"] == "modify" and data["base"]["pet_id"] == "pet_portablefixture"'

python3 -B - "$MODIFY_WORKSPACE/petpack-source" <<'PY'
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

root = Path(sys.argv[1])
states = ("idle", "start", "tool", "waiting", "review", "done", "failed")
created_at = "2026-07-16T00:01:00Z"


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


for index, frame_path in enumerate(sorted((root / "assets" / "frames" / "tool").glob("*.png"))):
    with Image.open(frame_path) as source:
        frame = source.convert("RGBA")
    draw = ImageDraw.Draw(frame)
    draw.rounded_rectangle(
        (71 + index * 3, 131 - index * 2, 125 + index * 3, 175 - index * 2),
        radius=8,
        fill=(25, 38, 59, 235),
        outline=(116, 232, 208, 255),
        width=4,
    )
    draw.line((79, 144 + index, 117, 144 + index), fill=(255, 255, 255, 255), width=3)
    draw.line((79, 155 + index, 108, 155 + index), fill=(255, 255, 255, 255), width=3)
    frame.save(frame_path, format="PNG", optimize=False)

manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
write_json(
    root / "brief.json",
    {
        "schema_version": "apc.pet-brief.v1",
        "name": manifest["name"],
        "style": manifest["style"],
        "quality": "standard",
        "description": "The isolated fixture now has a visibly revised tool state.",
        "generation": {
            "generator": "repository-fixture-editor",
            "provenance": "skill-full-source",
            "skill_helper": "agent-pet-maker",
            "preview_only": False,
        },
        "states": [
            {
                "name": state,
                "motion": (
                    "Uses a small dark work panel."
                    if state == "tool"
                    else f"Preserved deterministic {state} fixture motion."
                ),
            }
            for state in states
        ],
        "runtime": {
            "default_fps": 12,
            "smooth_fps": 20,
            "frames_per_state": 2,
            "render_size": {"width": 192, "height": 208},
        },
        "extensions": {"dev.agentpet.validation/fixture": True},
    },
)
write_json(
    root / "source" / "source.json",
    {
        "schema_version": "apc.pet-source.v1",
        "generator": "repository-fixture-editor",
        "provenance": "skill-full-source",
        "created_at": created_at,
        "manifest_id": manifest["id"],
        "pet_name": manifest["name"],
        "style": manifest["style"],
        "quality": "standard",
        "visual_source": "image-generation",
        "frames_per_state": 2,
        "preview_only": False,
        "reference_files": [],
        "runner": "repository-validation",
        "skill_helper": "agent-pet-maker",
        "extensions": {"dev.agentpet.validation/fixture": True},
    },
)
(root / "source" / "prompt.md").write_text(
    "Modify only the tool state of the deterministic repository validation fixture.\n",
    encoding="utf-8",
)
session = root / "source" / "skill_session.jsonl"
with session.open("a", encoding="utf-8") as handle:
    handle.write(
        json.dumps(
            {
                "schema_version": "apc.pet-source-event.v1",
                "event": "states.rendered",
                "created_at": created_at,
                "skill": "agent-pet-maker",
                "runner": "repository-validation",
                "generator": "repository-fixture-editor",
                "manifest_id": manifest["id"],
                "quality": "standard",
                "render_size": {"width": 192, "height": 208},
                "states": ["tool"],
                "changed_states": ["tool"],
                "frames_per_state": 2,
                "fps_profiles": {"standard": 12, "smooth": 20},
                "extensions": {"dev.agentpet.validation/fixture": True},
            },
            ensure_ascii=False,
            sort_keys=True,
        )
        + "\n"
    )
PY

MODIFY_FINALIZE="$(python3 -B "$HELPER" finalize \
  --operation modify \
  --workspace "$MODIFY_WORKSPACE" \
  --changed-state tool \
  --output "$MODIFY_OUTPUT" \
  --result "$MODIFY_RESULT" \
  --cli "$CLI")"
assert_json "$MODIFY_FINALIZE" 'data["status"] == "completed" and data["operation"] == "modify" and data["manifest"]["id"] == "pet_portablefixture" and data["base"]["pet_id"] == "pet_portablefixture" and data["changed_states"] == ["tool"] and data["validation"]["ok"] is True'

MODIFY_VALIDATION="$("$CLI" petpack validate "$MODIFY_OUTPUT")"
assert_json "$MODIFY_VALIDATION" 'data["ok"] is True and data["manifest"]["id"] == "pet_portablefixture" and data["frame_count"] == 14 and data["warnings"] == []'

python3 -B - "$CREATE_OUTPUT" "$MODIFY_OUTPUT" <<'PY'
import hashlib
import sys
import zipfile

states = ("idle", "start", "tool", "waiting", "review", "done", "failed")


def state_hashes(path: str) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    with zipfile.ZipFile(path) as archive:
        for state in states:
            prefix = f"assets/frames/{state}/"
            result[state] = {
                name: hashlib.sha256(archive.read(name)).hexdigest()
                for name in sorted(archive.namelist())
                if name.startswith(prefix) and name.endswith(".png")
            }
    return result


before = state_hashes(sys.argv[1])
after = state_hashes(sys.argv[2])
changed = [state for state in states if before[state] != after[state]]
if changed != ["tool"]:
    raise SystemExit(f"portable modify changed unexpected states: {changed}")
PY

(
  APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
    "$PETCORE" serve --ready-file "$TMP_DIR/daemon-ready"
) >"$TMP_DIR/petcore.log" 2>&1 &
PETCORE_PID="$!"
for _ in {1..200}; do
  [[ -f "$TMP_DIR/daemon-ready" ]] && break
  if ! kill -0 "$PETCORE_PID" >/dev/null 2>&1; then
    cat "$TMP_DIR/petcore.log" >&2
    exit 1
  fi
  sleep 0.05
done
[[ -f "$TMP_DIR/daemon-ready" ]]

HEALTH="$("$CLI" health)"
assert_json "$HEALTH" 'data["ok"] is True'
"$CLI" behavior set-json --value-json '{"enabled":false}' >/dev/null

INSTALL_RESULT="$TMP_DIR/portable-fixture.install-result.json"
INSTALL="$(python3 -B "$HELPER" install \
  --input "$MODIFY_OUTPUT" \
  --activate \
  --result "$INSTALL_RESULT" \
  --cli "$CLI")"
assert_json "$INSTALL" 'data["status"] == "completed" and data["manifest"]["id"] == "pet_portablefixture" and data["install"]["online_only"] is True and data["install"]["import"]["returned_id"] == "pet_portablefixture" and data["install"]["import"]["succeeded"] is True and data["install"]["activation"]["succeeded"] is True and data["install"]["verification"]["active"] is True and data["install"]["verification"]["behavior_enabled"] is False and data["install"]["verification"]["overlay_visibility"]["pet_visible"] is False'

EXPORTED_OUTPUT="$TMP_DIR/portable-fixture-exported.petpack"
EXPORTED="$("$CLI" petpack export --id pet_portablefixture --output "$EXPORTED_OUTPUT")"
assert_json "$EXPORTED" 'data["ok"] is True and data["pet_id"] == "pet_portablefixture" and data["validation"]["ok"] is True'
cmp -s "$MODIFY_OUTPUT" "$EXPORTED_OUTPUT"

"$CLI" pet delete --id pet_portablefixture >/dev/null
POST_DELETE="$("$CLI" pet list)"
assert_json "$POST_DELETE" 'all(pet["id"] != "pet_portablefixture" for pet in data)'

REIMPORTED="$("$CLI" petpack import "$EXPORTED_OUTPUT")"
assert_json "$REIMPORTED" 'data["id"] == "pet_portablefixture"'
"$CLI" pet activate --id pet_portablefixture >/dev/null
FINAL_SNAPSHOT="$("$CLI" state snapshot)"
assert_json "$FINAL_SNAPSHOT" 'any(pet["id"] == "pet_portablefixture" and pet["active"] is True for pet in data["pets"])'

if find "$ROOT_DIR/skills/agent-pet-maker" \
  \( -type d -name '__pycache__' -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
  -print -quit | grep -q .; then
  printf 'portable pet maker validation polluted the source skill with Python bytecode\n' >&2
  exit 1
fi

echo "Portable agent-pet-maker validation ok (unit tests, create, modify, online install/activate, export/reimport)"
