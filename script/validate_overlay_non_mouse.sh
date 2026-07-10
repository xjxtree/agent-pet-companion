#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "overlay non-mouse validation"
APP_NAME="${APC_OVERLAY_APP_NAME:-AgentPetCompanion}"
APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="${1:-$APP_BUNDLE/Contents/Resources/bin/petcore-cli}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-overlay-non-mouse.XXXXXX")"
apc_use_isolated_home "$TMP_DIR"
OWNED_PROTOCOL="$APC_HOME/run/validation-owned-runtime.json"
APP_LOG="$TMP_DIR/app.log"
RUN_ID="overlay_nomouse_$(date -u +%Y%m%dT%H%M%SZ)_$$"
ORIGINAL_BEHAVIOR_JSON=""
ORIGINAL_PLACEMENT_JSON=""

restore_state() {
  if [[ -x "$PETCORE_CLI" && -n "$ORIGINAL_BEHAVIOR_JSON" ]]; then
    "$PETCORE_CLI" behavior set-json --value-json "$ORIGINAL_BEHAVIOR_JSON" >/dev/null 2>&1 || true
  fi
  if [[ -x "$PETCORE_CLI" && -n "$ORIGINAL_PLACEMENT_JSON" ]]; then
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
}

cleanup() {
  restore_state
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

required = {"behavior", "overlay_placement", "events"}
sys.exit(0 if required.issubset(data.keys()) else 1)
PY
    then
      printf '%s\n' "$snapshot"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

SNAPSHOT="$(wait_snapshot)"
ORIGINAL_BEHAVIOR_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

print(json.dumps(json.loads(os.environ["SNAPSHOT"])["behavior"], ensure_ascii=False))
PY
)"
ORIGINAL_PLACEMENT_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

print(json.dumps(json.loads(os.environ["SNAPSHOT"])["overlay_placement"], ensure_ascii=False))
PY
)"

ENABLED_BEHAVIOR_JSON="$(SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SNAPSHOT"])
behavior = dict(data["behavior"])
behavior["enabled"] = True
behavior["status_bubble"] = True
behavior["click_menu"] = True
behavior["mouse_passthrough"] = True
behavior["auto_hide"] = False
for key in ["codex", "claude_code", "pi", "opencode"]:
    behavior.setdefault("sources", {})[key] = True
for key in ["start", "tool", "waiting", "review", "done", "failed"]:
    behavior.setdefault("events", {})[key] = True
print(json.dumps(behavior, ensure_ascii=False))
PY
)"
"$PETCORE_CLI" behavior set-json --value-json "$ENABLED_BEHAVIOR_JSON" >/dev/null

read -r MIN_X MIN_Y MAX_X MAX_Y MID_X MID_Y <<<"$(swift - <<'SWIFT'
import AppKit
let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
print(Int(frame.minX), Int(frame.minY), Int(frame.maxX), Int(frame.maxY), Int(frame.midX), Int(frame.midY))
SWIFT
)"

BOTTOM_X=$((MAX_X - 170))
BOTTOM_Y=$((MIN_Y + 110))
TOP_X=$((MAX_X - 170))
TOP_Y=$((MAX_Y - 90))

ingest_event() {
  local source="$1"
  local event_type="$2"
  local title="$3"
  local detail="$4"
  "$PETCORE_CLI" agent ingest \
    --id "${RUN_ID}_${source}_${event_type}" \
    --source "$source" \
    --event-type "$event_type" \
    --title "$title" \
    --detail "$detail" >/dev/null
}

ingest_event codex tool "执行工具" "OK"
ingest_event claude_code waiting "等待确认" "这是一条较长的 Claude Code 无鼠标验证消息 ${RUN_ID}，用来确认最大宽度、自动换行以及最多两行截断。"
ingest_event pi start "开始处理" "Pi 已开始 ${RUN_ID}"
ingest_event opencode review "待查看" "OpenCode 有内容待查看 ${RUN_ID}"

validate_overlay_ax() {
  local expected_vertical_relation="$1"
  APP_NAME="$APP_NAME" APP_PID="$APC_OWNED_APP_PID" EXPECTED_VERTICAL_RELATION="$expected_vertical_relation" swift - <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "AgentPetCompanion"
let appPID = Int32(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1
let relation = ProcessInfo.processInfo.environment["EXPECTED_VERTICAL_RELATION"] ?? "above"

guard let app = NSRunningApplication(processIdentifier: appPID),
      (app.executableURL?.lastPathComponent == appName || app.localizedName == appName) else {
    fputs("overlay non-mouse validation failed: app is not running\n", stderr)
    exit(1)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

func copy(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ attr: String) -> String {
    (copy(element, attr) as? String) ?? ""
}

func point(_ element: AXUIElement, _ attr: String) -> CGPoint? {
    guard let value = copy(element, attr) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func size(_ element: AXUIElement, _ attr: String) -> CGSize? {
    guard let value = copy(element, attr) else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

struct TextNode {
    let value: String
    let frame: CGRect
}

func collectTexts(_ element: AXUIElement, into texts: inout [TextNode]) {
    let role = string(element, kAXRoleAttribute)
    let value = string(element, kAXValueAttribute)
    if role == kAXStaticTextRole as String, !value.isEmpty,
       let position = point(element, kAXPositionAttribute),
       let nodeSize = size(element, kAXSizeAttribute) {
        texts.append(TextNode(value: value, frame: CGRect(origin: position, size: nodeSize)))
    }
    if let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            collectTexts(child, into: &texts)
        }
    }
}

guard let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
    fputs("overlay non-mouse validation failed: AX windows are unavailable\n", stderr)
    exit(1)
}

var bubbleWindow: (element: AXUIElement, frame: CGRect, texts: [TextNode])?
var emptyWindows: [(AXUIElement, CGRect)] = []

for window in windows {
    let title = string(window, kAXTitleAttribute)
    guard let position = point(window, kAXPositionAttribute),
          let windowSize = size(window, kAXSizeAttribute) else { continue }
    let frame = CGRect(origin: position, size: windowSize)
    if title.isEmpty {
        emptyWindows.append((window, frame))
    }
    var texts: [TextNode] = []
    collectTexts(window, into: &texts)
    let values = Set(texts.map(\.value))
    if values.contains("Claude") && values.contains("等待确认") {
        bubbleWindow = (window, frame, texts)
    }
}

guard let bubble = bubbleWindow else {
    fputs("overlay non-mouse validation failed: canonical Claude waiting bubble was not found\n", stderr)
    exit(1)
}

var petCandidates: [CGRect] = []
for (_, frame) in emptyWindows {
    let compact = frame.width >= 28
        && frame.width <= 220
        && frame.height >= 40
        && frame.height <= 260
    if compact && frame != bubble.frame {
        petCandidates.append(frame)
    }
}
let sortedPetCandidates = petCandidates.sorted { lhs, rhs in
    (lhs.width * lhs.height) < (rhs.width * rhs.height)
}
guard let pet = sortedPetCandidates.first else {
    fputs("overlay non-mouse validation failed: compact pet panel was not found\n", stderr)
    exit(1)
}

let values = Set(bubble.texts.map(\.value))
let forbiddenAgents = ["Codex", "Pi", "OpenCode"].filter(values.contains)
if !forbiddenAgents.isEmpty {
    fputs("overlay non-mouse validation failed: canonical bubble contains lower-priority agents \(forbiddenAgents)\n", stderr)
    exit(1)
}

guard let messageText = bubble.texts.first(where: { $0.value == "等待确认" }) else {
    fputs("overlay non-mouse validation failed: privacy-normalized waiting message is missing\n", stderr)
    exit(1)
}

if !(bubble.frame.width >= 112 && bubble.frame.width <= 190 && bubble.frame.height >= 44 && bubble.frame.height <= 70) {
    fputs("overlay non-mouse validation failed: unexpected canonical bubble frame \(bubble.frame)\n", stderr)
    exit(1)
}

if messageText.frame.height > 20 || messageText.frame.width > 80 {
    fputs("overlay non-mouse validation failed: normalized message metrics unexpected, frame=\(messageText.frame)\n", stderr)
    exit(1)
}

let bubbleAbovePet = bubble.frame.midY < pet.midY
if relation == "above", !bubbleAbovePet {
    fputs("overlay non-mouse validation failed: bubble should be above pet near bottom edge\n", stderr)
    exit(1)
}
if relation == "below", bubbleAbovePet {
    fputs("overlay non-mouse validation failed: bubble should move below pet near top edge\n", stderr)
    exit(1)
}

print("Overlay AX non-mouse check ok: relation=\(relation) bubble=\(Int(bubble.frame.width))x\(Int(bubble.frame.height)) pet=\(Int(pet.width))x\(Int(pet.height))")
SWIFT
}

validate_single_short_bubble() {
  APP_NAME="$APP_NAME" APP_PID="$APC_OWNED_APP_PID" swift - <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "AgentPetCompanion"
let appPID = Int32(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1

guard let app = NSRunningApplication(processIdentifier: appPID),
      (app.executableURL?.lastPathComponent == appName || app.localizedName == appName) else {
    fputs("overlay short-bubble validation failed: app is not running\n", stderr)
    exit(1)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

func copy(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ attr: String) -> String {
    (copy(element, attr) as? String) ?? ""
}

func point(_ element: AXUIElement, _ attr: String) -> CGPoint? {
    guard let value = copy(element, attr) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func size(_ element: AXUIElement, _ attr: String) -> CGSize? {
    guard let value = copy(element, attr) else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

struct TextNode {
    let value: String
    let frame: CGRect
}

func collectTexts(_ element: AXUIElement, into texts: inout [TextNode]) {
    let role = string(element, kAXRoleAttribute)
    let value = string(element, kAXValueAttribute)
    if role == kAXStaticTextRole as String, !value.isEmpty,
       let position = point(element, kAXPositionAttribute),
       let nodeSize = size(element, kAXSizeAttribute) {
        texts.append(TextNode(value: value, frame: CGRect(origin: position, size: nodeSize)))
    }
    if let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            collectTexts(child, into: &texts)
        }
    }
}

guard let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
    fputs("overlay short-bubble validation failed: AX windows are unavailable\n", stderr)
    exit(1)
}

var candidates: [(frame: CGRect, texts: [TextNode])] = []
for window in windows where string(window, kAXTitleAttribute).isEmpty {
    guard let position = point(window, kAXPositionAttribute),
          let windowSize = size(window, kAXSizeAttribute) else { continue }
    var texts: [TextNode] = []
    collectTexts(window, into: &texts)
    let values = Set(texts.map(\.value))
    if values.contains("Codex") && values.contains("完成") {
        candidates.append((CGRect(origin: position, size: windowSize), texts))
    }
}

guard let bubble = candidates.sorted(by: { $0.frame.width < $1.frame.width }).first else {
    fputs("overlay short-bubble validation failed: compact Codex done bubble not found\n", stderr)
    exit(1)
}

let values = Set(bubble.texts.map(\.value))
let forbidden = ["Claude", "Pi", "OpenCode"].filter(values.contains)
if !forbidden.isEmpty {
    fputs("overlay short-bubble validation failed: single-agent bubble contains extra agents \(forbidden)\n", stderr)
    exit(1)
}

guard let doneText = bubble.texts.first(where: { $0.value == "完成" }) else {
    fputs("overlay short-bubble validation failed: normalized done text missing\n", stderr)
    exit(1)
}

if !(bubble.frame.width >= 112 && bubble.frame.width <= 170 && bubble.frame.height >= 44 && bubble.frame.height <= 66) {
    fputs("overlay short-bubble validation failed: short bubble did not shrink to content, frame=\(bubble.frame)\n", stderr)
    exit(1)
}

if doneText.frame.height > 18 || doneText.frame.width > 36 {
    fputs("overlay short-bubble validation failed: done text metrics unexpected, frame=\(doneText.frame)\n", stderr)
    exit(1)
}

print("Overlay short-bubble non-mouse check ok: bubble=\(Int(bubble.frame.width))x\(Int(bubble.frame.height))")
SWIFT
}

"$PETCORE_CLI" overlay placement set \
  --x "$BOTTOM_X" \
  --y "$BOTTOM_Y" \
  --scale 0.12 \
  --display-id overlay-nomouse-bottom >/dev/null
sleep 1.5
validate_overlay_ax above

"$PETCORE_CLI" overlay placement set \
  --x "$TOP_X" \
  --y "$TOP_Y" \
  --scale 0.12 \
  --display-id overlay-nomouse-top >/dev/null
sleep 1.5
validate_overlay_ax below

CODEX_ONLY_BEHAVIOR_JSON="$(SNAPSHOT="$(wait_snapshot)" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["SNAPSHOT"])
behavior = dict(data["behavior"])
for key in ["codex", "claude_code", "pi", "opencode"]:
    behavior.setdefault("sources", {})[key] = key == "codex"
print(json.dumps(behavior, ensure_ascii=False))
PY
)"
"$PETCORE_CLI" behavior set-json --value-json "$CODEX_ONLY_BEHAVIOR_JSON" >/dev/null
ingest_event codex done "短消息 ${RUN_ID}" "OK"
sleep 1.5
validate_single_short_bubble

echo "Overlay non-mouse validation ok: $RUN_ID"
