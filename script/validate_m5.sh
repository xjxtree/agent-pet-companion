#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-m5.XXXXXX")"
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

cd "$ROOT_DIR"
cargo build --workspace >/dev/null
(APC_HOME="$TMP_DIR/home" APC_DISABLE_CODEX_APP_SERVER_AUTO=1 "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready") &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

"$ROOT_DIR/target/debug/petcore-cli" petpack sample --output "$TMP_DIR/pet" --quality high --frames 1 >/dev/null
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack import "$TMP_DIR/pet")"
grep -q '"active": true' <<<"$OUT"

BEHAVIOR='{"enabled":false,"status_bubble":true,"click_menu":true,"mouse_passthrough":false,"auto_hide":true,"fps_profile":"smooth","sources":{"codex":false,"claude_code":true,"pi":true,"opencode":true},"events":{"start":true,"tool":false,"waiting":true,"review":true,"done":true,"failed":true}}'
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" behavior set-json --value-json "$BEHAVIOR")"
grep -q '"enabled": false' <<<"$OUT"
grep -q '"auto_hide": true' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id evt_filtered_source --source codex --event-type start --title 开始处理)"
grep -q '"triggered": false' <<<"$OUT"
HOOK_OUT="$(printf 'plain hook stdin token=must-not-be-stored' | APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent hook --source claude_code --event-type start --title 开始处理)"
HOOK_OUT="$HOOK_OUT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["HOOK_OUT"])
payload = data["event"]["payload_json"]
assert data["ok"] is True
assert data["event"]["title"] == "开始处理"
assert data["event"]["detail"] is None
assert set(payload) == {"schema_version", "external_event_id", "source_event", "tool_name", "outcome", "diagnostic"}
assert payload["source_event"] == "start"
assert payload["tool_name"] is None
assert payload["outcome"] is None
assert payload["diagnostic"] is False
assert "must-not-be-stored" not in json.dumps(payload, ensure_ascii=False)
PY
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" behavior get)"
grep -q '"fps_profile": "smooth"' <<<"$OUT"

PET_LIBRARY_VIEW="$ROOT_DIR/apps/macos/Sources/AgentPetCompanion/Views/PetLibraryView.swift"
grep -q 'confirmationDialog' "$PET_LIBRARY_VIEW"
grep -q 'pendingDeletePet' "$PET_LIBRARY_VIEW"
if grep -q 'Button("删除".*store.deletePet(pet)' "$PET_LIBRARY_VIEW"; then
  echo "PetLibraryView delete action must go through confirmation" >&2
  exit 1
fi

echo "M5 validation ok"
