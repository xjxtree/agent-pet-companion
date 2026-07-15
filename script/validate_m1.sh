#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-m1.XXXXXX")"
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
grep -q 'func presentMainWindow' "$ROOT_DIR/apps/macos/Sources/AgentPetCompanion/App/AppStore.swift"
grep -q 'openWindow(id: "main")' "$ROOT_DIR/apps/macos/Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
grep -q 'store.presentMainWindow()' "$ROOT_DIR/apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"

OUT="$(APC_LAUNCH_AGENT_DIR="$TMP_DIR/LaunchAgents" "$ROOT_DIR/target/debug/petcore-cli" launch-agent install --no-load --program "$ROOT_DIR/target/debug/petcore" --home "$TMP_DIR/home")"
grep -q '"installed": true' <<<"$OUT"
grep -q '<key>KeepAlive</key>' "$TMP_DIR/LaunchAgents/dev.agentpet.petcore.plist"
OUT="$(APC_LAUNCH_AGENT_DIR="$TMP_DIR/LaunchAgents" "$ROOT_DIR/target/debug/petcore-cli" launch-agent uninstall --no-load)"
grep -q '"installed": false' <<<"$OUT"

(APC_HOME="$TMP_DIR/home" APC_DISABLE_CODEX_APP_SERVER_AUTO=1 "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready") &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" health)"
grep -q '"ok": true' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" behavior get)"
grep -q '"enabled": true' <<<"$OUT"

PORT="$(cat "$TMP_DIR/home/run/http-port")"
TOKEN="$(cat "$TMP_DIR/home/run/update-token")"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"start","title":"开始处理"}')"
[[ "$HTTP_CODE" == "401" ]]
OUT="$(curl -s -H "X-Agent-Pet-Token: $TOKEN" -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"start","title":"开始处理"}')"
grep -q '"triggered":true' <<<"$OUT"
OUT="$(curl -s -H "X-Agent-Pet-Token: $TOKEN" -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"id":"evt_m1_payload_alias","source":"codex","event_type":"tool","title":"不可信兼容文案","detail":"不可信兼容详情","payload_json":{"schema_version":"apc.agent-event.v1","external_event_id":"evt_m1_payload_alias","source_event":"connection.test","tool_name":"Bash","outcome":"started","diagnostic":true}}')"
python3 - "$OUT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["inserted"] is True, data
assert data["event"]["title"] == "执行工具", data
assert data["event"]["detail"] is None, data
assert data["event"]["payload_json"] == {
    "schema_version": "apc.agent-event.v1",
    "external_event_id": "evt_m1_payload_alias",
    "source_event": "connection.test",
    "tool_name": "shell",
    "outcome": "started",
    "diagnostic": True,
    "turn_id": None,
    "session_active": False,
    "message_role": None,
    "message_content": None,
    "activity_kind": None,
    "activity_content": None,
    "interaction_kind": None,
    "project_label": None,
    "session_title": None,
    "session_open": None,
    "session_surface": None,
    "terminal_app": None,
    "session_open_url": None,
}, data
PY
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Agent-Pet-Token: $TOKEN" -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"tool","payload":["bad"]}')"
[[ "$HTTP_CODE" == "400" ]]
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Agent-Pet-Token: $TOKEN" -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"tool","extra":true}')"
[[ "$HTTP_CODE" == "400" ]]
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
grep -q '"events"' <<<"$OUT"

echo "M1 validation ok"
