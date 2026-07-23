#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-real-app-server.XXXXXX")"
REAL_USER_HOME="${HOME:-}"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"
JOB_ID=""
PETCORE_PID=""

cleanup() {
  if [[ -n "$PETCORE_PID" ]]; then
    kill "$PETCORE_PID" >/dev/null 2>&1 || true
    wait "$PETCORE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

disabled() {
  case "${1:-}" in
    0|false|FALSE|no|NO) return 0 ;;
    *) return 1 ;;
  esac
}

skip() {
  printf 'Skipped real Codex App Server validation: %s\n' "$1"
  exit 0
}

fail() {
  printf 'Real Codex App Server validation failed: %s\n' "$1" >&2
  if [[ -n "${PROBE:-}" ]]; then
    printf '\n--- codex app-server probe ---\n%s\n' "$PROBE" >&2
  fi
  if [[ -s "$TMP_DIR/probe.err" ]]; then
    printf '\n--- probe stderr ---\n' >&2
    cat "$TMP_DIR/probe.err" >&2
  fi
  if [[ -n "$JOB_ID" ]]; then
    printf '\n--- generation status ---\n' >&2
    APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation status \
      --job-id "$JOB_ID" --include-messages >&2 || true
  fi
  printf '\nAction: set CODEX_APP_SERVER_CMD to a real stdio Codex App Server command, or install a codex CLI that supports `codex app-server --stdio`. This validation never reads auth/token/cookie/API key files directly.\n' >&2
  exit 1
}

assert_json() {
  local json="$1"
  local expr="$2"
  JSON="$json" python3 - "$expr" <<'PY'
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

app_server_skip_reason() {
  local setting="${APC_VALIDATE_REAL_APP_SERVER:-0}"
  if disabled "$setting"; then
    printf 'APC_VALIDATE_REAL_APP_SERVER=%s explicitly disables real App Server validation' "$setting"
    return 0
  fi
  if ! truthy "$setting"; then
    printf 'APC_VALIDATE_REAL_APP_SERVER=%s is not an explicit opt-in; use 1 to run the real App Server validation' "$setting"
    return 0
  fi
  if [[ -n "${CODEX_APP_SERVER_CMD:-}" ]]; then
    return 1
  fi
  if command -v codex >/dev/null 2>&1 && codex app-server --help >/dev/null 2>&1; then
    return 1
  fi
  if truthy "$setting"; then
    return 1
  fi
  if ! command -v codex >/dev/null 2>&1; then
    printf 'CODEX_APP_SERVER_CMD is unset and codex CLI was not found'
  else
    printf 'CODEX_APP_SERVER_CMD is unset and codex CLI does not expose a working app-server command'
  fi
  return 0
}

if reason="$(app_server_skip_reason)"; then
  skip "$reason"
fi

if truthy "${APC_VALIDATE_REAL_APP_SERVER:-0}" && [[ -z "${CODEX_APP_SERVER_CMD:-}" ]]; then
  if ! command -v codex >/dev/null 2>&1; then
    fail "APC_VALIDATE_REAL_APP_SERVER is forced but CODEX_APP_SERVER_CMD is unset and codex CLI was not found"
  fi
  if ! codex app-server --help >/dev/null 2>&1; then
    fail "APC_VALIDATE_REAL_APP_SERVER is forced but CODEX_APP_SERVER_CMD is unset and codex app-server is unavailable"
  fi
fi

cd "$ROOT_DIR"
cargo build --workspace >/dev/null

(
  # PetCore storage and connector paths remain isolated. HOME is restored only
  # for the explicitly opted-in Codex subprocess so it can use its own normal
  # login context; this validator never reads authentication files itself.
  HOME="$REAL_USER_HOME" \
  APC_HOME="$TMP_DIR/home" \
  APC_AGENT_CONFIG_HOME="$TMP_DIR/agent-home" \
  APC_CONNECTOR_CLI_PATH="$ROOT_DIR/target/debug/petcore-cli" \
  APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK=0 \
  APC_REQUIRE_SKILL_FULL_SOURCE="${APC_REQUIRE_SKILL_FULL_SOURCE:-1}" \
  APC_REQUIRE_EXTERNAL_SKILL_SOURCE="${APC_REQUIRE_EXTERNAL_SKILL_SOURCE:-1}" \
  "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready"
) &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]] || fail "PetCore did not report ready"

if ! PROBE="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" codex 2>"$TMP_DIR/probe.err")"; then
  fail "petcore-cli codex probe command failed"
fi
assert_json "$PROBE" 'data["initialized"] is True and data["transport"] == "stdio"' \
  || fail "Codex App Server probe did not initialize"

FORM='{"description":"真实 Codex App Server 验收用的小型半写实桌宠，透明背景，动作简洁。主体是一只蓝白云朵猫，圆眼、轻盈尾巴。请返回完整七状态设计 brief；不要读取秘密或无关项目文件。","style":"半写实","quality":"standard","reference_images":[]}'
JOB_JSON="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation start --form-json "$FORM")"
JOB_ID="$(JSON="$JOB_JSON" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["JSON"])["job_id"])
PY
)"

REPLIED_TO_INPUT_REQUEST=0
for _ in {1..1500}; do
  STATUS="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation status --job-id "$JOB_ID" --include-messages)"
  if grep -q '"status"[[:space:]]*:[[:space:]]*"failed"' <<<"$STATUS"; then
    fail "generation job entered failed status"
  fi
  if grep -q '完成，可在宠物库启用\|调整版本已保存入库并已启用' <<<"$STATUS"; then
    break
  fi
  if [[ "$REPLIED_TO_INPUT_REQUEST" == "0" ]] && grep -Eq '"kind"[[:space:]]*:[[:space:]]*"input_request"' <<<"$STATUS"; then
    APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation reply \
      --job-id "$JOB_ID" \
      --content "主体是一只蓝白云朵猫，圆眼、轻盈尾巴，待机时呼吸漂浮，工具执行时尾巴发光。" >/dev/null
    REPLIED_TO_INPUT_REQUEST=1
  fi
  sleep 0.5
done

FINAL_STATUS="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation status --job-id "$JOB_ID" --include-messages)"
assert_json "$FINAL_STATUS" 'data["status"] == "completed"' \
  || fail "generation job did not complete"
assert_json "$FINAL_STATUS" 'data["app_server"]["initialized"] is True and data["app_server"]["started"] is True and data["app_server"]["turn_started"] is True' \
  || fail "App Server session did not initialize/start a Pet Studio turn"
assert_json "$FINAL_STATUS" 'data["app_server"]["thread_id"] is not None and data["app_server"]["turn_id"] is not None' \
  || fail "App Server session is missing thread_id or turn_id"
assert_json "$FINAL_STATUS" 'data["app_server"]["completed"] is True or data["artifacts"]["petpack_source"]["manifest_exists"] is True' \
  || fail "App Server turn did not complete and no Skill full-source artifact was written"
assert_json "$FINAL_STATUS" 'data["app_server"]["ai_brief"]["states_count"] == 7 or data["artifacts"]["petpack_source"]["states_count"] == 7' \
  || fail "real App Server output did not prove seven fixed states"
assert_json "$FINAL_STATUS" 'data["artifacts"]["petpack_source"]["manifest_exists"] is True and data["artifacts"]["petpack_source"]["validation_ok"] is True and len(data["artifacts"]["petpack_files"]) >= 1' \
  || fail "generation artifacts are incomplete"
assert_json "$FINAL_STATUS" 'data["artifacts"]["petpack_source"]["source_metadata"]["generator"] in ["codex-app-server-skill", "codex-app-server-brief-petpack-v1"] and data["artifacts"]["petpack_source"]["source_metadata"]["provenance"] in ["skill-full-source", "codex_app_server_brief"] and data["artifacts"]["petpack_source"]["skill_session"]["exists"] is True' \
  || fail "real App Server generation did not preserve App Server provenance"
if truthy "${APC_REQUIRE_SKILL_FULL_SOURCE:-1}"; then
  assert_json "$FINAL_STATUS" 'data["artifacts"]["petpack_source"]["generation_mode"] == "skill_full_source" and data["artifacts"]["petpack_source"]["real_skill_source"] is True and data["artifacts"]["petpack_source"]["fallback_used"] is False and data["artifacts"]["petpack_source"]["sample_output"] is False and data["artifacts"]["petpack_source"]["repaired_validation"] is False and data["artifacts"]["petpack_source"]["materialized_by_petcore"] is False' \
    || fail "strict full-source mode used fallback/sample/repaired artifacts"
  assert_json "$FINAL_STATUS" 'data["artifacts"]["petpack_source"].get("materialized_by_cli") is False' \
    || fail "strict full-source mode accepted a CLI-materialized petpack-source"
  assert_json "$FINAL_STATUS" 'data["artifacts"]["petpack_source"]["source_metadata"]["generator"] == "codex-app-server-skill" and data["artifacts"]["petpack_source"]["source_metadata"]["provenance"] == "skill-full-source"' \
    || fail "strict full-source mode did not produce trusted Skill provenance"
fi
if truthy "${APC_REQUIRE_EXTERNAL_SKILL_SOURCE:-1}"; then
  assert_json "$FINAL_STATUS" 'data["artifacts"]["petpack_source"]["generation_mode"] == "skill_full_source" and data["artifacts"]["petpack_source"]["real_skill_source"] is True and data["artifacts"]["petpack_source"].get("materializer") is None and data["artifacts"]["petpack_source"].get("skill_helper") != "agent-pet-studio-preview-helper-v2"' \
    || fail "external full-source mode accepted preview or internally materialized output"
fi

SOURCE_DIR="$TMP_DIR/home/generation-jobs/$JOB_ID/petpack-source"
if truthy "${APC_REQUIRE_EXTERNAL_SKILL_SOURCE:-1}"; then
  SOURCE_DIR="$SOURCE_DIR" python3 - <<'PY' || fail "external full-source visual semantics were not proven"
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["SOURCE_DIR"])
metadata = json.loads((root / "source/source.json").read_text(encoding="utf-8"))
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
assert metadata.get("generator") == "codex-app-server-skill"
assert metadata.get("provenance") == "skill-full-source"
assert metadata.get("visual_source") in {"image-generation", "user-reference-derived"}
assert metadata.get("preview_only") is False
native_fps = int(manifest["native_fps"])
assert native_fps in {10, 20}
durations = {state["name"]: int(state["duration_ms"]) for state in manifest["states"]}
assert set(durations) == {"idle", "start", "tool", "waiting", "review", "done", "failed"}
assert set(durations.values()) <= {1000, 2000}
expected_counts = {
    state: native_fps * duration_ms // 1000
    for state, duration_ms in durations.items()
}
assert metadata.get("native_fps") == native_fps
assert metadata.get("state_durations_ms") == durations
assert metadata.get("state_frame_counts") == expected_counts

first_frames = set()
for state in ["idle", "start", "tool", "waiting", "review", "done", "failed"]:
    frames = sorted((root / "assets/frames" / state).glob("*.png"))
    assert len(frames) == expected_counts[state]
    digests = {hashlib.sha256(path.read_bytes()).hexdigest() for path in frames}
    assert len(digests) >= 2
    first_frames.add(hashlib.sha256(frames[0].read_bytes()).hexdigest())
assert len(first_frames) >= 4
PY
fi
SOURCE_VALIDATION="$("$ROOT_DIR/target/debug/petcore-cli" petpack validate "$SOURCE_DIR")"
assert_json "$SOURCE_VALIDATION" 'data["ok"] is True and len(data["manifest"]["states"]) == 7' \
  || fail "built petpack-source validation failed"

SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'len(data["pets"]) == 1 and data["pets"][0]["active"] is True and data["pets"][0]["quality"] == "standard"' \
  || fail "completed pet was not imported and activated"
assert_json "$SNAPSHOT" 'data["pets"][0]["generator"] in ["codex-app-server-skill", "codex-app-server-brief-petpack-v1"] and data["pets"][0]["provenance"] in ["skill-full-source", "codex_app_server_brief"]' \
  || fail "imported pet does not preserve real App Server provenance"
if truthy "${APC_REQUIRE_SKILL_FULL_SOURCE:-1}"; then
  assert_json "$SNAPSHOT" 'data["pets"][0]["generator"] == "codex-app-server-skill" and data["pets"][0]["provenance"] == "skill-full-source"' \
    || fail "strict full-source imported pet does not preserve Skill provenance"
fi

if [[ -n "${APC_REAL_APP_SERVER_ARTIFACT_DIR:-}" ]]; then
  ARTIFACT_DIR="$APC_REAL_APP_SERVER_ARTIFACT_DIR"
  mkdir -p "$ARTIFACT_DIR"
  ditto "$TMP_DIR/home/generation-jobs/$JOB_ID" "$ARTIFACT_DIR/job"
  printf '%s\n' "$FINAL_STATUS" >"$ARTIFACT_DIR/final-status.json"
  printf '%s\n' "$SNAPSHOT" >"$ARTIFACT_DIR/snapshot.json"
  printf 'Preserved real App Server validation artifacts: %s\n' "$ARTIFACT_DIR"
fi

echo "Real Codex App Server validation ok"
