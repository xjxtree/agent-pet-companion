#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---build-only}"
APP_NAME="AgentPetCompanion"
LIFECYCLE_CLIENT_NAME="AgentPetCompanionLifecycleClient"
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
  --build-only|build-only|--bundle|bundle|--run|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [--build-only|--bundle|--run|--debug|--logs|--telemetry|--verify]" >&2
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

quit_running_app() {
  local lifecycle_client
  local swift_bin_path

  # Build the tiny AppKit control client without replacing the currently
  # installed App bundle. It requests a normal bundle-ID-scoped Quit and waits
  # for the old UI host to exit before the bundle is rebuilt in place.
  (cd "$SWIFT_DIR" && swift build --product "$LIFECYCLE_CLIENT_NAME")
  swift_bin_path="$(cd "$SWIFT_DIR" && swift build --show-bin-path)"
  lifecycle_client="$swift_bin_path/$LIFECYCLE_CLIENT_NAME"
  [[ -x "$lifecycle_client" ]] || {
    echo "missing lifecycle client: $lifecycle_client" >&2
    return 1
  }
  "$lifecycle_client" --quit-running-app
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

bundle_build_id() {
  /usr/libexec/PlistBuddy -c 'Print :APCBuildID' \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null
}

run_default_user_environment() {
  /usr/bin/env \
    -u APC_HOME \
    -u APC_DISABLE_LAUNCH_AGENT \
    -u APC_RUNTIME_MANIFEST_PATH \
    -u APC_BUILD_ID \
    "$@"
}

bundle_cli_build_ids() {
  local build_info
  build_info="$("$PETCORE_CLI" build-info 2>/dev/null)" || return 1
  APC_RUN_BUILD_INFO_JSON="$build_info" python3 - <<'PY'
import json
import os

try:
    build_info = json.loads(os.environ["APC_RUN_BUILD_INFO_JSON"])
except (KeyError, json.JSONDecodeError):
    raise SystemExit(1)

manifest = build_info.get("runtime_manifest")
if not isinstance(manifest, dict):
    raise SystemExit(1)
values = (
    build_info.get("build_id"),
    manifest.get("build_id"),
    manifest.get("petcore_build_id"),
    manifest.get("petcore_cli_build_id"),
)
if not all(isinstance(value, str) for value in values):
    raise SystemExit(1)
print(*values, sep="\t")
PY
}

health_build_ids() {
  local health="$1"
  APC_RUN_HEALTH_JSON="$health" python3 - <<'PY'
import json
import os

try:
    health = json.loads(os.environ["APC_RUN_HEALTH_JSON"])
except (KeyError, json.JSONDecodeError):
    raise SystemExit(1)

manifest = health.get("runtime_manifest")
if health.get("ok") is not True or not isinstance(manifest, dict):
    raise SystemExit(1)
build_id = health.get("build_id")
manifest_build_id = manifest.get("build_id")
petcore_build_id = manifest.get("petcore_build_id")
cli_build_id = manifest.get("petcore_cli_build_id")
if not all(
    isinstance(value, str)
    for value in (build_id, manifest_build_id, petcore_build_id, cli_build_id)
):
    raise SystemExit(1)
print(build_id, manifest_build_id, petcore_build_id, cli_build_id, sep="\t")
PY
}

wait_for_runtime_sync() {
  local expected_build_id="$1"
  local observed_build_id=""
  local observed_manifest_build_id=""
  local observed_component_build_id=""
  local observed_cli_build_id=""
  local health=""
  local identities=""

  for _ in {1..100}; do
    if health="$(run_default_user_environment "$PETCORE_CLI" health 2>/dev/null)" \
      && identities="$(health_build_ids "$health" 2>/dev/null)"; then
      IFS=$'\t' read -r \
        observed_build_id \
        observed_manifest_build_id \
        observed_component_build_id \
        observed_cli_build_id <<<"$identities"
      if [[ "$observed_build_id" == "$expected_build_id" \
        && "$observed_manifest_build_id" == "$expected_build_id" \
        && "$observed_component_build_id" == "$expected_build_id" \
        && "$observed_cli_build_id" == "$expected_build_id" ]]; then
        printf 'Runtime synchronized: App and PetCore build %s\n' "$expected_build_id"
        return 0
      fi
    fi
    sleep 0.2
  done

  printf 'runtime synchronization timed out: App=%s health=%s manifest=%s PetCore=%s CLI=%s\n' \
    "$expected_build_id" \
    "${observed_build_id:-unavailable}" \
    "${observed_manifest_build_id:-unavailable}" \
    "${observed_component_build_id:-unavailable}" \
    "${observed_cli_build_id:-unavailable}" >&2
  return 1
}

run_host_bundle() {
  quit_running_app
  build_bundle
  local expected_build_id
  local cli_build_id
  local cli_manifest_build_id
  local cli_manifest_petcore_build_id
  local cli_manifest_component_build_id
  local cli_identities
  expected_build_id="$(bundle_build_id)"
  if [[ ! "$expected_build_id" =~ ^[A-Za-z0-9._+-]{1,128}$ ]]; then
    echo 'built App bundle does not contain a valid APCBuildID' >&2
    return 1
  fi
  cli_identities="$(bundle_cli_build_ids)" || {
    echo 'packaged petcore-cli does not expose valid build identity' >&2
    return 1
  }
  IFS=$'\t' read -r \
    cli_build_id \
    cli_manifest_build_id \
    cli_manifest_petcore_build_id \
    cli_manifest_component_build_id <<<"$cli_identities"
  if [[ "$cli_build_id" != "$expected_build_id" \
    || "$cli_manifest_build_id" != "$expected_build_id" \
    || "$cli_manifest_petcore_build_id" != "$expected_build_id" \
    || "$cli_manifest_component_build_id" != "$expected_build_id" ]]; then
    printf 'packaged runtime identity mismatch: App=%s CLI=%s manifest=%s PetCore=%s component=%s\n' \
      "$expected_build_id" \
      "${cli_build_id:-unavailable}" \
      "${cli_manifest_build_id:-unavailable}" \
      "${cli_manifest_petcore_build_id:-unavailable}" \
      "${cli_manifest_component_build_id:-unavailable}" >&2
    return 1
  fi

  # The lifecycle client has already confirmed that every UI host with this
  # bundle identifier exited normally. Open exactly the newly built bundle;
  # validation-only overrides must not redirect this real Run action to an
  # isolated home or disable its user LaunchAgent update path.
  run_default_user_environment /usr/bin/open -n "$APP_BUNDLE"
  wait_for_runtime_sync "$expected_build_id"
}

case "$MODE" in
  --build-only|build-only)
    build_only
    ;;
  --bundle|bundle)
    build_bundle
    ;;
  --run|run)
    run_host_bundle
    ;;
  --debug|debug)
    quit_running_app
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
