#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "audit screenshot capture"

OUTPUT_DIR="${1:-$ROOT_DIR/docs/audits/2026-07-10-project-review/screenshots/after}"
APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="$APP_BUNDLE/Contents/Resources/bin/petcore-cli"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-audit-capture.XXXXXX")"
apc_use_isolated_home "$TMP_DIR"
OWNED_PROTOCOL="$APC_HOME/run/validation-owned-runtime.json"
APP_LOG="$TMP_DIR/app.log"

cleanup() {
  apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
"$ROOT_DIR/script/build_app_bundle.sh" >/dev/null
command -v ffmpeg >/dev/null
command -v ffprobe >/dev/null

for quality in high ultra original; do
  source_dir="$TMP_DIR/$quality-source"
  "$PETCORE_CLI" petpack sample --output "$source_dir" --quality "$quality" --frames 2 >/dev/null
  APC_HOME="$APC_HOME" "$PETCORE_CLI" petpack import --offline "$source_dir" >/dev/null
done

export APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK=1
export APC_DISABLE_CODEX_APP_SERVER_AUTO=1
apc_start_owned_runtime \
  "$APP_BINARY" \
  "$PETCORE_CLI" \
  "$PETCORE_BINARY" \
  "$APP_LOG" \
  "$OWNED_PROTOCOL"

for _ in {1..80}; do
  if "$PETCORE_CLI" snapshot >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

main_window_id() {
  local action="$1"
  local width="$2"
  local height="$3"
  ACTION="$action" WIDTH="$width" HEIGHT="$height" APP_PID="$APC_OWNED_APP_PID" swift - <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let pid = Int32(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1
let action = ProcessInfo.processInfo.environment["ACTION"] ?? "none"
let width = Double(ProcessInfo.processInfo.environment["WIDTH"] ?? "") ?? 1296
let height = Double(ProcessInfo.processInfo.environment["HEIGHT"] ?? "") ?? 768
let axApp = AXUIElementCreateApplication(pid)

func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        ? value
        : nil
}

func string(_ element: AXUIElement, _ attribute: String) -> String {
    (copy(element, attribute) as? String) ?? ""
}

func collect(_ element: AXUIElement, into values: inout [AXUIElement]) {
    values.append(element)
    if let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            collect(child, into: &values)
        }
    }
}

guard let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement],
      let mainWindow = windows.first(where: { string($0, kAXTitleAttribute) == "Agent Pet Companion" })
else {
    fputs("audit capture failed: main AX window not found\n", stderr)
    exit(1)
}

var size = CGSize(width: width, height: height)
if let value = AXValueCreate(.cgSize, &size) {
    _ = AXUIElementSetAttributeValue(mainWindow, kAXSizeAttribute as CFString, value)
}
var position = CGPoint(x: 64, y: 72)
if let value = AXValueCreate(.cgPoint, &position) {
    _ = AXUIElementSetAttributeValue(mainWindow, kAXPositionAttribute as CFString, value)
}

let actionLabels: [String: (roles: Set<String>, labels: [String])] = [
    "studio": ([kAXButtonRole as String], ["宠物 Studio", "Pet Studio"]),
    "behavior": ([kAXButtonRole as String], ["启用与行为", "Enable & Behavior"]),
    "connections": ([kAXButtonRole as String], ["Agent 连接", "Agent Connections"]),
    "new": ([kAXRadioButtonRole as String], ["新建", "New"]),
    "library": ([kAXRadioButtonRole as String], ["宠物库", "Pet Library"]),
]

if action == "start-generation" {
    var elements: [AXUIElement] = []
    collect(mainWindow, into: &elements)
    guard let description = elements.first(where: { element in
        string(element, kAXRoleAttribute) == kAXTextAreaRole as String
            && string(element, kAXDescriptionAttribute) == "宠物描述"
    }) else {
        fputs("audit capture failed: pet description text area not found\n", stderr)
        exit(1)
    }
    guard AXUIElementSetAttributeValue(
        description,
        kAXValueAttribute as CFString,
        "安静陪伴的东方幻想角色，等待确认时抬头提醒。" as CFTypeRef
    ) == .success else {
        fputs("audit capture failed: could not set pet description\n", stderr)
        exit(1)
    }
    usleep(250_000)
    elements.removeAll(keepingCapacity: true)
    collect(mainWindow, into: &elements)
    guard let start = elements.first(where: { element in
        string(element, kAXRoleAttribute) == kAXButtonRole as String
            && [
                string(element, kAXTitleAttribute),
                string(element, kAXValueAttribute),
                string(element, kAXDescriptionAttribute),
            ].contains("发起 AI 辅助会话")
    }), AXUIElementPerformAction(start, kAXPressAction as CFString) == .success else {
        fputs("audit capture failed: generation action was not available\n", stderr)
        exit(1)
    }
} else if let target = actionLabels[action] {
    var elements: [AXUIElement] = []
    collect(mainWindow, into: &elements)
    guard let control = elements.first(where: { element in
        let role = string(element, kAXRoleAttribute)
        guard target.roles.contains(role) else { return false }
        let values = [
            string(element, kAXTitleAttribute),
            string(element, kAXValueAttribute),
            string(element, kAXDescriptionAttribute),
        ]
        return target.labels.contains(where: values.contains)
    }) else {
        fputs("audit capture failed: AX control not found for \(action)\n", stderr)
        exit(1)
    }
    guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else {
        fputs("audit capture failed: AXPress failed for \(action)\n", stderr)
        exit(1)
    }
}

_ = AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)
NSRunningApplication(processIdentifier: pid)?.activate(options: [])
usleep(900_000)

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
guard let info = infos.first(where: { item in
    (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        && (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        && (item[kCGWindowName as String] as? String) == "Agent Pet Companion"
}), let number = info[kCGWindowNumber as String] as? NSNumber else {
    fputs("audit capture failed: main CGWindow not found\n", stderr)
    exit(1)
}
print(number.intValue)
SWIFT
}

flatten_window_capture() {
  local raw_path="$1"
  local output_path="$2"
  local size
  size="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$raw_path")"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "color=c=white:s=$size" \
    -i "$raw_path" \
    -filter_complex '[0:v][1:v]overlay=shortest=1:format=auto,format=rgb24' \
    -frames:v 1 "$output_path"
}

capture_main() {
  local action="$1"
  local width="$2"
  local height="$3"
  local name="$4"
  local window_id raw_path
  window_id="$(main_window_id "$action" "$width" "$height")"
  raw_path="$TMP_DIR/$name"
  /usr/sbin/screencapture -x -o -tpng -l"$window_id" "$raw_path"
  flatten_window_capture "$raw_path" "$OUTPUT_DIR/$name"
  [[ -s "$OUTPUT_DIR/$name" ]]
}

pet_window_id() {
  APP_PID="$APC_OWNED_APP_PID" swift - <<'SWIFT'
import CoreGraphics
import Foundation

let pid = Int32(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let candidates: [(number: Int, area: Double)] = infos.compactMap { item in
    guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          ((item[kCGWindowName as String] as? String) ?? "").isEmpty,
          let number = item[kCGWindowNumber as String] as? NSNumber,
          let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let width = (bounds["Width"] as? NSNumber)?.doubleValue,
          let height = (bounds["Height"] as? NSNumber)?.doubleValue,
          width >= 28, height >= 40
    else { return nil }
    return (number.intValue, width * height)
}
guard let candidate = candidates.min(by: { $0.area < $1.area }) else {
    fputs("audit capture failed: pet overlay CGWindow not found\n", stderr)
    exit(1)
}
print(candidate.number)
SWIFT
}

capture_main none 760 552 01-pet-studio-new.png
capture_main studio 1296 768 02-pet-studio-new-wide.png
capture_main library 1296 768 03-pet-library.png
capture_main behavior 1296 768 04-enable-behavior.png
capture_main connections 1296 768 05-agent-connections.png

main_window_id studio 1296 768 >/dev/null
main_window_id new 1296 768 >/dev/null
capture_main start-generation 1296 768 08-ai-session-retry.png

HIDDEN_BUBBLE_BEHAVIOR='{"enabled":true,"status_bubble":true,"click_menu":true,"mouse_passthrough":true,"auto_hide":true,"fps_profile":"standard","sources":{"codex":false,"claude_code":false,"pi":false,"opencode":false},"events":{"start":true,"tool":true,"waiting":true,"review":true,"done":true,"failed":true}}'
"$PETCORE_CLI" behavior set-json --value-json "$HIDDEN_BUBBLE_BEHAVIOR" >/dev/null
"$PETCORE_CLI" overlay placement set --x 900 --y 180 --scale 0.12 --display-id audit-capture >/dev/null
sleep 1
overlay_id="$(pet_window_id)"
raw_overlay="$TMP_DIR/06-overlay-collapsed.png"
/usr/sbin/screencapture -x -o -tpng -l"$overlay_id" "$raw_overlay"
flatten_window_capture "$raw_overlay" "$OUTPUT_DIR/06-overlay-collapsed.png"

"$PETCORE_CLI" overlay placement set --x 900 --y 180 --scale 0.24 --display-id audit-capture >/dev/null
sleep 1
overlay_id="$(pet_window_id)"
raw_overlay="$TMP_DIR/07-overlay-large.png"
/usr/sbin/screencapture -x -o -tpng -l"$overlay_id" "$raw_overlay"
flatten_window_capture "$raw_overlay" "$OUTPUT_DIR/07-overlay-large.png"

find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.png' -print0 \
  | xargs -0 file \
  | grep -q 'PNG image data'
printf 'Audit screenshots captured in %s\n' "$OUTPUT_DIR"
