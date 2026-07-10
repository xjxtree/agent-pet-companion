#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-m2.XXXXXX")"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"
cargo build --workspace >/dev/null
python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
raw_hook = json.loads((root / "schemas/agent-hook-input.schema.json").read_text())
ingest = json.loads((root / "schemas/agent-event-ingest.schema.json").read_text())
agent = json.loads((root / "schemas/agent-event.schema.json").read_text())
petpack = json.loads((root / "schemas/petpack.schema.json").read_text())

assert raw_hook.get("type") == "object" and raw_hook.get("additionalProperties") is True, raw_hook
ingest_props = ingest["properties"]
assert "payload" in ingest_props and "payload_json" in ingest_props, ingest_props
assert ingest.get("additionalProperties") is False, ingest

agent_props = agent["properties"]
assert "payload" not in agent_props and "payload_json" in agent_props, agent_props
event_id = agent_props["id"]
assert event_id.get("minLength") == 1 and event_id.get("maxLength") == 256, event_id
assert event_id.get("pattern") != "^evt_[a-z0-9]+$", event_id
assert agent.get("additionalProperties") is False, agent
payload_props = agent["$defs"]["persistedEnvelope"]["properties"]
assert "unclassified" in payload_props["source_event"]["enum"], payload_props
assert "other" in payload_props["tool_name"]["enum"], payload_props
assert "unknown" in payload_props["outcome"]["enum"], payload_props

states = petpack["properties"]["states"]
assert petpack.get("additionalProperties") is False, petpack
assert states.get("minItems") == 7 and states.get("maxItems") == 7, states
for state in ["idle", "start", "tool", "waiting", "review", "done", "failed"]:
    assert any(rule.get("contains", {}).get("properties", {}).get("name", {}).get("const") == state for rule in states["allOf"]), state

render_rules = json.dumps(petpack["allOf"], ensure_ascii=False)
for quality, width, height in [
    ("standard", 192, 208),
    ("high", 384, 416),
    ("ultra", 768, 832),
    ("original", 1536, 1664),
]:
    assert quality in render_rules and str(width) in render_rules and str(height) in render_rules, quality
PY

for quality in standard high ultra original; do
  "$ROOT_DIR/target/debug/petcore-cli" petpack sample --output "$TMP_DIR/$quality" --quality "$quality" --frames 1 >/dev/null
  OUT="$("$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/$quality")"
  grep -q '"ok": true' <<<"$OUT"
  OUT="$("$ROOT_DIR/target/debug/petcore-cli" petpack build --input "$TMP_DIR/$quality" --output "$TMP_DIR/$quality.petpack")"
  grep -q '"ok": true' <<<"$OUT"
done

FORM='{"description":"CLI materialize provenance guard","style":"半写实","quality":"standard","reference_images":[]}'
if "$ROOT_DIR/target/debug/petcore-cli" petpack materialize \
  --output "$TMP_DIR/forged-skill-source" \
  --form-json "$FORM" \
  --generator codex-app-server-skill \
  --provenance skill-full-source >/dev/null 2>&1; then
  echo "expected CLI materialize trusted skill provenance forgery to fail" >&2
  exit 1
fi

rm -rf "$TMP_DIR/high/assets/frames/tool"
if "$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/high" >/dev/null 2>&1; then
  echo "expected missing state validation to fail" >&2
  exit 1
fi
cp -R "$TMP_DIR/standard" "$TMP_DIR/bad-id-uppercase"
python3 - "$TMP_DIR/bad-id-uppercase/manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.loads(open(path).read())
data["id"] = "Pet_BAD"
open(path, "w").write(json.dumps(data, ensure_ascii=False))
PY
if "$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/bad-id-uppercase" >/dev/null 2>&1; then
  echo "expected uppercase pet id validation to fail" >&2
  exit 1
fi
cp -R "$TMP_DIR/standard" "$TMP_DIR/bad-id-prefix"
python3 - "$TMP_DIR/bad-id-prefix/manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.loads(open(path).read())
data["id"] = "badid"
open(path, "w").write(json.dumps(data, ensure_ascii=False))
PY
if "$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/bad-id-prefix" >/dev/null 2>&1; then
  echo "expected missing pet_ prefix validation to fail" >&2
  exit 1
fi

OUT="$("$ROOT_DIR/target/debug/petcore-cli" renderer budget --quality high --fps 12)"
grep -q '"renderer_budget_mb": 180' <<<"$OUT"
OUT="$("$ROOT_DIR/target/debug/petcore-cli" renderer budget --quality original --fps 20)"
grep -q '"uses_ring_cache": true' <<<"$OUT"

echo "M2 validation ok"
