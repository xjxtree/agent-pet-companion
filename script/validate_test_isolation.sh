#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-test-isolation.XXXXXX")"
SHIM_DIR="$TMP_DIR/shims"
FORBIDDEN_LOG="$TMP_DIR/forbidden.log"
FAILURES=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

record_failure() {
  printf 'test isolation validation failed: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

write_executable() {
  local path="$1"
  shift
  printf '%s\n' "$@" >"$path"
  chmod +x "$path"
}

mkdir -p "$SHIM_DIR"
: >"$FORBIDDEN_LOG"

for command_name in launchctl pkill killall open osascript codex claude pi opencode; do
  write_executable "$SHIM_DIR/$command_name" \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$(basename "$0")" >>"$APC_ISOLATION_FORBIDDEN_LOG"' \
    'exit 97'
done

write_executable "$SHIM_DIR/uname" \
  '#!/usr/bin/env bash' \
  'printf '\''Darwin\n'\'''
write_executable "$SHIM_DIR/cargo" \
  '#!/usr/bin/env bash' \
  'if [[ -n "${APC_BUILD_ENV_LOG:-}" ]]; then' \
  '  printf '\''%s\t%s\t%s\t%s\n'\'' "$HOME" "${XDG_CONFIG_HOME:-}" "${APC_AGENT_CONFIG_HOME:-}" "${APC_HOME:-}" >>"$APC_BUILD_ENV_LOG"' \
  'fi' \
  'exit 0'
write_executable "$SHIM_DIR/swift" \
  '#!/usr/bin/env bash' \
  'if [[ " $* " == *" --show-bin-path "* ]]; then' \
  '  printf '\''%s\n'\'' "$APC_FAKE_SWIFT_BIN"' \
  'fi' \
  'exit 0'

# Exercise build-only against a complete throwaway workspace. This catches
# commands executed before argument parsing without compiling the real project.
BUILD_ROOT="$TMP_DIR/build-workspace"
FAKE_SWIFT_BIN="$TMP_DIR/fake-swift-bin"
mkdir -p \
  "$BUILD_ROOT/script" \
  "$BUILD_ROOT/apps/macos" \
  "$BUILD_ROOT/target/debug" \
  "$BUILD_ROOT/skills/agent-pet-studio/scripts/__pycache__" \
  "$FAKE_SWIFT_BIN"
cp "$ROOT_DIR/script/build_and_run.sh" "$BUILD_ROOT/script/build_and_run.sh"
cp "$ROOT_DIR/script/validation_helpers.sh" "$BUILD_ROOT/script/validation_helpers.sh"
if [[ -f "$ROOT_DIR/script/build_app_bundle.sh" ]]; then
  cp "$ROOT_DIR/script/build_app_bundle.sh" "$BUILD_ROOT/script/build_app_bundle.sh"
fi
write_executable "$BUILD_ROOT/script/validate_app_bundle.sh" \
  '#!/usr/bin/env bash' \
  'exit 0'
for binary in \
  "$BUILD_ROOT/target/debug/petcore" \
  "$BUILD_ROOT/target/debug/petcore-cli" \
  "$FAKE_SWIFT_BIN/AgentPetCompanion"; do
  write_executable "$binary" '#!/usr/bin/env bash' 'exit 0'
done
printf '%s\n' 'name: agent-pet-studio' >"$BUILD_ROOT/skills/agent-pet-studio/SKILL.md"
printf '%s\n' 'cache sentinel' >"$BUILD_ROOT/skills/agent-pet-studio/scripts/__pycache__/sentinel.pyc"

BUILD_TMP="$TMP_DIR/build-tmp"
BUILD_ENV_LOG="$TMP_DIR/build-env.log"
mkdir -p "$BUILD_TMP"
: >"$BUILD_ENV_LOG"
if ! HOME="$TMP_DIR/outside-build-home" \
  XDG_CONFIG_HOME="$TMP_DIR/outside-build-xdg" \
  APC_AGENT_CONFIG_HOME="$TMP_DIR/outside-build-agent" \
  APC_HOME="$TMP_DIR/outside-build-apc" \
  TMPDIR="$BUILD_TMP" \
  PATH="$SHIM_DIR:$PATH" \
  APC_ISOLATION_FORBIDDEN_LOG="$FORBIDDEN_LOG" \
  APC_BUILD_ENV_LOG="$BUILD_ENV_LOG" \
  APC_FAKE_SWIFT_BIN="$FAKE_SWIFT_BIN" \
  "$BUILD_ROOT/script/build_and_run.sh" --build-only >/dev/null 2>&1; then
  record_failure 'build_and_run.sh --build-only did not complete in the isolated fixture'
fi
if [[ "$(wc -l <"$BUILD_ENV_LOG" | tr -d ' ')" != "1" ]]; then
  record_failure 'build-only did not execute its injected build dependency exactly once'
else
  build_environment="$(tail -n 1 "$BUILD_ENV_LOG")"
  IFS=$'\t' read -r build_home build_xdg build_agent_home build_apc_home <<<"$build_environment"
  for observed in "$build_home" "$build_xdg" "$build_agent_home" "$build_apc_home"; do
    if [[ "$observed" != "$BUILD_TMP"/* ]]; then
      record_failure "build-only exposed a non-temporary user path before build: $build_environment"
      break
    fi
  done
fi
if [[ -s "$FORBIDDEN_LOG" ]]; then
  record_failure "build-only invoked forbidden host commands: $(tr '\n' ' ' <"$FORBIDDEN_LOG")"
fi
if grep -q 'MODE="${1:-run}"' "$ROOT_DIR/script/build_and_run.sh"; then
  record_failure 'build_and_run.sh still defaults to the GUI-launching run mode'
fi

# Run test_all from a mirror whose validation steps are inert. A Darwin shim
# makes this deterministic even when the validator itself runs on Linux.
TEST_ROOT="$TMP_DIR/test-workspace"
mkdir -p "$TEST_ROOT/script"
cp "$ROOT_DIR/script/test_all.sh" "$TEST_ROOT/script/test_all.sh"
cp "$ROOT_DIR/script/validation_helpers.sh" "$TEST_ROOT/script/validation_helpers.sh"
for script_name in \
  validate_test_isolation.sh validate_schema_fixtures.sh \
  validate_build_scripts_safety.sh validate_source_syntax.sh build_app_bundle.sh \
  validate_m0.sh validate_m1.sh validate_m2.sh validate_m3.sh \
  validate_m4.sh validate_m5.sh validate_m6.sh validate_v1.sh \
  validate_connectors_runtime.sh validate_event_storm.sh \
  validate_security_boundaries.sh validate_overlay_offline.sh validate_main_window_ui.sh \
  validate_overlay_non_mouse.sh validate_overlay_interaction.sh \
  validate_overlay_scale_persistence.sh validate_renderer_runtime_budget.sh \
  validate_app_recovery.sh; do
  write_executable "$TEST_ROOT/script/$script_name" \
    '#!/usr/bin/env bash' \
    'exit 0'
done
write_executable "$TEST_ROOT/script/build_and_run.sh" \
  '#!/usr/bin/env bash' \
  'printf '\''host-ui\n'\'' >>"$APC_ISOLATION_FORBIDDEN_LOG"' \
  'exit 0'
write_executable "$TEST_ROOT/script/validate_real_agent_connectors.sh" \
  '#!/usr/bin/env bash' \
  'printf '\''real-agent-connectors\n'\'' >>"$APC_ISOLATION_FORBIDDEN_LOG"' \
  'exit 0'
write_executable "$TEST_ROOT/script/validate_real_app_server.sh" \
  '#!/usr/bin/env bash' \
  'printf '\''real-app-server\n'\'' >>"$APC_ISOLATION_FORBIDDEN_LOG"' \
  'exit 0'

: >"$FORBIDDEN_LOG"
if ! env \
  -u APC_VALIDATE_HOST_UI \
  -u APC_VALIDATE_OVERLAY_RUNTIME \
  -u APC_VALIDATE_REAL_AGENT_CONNECTORS \
  -u APC_VALIDATE_REAL_APP_SERVER \
  PATH="$SHIM_DIR:$PATH" \
  APC_ISOLATION_FORBIDDEN_LOG="$FORBIDDEN_LOG" \
  "$TEST_ROOT/script/test_all.sh" >/dev/null 2>&1; then
  record_failure 'default test_all.sh failed in the isolated fixture'
fi
if [[ -s "$FORBIDDEN_LOG" ]]; then
  record_failure "default test_all invoked forbidden host/agent commands: $(tr '\n' ' ' <"$FORBIDDEN_LOG")"
fi

if rg -n '/tmp/apc-connector-extra\.(out|err)' "$ROOT_DIR/script/validate_connectors_runtime.sh" >/dev/null; then
  record_failure 'connector validation still uses shared /tmp output paths'
fi

DEFAULT_VALIDATORS=(
  "$ROOT_DIR/script/validate_m0.sh"
  "$ROOT_DIR/script/validate_m1.sh"
  "$ROOT_DIR/script/validate_m2.sh"
  "$ROOT_DIR/script/validate_m3.sh"
  "$ROOT_DIR/script/validate_m4.sh"
  "$ROOT_DIR/script/validate_connectors_runtime.sh"
  "$ROOT_DIR/script/validate_event_storm.sh"
  "$ROOT_DIR/script/validate_m5.sh"
  "$ROOT_DIR/script/validate_m6.sh"
  "$ROOT_DIR/script/validate_v1.sh"
  "$ROOT_DIR/script/validate_security_boundaries.sh"
)
if forbidden_lines="$(rg -n '\b(pkill|killall|launchctl|osascript)\b|(^|[[:space:];|&])(/usr/bin/)?open([[:space:]]|$)' "${DEFAULT_VALIDATORS[@]}" || true)" && [[ -n "$forbidden_lines" ]]; then
  record_failure "default validators contain host-wide process commands: ${forbidden_lines//$'\n'/; }"
fi

# Exercise every actual default validator through its real setup path. Cargo is
# the first expensive dependency in each script; the injected cargo records the
# environment and stops there. This proves isolation is established before any
# build, daemon, snapshot, or connector operation.
PREFLIGHT_BIN="$TMP_DIR/preflight-bin"
PREFLIGHT_TMP="$TMP_DIR/preflight-tmp"
PREFLIGHT_ENV_LOG="$TMP_DIR/preflight-env.log"
PREFLIGHT_FORBIDDEN_LOG="$TMP_DIR/preflight-forbidden.log"
mkdir -p "$PREFLIGHT_BIN" "$PREFLIGHT_TMP"
: >"$PREFLIGHT_ENV_LOG"
: >"$PREFLIGHT_FORBIDDEN_LOG"
write_executable "$PREFLIGHT_BIN/cargo" \
  '#!/usr/bin/env bash' \
  'printf '\''%s\t%s\t%s\t%s\n'\'' "$HOME" "${XDG_CONFIG_HOME:-}" "${APC_AGENT_CONFIG_HOME:-}" "${APC_HOME:-}" >>"$APC_PREFLIGHT_ENV_LOG"' \
  'exit 73'
for command_name in launchctl pkill killall open osascript codex claude pi opencode; do
  write_executable "$PREFLIGHT_BIN/$command_name" \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$(basename "$0")" >>"$APC_PREFLIGHT_FORBIDDEN_LOG"' \
    'exit 97'
done

for validator in "${DEFAULT_VALIDATORS[@]}"; do
  before_lines="$(wc -l <"$PREFLIGHT_ENV_LOG" | tr -d ' ')"
  set +e
  env \
    HOME="$TMP_DIR/outside-home" \
    XDG_CONFIG_HOME="$TMP_DIR/outside-xdg" \
    APC_AGENT_CONFIG_HOME="$TMP_DIR/outside-agent-home" \
    APC_HOME="$TMP_DIR/outside-apc-home" \
    TMPDIR="$PREFLIGHT_TMP" \
    PATH="$PREFLIGHT_BIN:$PATH" \
    APC_PREFLIGHT_ENV_LOG="$PREFLIGHT_ENV_LOG" \
    APC_PREFLIGHT_FORBIDDEN_LOG="$PREFLIGHT_FORBIDDEN_LOG" \
    "$validator" >/dev/null 2>&1
  validator_status="$?"
  set -e
  after_lines="$(wc -l <"$PREFLIGHT_ENV_LOG" | tr -d ' ')"
  if [[ "$validator_status" == "0" || "$after_lines" -ne $((before_lines + 1)) ]]; then
    record_failure "actual validator did not reach the injected dependency after isolated setup: $validator"
    continue
  fi
  environment_line="$(tail -n 1 "$PREFLIGHT_ENV_LOG")"
  IFS=$'\t' read -r observed_home observed_xdg observed_agent_home observed_apc_home <<<"$environment_line"
  for observed in "$observed_home" "$observed_xdg" "$observed_agent_home" "$observed_apc_home"; do
    if [[ "$observed" != "$PREFLIGHT_TMP"/* ]]; then
      record_failure "validator exposed a non-temporary user path before build/snapshot: $validator ($environment_line)"
      break
    fi
  done
done
if [[ -s "$PREFLIGHT_FORBIDDEN_LOG" ]]; then
  record_failure "actual default validator setup invoked forbidden host/agent commands: $(tr '\n' ' ' <"$PREFLIGHT_FORBIDDEN_LOG")"
fi

HOST_MUTATING_VALIDATORS=(
  "$ROOT_DIR/script/validate_main_window_ui.sh"
  "$ROOT_DIR/script/validate_overlay_runtime.sh"
  "$ROOT_DIR/script/validate_overlay_non_mouse.sh"
  "$ROOT_DIR/script/validate_overlay_interaction.sh"
  "$ROOT_DIR/script/validate_overlay_scale_persistence.sh"
  "$ROOT_DIR/script/validate_renderer_runtime_budget.sh"
  "$ROOT_DIR/script/validate_app_recovery.sh"
)
for validator in "${HOST_MUTATING_VALIDATORS[@]}"; do
  if ! rg -q 'apc_require_host_ui_opt_in' "$validator"; then
    record_failure "host-mutating validator lacks an independent APC_VALIDATE_HOST_UI gate: $validator"
  fi
done
: >"$FORBIDDEN_LOG"
for validator in "${HOST_MUTATING_VALIDATORS[@]}"; do
  set +e
  PATH="$SHIM_DIR:$PATH" \
    APC_VALIDATE_HOST_UI=0 \
    APC_ISOLATION_FORBIDDEN_LOG="$FORBIDDEN_LOG" \
    "$validator" >/dev/null 2>&1
  gate_status="$?"
  set -e
  if [[ "$gate_status" != "2" ]]; then
    record_failure "host-mutating validator did not stop at its disabled gate: $validator (status=$gate_status)"
  fi
done
set +e
PATH="$SHIM_DIR:$PATH" \
  APC_VALIDATE_HOST_UI=0 \
  APC_ISOLATION_FORBIDDEN_LOG="$FORBIDDEN_LOG" \
  "$ROOT_DIR/script/build_and_run.sh" --verify >/dev/null 2>&1
verify_gate_status="$?"
set -e
if [[ "$verify_gate_status" != "2" ]]; then
  record_failure "build_and_run.sh --verify did not stop at its disabled host gate (status=$verify_gate_status)"
fi
if [[ -s "$FORBIDDEN_LOG" ]]; then
  record_failure "disabled host validators invoked forbidden commands before their gate: $(tr '\n' ' ' <"$FORBIDDEN_LOG")"
fi

OWNERSHIP_SCRIPTS=(
  "$ROOT_DIR/script/build_and_run.sh"
  "${HOST_MUTATING_VALIDATORS[@]}"
)
if ownership_lines="$(rg -n '\b(pkill|killall|pgrep|launchctl|osascript)\b|(^|[[:space:];|&])(/usr/bin/)?open([[:space:]]|$)' "${OWNERSHIP_SCRIPTS[@]}" || true)" && [[ -n "$ownership_lines" ]]; then
  record_failure "UI process ownership still relies on global discovery/mutation: ${ownership_lines//$'\n'/; }"
fi

for validator in \
  "$ROOT_DIR/script/build_and_run.sh" \
  "$ROOT_DIR/script/validate_main_window_ui.sh" \
  "$ROOT_DIR/script/validate_overlay_non_mouse.sh" \
  "$ROOT_DIR/script/validate_overlay_interaction.sh" \
  "$ROOT_DIR/script/validate_overlay_scale_persistence.sh" \
  "$ROOT_DIR/script/validate_renderer_runtime_budget.sh" \
  "$ROOT_DIR/script/validate_app_recovery.sh"; do
  if ! rg -q 'apc_start_owned_runtime' "$validator"; then
    record_failure "host validator does not launch a dedicated owned runtime: $validator"
  fi
done
if ! rg -q 'APP_PID=.*swift|APP_PID="\$APC_OWNED_APP_PID"' "$ROOT_DIR/script/validate_main_window_ui.sh" \
  || ! rg -q 'APP_PID=.*swift|APP_PID="\$APC_OWNED_APP_PID"' "$ROOT_DIR/script/validate_overlay_non_mouse.sh"; then
  record_failure 'Swift/CGWindow host checks are not bound to the explicitly owned app PID'
fi

# Exercise the real owned-runtime helper with a minimal app/daemon/CLI fixture.
# The fixture reaches runtime.json publication, health identity, snapshot, PID
# transfer, normal cleanup, and tampered-marker conservative cleanup.
. "$ROOT_DIR/script/validation_helpers.sh"
if ! declare -F apc_start_owned_runtime >/dev/null \
  || ! declare -F apc_stop_owned_runtime >/dev/null; then
  record_failure 'owned runtime helper protocol is missing'
else
  RUNTIME_FIXTURE="$TMP_DIR/runtime-fixture"
  RUNTIME_HOME="$RUNTIME_FIXTURE/environment"
  RUNTIME_PROTOCOL="$RUNTIME_FIXTURE/owned-runtime.json"
  RUNTIME_BUNDLE="$RUNTIME_FIXTURE/Fake.app"
  RUNTIME_APP="$RUNTIME_BUNDLE/Contents/MacOS/FakeApp"
  RUNTIME_PETCORE="$RUNTIME_BUNDLE/Contents/Resources/bin/petcore"
  RUNTIME_CLI="$RUNTIME_BUNDLE/Contents/Resources/bin/petcore-cli"
  mkdir -p "$(dirname "$RUNTIME_APP")" "$(dirname "$RUNTIME_PETCORE")"
  write_executable "$RUNTIME_PETCORE" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'mkdir -p "$APC_HOME/run"' \
    'printf '\''{"schema_version":"apc.runtime.v1","pid":%s,"process_start":"2026-07-10T00:00:00Z","instance_id":"fixture-instance","http_port":43210}\n'\'' "$$" >"$APC_HOME/run/runtime.json"' \
    'trap '\''exit 0'\'' TERM INT' \
    'while :; do sleep 1; done'
  write_executable "$RUNTIME_APP" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '"$APC_FAKE_PETCORE" &' \
    'trap '\''exit 0'\'' TERM INT' \
    'while :; do sleep 1; done'
  write_executable "$RUNTIME_CLI" \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "${1:-}" in' \
    '  health)' \
    '    python3 - "$APC_HOME/run/runtime.json" "$APC_HOME" <<'\''PY'\''' \
    'import json, sys' \
    'marker = json.load(open(sys.argv[1], encoding="utf-8"))' \
    'print(json.dumps({"ok": True, "instance_id": marker["instance_id"], "home": sys.argv[2]}))' \
    'PY' \
    '    ;;' \
    '  snapshot)' \
    '    printf '\''{"behavior":{"enabled":true},"overlay_placement":{"x":0,"y":0,"scale":0.12,"display_id":"fixture"},"events":[]}\n'\''' \
    '    ;;' \
    '  *) printf '\''{"ok":true}\n'\'' ;;' \
    'esac'

  (
    apc_use_isolated_home "$RUNTIME_HOME"
    export APC_FAKE_PETCORE="$RUNTIME_PETCORE"
    apc_start_owned_runtime "$RUNTIME_APP" "$RUNTIME_CLI" "$RUNTIME_PETCORE" "$RUNTIME_FIXTURE/app.log" "$RUNTIME_PROTOCOL"
    first_app_pid="$APC_OWNED_APP_PID"
    first_petcore_pid="$APC_OWNED_PETCORE_PID"
    kill -0 "$first_app_pid"
    kill -0 "$first_petcore_pid"
    "$RUNTIME_CLI" snapshot >/dev/null
    python3 - "$RUNTIME_PROTOCOL" "$first_app_pid" "$first_petcore_pid" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["app_pid"] == int(sys.argv[2]), data
assert data["petcore_pid"] == int(sys.argv[3]), data
assert data["schema_version"] == "apc.runtime.v1", data
assert data["instance_id"] == "fixture-instance", data
assert data["process_start"], data
PY
    apc_stop_owned_runtime "$RUNTIME_CLI" "$RUNTIME_PETCORE" "$RUNTIME_PROTOCOL"
    ! kill -0 "$first_app_pid" >/dev/null 2>&1
    ! kill -0 "$first_petcore_pid" >/dev/null 2>&1

    apc_start_owned_runtime "$RUNTIME_APP" "$RUNTIME_CLI" "$RUNTIME_PETCORE" "$RUNTIME_FIXTURE/app-tampered.log" "$RUNTIME_PROTOCOL"
    second_app_pid="$APC_OWNED_APP_PID"
    second_petcore_pid="$APC_OWNED_PETCORE_PID"
    python3 - "$APC_HOME/run/runtime.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["instance_id"] = "tampered-instance"
with open(path, "w", encoding="utf-8") as file:
    json.dump(data, file)
PY
    apc_stop_owned_runtime "$RUNTIME_CLI" "$RUNTIME_PETCORE" "$RUNTIME_PROTOCOL"
    ! kill -0 "$second_app_pid" >/dev/null 2>&1
    kill -0 "$second_petcore_pid" >/dev/null 2>&1
    kill "$second_petcore_pid" >/dev/null 2>&1 || true
  ) || record_failure 'owned runtime fixture failed PID/marker/snapshot initialization or conservative cleanup'
fi
for validator in "${DEFAULT_VALIDATORS[@]}"; do
  if rg -q 'petcore" serve' "$validator" \
    && ! rg -q 'APC_DISABLE_CODEX_APP_SERVER_AUTO=1' "$validator"; then
    record_failure "default validator can auto-start a real Codex App Server: $validator"
  fi
done
if ! rg -q 'SIMULATED_AGENT_BIN' "$ROOT_DIR/script/validate_connectors_runtime.sh" \
  || ! rg -q 'PATH="\$SIMULATED_AGENT_BIN:\$PATH"' "$ROOT_DIR/script/validate_connectors_runtime.sh"; then
  record_failure 'simulated connector validation does not isolate third-party agent commands behind local shims'
fi
if auto_gates="$(rg -n 'APC_VALIDATE_(REAL_APP_SERVER|REAL_AGENT_CONNECTORS|OVERLAY_INTERACTION):-auto' \
  "$ROOT_DIR/script/validate_real_app_server.sh" \
  "$ROOT_DIR/script/validate_real_agent_connectors.sh" \
  "$ROOT_DIR/script/validate_overlay_interaction.sh" || true)" && [[ -n "$auto_gates" ]]; then
  record_failure "real validation gates still auto-enable: ${auto_gates//$'\n'/; }"
fi
if ! rg -q 'if ! truthy "\$setting"' "$ROOT_DIR/script/validate_real_app_server.sh"; then
  record_failure 'real App Server validation does not reject non-truthy gate values before probing Codex'
fi
if ! rg -q 'if ! is_truthy "\$SETTING"' "$ROOT_DIR/script/validate_real_agent_connectors.sh"; then
  record_failure 'real connector validation does not require a truthy explicit gate'
fi
if ! rg -q 'if ! truthy "\$MODE"' "$ROOT_DIR/script/validate_overlay_interaction.sh"; then
  record_failure 'real overlay interaction validation does not require a truthy explicit gate'
fi

if [[ ! -x "$ROOT_DIR/script/build_app_bundle.sh" ]]; then
  record_failure 'script/build_app_bundle.sh is missing or not executable'
else
  : >"$FORBIDDEN_LOG"
  if ! PATH="$SHIM_DIR:$PATH" \
    APC_ISOLATION_FORBIDDEN_LOG="$FORBIDDEN_LOG" \
    APC_FAKE_SWIFT_BIN="$FAKE_SWIFT_BIN" \
    "$BUILD_ROOT/script/build_app_bundle.sh" >/dev/null 2>&1; then
    record_failure 'build_app_bundle.sh did not complete in the isolated fixture'
  elif find "$BUILD_ROOT/dist/AgentPetCompanion.app" \
    \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
    record_failure 'app bundle contains Python cache artifacts'
  fi
  if [[ -s "$FORBIDDEN_LOG" ]]; then
    record_failure "bundle build invoked forbidden host commands: $(tr '\n' ' ' <"$FORBIDDEN_LOG")"
  fi
fi

if ((FAILURES > 0)); then
  exit 1
fi

echo 'Test isolation validation ok'
