#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "overlay interaction validation"
APP_NAME="${APC_OVERLAY_APP_NAME:-AgentPetCompanion}"
APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="${1:-$APP_BUNDLE/Contents/Resources/bin/petcore-cli}"
MODE="${APC_VALIDATE_OVERLAY_INTERACTION:-0}"
RESTORE_STATE=0
ORIGINAL_BEHAVIOR_JSON=""
ORIGINAL_PLACEMENT_JSON=""

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

skip() {
  echo "overlay interaction validation skipped: $1"
  exit 0
}

if ! truthy "$MODE"; then
  skip "APC_VALIDATE_OVERLAY_INTERACTION=$MODE is not an explicit opt-in; use 1"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  skip "requires macOS"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-overlay-interaction.XXXXXX")"
apc_use_isolated_home "$TMP_DIR"
OWNED_PROTOCOL="$APC_HOME/run/validation-owned-runtime.json"
APP_LOG="$TMP_DIR/app.log"

ax_trusted() {
  swift - <<'SWIFT'
import ApplicationServices
import Foundation

exit(AXIsProcessTrusted() ? 0 : 1)
SWIFT
}

if ! ax_trusted; then
  if truthy "$MODE"; then
    echo "overlay interaction validation failed: Accessibility permission is required to post real mouse events" >&2
    exit 1
  fi
  skip "Accessibility permission is not granted to the current automation host"
fi

if [[ ! -x "$PETCORE_CLI" || ! -x "$PETCORE_BINARY" || ! -x "$APP_BINARY" ]]; then
  "$ROOT_DIR/script/build_app_bundle.sh" >/dev/null
fi

if [[ ! -x "$PETCORE_CLI" || ! -x "$PETCORE_BINARY" || ! -x "$APP_BINARY" ]]; then
  echo "overlay interaction validation failed: dist app is not built" >&2
  exit 1
fi

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

ok = isinstance(data.get("behavior"), dict) and isinstance(data.get("overlay_placement"), dict)
sys.exit(0 if ok else 1)
PY
    then
      printf '%s\n' "$snapshot"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

launch_owned_app() {
  apc_start_owned_runtime \
    "$APP_BINARY" \
    "$PETCORE_CLI" \
    "$PETCORE_BINARY" \
    "$APP_LOG" \
    "$OWNED_PROTOCOL"
  "$ROOT_DIR/script/validate_overlay_runtime.sh" "$PETCORE_CLI" >/dev/null
}

relaunch_owned_app() {
  apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
  launch_owned_app
}

restore_state() {
  if [[ "$RESTORE_STATE" == "1" ]]; then
    if [[ -n "$ORIGINAL_BEHAVIOR_JSON" ]]; then
      "$PETCORE_CLI" behavior set-json --value-json "$ORIGINAL_BEHAVIOR_JSON" >/dev/null 2>&1 || true
    fi
    if [[ -n "$ORIGINAL_PLACEMENT_JSON" ]]; then
      PLACEMENT="$ORIGINAL_PLACEMENT_JSON" python3 - <<'PY' | while read -r x y scale display_id; do
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
    fi
  fi
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && -s "$APP_LOG" ]]; then
    echo "overlay interaction app log:" >&2
    tail -n 120 "$APP_LOG" >&2
  fi
  restore_state
  apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
  rm -rf "$TMP_DIR"
  return "$status"
}
trap cleanup EXIT

launch_owned_app >/dev/null
SNAPSHOT="$(wait_snapshot)"

ORIGINAL_BEHAVIOR_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SNAPSHOT"])
print(json.dumps(data["behavior"], ensure_ascii=False))
PY
)"
ORIGINAL_PLACEMENT_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SNAPSHOT"])
print(json.dumps(data["overlay_placement"], ensure_ascii=False))
PY
)"
RESTORE_STATE=1

TARGET="$(swift - <<'SWIFT'
import AppKit
import Foundation

guard let screen = NSScreen.main ?? NSScreen.screens.first else {
    fputs("no screen\n", stderr)
    exit(1)
}
let frame = screen.frame
let visible = screen.visibleFrame
let target = [
    "x": visible.midX,
    "y": visible.midY,
    // Match the product's first-run overlay scale. Values below the supported
    // range intentionally resolve to this default instead of creating a tiny,
    // inaccessible target.
    "scale": 0.72,
    "display_id": String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0),
    "display_height": frame.height
] as [String : Any]
let data = try JSONSerialization.data(withJSONObject: target, options: [])
print(String(data: data, encoding: .utf8)!)
SWIFT
)"

read -r TARGET_X TARGET_Y TARGET_SCALE TARGET_DISPLAY_ID <<<"$(TARGET="$TARGET" python3 - <<'PY'
import json
import os

target = json.loads(os.environ["TARGET"])
print(target["x"], target["y"], target["scale"], target["display_id"])
PY
)"

TEST_BEHAVIOR_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SNAPSHOT"])
behavior = dict(data["behavior"])
behavior["enabled"] = True
behavior["status_bubble"] = True
behavior["click_menu"] = True
behavior["mouse_passthrough"] = True
behavior["auto_hide"] = False
behavior.setdefault("sources", {})
behavior.setdefault("events", {})
for source in ["codex", "claude_code", "pi", "opencode"]:
    behavior["sources"][source] = True
for event in ["start", "tool", "waiting", "review", "done", "failed"]:
    behavior["events"][event] = True
print(json.dumps(behavior, ensure_ascii=False))
PY
)"

"$PETCORE_CLI" behavior set-json --value-json "$TEST_BEHAVIOR_JSON" >/dev/null
"$PETCORE_CLI" overlay placement set \
  --x "$TARGET_X" \
  --y "$TARGET_Y" \
  --scale "$TARGET_SCALE" \
  --display-id "$TARGET_DISPLAY_ID" >/dev/null

# Allow the relaunched app to complete its initial snapshot and enter the
# long-poll before injecting the live event exercised by this interaction gate.
relaunch_owned_app >/dev/null
sleep 1.5

EVENT_ID="evt_overlay_interaction_$(date -u +%Y%m%dT%H%M%SZ)_$$"
"$PETCORE_CLI" agent ingest \
  --id "$EVENT_ID" \
  --source codex \
  --event-type tool \
  --title "桌宠交互验收" \
  --detail "验证拖动、缩放与气泡按钮" >/dev/null

sleep 0.8

SNAPSHOT="$(wait_snapshot)"
SNAPSHOT="$SNAPSHOT" TARGET="$TARGET" PETCORE_CLI="$PETCORE_CLI" APP_NAME="$APP_NAME" APP_PID="$APC_OWNED_APP_PID" swift - <<'SWIFT'
import ApplicationServices
import CoreGraphics
import Foundation

let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "AgentPetCompanion"
let appPID = Int(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1
let petcoreCLI = ProcessInfo.processInfo.environment["PETCORE_CLI"] ?? ""

func jsonFromEnv(_ key: String) -> [String: Any] {
    guard let value = ProcessInfo.processInfo.environment[key],
          let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

func runCLI(_ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: petcoreCLI)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

func snapshot() -> [String: Any] {
    guard let output = runCLI(["snapshot"]),
          let data = output.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

func placement() -> (x: Double, y: Double, scale: Double)? {
    guard let placement = snapshot()["overlay_placement"] as? [String: Any] else { return nil }
    let x = (placement["x"] as? NSNumber)?.doubleValue
    let y = (placement["y"] as? NSNumber)?.doubleValue
    let scale = (placement["scale"] as? NSNumber)?.doubleValue
    guard let x, let y, let scale else { return nil }
    return (x, y, scale)
}

struct WindowInfo {
    let id: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let layer: Int
}

func floatingWindows() -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list.compactMap { info in
        guard (info[kCGWindowOwnerName as String] as? String) == appName else { return nil }
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == appPID else { return nil }
        guard ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) != 0 else { return nil }
        guard ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { return nil }
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return WindowInfo(
            id: (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1,
            x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
            y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
            width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
            height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0,
            layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        )
    }
}

func bubbleWindow() -> WindowInfo? {
    for _ in 0..<40 {
        if let bubble = floatingWindows().first(where: {
            $0.width >= 108 && $0.width <= 310 && $0.height >= 44 && $0.height <= 70
        }) {
            return bubble
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
        return
    }
    event.post(tap: .cghidEventTap)
}

let target = jsonFromEnv("TARGET")
let displayHeight = (target["display_height"] as? NSNumber)?.doubleValue
    ?? Double(CGDisplayBounds(CGMainDisplayID()).height)

func quartzPoint(cocoaX x: Double, cocoaY y: Double) -> CGPoint {
    CGPoint(x: x, y: displayHeight - y)
}

func drag(from start: CGPoint, to end: CGPoint, steps: Int = 18) {
    postMouse(.mouseMoved, at: start)
    Thread.sleep(forTimeInterval: 0.08)
    postMouse(.leftMouseDown, at: start)
    Thread.sleep(forTimeInterval: 0.08)
    for index in 1...steps {
        let t = Double(index) / Double(steps)
        let point = CGPoint(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t
        )
        postMouse(.leftMouseDragged, at: point)
        Thread.sleep(forTimeInterval: 0.018)
    }
    postMouse(.leftMouseUp, at: end)
    Thread.sleep(forTimeInterval: 0.35)
}

func click(at point: CGPoint) {
    postMouse(.mouseMoved, at: point)
    Thread.sleep(forTimeInterval: 0.08)
    postMouse(.leftMouseDown, at: point)
    Thread.sleep(forTimeInterval: 0.05)
    postMouse(.leftMouseUp, at: point)
    Thread.sleep(forTimeInterval: 0.35)
}

guard let initial = placement() else {
    fputs("overlay interaction validation failed: no initial overlay placement\n", stderr)
    exit(1)
}

guard bubbleWindow() != nil else {
    fputs("overlay interaction validation failed: status bubble did not appear after event ingestion\n", stderr)
    for window in floatingWindows() {
        fputs("  id=\(window.id) layer=\(window.layer) frame=(\(window.x), \(window.y), \(window.width), \(window.height))\n", stderr)
    }
    exit(1)
}

let dragStart = quartzPoint(cocoaX: initial.x, cocoaY: initial.y)
let dragEnd = quartzPoint(cocoaX: initial.x + 96, cocoaY: initial.y + 42)
drag(from: dragStart, to: dragEnd)

var moved: (x: Double, y: Double, scale: Double)?
for _ in 0..<30 {
    if let next = placement(),
       abs(next.x - initial.x) >= 40,
       abs(next.y - initial.y) >= 18 {
        moved = next
        break
    }
    Thread.sleep(forTimeInterval: 0.15)
}

guard let moved else {
    fputs("overlay interaction validation failed: pet drag did not update persisted placement\n", stderr)
    if let current = placement() {
        fputs("  initial=(\(initial.x), \(initial.y)) current=(\(current.x), \(current.y))\n", stderr)
    }
    exit(1)
}

let petWidth = max(34, 230 * moved.scale)
let petHeight = max(48, 310 * moved.scale)
let resizeX = moved.x + petWidth / 2 + 8
let resizeY = moved.y - petHeight / 2 - 8
let resizeStart = quartzPoint(cocoaX: resizeX, cocoaY: resizeY)
let resizeEnd = quartzPoint(cocoaX: resizeX + 110, cocoaY: resizeY - 110)
drag(from: resizeStart, to: resizeEnd)

var resized: (x: Double, y: Double, scale: Double)?
for _ in 0..<30 {
    if let next = placement(), next.scale >= moved.scale + 0.20 {
        resized = next
        break
    }
    Thread.sleep(forTimeInterval: 0.15)
}

guard let resized else {
    fputs("overlay interaction validation failed: resize handle drag did not update scale\n", stderr)
    if let current = placement() {
        fputs("  before=\(moved.scale) current=\(current.scale)\n", stderr)
    }
    exit(1)
}

guard let bubble = bubbleWindow() else {
    fputs("overlay interaction validation failed: no status bubble panel before close click\n", stderr)
    for window in floatingWindows() {
        fputs("  id=\(window.id) layer=\(window.layer) frame=(\(window.x), \(window.y), \(window.width), \(window.height))\n", stderr)
    }
    exit(1)
}

click(at: CGPoint(x: bubble.x + 18, y: bubble.y + 18))

for _ in 0..<30 {
    if bubbleWindow() == nil {
        print("Overlay interaction validation ok")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.15)
}

fputs("overlay interaction validation failed: bubble close click did not dismiss the bubble panel\n", stderr)
exit(1)
SWIFT
