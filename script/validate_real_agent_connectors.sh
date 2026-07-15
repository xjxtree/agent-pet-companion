#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SETTING="${APC_VALIDATE_REAL_AGENT_CONNECTORS:-0}"
RUN_ID="real_agent_$(date -u +%Y%m%dT%H%M%SZ)_$$"
PETCORE_CLI="${APC_REAL_AGENT_VALIDATE_CLI:-$ROOT_DIR/target/debug/petcore-cli}"

is_truthy() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_disabled() {
  case "$1" in
    0|false|FALSE|no|NO|off|OFF) return 0 ;;
    *) return 1 ;;
  esac
}

skip() {
  printf 'Skipping real agent connector validation: %s\n' "$1"
  exit 0
}

fail() {
  printf 'Real agent connector validation failed: %s\n' "$1" >&2
  exit 1
}

require_or_skip() {
  local description="$1"
  shift
  if "$@"; then
    return 0
  fi
  if is_truthy "$SETTING"; then
    fail "$description"
  fi
  skip "$description"
}

petcore_health_ok() {
  "$PETCORE_CLI" health >/dev/null
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
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

assert_real_connection_items_ok() {
  local raw="$1"
  RAW="$raw" python3 - <<'PY'
import json
import os
import sys

required = {
    "codex": {
        "Codex CLI",
        "本地事件 CLI",
        "插件源",
        "Hook",
        "Codex marketplace",
        "Codex 插件安装",
        "事件回传",
        "PetCore 通道自检",
    },
    "claude_code": {
        "Claude CLI",
        "本地事件 CLI",
        "Hooks",
        "事件通道",
        "Claude settings.json",
        "事件回传",
        "PetCore 通道自检",
    },
    "pi": {
        "Pi CLI",
        "本地事件 CLI",
        "Extension",
        "Extension 运行时",
        "事件回传",
        "PetCore 通道自检",
    },
    "opencode": {
        "OpenCode CLI",
        "本地事件 CLI",
        "Plugin",
        "Plugin 运行时",
        "事件回传",
        "PetCore 通道自检",
    },
}

try:
    data = json.loads(os.environ["RAW"])
except Exception as error:
    print(f"connections check did not return JSON: {error}", file=sys.stderr)
    print(os.environ["RAW"], file=sys.stderr)
    raise SystemExit(1)

by_source = {entry.get("source"): entry for entry in data}
missing_sources = sorted(set(required) - set(by_source))
if missing_sources:
    raise SystemExit(f"missing connection sources: {', '.join(missing_sources)}")

failures = []
for source, names in required.items():
    item_by_name = {item.get("name"): item for item in by_source[source].get("items", [])}
    for name in sorted(names):
        item = item_by_name.get(name)
        if not item:
            failures.append(f"{source}: missing check {name}")
            continue
        if item.get("status") != "ok":
            failures.append(
                f"{source}: {name} is {item.get('status')} - {item.get('detail', '')}"
            )

opencode_server = {
    item.get("name"): item for item in by_source["opencode"].get("items", [])
}.get("OpenCode Server", {})
if opencode_server.get("status") != "not_required":
    failures.append("opencode: optional Server must report not_required in the standard check")

codex_trust = {
    item.get("name"): item for item in by_source["codex"].get("items", [])
}.get("Codex Hook Trust", {})
if codex_trust.get("status") not in {"ok", "unverified"}:
    failures.append("codex: Hook Trust must be verified or explicitly unverified")

if failures:
    raise SystemExit("\n".join(failures))
PY
}

assert_recent_event() {
  local source="$1"
  local event_type="$2"
  local needle="$3"
  local events

  for _ in {1..40}; do
    events="$("$PETCORE_CLI" events recent --limit 240)"
    if EVENTS="$events" SOURCE="$source" EVENT_TYPE="$event_type" NEEDLE="$needle" python3 - <<'PY'
import json
import os
import sys

events = json.loads(os.environ["EVENTS"])
source = os.environ["SOURCE"]
event_type = os.environ["EVENT_TYPE"]
needle = os.environ["NEEDLE"]

def contains(value, text):
    return text in json.dumps(value, ensure_ascii=False)

for event in events:
    if (
        event.get("source") == source
        and event.get("event_type") == event_type
        and contains(event, needle)
    ):
        raise SystemExit(0)

raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 0.15
  done

  events="$("$PETCORE_CLI" events recent --limit 80)"
  printf 'Recent events:\n%s\n' "$events" >&2
  fail "missing event source=$source event_type=$event_type needle=$needle"
}

if is_disabled "$SETTING"; then
  skip "APC_VALIDATE_REAL_AGENT_CONNECTORS=$SETTING explicitly disables it"
fi
if ! is_truthy "$SETTING"; then
  skip "APC_VALIDATE_REAL_AGENT_CONNECTORS=$SETTING is not an explicit opt-in; use 1"
fi

require_or_skip "real connector validation is only supported on macOS/Darwin" \
  test "$(uname -s)" = "Darwin"

if [[ ! -x "$PETCORE_CLI" ]]; then
  if command -v cargo >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && cargo build -p petcore-cli >/dev/null)
  fi
fi
require_or_skip "petcore-cli is not built at $PETCORE_CLI" test -x "$PETCORE_CLI"
require_or_skip "current PetCore daemon is not reachable; run ./script/build_and_run.sh --verify first" \
  petcore_health_ok

for command in codex claude pi opencode node; do
  require_or_skip "$command command is not available" command_exists "$command"
done

CODEX_HOOKS="$HOME/.agents/plugins/plugins/agent-pet-companion/hooks/hooks.json"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
PI_EXTENSION="$HOME/.pi/agent/extensions/agent-pet-companion.ts"
OPENCODE_PLUGIN="$HOME/.config/opencode/plugins/agent-pet-companion.js"

require_or_skip "Codex hook file is missing at $CODEX_HOOKS" test -f "$CODEX_HOOKS"
require_or_skip "Claude settings file is missing at $CLAUDE_SETTINGS" test -f "$CLAUDE_SETTINGS"
require_or_skip "Pi extension file is missing at $PI_EXTENSION" test -f "$PI_EXTENSION"
require_or_skip "OpenCode plugin file is missing at $OPENCODE_PLUGIN" test -f "$OPENCODE_PLUGIN"

printf 'Checking current app connection diagnostics...\n'
CONNECTIONS_JSON="$("$PETCORE_CLI" connections check)"
assert_real_connection_items_ok "$CONNECTIONS_JSON"

printf 'Running explicit bounded OpenCode /global/health probe...\n'
OPENCODE_SERVER_PROBE="$("$PETCORE_CLI" connections probe-opencode-server)"
RAW="$OPENCODE_SERVER_PROBE" python3 - <<'PY'
import json
import os

probe = json.loads(os.environ["RAW"])
assert probe.get("status") == "ok", probe
assert "runtime_verified" in probe.get("detail", ""), probe
PY

printf 'Sending diagnostic Codex hook event through installed user hook...\n'
CODEX_START_CMD="$(json_path "$CODEX_HOOKS" 'data["hooks"]["SessionStart"][0]["hooks"][0]["command"]')"
printf '%s\n' "{\"hook_event_name\":\"SessionStart\",\"session\":{\"id\":\"$RUN_ID-codex\"},\"session_id\":\"$RUN_ID-codex\",\"cwd\":\"$ROOT_DIR\",\"diagnostic\":true,\"title\":\"真实连接验收\"}" \
  | sh -c "$CODEX_START_CMD" >/dev/null
assert_recent_event codex start "$RUN_ID-codex"

printf 'Sending diagnostic Claude hook event through installed settings command...\n'
CLAUDE_TOOL_CMD="$(json_path "$CLAUDE_SETTINGS" 'data["hooks"]["PreToolUse"][0]["hooks"][0]["command"]')"
printf '%s\n' "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$RUN_ID-claude\",\"cwd\":\"$ROOT_DIR\",\"diagnostic\":true,\"title\":\"真实连接验收\"}" \
  | sh -c "$CLAUDE_TOOL_CMD" >/dev/null
assert_recent_event claude_code tool "$RUN_ID-claude"

printf 'Loading real Pi extension from the user extension directory...\n'
PI_MODULE="$TMP_DIR/pi-connector.mjs"
cp "$PI_EXTENSION" "$PI_MODULE"
PI_CONNECTOR_MODULE="$PI_MODULE" RUN_ID="$RUN_ID" ROOT_DIR="$ROOT_DIR" node --input-type=module <<'NODE'
import { pathToFileURL } from 'node:url';

const mod = await import(pathToFileURL(process.env.PI_CONNECTOR_MODULE).href);
const handlers = new Map();
mod.default({ on: (name, callback) => handlers.set(name, callback) });

for (const name of ['session_start', 'before_agent_start', 'message_end', 'tool_call', 'tool_execution_end', 'agent_end', 'agent_settled', 'session_shutdown']) {
  if (!handlers.has(name)) {
    throw new Error(`Pi ${name} handler missing`);
  }
}

await handlers.get('session_start')(
  { type: 'session_start', reason: 'startup', diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-start` }, cwd: process.env.ROOT_DIR }
);
await handlers.get('before_agent_start')(
  { type: 'before_agent_start', prompt: '真实 Pi 用户消息', diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-prompt`, getSessionName: () => '真实 Pi 会话' }, cwd: process.env.ROOT_DIR }
);
await handlers.get('tool_call')(
  { type: 'tool_call', toolName: 'bash', toolCallId: 'secret-call', input: { command: 'TOKEN=secret-command' }, diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-tool` }, cwd: process.env.ROOT_DIR }
);
await handlers.get('tool_execution_end')(
  { type: 'tool_execution_end', toolName: 'bash', toolCallId: 'secret-call', result: 'secret-output', isError: true, diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-failed` }, cwd: process.env.ROOT_DIR }
);
await handlers.get('agent_settled')(
  { type: 'agent_settled', diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-done` }, cwd: process.env.ROOT_DIR }
);
const replyContext = { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-reply`, getSessionName: () => '真实 Pi 会话' }, cwd: process.env.ROOT_DIR };
await handlers.get('before_agent_start')(
  { type: 'before_agent_start', prompt: '请回复真实 Pi 消息', diagnostic: true },
  replyContext
);
await handlers.get('message_end')(
  { type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: '真实 Pi Agent 回复' }], stopReason: 'stop' }, diagnostic: true },
  replyContext
);
await handlers.get('agent_end')(
  { type: 'agent_end', messages: [{ role: 'assistant', content: [{ type: 'text', text: '真实 Pi Agent 回复' }], stopReason: 'stop' }], diagnostic: true },
  replyContext
);
await handlers.get('agent_settled')(
  { type: 'agent_settled', diagnostic: true },
  replyContext
);
await handlers.get('agent_end')(
  { type: 'agent_end', messages: [{ role: 'assistant', stopReason: 'error', content: [] }], diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-agent-error`, getSessionName: () => '真实 Pi 错误会话' }, cwd: process.env.ROOT_DIR }
);
await handlers.get('agent_settled')(
  { type: 'agent_settled', diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-agent-error`, getSessionName: () => '真实 Pi 错误会话' }, cwd: process.env.ROOT_DIR }
);
await handlers.get('session_shutdown')(
  { type: 'session_shutdown', reason: 'quit', diagnostic: true },
  { sessionManager: { getSessionId: () => `${process.env.RUN_ID}-pi-closed`, getSessionName: () => '真实 Pi 会话' }, cwd: process.env.ROOT_DIR }
);
await new Promise((resolve) => setTimeout(resolve, 800));
NODE
# Merely opening/resuming a Pi page is intentionally ignored: it does not
# prove that an Agent turn is active and must not create a misleading bubble.
assert_recent_event pi start "$RUN_ID-pi-prompt"
assert_recent_event pi tool "$RUN_ID-pi-tool"
assert_recent_event pi tool "$RUN_ID-pi-failed"
assert_recent_event pi done "$RUN_ID-pi-done"
assert_recent_event pi done "$RUN_ID-pi-reply"
assert_recent_event pi failed "$RUN_ID-pi-agent-error"
assert_recent_event pi done "$RUN_ID-pi-closed"

printf 'Loading real OpenCode plugin from the user plugin directory...\n'
OPENCODE_MODULE="$TMP_DIR/opencode-connector.mjs"
cp "$OPENCODE_PLUGIN" "$OPENCODE_MODULE"
OPENCODE_CONNECTOR_MODULE="$OPENCODE_MODULE" RUN_ID="$RUN_ID" ROOT_DIR="$ROOT_DIR" node --input-type=module <<'NODE'
import { pathToFileURL } from 'node:url';

const mod = await import(pathToFileURL(process.env.OPENCODE_CONNECTOR_MODULE).href);
const plugin = await mod.AgentPetCompanion({
  project: 'agent-pet-companion',
  directory: process.env.ROOT_DIR,
  worktree: process.env.ROOT_DIR,
});

if (!plugin.event) {
  throw new Error('OpenCode generic event handler missing');
}

await plugin.event({
  event: {
    type: 'session.created',
    properties: { info: { id: `${process.env.RUN_ID}-opencode-start`, diagnostic: true } },
  },
});
await plugin.event({
  event: {
    type: 'permission.updated',
    properties: { sessionID: `${process.env.RUN_ID}-opencode-waiting`, diagnostic: true },
  },
});
await plugin['tool.execute.before'](
  { tool: 'bash', sessionID: `${process.env.RUN_ID}-opencode-tool`, callID: 'secret-call', diagnostic: true },
  { args: { command: 'TOKEN=secret-command' } },
);
await plugin.event({
  event: {
    type: 'session.idle',
    properties: { sessionID: `${process.env.RUN_ID}-opencode-done`, diagnostic: true },
  },
});
await new Promise((resolve) => setTimeout(resolve, 800));
NODE
assert_recent_event opencode start "$RUN_ID-opencode-start"
assert_recent_event opencode waiting "$RUN_ID-opencode-waiting"
assert_recent_event opencode tool "$RUN_ID-opencode-tool"
assert_recent_event opencode done "$RUN_ID-opencode-done"

printf 'Real agent connector validation ok: %s\n' "$RUN_ID"
