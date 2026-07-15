#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-connectors.XXXXXX")"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"
export CLAUDE_CONFIG_DIR="$APC_AGENT_CONFIG_HOME/.claude"
PETCORE_PID=""
SIMULATED_AGENT_BIN="$TMP_DIR/simulated-agent-bin"
EXTRA_OUT="$TMP_DIR/connector-extra.out"
EXTRA_ERR="$TMP_DIR/connector-extra.err"

cleanup() {
  if [[ -n "$PETCORE_PID" ]]; then
    kill "$PETCORE_PID" >/dev/null 2>&1 || true
    wait "$PETCORE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$SIMULATED_AGENT_BIN"
for command_name in codex claude; do
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''simulated agent command\n'\''' \
    >"$SIMULATED_AGENT_BIN/$command_name"
  chmod +x "$SIMULATED_AGENT_BIN/$command_name"
done
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''Usage: pi --mode rpc\n'\''' \
  >"$SIMULATED_AGENT_BIN/pi"
chmod +x "$SIMULATED_AGENT_BIN/pi"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''opencode serve starts a headless opencode server\n'\''' \
  >"$SIMULATED_AGENT_BIN/opencode"
chmod +x "$SIMULATED_AGENT_BIN/opencode"

assert_recent_event() {
  local source="$1"
  local event_type="$2"
  local needle="$3"
  local events
  events="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" events recent --limit 80)"
  EVENTS="$events" SOURCE="$source" EVENT_TYPE="$event_type" NEEDLE="$needle" python3 - <<'PY'
import json
import os

events = json.loads(os.environ["EVENTS"])
source = os.environ["SOURCE"]
event_type = os.environ["EVENT_TYPE"]
needle = os.environ["NEEDLE"]

def contains(value, text):
    return text in json.dumps(value, ensure_ascii=False)

for event in events:
    if event.get("source") == source and event.get("event_type") == event_type and contains(event, needle):
        raise SystemExit(0)

raise SystemExit(
    f"missing runtime connector event source={source} event_type={event_type} needle={needle}\n"
    + json.dumps(events, ensure_ascii=False, indent=2)
)
PY
}

json_path() {
  local path="$1"
  local expr="$2"
  python3 - "$path" "$expr" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as file:
    data = json.load(file)
print(eval(sys.argv[2], {"__builtins__": {}}, {"data": data}))
PY
}

assert_json_expr() {
  local json="$1"
  local expr="$2"
  JSON="$json" python3 - "$expr" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON"])
expr = sys.argv[1]
if not eval(
    expr,
    {"__builtins__": {}, "all": all, "any": any, "isinstance": isinstance, "len": len, "list": list, "set": set},
    {"data": data}
):
    raise SystemExit(f"assertion failed: {expr}\n{json.dumps(data, ensure_ascii=False, indent=2)}")
PY
}

cd "$ROOT_DIR"
cargo build --workspace >/dev/null

(
  PATH="$SIMULATED_AGENT_BIN:$PATH" \
  APC_HOME="$TMP_DIR/home" \
  APC_AGENT_CONFIG_HOME="$TMP_DIR/agent-home" \
  APC_CONNECTOR_CLI_PATH="$ROOT_DIR/target/debug/petcore-cli" \
  APC_CONNECTOR_RUNTIME_SMOKE=1 \
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
  APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections repair --source "$source" >/dev/null
done

CHECK_CODEX="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections check codex)"
assert_json_expr "$CHECK_CODEX" 'data["source"] == "codex"'
CHECK_PI="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections check --source pi)"
assert_json_expr "$CHECK_PI" 'data["source"] == "pi"'
CHECK_ALL="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections check)"
assert_json_expr "$CHECK_ALL" 'isinstance(data, list) and {item["source"] for item in data} == {"codex", "claude_code", "pi", "opencode"}'
assert_json_expr "$CHECK_ALL" 'any(item["source"] == "opencode" and any(check["name"] == "OpenCode CLI" for check in item["items"]) and any(check["name"] == "OpenCode Server" for check in item["items"]) and len([check for check in item["items"] if check["name"] == "Server"]) == 0 for item in data)'
assert_json_expr "$CHECK_ALL" 'any(item["source"] == "pi" and any(check["name"] == "Extension 运行时" and check["status"] == "ok" for check in item["items"]) for item in data)'
assert_json_expr "$CHECK_ALL" 'any(item["source"] == "opencode" and any(check["name"] == "Plugin 运行时" and check["status"] == "ok" for check in item["items"]) for item in data)'
if APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections check --verbose >"$EXTRA_OUT" 2>"$EXTRA_ERR"; then
  cat "$EXTRA_OUT" >&2
  echo "connector runtime validation failed: unexpected connections argument was accepted" >&2
  exit 1
fi
grep -q "unexpected connections check argument" "$EXTRA_ERR"

CODEX_HOOKS="$TMP_DIR/agent-home/.agents/plugins/plugins/agent-pet-companion/hooks/hooks.json"
CODEX_START_CMD="$(json_path "$CODEX_HOOKS" 'data["hooks"]["SessionStart"][0]["hooks"][0]["command"]')"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"sess_runtime_codex","cwd":"/tmp/apc-codex-project"}' \
  | APC_HOME="$TMP_DIR/home" sh -c "$CODEX_START_CMD" >/dev/null
assert_recent_event codex start sess_runtime_codex

CLAUDE_SETTINGS="$TMP_DIR/agent-home/.claude/settings.json"
CLAUDE_TOOL_CMD="$(json_path "$CLAUDE_SETTINGS" 'data["hooks"]["PreToolUse"][0]["hooks"][0]["command"]')"
printf '%s\n' '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"sess_runtime_claude","cwd":"/tmp/apc-claude-project"}' \
  | APC_HOME="$TMP_DIR/home" sh -c "$CLAUDE_TOOL_CMD" >/dev/null
assert_recent_event claude_code tool sess_runtime_claude

CLAUDE_HELPER="$TMP_DIR/home/connectors/claude-code/agent-pet-companion-hook.sh"
APC_HOME="$TMP_DIR/home" APC_EVENT_TYPE=waiting APC_EVENT_TITLE=等待确认 "$CLAUDE_HELPER" >/dev/null
assert_recent_event claude_code waiting 等待确认

if command -v node >/dev/null 2>&1; then
  PI_MODULE="$TMP_DIR/pi-connector.mjs"
  cp "$TMP_DIR/agent-home/.pi/agent/extensions/agent-pet-companion.ts" "$PI_MODULE"
  APC_HOME="$TMP_DIR/home" node --input-type=module --eval "
const mod = await import('file://$PI_MODULE');
const handlers = new Map();
mod.default({ on: (name, callback) => handlers.set(name, callback) });
if (!handlers.has('tool_call')) throw new Error('Pi tool_call handler missing');
if (!handlers.has('session_start')) throw new Error('Pi session_start handler missing');
if (!handlers.has('before_agent_start')) throw new Error('Pi before_agent_start handler missing');
if (!handlers.has('tool_execution_end')) throw new Error('Pi tool_execution_end handler missing');
if (!handlers.has('message_end')) throw new Error('Pi message_end handler missing');
if (!handlers.has('agent_end')) throw new Error('Pi agent_end handler missing');
if (!handlers.has('agent_settled')) throw new Error('Pi agent_settled handler missing');
if (!handlers.has('session_before_compact')) throw new Error('Pi session_before_compact handler missing');
if (!handlers.has('session_compact')) throw new Error('Pi session_compact handler missing');
if (handlers.has('permission_request')) throw new Error('Pi invalid permission_request handler registered');
if (handlers.has('tool_execution_failed')) throw new Error('Pi invalid tool_execution_failed handler registered');
await handlers.get('before_agent_start')(
  { type: 'before_agent_start', prompt: 'Runtime prompt' },
  { sessionManager: { getSessionId: () => 'sess_runtime_pi_start' }, cwd: '/tmp/apc-pi-project' }
);
const messageContext = { sessionManager: { getSessionId: () => 'sess_runtime_pi_message' }, cwd: '/tmp/apc-pi-project' };
await handlers.get('message_end')(
  { type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: 'Pi runtime assistant response' }], stopReason: 'stop' } },
  messageContext
);
await handlers.get('agent_end')(
  { type: 'agent_end', messages: [{ role: 'assistant', content: [{ type: 'text', text: 'Pi runtime assistant response' }], stopReason: 'stop' }] },
  messageContext
);
await handlers.get('agent_settled')(
  { type: 'agent_settled' },
  messageContext
);
await handlers.get('tool_call')(
  { type: 'tool_call', toolName: 'bash', toolCallId: 'secret-call', input: { command: 'TOKEN=secret-command' } },
  { sessionManager: { getSessionId: () => 'sess_runtime_pi' }, cwd: '/tmp/apc-pi-project' }
);
await handlers.get('tool_execution_end')(
  { type: 'tool_execution_end', toolName: 'bash', toolCallId: 'secret-call', result: 'secret-output', isError: true },
  { sessionManager: { getSessionId: () => 'sess_runtime_pi_failed' }, cwd: '/tmp/apc-pi-project' }
);
await handlers.get('agent_settled')(
  { type: 'agent_settled' },
  { sessionManager: { getSessionId: () => 'sess_runtime_pi_done' }, cwd: '/tmp/apc-pi-project' }
);
await handlers.get('agent_end')(
  { type: 'agent_end', messages: [{ role: 'assistant', stopReason: 'error', content: [] }] },
  { sessionManager: { getSessionId: () => 'sess_runtime_pi_agent_error' }, cwd: '/tmp/apc-pi-project' }
);
await handlers.get('agent_settled')(
  { type: 'agent_settled' },
  { sessionManager: { getSessionId: () => 'sess_runtime_pi_agent_error' }, cwd: '/tmp/apc-pi-project' }
);
await new Promise((resolve) => setTimeout(resolve, 700));
"
  assert_recent_event pi start sess_runtime_pi_start
  assert_recent_event pi done 'Pi runtime assistant response'
  assert_recent_event pi tool sess_runtime_pi
  assert_recent_event pi tool sess_runtime_pi_failed
  assert_recent_event pi done sess_runtime_pi_done
  assert_recent_event pi failed sess_runtime_pi_agent_error

  OPENCODE_MODULE="$TMP_DIR/opencode-connector.mjs"
  cp "$TMP_DIR/agent-home/.config/opencode/plugins/agent-pet-companion.js" "$OPENCODE_MODULE"
  APC_HOME="$TMP_DIR/home" node --input-type=module --eval "
const mod = await import('file://$OPENCODE_MODULE');
const plugin = await mod.AgentPetCompanion({
  project: 'demo',
  directory: '/tmp/apc-opencode-project',
  worktree: '/tmp/apc-opencode-worktree'
});
if (!plugin['tool.execute.before']) throw new Error('OpenCode tool.execute.before handler missing');
if (!plugin['tool.execute.after']) throw new Error('OpenCode tool.execute.after handler missing');
if (!plugin.event) throw new Error('OpenCode generic event handler missing');
await plugin.event({ event: { type: 'session.created', properties: { info: { id: 'sess_runtime_opencode_start' } } } });
await plugin.event({ event: { type: 'permission.updated', properties: { sessionID: 'sess_runtime_opencode_waiting' } } });
await plugin['tool.execute.before'](
  { tool: 'bash', sessionID: 'sess_runtime_opencode_tool', callID: 'secret-call' },
  { args: { command: 'TOKEN=secret-command' } }
);
await plugin['tool.execute.after'](
  { tool: 'bash', sessionID: 'sess_runtime_opencode_tool', callID: 'secret-call', args: { command: 'TOKEN=secret-command' } },
  { title: 'Bash', output: 'secret-output', metadata: {} }
);
await plugin.event({ event: { type: 'session.error', properties: { sessionID: 'sess_runtime_opencode_failed', error: { message: 'secret-error' } } } });
await plugin.event({ event: { type: 'session.idle', properties: { sessionID: 'sess_runtime_opencode_done' } } });
await new Promise((resolve) => setTimeout(resolve, 700));
"
  assert_recent_event opencode start sess_runtime_opencode_start
  assert_recent_event opencode waiting sess_runtime_opencode_waiting
  assert_recent_event opencode tool sess_runtime_opencode_tool
  assert_recent_event opencode failed sess_runtime_opencode_failed
  assert_recent_event opencode done sess_runtime_opencode_done
  OPENCODE_EVENTS="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" events recent --limit 80)"
  EVENTS="$OPENCODE_EVENTS" python3 - <<'PY'
import json
import os

events = json.loads(os.environ["EVENTS"])
matching = [
    event for event in events
    if event.get("source") == "opencode"
    and event.get("event_type") == "start"
    and event.get("session_id") == "sess_runtime_opencode_start"
]
assert matching and matching[0].get("session_id") == "sess_runtime_opencode_start", matching
serialized = json.dumps(events, ensure_ascii=False)
for forbidden in ["TOKEN=secret-command", "secret-output", "secret-error", "secret-call"]:
    assert forbidden not in serialized, forbidden
PY
else
  echo "Skipping Pi/OpenCode Node connector runtime smoke; node is not available"
fi

for source in codex claude_code pi opencode; do
  APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections uninstall --source "$source" >/dev/null
done
CHECK_AFTER_UNINSTALL="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections check)"
assert_json_expr "$CHECK_AFTER_UNINSTALL" 'all(not any(check["name"] in {"插件源", "Hook", "Pet Studio Skill", "Codex marketplace", "Codex 插件安装", "Hooks", "事件通道", "Claude settings.json", "Extension", "Extension 运行时", "Plugin", "Plugin 运行时"} and check["status"] == "ok" for check in item["items"]) for item in data)'

echo "Connector runtime validation ok"
