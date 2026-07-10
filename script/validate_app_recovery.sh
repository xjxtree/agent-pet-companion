#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "app recovery validation"

APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="$APP_BUNDLE/Contents/Resources/bin/petcore-cli"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-app-recovery.XXXXXX")"
apc_use_isolated_home "$TMP_DIR"
OWNED_PROTOCOL="$APC_HOME/run/validation-owned-runtime.json"
APP_LOG="$TMP_DIR/app.log"

cleanup() {
  apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ ! -x "$APP_BINARY" || ! -x "$PETCORE_BINARY" || ! -x "$PETCORE_CLI" ]]; then
  "$ROOT_DIR/script/build_app_bundle.sh" >/dev/null
fi

apc_start_owned_runtime \
  "$APP_BINARY" \
  "$PETCORE_CLI" \
  "$PETCORE_BINARY" \
  "$APP_LOG" \
  "$OWNED_PROTOCOL"

initial_pid="$APC_OWNED_PETCORE_PID"
initial_instance="$APC_OWNED_INSTANCE_ID"
initial_process_start="$APC_OWNED_PROCESS_START"

# Revalidate the full runtime marker and health identity immediately before the
# intentional crash. No daemon discovered by name or global process search is
# ever eligible for termination.
apc_claim_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
[[ "$APC_OWNED_PETCORE_PID" == "$initial_pid" ]]
[[ "$APC_OWNED_INSTANCE_ID" == "$initial_instance" ]]
[[ "$APC_OWNED_PROCESS_START" == "$initial_process_start" ]]
kill "$initial_pid"

for _ in {1..40}; do
  if ! kill -0 "$initial_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if kill -0 "$initial_pid" >/dev/null 2>&1; then
  echo "app recovery validation failed: owned PetCore pid $initial_pid did not exit" >&2
  exit 1
fi

for _ in {1..120}; do
  identity="$(apc_read_runtime_identity "$PETCORE_CLI" "$PETCORE_BINARY" || true)"
  if [[ -n "$identity" ]]; then
    IFS=$'\t' read -r recovered_pid recovered_process_start recovered_instance <<<"$identity"
    recovered_parent="$(ps -p "$recovered_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)"
    if [[ "$recovered_pid" != "$initial_pid" \
      && "$recovered_instance" != "$initial_instance" \
      && "$recovered_process_start" != "$initial_process_start" \
      && "$recovered_parent" == "$APC_OWNED_APP_PID" ]]; then
      APC_OWNED_PETCORE_PID="$recovered_pid"
      APC_OWNED_PROCESS_START="$recovered_process_start"
      APC_OWNED_INSTANCE_ID="$recovered_instance"
      apc_write_owned_runtime_protocol "$OWNED_PROTOCOL" "$PETCORE_BINARY"
      echo "App recovery validation ok: app_pid=$APC_OWNED_APP_PID petcore_pid=$recovered_pid"
      exit 0
    fi
  fi
  if ! kill -0 "$APC_OWNED_APP_PID" >/dev/null 2>&1; then
    echo "app recovery validation failed: owned app exited during recovery" >&2
    cat "$APP_LOG" >&2 || true
    exit 1
  fi
  sleep 0.25
done

echo "app recovery validation failed: owned PetCore did not recover after pid $initial_pid was terminated" >&2
cat "$APP_LOG" >&2 || true
exit 1
