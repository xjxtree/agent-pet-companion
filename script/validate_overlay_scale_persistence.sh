#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "overlay scale persistence validation"
APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="$APP_BUNDLE/Contents/Resources/bin/petcore-cli"
TARGET_SCALE="${APC_OVERLAY_PERSISTENCE_SCALE:-0.42}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-overlay-persistence.XXXXXX")"
apc_use_isolated_home "$TMP_DIR"
OWNED_PROTOCOL="$APC_HOME/run/validation-owned-runtime.json"
APP_LOG="$TMP_DIR/app.log"
ORIGINAL_PLACEMENT=""

restore_original_placement() {
  if [[ -z "$ORIGINAL_PLACEMENT" || ! -x "$PETCORE_CLI" ]]; then
    return 0
  fi
  PLACEMENT="$ORIGINAL_PLACEMENT" python3 - <<'PY' | while read -r x y scale display_id; do
import json
import os

placement = json.loads(os.environ["PLACEMENT"])
print(placement["x"], placement["y"], placement["scale"], placement.get("display_id", "main"))
PY
    "$PETCORE_CLI" overlay placement set \
      --x "$x" \
      --y "$y" \
      --scale "$scale" \
      --display-id "$display_id" >/dev/null 2>&1 || true
  done
}

cleanup() {
  restore_original_placement
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

wait_snapshot() {
  local snapshot=""
  for _ in {1..80}; do
    snapshot="$("$PETCORE_CLI" snapshot 2>/dev/null || true)"
    if SNAPSHOT="$snapshot" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("SNAPSHOT", "{}"))
except json.JSONDecodeError:
    sys.exit(1)

sys.exit(0 if isinstance(data.get("overlay_placement"), dict) else 1)
PY
    then
      printf '%s\n' "$snapshot"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

ORIGINAL_SNAPSHOT="$(wait_snapshot)"
ORIGINAL_PLACEMENT="$(SNAPSHOT="$ORIGINAL_SNAPSHOT" python3 - <<'PY'
import json
import os

placement = json.loads(os.environ["SNAPSHOT"])["overlay_placement"]
print(json.dumps(placement))
PY
)"

TARGET_PLACEMENT="$(swift - <<'SWIFT'
import AppKit

guard let screen = NSScreen.screens.last ?? NSScreen.main ?? NSScreen.screens.first else {
    fputs("overlay scale persistence validation failed: no NSScreen available\n", stderr)
    exit(1)
}

let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
let displayID = number?.stringValue ?? "main"
let visible = screen.visibleFrame
print([
    displayID,
    String(format: "%.4f", visible.maxX + 400),
    String(format: "%.4f", visible.minY - 400),
    String(format: "%.4f", visible.minX),
    String(format: "%.4f", visible.maxX),
    String(format: "%.4f", visible.minY),
    String(format: "%.4f", visible.maxY),
].joined(separator: " "))
SWIFT
)"

read -r TARGET_DISPLAY_ID TARGET_X TARGET_Y TARGET_MIN_X TARGET_MAX_X TARGET_MIN_Y TARGET_MAX_Y <<<"$TARGET_PLACEMENT"

"$PETCORE_CLI" overlay placement set \
  --x "$TARGET_X" \
  --y "$TARGET_Y" \
  --scale "$TARGET_SCALE" \
  --display-id "$TARGET_DISPLAY_ID" >/dev/null

apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
apc_start_owned_runtime \
  "$APP_BINARY" \
  "$PETCORE_CLI" \
  "$PETCORE_BINARY" \
  "$APP_LOG" \
  "$OWNED_PROTOCOL"

for _ in {1..40}; do
  SNAPSHOT="$(wait_snapshot || true)"
  if SNAPSHOT="$SNAPSHOT" \
    TARGET_SCALE="$TARGET_SCALE" \
    TARGET_DISPLAY_ID="$TARGET_DISPLAY_ID" \
    TARGET_MIN_X="$TARGET_MIN_X" \
    TARGET_MAX_X="$TARGET_MAX_X" \
    TARGET_MIN_Y="$TARGET_MIN_Y" \
    TARGET_MAX_Y="$TARGET_MAX_Y" \
    python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("SNAPSHOT", "{}"))
except json.JSONDecodeError:
    sys.exit(1)

placement = data.get("overlay_placement", {})
actual = float(placement.get("scale", -1))
expected = float(os.environ["TARGET_SCALE"])
if abs(actual - expected) >= 0.0001:
    sys.exit(1)

if placement.get("display_id") != os.environ["TARGET_DISPLAY_ID"]:
    sys.exit(1)

x = float(placement.get("x", 0))
y = float(placement.get("y", 0))
min_x = float(os.environ["TARGET_MIN_X"])
max_x = float(os.environ["TARGET_MAX_X"])
min_y = float(os.environ["TARGET_MIN_Y"])
max_y = float(os.environ["TARGET_MAX_Y"])
if not (min_x <= x <= max_x and min_y <= y <= max_y):
    sys.exit(1)

sys.exit(0)
PY
  then
    echo "Overlay scale/display persistence validation ok"
    exit 0
  fi
  sleep 0.25
done

echo "overlay scale persistence validation failed: app reset persisted scale or display" >&2
"$PETCORE_CLI" snapshot >&2 || true
exit 1
