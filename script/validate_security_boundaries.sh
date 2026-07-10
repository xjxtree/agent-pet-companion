#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-security.XXXXXX")"
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

assert_no_secret() {
  local label="$1"
  local content="$2"
  if grep -q 'APC_SECRET_SENTINEL_' <<<"$content"; then
    echo "security boundary validation failed: $label leaked a fake agent secret" >&2
    printf '%s\n' "$content" >&2
    exit 1
  fi
}

assert_no_raw_alias() {
  local label="$1"
  local content="$2"
  if grep -Eq 'RAW_(TITLE|DETAIL|SOURCE_EVENT|TOOL_NAME|OUTCOME)_ALIAS_SENTINEL' <<<"$content"; then
    echo "security boundary validation failed: $label leaked an untrusted event alias" >&2
    printf '%s\n' "$content" >&2
    exit 1
  fi
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
allowed = {"__builtins__": {}, "data": data, "any": any, "all": all, "len": len, "str": str}
if not eval(expr, allowed, {}):
    raise SystemExit(f"assertion failed: {expr}\n{json.dumps(data, ensure_ascii=False, indent=2)}")
PY
}

cd "$ROOT_DIR"

set +e
STATIC_MATCHES="$(rg -n \
  '(read_to_string|std::fs::read|File::open|fs::read|NSData|Data\(|contentsOfFile|contentsOf:|open\().*(auth\.json|cookie|cookies|api[_-]?key|oauth|credential|credentials|secret|bearer)' \
  apps crates plugins skills script \
  -g '!target' \
  -g '!script/validate_security_boundaries.sh' 2>&1)"
STATIC_STATUS="$?"
set -e
if [[ "$STATIC_STATUS" == "0" ]]; then
  echo "security boundary validation failed: source contains a direct read/open of an agent secret-looking path" >&2
  printf '%s\n' "$STATIC_MATCHES" >&2
  exit 1
elif [[ "$STATIC_STATUS" != "1" ]]; then
  echo "security boundary validation failed: static scan could not run" >&2
  printf '%s\n' "$STATIC_MATCHES" >&2
  exit 1
fi

mkdir -p \
  "$TMP_DIR/agent-home/.codex" \
  "$TMP_DIR/agent-home/.claude" \
  "$TMP_DIR/agent-home/.pi/agent" \
  "$TMP_DIR/agent-home/.config/opencode" \
  "$TMP_DIR/home"

cat >"$TMP_DIR/agent-home/.codex/auth.json" <<'EOF'
{"token":"APC_SECRET_SENTINEL_CODEX_AUTH"}
EOF
cat >"$TMP_DIR/agent-home/.claude/oauth.json" <<'EOF'
{"access_token":"APC_SECRET_SENTINEL_CLAUDE_OAUTH"}
EOF
cat >"$TMP_DIR/agent-home/.pi/agent/token.json" <<'EOF'
{"token":"APC_SECRET_SENTINEL_PI_TOKEN"}
EOF
cat >"$TMP_DIR/agent-home/.config/opencode/cookies.json" <<'EOF'
{"cookie":"APC_SECRET_SENTINEL_OPENCODE_COOKIE"}
EOF

chmod 000 \
  "$TMP_DIR/agent-home/.codex/auth.json" \
  "$TMP_DIR/agent-home/.claude/oauth.json" \
  "$TMP_DIR/agent-home/.pi/agent/token.json" \
  "$TMP_DIR/agent-home/.config/opencode/cookies.json"

cargo build --workspace >/dev/null

(
  APC_HOME="$TMP_DIR/home" \
  APC_AGENT_CONFIG_HOME="$TMP_DIR/agent-home" \
  APC_CONNECTOR_CLI_PATH="$ROOT_DIR/target/debug/petcore-cli" \
  APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready"
) &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

for source in codex claude_code pi opencode; do
  REPAIR="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections repair --source "$source" 2>&1)"
  assert_no_secret "connections repair $source" "$REPAIR"
  assert_json "$REPAIR" 'data["source"] in ["codex", "claude_code", "pi", "opencode"]'

  CHECK="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections check --source "$source" 2>&1)"
  assert_no_secret "connections check $source" "$CHECK"
  assert_json "$CHECK" 'data["source"] in ["codex", "claude_code", "pi", "opencode"]'
done

SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot 2>&1)"
assert_no_secret "state snapshot" "$SNAPSHOT"
assert_json "$SNAPSHOT" 'all("APC_SECRET_SENTINEL_" not in str(item) for item in data.get("connections", []))'

SENSITIVE_PAYLOAD='{"source_event":"PostToolUse","tool_name":"shell","outcome":"completed","diagnostic":false,"prompt":"APC_SECRET_SENTINEL_EVENT_PROMPT","tool_input":{"command":"APC_SECRET_SENTINEL_EVENT_COMMAND","env":{"API_KEY":"APC_SECRET_SENTINEL_EVENT_API_KEY"}},"tool_response":{"output":"APC_SECRET_SENTINEL_EVENT_TOOL_RESPONSE"},"transcript_path":"/tmp/APC_SECRET_SENTINEL_EVENT_TRANSCRIPT.jsonl","output":"APC_SECRET_SENTINEL_EVENT_OUTPUT","token":"APC_SECRET_SENTINEL_EVENT_TOKEN","headers":{"Authorization":"Bearer APC_SECRET_SENTINEL_EVENT_AUTH"}}'
if REJECTED_INGEST="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest \
  --id evt_secret_redaction \
  --source codex \
  --event-type tool \
  --title 'curl --token APC_SECRET_SENTINEL_EVENT_TITLE' \
  --detail 'Authorization: Bearer APC_SECRET_SENTINEL_EVENT_DETAIL' \
  --payload-json "$SENSITIVE_PAYLOAD" 2>&1)"; then
  echo "security boundary validation failed: strict ingest accepted unknown sensitive payload fields" >&2
  exit 1
fi
assert_no_secret "rejected sensitive event ingest" "$REJECTED_INGEST"
grep -q 'payload field is not supported' <<<"$REJECTED_INGEST"

SAFE_ALIAS_PAYLOAD='{"source_event":"RAW_SOURCE_EVENT_ALIAS_SENTINEL","tool_name":"RAW_TOOL_NAME_ALIAS_SENTINEL","outcome":"RAW_OUTCOME_ALIAS_SENTINEL","diagnostic":false}'
INGEST="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest \
  --id evt_safe_alias_normalization \
  --source codex \
  --event-type tool \
  --title 'RAW_TITLE_ALIAS_SENTINEL' \
  --detail 'RAW_DETAIL_ALIAS_SENTINEL' \
  --payload-json "$SAFE_ALIAS_PAYLOAD" 2>&1)"
assert_no_raw_alias "normalized event ingest" "$INGEST"
assert_json "$INGEST" 'data["event"]["title"] == "执行工具" and data["event"]["detail"] is None and len(data["event"]["payload_json"]) == 6 and all(key in ["schema_version", "external_event_id", "source_event", "tool_name", "outcome", "diagnostic"] for key in data["event"]["payload_json"]) and data["event"]["payload_json"]["external_event_id"] == "evt_safe_alias_normalization" and data["event"]["payload_json"]["source_event"] == "unclassified" and data["event"]["payload_json"]["tool_name"] == "other" and data["event"]["payload_json"]["outcome"] == "unknown"'

RECENT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" events recent --limit 1 2>&1)"
assert_no_secret "events recent redaction" "$RECENT"
assert_no_raw_alias "events recent normalization" "$RECENT"
assert_json "$RECENT" 'data[0]["id"] == "evt_safe_alias_normalization" and data[0]["title"] == "执行工具" and data[0]["detail"] is None and len(data[0]["payload_json"]) == 6 and all(key in ["schema_version", "external_event_id", "source_event", "tool_name", "outcome", "diagnostic"] for key in data[0]["payload_json"])'

SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot 2>&1)"
assert_no_secret "state snapshot redaction" "$SNAPSHOT"
assert_no_raw_alias "state snapshot normalization" "$SNAPSHOT"
assert_json "$SNAPSHOT" 'all("APC_SECRET_SENTINEL_" not in str(item) for item in data.get("events", [])) and all(len(item["payload_json"]) == 6 and all(key in ["schema_version", "external_event_id", "source_event", "tool_name", "outcome", "diagnostic"] for key in item["payload_json"]) for item in data.get("events", []) + data.get("recent_events", []))'

TOKEN="$(cat "$TMP_DIR/home/run/update-token")"
[[ -n "$TOKEN" ]]
HEALTH="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" health 2>&1)"
assert_no_secret "health" "$HEALTH"
if grep -q "$TOKEN" <<<"$HEALTH"; then
  echo "security boundary validation failed: health output leaked the capability token" >&2
  printf '%s\n' "$HEALTH" >&2
  exit 1
fi

if [[ -d "$TMP_DIR/home/logs" ]]; then
  LOG_CONTENT="$(find "$TMP_DIR/home/logs" -maxdepth 1 -type f -exec cat {} + 2>/dev/null || true)"
  assert_no_secret "petcore logs" "$LOG_CONTENT"
  if grep -q "$TOKEN" <<<"$LOG_CONTENT"; then
    echo "security boundary validation failed: logs leaked the capability token" >&2
    printf '%s\n' "$LOG_CONTENT" >&2
    exit 1
  fi
fi

echo "Security boundary validation ok"
