#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---build-only}"
APP_NAME="AgentPetCompanion"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
SWIFT_DIR="$ROOT_DIR/apps/macos"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
PETCORE_BINARY="$APP_RESOURCES/bin/petcore"
PETCORE_CLI="$APP_RESOURCES/bin/petcore-cli"
RUNTIME_ROOT=""
OWNED_PROTOCOL=""
APP_LOG=""
BUILD_ONLY_ROOT=""

case "$MODE" in
  --build-only|build-only|--bundle|bundle|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [--build-only|--bundle|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

build_only() {
  BUILD_ONLY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/apc-build-only.XXXXXX")"
  trap cleanup_build_only EXIT
  apc_use_isolated_home "$BUILD_ONLY_ROOT"
  (cd "$ROOT_DIR" && cargo build --workspace --locked)
  (cd "$SWIFT_DIR" && swift build --product "$APP_NAME")
  cleanup_build_only
  trap - EXIT
}

cleanup_build_only() {
  if [[ -n "$BUILD_ONLY_ROOT" ]]; then
    rm -rf "$BUILD_ONLY_ROOT"
    BUILD_ONLY_ROOT=""
  fi
}

build_bundle() {
  "$ROOT_DIR/script/build_app_bundle.sh"
}

prepare_owned_runtime() {
  RUNTIME_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/apc-owned-app.XXXXXX")"
  apc_use_isolated_home "$RUNTIME_ROOT"
  OWNED_PROTOCOL="${APC_OWNED_PROCESS_FILE:-$APC_HOME/run/validation-owned-runtime.json}"
  APP_LOG="${APC_APP_LOG_PATH:-$RUNTIME_ROOT/app.log}"
}

start_owned_runtime() {
  prepare_owned_runtime
  apc_start_owned_runtime \
    "$APP_BINARY" \
    "$PETCORE_CLI" \
    "$PETCORE_BINARY" \
    "$APP_LOG" \
    "$OWNED_PROTOCOL"
}

cleanup_owned_runtime() {
  if [[ -n "$OWNED_PROTOCOL" ]]; then
    apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
  fi
  if [[ -n "$RUNTIME_ROOT" ]]; then
    rm -rf "$RUNTIME_ROOT"
  fi
}

case "$MODE" in
  --build-only|build-only)
    build_only
    ;;
  --bundle|bundle)
    build_bundle
    ;;
  run)
    build_bundle
    start_owned_runtime
    printf 'Launched owned %s pid=%s petcore_pid=%s protocol=%s log=%s\n' \
      "$APP_NAME" "$APC_OWNED_APP_PID" "$APC_OWNED_PETCORE_PID" "$OWNED_PROTOCOL" "$APP_LOG"
    ;;
  --debug|debug)
    build_bundle
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_bundle
    start_owned_runtime
    trap cleanup_owned_runtime EXIT
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_bundle
    start_owned_runtime
    trap cleanup_owned_runtime EXIT
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"dev.agentpet.companion\""
    ;;
  --verify|verify)
    apc_require_host_ui_opt_in "host UI verification"
    build_bundle
    start_owned_runtime
    trap cleanup_owned_runtime EXIT
    "$ROOT_DIR/script/validate_overlay_runtime.sh" "$PETCORE_CLI"
    printf 'Host UI verification ok for owned pid %s instance=%s\n' \
      "$APC_OWNED_APP_PID" "$APC_OWNED_INSTANCE_ID"
    ;;
esac
