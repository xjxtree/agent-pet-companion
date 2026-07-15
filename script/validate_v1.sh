#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-v1.XXXXXX")"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"
PETCORE_PID=""

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
  local script="$2"
  JSON="$json" python3 - "$script" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON"])
expr = sys.argv[1]
allowed = {"__builtins__": {}, "data": data, "any": any, "all": all, "len": len, "set": set}
if not eval(expr, allowed, {}):
    raise SystemExit(f"assertion failed: {expr}\n{json.dumps(data, ensure_ascii=False, indent=2)}")
PY
}

wait_for_generation_message() {
  local job_id="$1"
  local needle="$2"
  local out=""
  for _ in {1..300}; do
    out="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation messages --job-id "$job_id")"
    if grep -q "$needle" <<<"$out"; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 0.1
  done
  printf '%s\n' "$out" >&2
  return 1
}

cd "$ROOT_DIR"
cargo build --workspace >/dev/null

(
  APC_HOME="$TMP_DIR/home" \
  APC_AGENT_CONFIG_HOME="$TMP_DIR/agent-home" \
  APC_CONNECTOR_CLI_PATH="$ROOT_DIR/target/debug/petcore-cli" \
  APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK=1 \
  "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready"
) &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

HEALTH="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" health)"
assert_json "$HEALTH" 'data["ok"] is True and data["socket"].endswith("petcore.sock")'

SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'set(data.keys()) >= {"behavior", "overlay_placement", "pets", "events", "recent_events", "connections"}'
assert_json "$SNAPSHOT" 'data["overlay_placement"]["scale"] == 0.12'

OVERLAY_SET="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" overlay placement set --x 321 --y 654 --scale 0.82 --display-id v1-display)"
assert_json "$OVERLAY_SET" 'data["ok"] is True and data["overlay_placement"]["scale"] == 0.82'
OVERLAY_GET="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" overlay placement get)"
assert_json "$OVERLAY_GET" 'data["x"] == 321 and data["y"] == 654 and data["scale"] == 0.82 and data["display_id"] == "v1-display"'
APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" overlay placement set --x 0 --y 0 --scale 0.12 --display-id main >/dev/null

for quality in standard high ultra original; do
  "$ROOT_DIR/target/debug/petcore-cli" petpack sample \
    --output "$TMP_DIR/$quality" \
    --quality "$quality" \
    --frames 2 >/dev/null
  VALIDATION="$("$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/$quality")"
  assert_json "$VALIDATION" 'data["ok"] is True and len(data["manifest"]["states"]) == 7'
  BUILD="$("$ROOT_DIR/target/debug/petcore-cli" petpack build --input "$TMP_DIR/$quality" --output "$TMP_DIR/$quality.petpack")"
  assert_json "$BUILD" 'data["ok"] is True and data["validation"]["ok"] is True'
done

IMPORTED_FIRST="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack import "$TMP_DIR/high")"
FIRST_ID="$(JSON="$IMPORTED_FIRST" python3 - <<'PY'
import json, os
print(json.loads(os.environ["JSON"])["id"])
PY
)"
IMPORTED_SECOND="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack import "$TMP_DIR/ultra")"
SECOND_ID="$(JSON="$IMPORTED_SECOND" python3 - <<'PY'
import json, os
print(json.loads(os.environ["JSON"])["id"])
PY
)"
[[ "$FIRST_ID" != "$SECOND_ID" ]]

APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack import "$TMP_DIR/original" >/dev/null
SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'len(data["pets"]) == 3 and any(p["quality"] == "original" for p in data["pets"])'
FIRST_ASSETS="$(JSON="$SNAPSHOT" FIRST_ID="$FIRST_ID" python3 - <<'PY'
import json
import os

snapshot = json.loads(os.environ["JSON"])
pet = next(p for p in snapshot["pets"] if p["id"] == os.environ["FIRST_ID"])
print(json.dumps({
    "petpack": pet["petpack_path"],
    "cover": pet["cover_path"],
}, ensure_ascii=False))
PY
)"
FIRST_PETPACK="$(JSON="$FIRST_ASSETS" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["JSON"])["petpack"])
PY
)"
FIRST_COVER="$(JSON="$FIRST_ASSETS" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["JSON"])["cover"])
PY
)"
FIRST_FRAMES="$(dirname "$FIRST_PETPACK")/$FIRST_ID-frames"
[[ -f "$FIRST_PETPACK" ]]
[[ -f "$FIRST_COVER" ]]
[[ -d "$FIRST_FRAMES" ]]
APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" pet activate --id "$FIRST_ID" >/dev/null
SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'len(data["pets"]) == 3 and any(p["id"] == "'"$FIRST_ID"'" and p["active"] for p in data["pets"])'
APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" pet delete --id "$FIRST_ID" >/dev/null
SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'len(data["pets"]) == 2 and all(p["id"] != "'"$FIRST_ID"'" for p in data["pets"]) and any(p["active"] for p in data["pets"])'
[[ ! -e "$FIRST_PETPACK" ]]
[[ ! -e "$FIRST_COVER" ]]
[[ ! -e "$FIRST_FRAMES" ]]

APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" behavior set-json --value-json \
  '{"enabled":true,"status_bubble":true,"click_menu":true,"mouse_passthrough":true,"auto_hide":false,"fps_profile":"smooth","sources":{"codex":false,"claude_code":true,"pi":true,"opencode":true},"events":{"start":true,"tool":false,"waiting":true,"review":true,"done":true,"failed":true}}' >/dev/null
FILTERED_SOURCE="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id evt_v1_filtered_source --source codex --event-type start --title 开始处理)"
assert_json "$FILTERED_SOURCE" 'data["inserted"] is True and data["triggered"] is False'
FILTERED_EVENT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id evt_v1_filtered_event --source claude_code --event-type tool --title 执行工具)"
assert_json "$FILTERED_EVENT" 'data["inserted"] is True and data["triggered"] is False'
RECENT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$RECENT" 'all(event["id"] not in {"evt_v1_filtered_source", "evt_v1_filtered_event"} for event in data["events"])'
EVENT_HISTORY="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" events recent --limit 10)"
assert_json "$EVENT_HISTORY" 'any(event["id"] == "evt_v1_filtered_source" for event in data) and any(event["id"] == "evt_v1_filtered_event" for event in data)'

TRIGGERED="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id evt_v1_waiting --source claude_code --event-type waiting --title 等待确认)"
assert_json "$TRIGGERED" 'data["triggered"] is True and data["state"] == "waiting"'
SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'any(event["id"] == "evt_v1_waiting" for event in data["events"]) and any(event["id"] == "evt_v1_waiting" for event in data["recent_events"])'

PORT="$(cat "$TMP_DIR/home/run/http-port")"
TOKEN="$(cat "$TMP_DIR/home/run/update-token")"
[[ "$(stat -f '%Lp' "$TMP_DIR/home/run/update-token")" == "600" ]]
if command -v lsof >/dev/null 2>&1; then
  HTTP_LISTENER="$(lsof -nP -a -p "$PETCORE_PID" -iTCP:"$PORT" -sTCP:LISTEN || true)"
  grep -Eq '127\.0\.0\.1|localhost' <<<"$HTTP_LISTENER"
  ! grep -Eq '(\*:|0\.0\.0\.0)' <<<"$HTTP_LISTENER"
fi
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"failed","title":"失败"}')"
[[ "$HTTP_CODE" == "401" ]]
HTTP_OK="$(curl -s -H "X-Agent-Pet-Token: $TOKEN" -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"claude_code","event_type":"review","title":"待查看"}')"
assert_json "$HTTP_OK" 'data["ok"] is True and data["inserted"] is True'

PRE_GENERATION_SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
PRE_GENERATION_PET_IDS="$(JSON="$PRE_GENERATION_SNAPSHOT" python3 - <<'PY'
import json
import os

snapshot = json.loads(os.environ["JSON"])
print(json.dumps([pet["id"] for pet in snapshot["pets"]]))
PY
)"
REFERENCE_IMAGE="$TMP_DIR/high/assets/preview/cover.png"
[[ -f "$REFERENCE_IMAGE" ]]
FORM="$(REFERENCE_IMAGE="$REFERENCE_IMAGE" python3 - <<'PY'
import json
import os

print(json.dumps({
    "description": "安静陪伴的东方幻想角色，等待确认时抬头提醒。",
    "style": "半写实",
    "quality": "high",
    "reference_images": [os.environ["REFERENCE_IMAGE"]],
}, ensure_ascii=False))
PY
)"
JOB_JSON="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation start --form-json "$FORM")"
JOB_ID="$(JSON="$JOB_JSON" python3 - <<'PY'
import json, os
print(json.loads(os.environ["JSON"])["job_id"])
PY
)"
wait_for_generation_message "$JOB_ID" "完成，可在宠物库启用" >/dev/null
SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'len(data["pets"]) >= 3 and any(p["active"] for p in data["pets"])'
GENERATED_PET_ID="$(JSON="$SNAPSHOT" PRE_GENERATION_PET_IDS="$PRE_GENERATION_PET_IDS" python3 - <<'PY'
import json
import os

snapshot = json.loads(os.environ["JSON"])
existing = set(json.loads(os.environ["PRE_GENERATION_PET_IDS"]))
generated = [pet for pet in snapshot["pets"] if pet["id"] not in existing]
assert len(generated) == 1, generated
print(generated[0]["id"])
PY
)"
GENERATED_PETPACK="$(JSON="$SNAPSHOT" PRE_GENERATION_PET_IDS="$PRE_GENERATION_PET_IDS" python3 - <<'PY'
import json
import os

snapshot = json.loads(os.environ["JSON"])
existing = set(json.loads(os.environ["PRE_GENERATION_PET_IDS"]))
generated = [pet for pet in snapshot["pets"] if pet["id"] not in existing]
assert len(generated) == 1, generated
print(generated[0]["petpack_path"])
PY
)"
python3 - "$GENERATED_PETPACK" "$REFERENCE_IMAGE" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = set(archive.namelist())
    manifest = json.loads(archive.read("manifest.json"))
    source = json.loads(archive.read("source/source.json"))
    prompt = archive.read("source/prompt.md").decode("utf-8")
    assert manifest["schema_version"] == "apc.petpack.v1", manifest
    forbidden = {
        ".codex-plugin/",
        "hooks/",
        "skills/",
        "codex-pet.json",
        "codex_pet.json",
        "pet.json",
    }
    present = [name for name in names for marker in forbidden if name == marker or name.startswith(marker)]
    assert not present, present
    assert source["input_reference_count"] == 1, source
    assert source["copied_reference_count"] == 1, source
    assert source["reference_files"] == ["source/references/reference-00.png"], source
    assert source["form"]["reference_images"] == ["source/references/reference-00.png"], source
    assert "source/references/reference-00.png" in prompt, prompt
    assert sys.argv[2] not in prompt, prompt
    assert "source/references/reference-00.png" in names, names
    assert archive.read("source/references/reference-00.png") == open(sys.argv[2], "rb").read()
PY
HISTORY="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation for-pet --pet-id "$GENERATED_PET_ID")"
HISTORY="$HISTORY" JOB_ID="$JOB_ID" GENERATED_PET_ID="$GENERATED_PET_ID" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["HISTORY"])
assert data["found"] is True, data
assert data["job_id"] == os.environ["JOB_ID"], data
assert data["result_pet_id"] == os.environ["GENERATED_PET_ID"], data
assert data["status"] == "completed", data
assert data["form"]["description"].startswith("安静陪伴"), data
assert data["form"]["reference_images"], data
assert any("完成，可在宠物库启用" in message["content"] for message in data["messages"]), data
PY
ACTIVE_PETPACK="$(JSON="$SNAPSHOT" python3 - <<'PY'
import json, os
snapshot = json.loads(os.environ["JSON"])
for pet in snapshot["pets"]:
    if pet["active"]:
        print(pet["petpack_path"])
        break
PY
)"
python3 - "$ACTIVE_PETPACK" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = set(archive.namelist())
    manifest = json.loads(archive.read("manifest.json"))
    assert manifest["schema_version"] == "apc.petpack.v1", manifest
    forbidden = {
        ".codex-plugin/",
        "hooks/",
        "skills/",
        "codex-pet.json",
        "codex_pet.json",
        "pet.json",
    }
    present = [name for name in names for marker in forbidden if name == marker or name.startswith(marker)]
    assert not present, present
PY

for source in codex claude_code pi opencode; do
  APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections repair --source "$source" >/dev/null
done
CONNECTIONS="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections check)"
assert_json "$CONNECTIONS" 'len(data) == 4 and {item["source"] for item in data} == {"codex", "claude_code", "pi", "opencode"}'
assert_json "$CONNECTIONS" 'all(item["install_paths"] for item in data)'
assert_json "$CONNECTIONS" 'all(any(check["name"] == "事件回传" for check in item["items"]) for item in data)'
CONNECTION_TEST="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections test --source opencode)"
assert_json "$CONNECTION_TEST" 'data["ok"] is True and data["triggered"] is False and data["event"]["source"] == "opencode" and data["event"]["payload_json"]["diagnostic"] is True'

for source in codex claude_code pi opencode; do
  APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections uninstall --source "$source" >/dev/null
done
[[ ! -e "$TMP_DIR/agent-home/.agents/plugins/plugins/agent-pet-companion" ]]
if [[ -f "$TMP_DIR/agent-home/.agents/plugins/marketplace.json" ]]; then
  ! grep -q 'agent-pet-companion' "$TMP_DIR/agent-home/.agents/plugins/marketplace.json"
fi
[[ ! -e "$TMP_DIR/home/connectors/claude-code" ]]
if [[ -f "$TMP_DIR/agent-home/.claude/settings.json" ]]; then
  ! grep -q 'agent hook --source claude_code' "$TMP_DIR/agent-home/.claude/settings.json"
fi
[[ ! -e "$TMP_DIR/agent-home/.pi/agent/extensions/agent-pet-companion.ts" ]]
[[ ! -e "$TMP_DIR/agent-home/.pi/agent/extensions/rpc-check.json" ]]
[[ ! -e "$TMP_DIR/agent-home/.config/opencode/plugins/agent-pet-companion.js" ]]
[[ ! -e "$TMP_DIR/agent-home/.config/opencode/plugins/server-check.json" ]]

ORIGINAL_BUDGET="$("$ROOT_DIR/target/debug/petcore-cli" renderer budget --quality original --fps-profile smooth)"
assert_json "$ORIGINAL_BUDGET" 'data["fps"] == 20 and data["uses_ring_cache"] is True and data["runtime_cache_frame_limit"] == 9 and data["estimated_runtime_cache_mb"] < data["decoded_state_mb"]'
HIGH_BUDGET="$("$ROOT_DIR/target/debug/petcore-cli" renderer budget --quality high --fps-profile standard)"
assert_json "$HIGH_BUDGET" 'data["fps"] == 12 and data["uses_ring_cache"] is False and data["renderer_budget_mb"] == 180'

(cd "$ROOT_DIR/apps/macos" && swift build --product AgentPetCompanion >/dev/null)
CORE_VALIDATION="$(cd "$ROOT_DIR/apps/macos" && swift run AgentPetCompanionCoreValidation)"
grep -q 'ok' <<<"$CORE_VALIDATION"

echo "V1 validation ok"
