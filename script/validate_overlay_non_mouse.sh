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
  APP_NAME="$APP_NAME" APP_PID="$APC_OWNED_APP_PID" RUN_ID="$RUN_ID" EXPECTED_VERTICAL_RELATION="$expected_vertical_relation" swift - <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "AgentPetCompanion"
let appPID = Int32(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1
let runID = ProcessInfo.processInfo.environment["RUN_ID"] ?? ""
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

struct AXNode {
    let role: String
    let identifier: String
    let title: String
    let value: String
    let description: String
    let frame: CGRect?

    var strings: [String] {
        [title, value, description].filter { !$0.isEmpty }
    }
}

func collectNodes(_ element: AXUIElement, into nodes: inout [AXNode]) {
    let position = point(element, kAXPositionAttribute)
    let nodeSize = size(element, kAXSizeAttribute)
    nodes.append(AXNode(
        role: string(element, kAXRoleAttribute),
        identifier: string(element, kAXIdentifierAttribute),
        title: string(element, kAXTitleAttribute),
        value: string(element, kAXValueAttribute),
        description: string(element, kAXDescriptionAttribute),
        frame: position.flatMap { origin in nodeSize.map { CGRect(origin: origin, size: $0) } }
    ))
    if let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            collectNodes(child, into: &nodes)
        }
    }
}

guard let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
    fputs("overlay non-mouse validation failed: AX windows are unavailable\n", stderr)
    exit(1)
}

var bubbleWindow: (element: AXUIElement, frame: CGRect, nodes: [AXNode])?
var emptyWindows: [(AXUIElement, CGRect)] = []

for window in windows {
    let title = string(window, kAXTitleAttribute)
    guard let position = point(window, kAXPositionAttribute),
          let windowSize = size(window, kAXSizeAttribute) else { continue }
    let frame = CGRect(origin: position, size: windowSize)
    if title.isEmpty {
        emptyWindows.append((window, frame))
    }
    var nodes: [AXNode] = []
    collectNodes(window, into: &nodes)
    let values = nodes.flatMap(\.strings)
    let containsWaitingSession = values.contains { value in
        (value.contains("Claude 会话") || value.contains("Claude session"))
            && (value.contains("需要输入") || value.contains("Needs input"))
    }
    if values.contains("Claude Code") && containsWaitingSession {
        bubbleWindow = (window, frame, nodes)
    }
}

guard let bubble = bubbleWindow else {
    fputs("overlay non-mouse validation failed: canonical Claude waiting bubble was not found\n", stderr)
    for (index, window) in windows.enumerated() {
        var diagnosticNodes: [AXNode] = []
        collectNodes(window, into: &diagnosticNodes)
        let summary = diagnosticNodes.prefix(80).map { node in
            [node.role, node.identifier, node.title, node.value, node.description]
                .filter { !$0.isEmpty }
                .joined(separator: ":")
        }.filter { !$0.isEmpty }.joined(separator: " | ")
        let windowFrame = point(window, kAXPositionAttribute).flatMap { origin in
            size(window, kAXSizeAttribute).map { CGRect(origin: origin, size: $0) }
        } ?? .zero
        fputs("AX window \(index) title=\(string(window, kAXTitleAttribute)) frame=\(windowFrame) nodes=\(summary)\n", stderr)
    }
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

let values = bubble.nodes.flatMap(\.strings)
let requiredAgentHeaders = ["Codex", "Claude Code", "Pi Coding Agent", "OpenCode"]
let missingAgentHeaders = requiredAgentHeaders.filter { !values.contains($0) }
if !missingAgentHeaders.isEmpty {
    fputs("overlay non-mouse validation failed: grouped bubble is missing agent headers \(missingAgentHeaders)\n", stderr)
    exit(1)
}

guard let waitingNode = bubble.nodes.first(where: { node in
    node.role == kAXButtonRole as String
        && node.strings.contains(where: { value in
            (value.contains("Claude 会话") || value.contains("Claude session"))
                && (value.contains("需要输入") || value.contains("Needs input"))
                && (
                    value.contains("请回到 Agent 完成确认、回答或决策。")
                        || value.contains("Return to the agent to approve, answer, or decide.")
                )
        })
}) else {
    fputs("overlay non-mouse validation failed: actionable privacy-normalized waiting session is missing\n", stderr)
    exit(1)
}

if (!runID.isEmpty && values.contains(where: { $0.contains(runID) }))
    || values.contains(where: { $0 == "等待确认" }) {
    fputs("overlay non-mouse validation failed: raw event copy leaked into the grouped bubble\n", stderr)
    exit(1)
}

if !(bubble.frame.width >= 108 && bubble.frame.width <= 344
    && bubble.frame.height >= 70 && bubble.frame.height <= 680) {
    fputs("overlay non-mouse validation failed: grouped bubble frame is outside the supported bounds \(bubble.frame)\n", stderr)
    exit(1)
}

guard let waitingFrame = waitingNode.frame,
      waitingFrame.width >= 80,
      waitingFrame.height >= 28,
      waitingFrame.width <= bubble.frame.width,
      waitingFrame.height <= 100 else {
    fputs("overlay non-mouse validation failed: waiting session has unexpected AX frame \(String(describing: waitingNode.frame))\n", stderr)
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

validate_single_compact_bubble() {
  APP_NAME="$APP_NAME" APP_PID="$APC_OWNED_APP_PID" RUN_ID="$RUN_ID" swift - <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "AgentPetCompanion"
let appPID = Int32(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1
let runID = ProcessInfo.processInfo.environment["RUN_ID"] ?? ""

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

struct AXNode {
    let role: String
    let title: String
    let value: String
    let description: String
    let frame: CGRect?

    var strings: [String] {
        [title, value, description].filter { !$0.isEmpty }
    }
}

func collectNodes(_ element: AXUIElement, into nodes: inout [AXNode]) {
    let position = point(element, kAXPositionAttribute)
    let nodeSize = size(element, kAXSizeAttribute)
    nodes.append(AXNode(
        role: string(element, kAXRoleAttribute),
        title: string(element, kAXTitleAttribute),
        value: string(element, kAXValueAttribute),
        description: string(element, kAXDescriptionAttribute),
        frame: position.flatMap { origin in nodeSize.map { CGRect(origin: origin, size: $0) } }
    ))
    if let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            collectNodes(child, into: &nodes)
        }
    }
}

guard let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
    fputs("overlay short-bubble validation failed: AX windows are unavailable\n", stderr)
    exit(1)
}

var candidates: [(frame: CGRect, nodes: [AXNode])] = []
for window in windows where string(window, kAXTitleAttribute).isEmpty {
    guard let position = point(window, kAXPositionAttribute),
          let windowSize = size(window, kAXSizeAttribute) else { continue }
    var nodes: [AXNode] = []
    collectNodes(window, into: &nodes)
    let values = nodes.flatMap(\.strings)
    let containsDoneSession = values.contains { value in
        (value.contains("Codex 会话") || value.contains("Codex session"))
            && (value.contains("已完成") || value.contains("Completed"))
    }
    if values.contains("Codex") && containsDoneSession {
        candidates.append((CGRect(origin: position, size: windowSize), nodes))
    }
}

guard let bubble = candidates.sorted(by: { $0.frame.width < $1.frame.width }).first else {
    fputs("overlay short-bubble validation failed: compact Codex done bubble not found\n", stderr)
    exit(1)
}

let values = bubble.nodes.flatMap(\.strings)
let forbidden = ["Claude Code", "Pi Coding Agent", "OpenCode"].filter(values.contains)
if !forbidden.isEmpty {
    fputs("overlay short-bubble validation failed: single-agent bubble contains extra agents \(forbidden)\n", stderr)
    exit(1)
}

guard let doneNode = bubble.nodes.first(where: { node in
    node.role == kAXButtonRole as String
        && node.strings.contains(where: { value in
            (value.contains("Codex 会话") || value.contains("Codex session"))
                && (value.contains("已完成") || value.contains("Completed"))
                && (
                    value.contains("Agent 已完成任务。")
                        || value.contains("The agent finished the task.")
                )
        })
}) else {
    fputs("overlay short-bubble validation failed: actionable normalized done session is missing\n", stderr)
    exit(1)
}

if (!runID.isEmpty && values.contains(where: { $0.contains(runID) }))
    || values.contains(where: { $0.hasPrefix("短消息 ") }) {
    fputs("overlay short-bubble validation failed: raw completion copy leaked into the bubble\n", stderr)
    exit(1)
}

if !(bubble.frame.width >= 108 && bubble.frame.width <= 344
    && bubble.frame.height >= 70 && bubble.frame.height <= 130) {
    fputs("overlay short-bubble validation failed: single-agent bubble is outside the supported bounds, frame=\(bubble.frame)\n", stderr)
    exit(1)
}

guard let doneFrame = doneNode.frame,
      doneFrame.width >= 80,
      doneFrame.height >= 28,
      doneFrame.width <= bubble.frame.width,
      doneFrame.height <= 100 else {
    fputs("overlay short-bubble validation failed: done session metrics unexpected, frame=\(String(describing: doneNode.frame))\n", stderr)
    exit(1)
}

print("Overlay single-agent non-mouse check ok: bubble=\(Int(bubble.frame.width))x\(Int(bubble.frame.height))")
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
validate_single_compact_bubble

echo "Overlay non-mouse validation ok: $RUN_ID"
