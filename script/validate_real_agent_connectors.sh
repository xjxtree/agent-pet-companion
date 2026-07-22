#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SETTING="${APC_VALIDATE_REAL_AGENT_CONNECTORS:-0}"
TASK_SETTING="${APC_VALIDATE_REAL_AGENT_TASKS:-0}"
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

assert_current_runtime_identity() {
  local build_info health
  build_info="$("$PETCORE_CLI" build-info)"
  health="$("$PETCORE_CLI" health)"
  BUILD_INFO="$build_info" HEALTH="$health" python3 - <<'PY'
import json
import os
from pathlib import Path

build = json.loads(os.environ["BUILD_INFO"])
health = json.loads(os.environ["HEALTH"])
if health.get("build_id") != build.get("build_id"):
    raise SystemExit(
        f"daemon build_id {health.get('build_id')!r} does not match CLI build_id {build.get('build_id')!r}"
    )
if health.get("runtime_manifest") != build.get("runtime_manifest"):
    raise SystemExit("daemon runtime_manifest does not match this petcore-cli build")

path_keys = [
    "CODEX_HOME",
    "CLAUDE_CONFIG_DIR",
    "PI_CODING_AGENT_DIR",
    "OPENCODE_CONFIG_DIR",
    "OPENCODE_CONFIG",
    "XDG_CONFIG_HOME",
    "APC_CODEX_CLI_PATH",
    "APC_CLAUDE_CLI_PATH",
    "APC_PI_CLI_PATH",
    "APC_OPENCODE_CLI_PATH",
]

def absolute_value(value):
    if not value or not value.strip():
        return None
    value = os.path.expanduser(value.strip())
    if not os.path.isabs(value):
        return None
    return os.path.normpath(value)

expected = {"HOME": os.path.normpath(str(Path.home()))}
for key in path_keys:
    value = absolute_value(os.environ.get(key))
    if value is not None:
        expected[key] = value

actual = health.get("connector_environment")
if not isinstance(actual, dict):
    raise SystemExit("daemon health is missing connector_environment")
actual_identity = {key: value for key, value in actual.items() if key != "PATH"}
if actual_identity != expected:
    raise SystemExit(
        "daemon connector roots/CLI overrides do not match this validation environment: "
        f"actual={actual_identity!r}, expected={expected!r}"
    )
path = actual.get("PATH")
if not isinstance(path, str) or not path:
    raise SystemExit("daemon health is missing its effective executable PATH")
relative = [entry for entry in path.split(":") if entry and not os.path.isabs(entry)]
if relative:
    raise SystemExit(f"daemon executable PATH contains relative entries: {relative!r}")
PY
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

agent_command_available() {
  local command_name="$1"
  local override_key="$2"
  local override="${!override_key:-}"
  if [[ -n "$override" ]]; then
    [[ "$override" = /* && -x "$override" ]]
  else
    command_exists "$command_name"
  fi
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
        "Codex 版本",
        "本地事件 CLI",
        "插件源",
        "Hook",
        "Codex marketplace",
        "Codex 插件安装",
        "Codex Hook Trust",
        "事件回传",
        "PetCore 通道自检",
    },
    "claude_code": {
        "Claude CLI",
        "Claude Code 版本",
        "本地事件 CLI",
        "Hooks",
        "事件通道",
        "Claude settings.json",
        "Claude Hooks Policy",
        "Claude Hook 真实触发",
        "事件回传",
        "PetCore 通道自检",
    },
    "pi": {
        "Pi CLI",
        "Pi Coding Agent 版本",
        "本地事件 CLI",
        "Extension",
        "Extension 运行时",
        "事件回传",
        "PetCore 通道自检",
    },
    "opencode": {
        "OpenCode CLI",
        "OpenCode 版本",
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

claude_auth = {
    item.get("name"): item for item in by_source["claude_code"].get("items", [])
}.get("Claude 登录状态", {})
if claude_auth.get("status") not in {"ok", "not_required"}:
    failures.append(
        "claude_code: auth information must be ok/not_required; "
        f"got {claude_auth.get('status')} - {claude_auth.get('detail', '')}"
    )

opencode_server = {
    item.get("name"): item for item in by_source["opencode"].get("items", [])
}.get("OpenCode Server", {})
if opencode_server.get("status") != "not_required":
    failures.append("opencode: optional Server must report not_required in the standard check")

expected_contracts = {
    "codex": "codex-hooks-2026-07-17-schema-v6",
    "claude_code": "claude-hooks-2026-07-17-activity-v5",
    "pi": "pi-extension-0.80.10-activity-v7",
    "opencode": "opencode-v1.18.0-activity-v8",
}
expected_capability_counts = {
    "codex": (80, 11),
    "claude_code": (30, 27),
    "pi": (33, 33),
    "opencode": (112, 9),
}
for source, expected in expected_contracts.items():
    entry = by_source[source]
    verification = entry.get("verification", {})
    capabilities = entry.get("capabilities", {})
    expected_statuses = (
        {"verified"}
        if source == "codex"
        else {"unverified", "verified"}
    )
    if verification.get("status") not in expected_statuses:
        failures.append(
            f"{source}: agent-side verification is {verification.get('status')} - "
            f"{verification.get('detail', '')}"
        )
    if source != "codex":
        last_event = verification.get("last_event")
        if verification.get("status") == "verified" and (
            not isinstance(last_event, str) or last_event.endswith(" (canary)")
        ):
            failures.append(
                f"{source}: verified status lacks a current non-canary ordinary event"
            )
        if verification.get("status") == "unverified" and (
            not isinstance(last_event, str) or not last_event.endswith(" (canary)")
        ):
            failures.append(
                f"{source}: host_loaded-only status lacks the expected diagnostic canary receipt"
            )
    if capabilities.get("contract_version") != expected:
        failures.append(
            f"{source}: contract is {capabilities.get('contract_version')}, expected {expected}"
        )
    audited_count, subscribed_count = expected_capability_counts[source]
    if len(capabilities.get("audited_events", [])) != audited_count:
        failures.append(
            f"{source}: audited event count is "
            f"{len(capabilities.get('audited_events', []))}, expected {audited_count}"
        )
    if len(capabilities.get("subscribed_events", [])) != subscribed_count:
        failures.append(
            f"{source}: registered event count is "
            f"{len(capabilities.get('subscribed_events', []))}, expected {subscribed_count}"
        )

if failures:
    raise SystemExit("\n".join(failures))
PY
}

assert_current_real_agent_tasks() {
  local receipts
  receipts="$("$PETCORE_CLI" connections receipts)"
  RECEIPTS="$receipts" python3 - <<'PY'
import json
import os

entries = json.loads(os.environ["RECEIPTS"])
contracts = {
    "codex": "codex-hooks-2026-07-17-schema-v6",
    "claude_code": "claude-hooks-2026-07-17-activity-v5",
    "pi": "pi-extension-0.80.10-activity-v7",
    "opencode": "opencode-v1.18.0-activity-v8",
}
task_events = {
    "codex": (
        {"UserPromptSubmit"},
        {"PreToolUse"},
        {"PostToolUse", "Stop"},
    ),
    "claude_code": (
        {"UserPromptSubmit"},
        {"PreToolUse"},
        {"PostToolUse", "PostToolUseFailure", "PermissionDenied", "Stop", "StopFailure"},
    ),
    "pi": (
        {"input", "before_agent_start", "agent_start", "turn_start"},
        {"tool_call", "tool_execution_start"},
        {"tool_execution_end", "agent_settled"},
    ),
    "opencode": (
        {"message.user", "session.next.prompt.admitted"},
        {"tool.execute.before", "command.execute.before"},
        {
            "tool.execute.after", "command.execute.after", "message.assistant",
            "session.idle", "session.status", "session.error",
            "session.next.step.ended", "session.next.step.failed",
        },
    ),
}
failures = []
by_source = {entry.get("source"): entry for entry in entries}
for source, contract in contracts.items():
    task = (by_source.get(source) or {}).get("task") or {}
    receipt = task.get("receipt") or {}
    start = receipt.get("start") or {}
    activity = receipt.get("activity") or {}
    completion = receipt.get("completion") or {}
    allowed_start, allowed_activity, allowed_completion = task_events[source]
    if (
        task.get("current") is not True
        or start.get("diagnostic") is not False
        or activity.get("diagnostic") is not False
        or completion.get("diagnostic") is not False
        or start.get("contract_version") != contract
        or activity.get("contract_version") != contract
        or completion.get("contract_version") != contract
        or start.get("source_event") not in allowed_start
        or activity.get("source_event") not in allowed_activity
        or completion.get("source_event") not in allowed_completion
    ):
        failures.append(
            f"{source}: no same-session current task start/tool/completion evidence after all managed artifacts; got {task}"
        )

if failures:
    raise SystemExit("\n".join(failures))
PY
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
assert_current_runtime_identity

require_or_skip "codex command is not available" agent_command_available codex APC_CODEX_CLI_PATH
require_or_skip "claude command is not available" agent_command_available claude APC_CLAUDE_CLI_PATH
require_or_skip "pi command is not available" agent_command_available pi APC_PI_CLI_PATH
require_or_skip "opencode command is not available" agent_command_available opencode APC_OPENCODE_CLI_PATH

CODEX_HOOKS="$HOME/.agents/plugins/plugins/agent-pet-companion/hooks/hooks.json"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_EXTENSION="$PI_AGENT_DIR/extensions/agent-pet-companion.ts"
if [[ -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
  OPENCODE_CONFIG_ROOT="$OPENCODE_CONFIG_DIR"
else
  OPENCODE_CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
fi
OPENCODE_PLUGIN="$OPENCODE_CONFIG_ROOT/plugins/agent-pet-companion.js"

printf 'Checking current app connection diagnostics...\n'
for source in codex claude_code pi opencode; do
  "$PETCORE_CLI" connections repair --source "$source" --cwd "$ROOT_DIR" >/dev/null
done
require_or_skip "Codex hook file is missing after repair at $CODEX_HOOKS" test -f "$CODEX_HOOKS"
require_or_skip "Claude settings file is missing after repair at $CLAUDE_SETTINGS" test -f "$CLAUDE_SETTINGS"
require_or_skip "Pi extension file is missing after repair at $PI_EXTENSION" test -f "$PI_EXTENSION"
require_or_skip "OpenCode plugin file is missing after repair at $OPENCODE_PLUGIN" test -f "$OPENCODE_PLUGIN"
CONNECTIONS_JSON="$("$PETCORE_CLI" connections check --cwd "$ROOT_DIR")"
assert_real_connection_items_ok "$CONNECTIONS_JSON"

if is_truthy "$TASK_SETTING"; then
  printf 'Checking current-contract same-session task sequences emitted by real Agent tasks...\n'
  assert_current_real_agent_tasks
else
  printf 'Ordinary task-event evidence not required (set APC_VALIDATE_REAL_AGENT_TASKS=1 after running one real task in every Agent).\n'
fi

printf 'Real native-host connector validation ok (load canaries reached host_loaded; ordinary events and same-session prompt/tool/completion evidence remain separate gates).\n'
