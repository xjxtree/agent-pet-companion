#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "overlay runtime validation"
APP_NAME="${APC_OVERLAY_APP_NAME:-AgentPetCompanion}"
PETCORE_CLI="${1:-$ROOT_DIR/target/debug/petcore-cli}"
RESTORE_BEHAVIOR=0
ORIGINAL_BEHAVIOR_JSON=""

restore_overlay_behavior() {
  if [[ "$RESTORE_BEHAVIOR" == "1" && -n "$ORIGINAL_BEHAVIOR_JSON" ]]; then
    "$PETCORE_CLI" behavior set-json --value-json "$ORIGINAL_BEHAVIOR_JSON" >/dev/null 2>&1 || true
  fi
}
trap restore_overlay_behavior EXIT

if [[ ! -x "$PETCORE_CLI" ]]; then
  echo "overlay runtime validation skipped: petcore-cli is unavailable at $PETCORE_CLI"
  exit 0
fi

SNAPSHOT=""
for _ in {1..40}; do
  SNAPSHOT="$("$PETCORE_CLI" snapshot 2>/dev/null || true)"
  OVERLAY_STATE="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("SNAPSHOT", "{}"))
except json.JSONDecodeError:
    print("invalid")
    raise SystemExit

behavior = data.get("behavior")
if not isinstance(behavior, dict):
    print("invalid")
elif behavior.get("enabled", False):
    print("enabled")
else:
    print("disabled")
PY
)"
  if [[ "$OVERLAY_STATE" != "invalid" ]]; then
    break
  fi
  sleep 0.25
done

if [[ "$OVERLAY_STATE" == "invalid" ]]; then
  echo "overlay runtime validation failed: petcore snapshot is unavailable" >&2
  exit 1
fi

if [[ "$OVERLAY_STATE" == "disabled" ]]; then
  ORIGINAL_BEHAVIOR_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SNAPSHOT"])
print(json.dumps(data["behavior"], ensure_ascii=False))
PY
)"
  ENABLED_BEHAVIOR_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SNAPSHOT"])
behavior = dict(data["behavior"])
behavior["enabled"] = True
behavior["status_bubble"] = True
behavior["auto_hide"] = False
print(json.dumps(behavior, ensure_ascii=False))
PY
)"
  "$PETCORE_CLI" behavior set-json --value-json "$ENABLED_BEHAVIOR_JSON" >/dev/null
  RESTORE_BEHAVIOR=1

  for _ in {1..40}; do
    SNAPSHOT="$("$PETCORE_CLI" snapshot 2>/dev/null || true)"
    OVERLAY_STATE="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("SNAPSHOT", "{}"))
except json.JSONDecodeError:
    print("invalid")
    raise SystemExit

behavior = data.get("behavior")
if not isinstance(behavior, dict):
    print("invalid")
elif behavior.get("enabled", False):
    print("enabled")
else:
    print("disabled")
PY
)"
    [[ "$OVERLAY_STATE" == "enabled" ]] && break
    sleep 0.25
  done

  if [[ "$OVERLAY_STATE" != "enabled" ]]; then
    echo "overlay runtime validation failed: desktop pet could not be enabled for validation" >&2
    exit 1
  fi
fi

SNAPSHOT="$SNAPSHOT" swift - "$APP_NAME" <<'SWIFT'
import CoreGraphics
import Foundation

let appName = CommandLine.arguments.dropFirst().first ?? "AgentPetCompanion"
let snapshotObject = (try? JSONSerialization.jsonObject(
    with: Data((ProcessInfo.processInfo.environment["SNAPSHOT"] ?? "{}").utf8)
)) as? [String: Any] ?? [:]
let placement = snapshotObject["overlay_placement"] as? [String: Any] ?? [:]
let behavior = snapshotObject["behavior"] as? [String: Any] ?? [:]
let activeEvents = ((snapshotObject["events"] as? [Any])?.isEmpty == false)
let persistedX = (placement["x"] as? NSNumber)?.doubleValue ?? 0
let persistedY = (placement["y"] as? NSNumber)?.doubleValue ?? 0
let persistedScale = (placement["scale"] as? NSNumber)?.doubleValue ?? 0
let hasPersistedPosition = persistedX != 0 || persistedY != 0
let scale = hasPersistedPosition && persistedScale.isFinite && persistedScale > 0
    ? max(0.10, min(1.8, persistedScale))
    : 0.72
let expectsBubble = (behavior["status_bubble"] as? Bool ?? true)
    && activeEvents

struct WindowInfo {
    let id: Int
    let layer: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

func agentWindows() -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return list.compactMap { info in
        guard (info[kCGWindowOwnerName as String] as? String) == appName else { return nil }
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0 else { return nil }
        return WindowInfo(
            id: (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1,
            layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
            y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
            width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
            height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
        )
    }
}

var windows: [WindowInfo] = []
for _ in 0..<40 {
    windows = agentWindows()
    let floatingWindows = windows.filter { $0.layer != 0 }
    if expectsBubble {
        if floatingWindows.contains(where: isBubblePanel) {
            break
        }
    } else if !floatingWindows.isEmpty {
        break
    }
    Thread.sleep(forTimeInterval: 0.25)
}

let floating = windows.filter { $0.layer != 0 }
if floating.isEmpty {
    fputs("overlay runtime validation failed: no floating pet windows found\n", stderr)
    exit(1)
}

let petVisibleWidth = max(34, 230 * scale)
let petVisibleHeight = max(48, 310 * scale)
let petMaxWidth = max(150, petVisibleWidth + 96)
let petMaxHeight = max(170, petVisibleHeight + 96)

func isPetPanel(_ window: WindowInfo) -> Bool {
    // The panel can briefly be smaller than the persisted scale immediately after
    // placement restoration; that is safe. Large panels are what block desktop input.
    window.width >= 28
        && window.height >= 40
        && window.width <= petMaxWidth
        && window.height <= petMaxHeight
}

func isBubblePanel(_ window: WindowInfo) -> Bool {
    window.width >= 140
        && window.width <= 430
        && window.height >= 48
        && window.height <= 360
}

let petPanels = floating.filter(isPetPanel)
if petPanels.isEmpty {
    fputs("overlay runtime validation failed: no compact pet panel found\n", stderr)
    for window in floating {
        fputs("  id=\(window.id) layer=\(window.layer) frame=(\(window.x), \(window.y), \(window.width), \(window.height))\n", stderr)
    }
    exit(1)
}

let bubblePanels = floating.filter(isBubblePanel)
if expectsBubble && bubblePanels.isEmpty {
    fputs("overlay runtime validation failed: status bubble is enabled but no compact bubble panel was found\n", stderr)
    for window in floating {
        fputs("  id=\(window.id) layer=\(window.layer) frame=(\(window.x), \(window.y), \(window.width), \(window.height))\n", stderr)
    }
    exit(1)
}

let unexpected = floating.filter { !isPetPanel($0) && !isBubblePanel($0) }
if !unexpected.isEmpty {
    fputs("overlay runtime validation failed: unexpected floating window size may block desktop input:\n", stderr)
    for window in unexpected {
        fputs("  id=\(window.id) layer=\(window.layer) frame=(\(window.x), \(window.y), \(window.width), \(window.height)) scale=\(scale)\n", stderr)
    }
    exit(1)
}

print("Overlay runtime validation ok")
SWIFT
