#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "main window UI validation"
APP_NAME="${APC_MAIN_UI_APP_NAME:-AgentPetCompanion}"
APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="$APP_BUNDLE/Contents/Resources/bin/petcore-cli"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-main-window-ui.XXXXXX")"
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

# Exercise the populated Pet Library rather than accidentally depending on a
# developer's existing pet data. All assets stay inside this validation HOME.
PET_SOURCE="$TMP_DIR/library-pet"
"$PETCORE_CLI" petpack sample --output "$PET_SOURCE" --quality high --frames 2 >/dev/null
"$PETCORE_CLI" petpack import "$PET_SOURCE" >/dev/null

APP_NAME="$APP_NAME" APP_PID="$APC_OWNED_APP_PID" swift - <<'SWIFT'
import AppKit
import ApplicationServices
import Foundation

let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "AgentPetCompanion"
let appPID = Int32(ProcessInfo.processInfo.environment["APP_PID"] ?? "") ?? -1

guard let app = NSRunningApplication(processIdentifier: appPID),
      app.executableURL?.lastPathComponent == appName || app.localizedName == appName else {
    fputs("main window UI validation failed: app is not running\n", stderr)
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

func actions(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
    return value as? [String] ?? []
}

struct Node {
    let element: AXUIElement
    let role: String
    let title: String
    let value: String
    let description: String
    let frame: CGRect?

    var strings: [String] {
        [title, value, description].filter { !$0.isEmpty }
    }
}

func collect(_ element: AXUIElement, into nodes: inout [Node]) {
    let position = point(element, kAXPositionAttribute)
    let nodeSize = size(element, kAXSizeAttribute)
    nodes.append(Node(
        element: element,
        role: string(element, kAXRoleAttribute),
        title: string(element, kAXTitleAttribute),
        value: string(element, kAXValueAttribute),
        description: string(element, kAXDescriptionAttribute),
        frame: position.flatMap { origin in nodeSize.map { CGRect(origin: origin, size: $0) } }
    ))

    if let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            collect(child, into: &nodes)
        }
    }
}

func snapshotNodes(_ root: AXUIElement) -> [Node] {
    var nodes: [Node] = []
    collect(root, into: &nodes)
    return nodes
}

let supportedMainWindowTitles: Set<String> = [
    "Agent Pet Companion",
    "宠物库", "Pet Library",
    "AI宠物制作", "AI Pet Maker",
    "宠物配置", "Pet Configuration",
    "Agent 连接", "Agent Connections",
    "服务与诊断", "Service & Diagnostics",
]
var resolvedMainWindow: AXUIElement?
for _ in 0..<40 {
    let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
    resolvedMainWindow = windows.first(where: {
        supportedMainWindowTitles.contains(string($0, kAXTitleAttribute))
    })
    if resolvedMainWindow != nil {
        break
    }
    usleep(100_000)
}
guard let mainWindow = resolvedMainWindow else {
    fputs("main window UI validation failed: main window was not found\n", stderr)
    exit(1)
}

guard let mainSize = size(mainWindow, kAXSizeAttribute) else {
    fputs("main window UI validation failed: main window has no AX size\n", stderr)
    exit(1)
}
if mainSize.width < 740 || mainSize.height < 500 {
    fputs("main window UI validation failed: main window is below the supported minimum size: \(mainSize.width)x\(mainSize.height)\n", stderr)
    exit(1)
}

if mainSize.width < 1000 {
    var validationSize = CGSize(width: 1120, height: max(720, mainSize.height))
    if let sizeValue = AXValueCreate(.cgSize, &validationSize) {
        _ = AXUIElementSetAttributeValue(
            mainWindow,
            kAXSizeAttribute as CFString,
            sizeValue
        )
        usleep(300_000)
    }
}

var nodes: [Node] = []
for _ in 0..<300 {
    nodes = snapshotNodes(mainWindow)
    let strings = nodes.flatMap(\.strings)
    let libraryIsVisible = strings.contains(where: { value in
        value == "宠物库" || value == "Pet Library"
            || value.contains("宠物库") || value.contains("Pet Library")
    })
    let bundledPetsAreVisible = ["星雾团子", "Bytebud 字节芽"].allSatisfy { petName in
        strings.contains { $0 == petName || $0.contains(petName) }
    }
    if libraryIsVisible && bundledPetsAreVisible {
        break
    }
    usleep(100_000)
}

func contains(_ text: String, in nodes: [Node]) -> Bool {
    nodes.flatMap(\.strings).contains { $0 == text || $0.contains(text) }
}

func require(_ text: String, _ context: String) {
    if !contains(text, in: nodes) {
        fputs("main window UI validation failed: missing \(context): \(text)\n", stderr)
        exit(1)
    }
}

func resolveVisibleControlLabel(
    _ candidates: [String],
    roles: Set<String>,
    _ context: String
) -> String {
    guard let label = candidates.first(where: { candidate in
        nodes.contains { node in
            (roles.contains(node.role) || actions(node.element).contains(kAXPressAction as String))
                && (node.description == candidate || node.title == candidate || node.value == candidate)
        }
    }) else {
        let visibleControls = nodes
            .filter {
                roles.contains($0.role) || actions($0.element).contains(kAXPressAction as String)
            }
            .flatMap(\.strings)
            .filter { !$0.isEmpty }
            .prefix(24)
            .joined(separator: " | ")
        let candidateNodes = nodes
            .filter { node in candidates.contains(where: { candidate in node.strings.contains(candidate) }) }
            .map {
                "\($0.role):\($0.strings.joined(separator: "/")) actions=\(actions($0.element).joined(separator: ","))"
            }
            .prefix(12)
            .joined(separator: " | ")
        fputs("main window UI validation failed: missing localized \(context): \(candidates.joined(separator: " / "))\n", stderr)
        if !visibleControls.isEmpty {
            fputs("available controls: \(visibleControls)\n", stderr)
        }
        if !candidateNodes.isEmpty {
            fputs("candidate nodes: \(candidateNodes)\n", stderr)
        }
        exit(1)
    }
    return label
}

let libraryNavigationLabel = resolveVisibleControlLabel(
    ["宠物库", "Pet Library"],
    roles: [kAXButtonRole as String],
    "primary navigation"
)
let makerNavigationLabel = resolveVisibleControlLabel(
    ["AI宠物制作", "AI Pet Maker"],
    roles: [kAXButtonRole as String],
    "primary navigation"
)
let configurationNavigationLabel = resolveVisibleControlLabel(
    ["宠物配置", "Pet Configuration"],
    roles: [kAXButtonRole as String],
    "primary navigation"
)
let connectionsNavigationLabel = resolveVisibleControlLabel(
    ["Agent 连接", "Agent Connections"],
    roles: [kAXButtonRole as String],
    "primary navigation"
)
let diagnosticsNavigationLabel = resolveVisibleControlLabel(
    ["服务与诊断", "Service & Diagnostics"],
    roles: [kAXButtonRole as String],
    "primary navigation"
)
let requiredVisibleContent: [(String, String)] = [
    ("宠物库", "library heading"),
    ("全部宠物", "library inventory"),
    ("宠物详情", "library detail"),
    ("星雾团子", "bundled pet"),
    ("Bytebud 字节芽", "bundled pet")
]

for (text, context) in requiredVisibleContent {
    require(text, context)
}

let scrollAreas = nodes.filter { $0.role == kAXScrollAreaRole as String }
if scrollAreas.count < 2 {
    fputs("main window UI validation failed: expected sidebar and content scroll areas, found \(scrollAreas.count)\n", stderr)
    exit(1)
}

let actionButtons = nodes.filter { $0.role == kAXButtonRole as String }
for label in [libraryNavigationLabel, makerNavigationLabel, configurationNavigationLabel, connectionsNavigationLabel, diagnosticsNavigationLabel] {
    guard actionButtons.contains(where: { $0.description == label || $0.title == label || $0.value == label }) else {
        fputs("main window UI validation failed: button not exposed: \(label)\n", stderr)
        exit(1)
    }
}

let actionableControls = nodes.filter {
    $0.role == kAXButtonRole as String || actions($0.element).contains(kAXPressAction as String)
}
let expectedNavigationOrder = [
    libraryNavigationLabel,
    makerNavigationLabel,
    configurationNavigationLabel,
    connectionsNavigationLabel,
    diagnosticsNavigationLabel
]
var resolvedNavigationNodes: [(label: String, node: Node)] = []
for label in expectedNavigationOrder {
    let matches = actionableControls.filter {
        $0.description == label || $0.title == label || $0.value == label
    }
    let semanticMatches = {
        let buttons = matches.filter { $0.role == kAXButtonRole as String }
        return buttons.isEmpty ? matches : buttons
    }()
    if semanticMatches.count != 1 {
        fputs("main window UI validation failed: expected exactly one primary navigation button \(label), found \(semanticMatches.count)\n", stderr)
        for match in semanticMatches {
            fputs("matching navigation node: \(match.role) actions=\(actions(match.element).joined(separator: ","))\n", stderr)
        }
        exit(1)
    }
    resolvedNavigationNodes.append((label, semanticMatches[0]))
}

guard resolvedNavigationNodes.allSatisfy({ $0.node.frame != nil }) else {
    fputs("main window UI validation failed: primary navigation controls have no AX frame\n", stderr)
    exit(1)
}
let displayedNavigationOrder = resolvedNavigationNodes
    .sorted { $0.node.frame!.midY < $1.node.frame!.midY }
    .map { $0.label }
if displayedNavigationOrder != expectedNavigationOrder {
    fputs(
        "main window UI validation failed: primary navigation order is \(displayedNavigationOrder.joined(separator: " → "))\n",
        stderr
    )
    exit(1)
}

func controlLabelMatches(_ node: Node, _ label: String) -> Bool {
    node.description == label || node.title == label || node.value == label
}

func pressControl(_ label: String, roles: Set<String>) {
    let currentNodes = snapshotNodes(mainWindow)
    let roleMatch = currentNodes.first(where: {
        roles.contains($0.role) && controlLabelMatches($0, label)
    })
    let actionableMatch = currentNodes.first(where: {
        actions($0.element).contains(kAXPressAction as String) && controlLabelMatches($0, label)
    })
    guard let node = roleMatch ?? actionableMatch else {
        fputs("main window UI validation failed: control not found for AXPress: \(label)\n", stderr)
        exit(1)
    }
    let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
    if result != .success {
        fputs("main window UI validation failed: AXPress failed for \(label): \(result.rawValue)\n", stderr)
        exit(1)
    }
}

func waitFor(_ description: String, _ predicate: ([Node]) -> Bool) {
    for _ in 0..<40 {
        let currentNodes = snapshotNodes(mainWindow)
        if predicate(currentNodes) {
            return
        }
        usleep(100_000)
    }
    fputs("main window UI validation failed: timed out waiting for \(description)\n", stderr)
    exit(1)
}

let buttonRole = kAXButtonRole as String

pressControl(makerNavigationLabel, roles: [buttonRole])
waitFor("AI Pet Maker page") { nodes in
    contains("新建宠物", in: nodes)
        && contains("AI 辅助会话", in: nodes)
        && contains("参考图", in: nodes)
        && contains("发起 AI 辅助会话", in: nodes)
        && !contains("宠物详情", in: nodes)
}
let makerNodes = snapshotNodes(mainWindow)
let removedStudioTabLabels: Set<String> = ["新建", "New", "宠物库", "Pet Library"]
if makerNodes.contains(where: { node in
    node.role == kAXRadioButtonRole as String
        && node.strings.contains(where: removedStudioTabLabels.contains)
}) {
    fputs("main window UI validation failed: AI Pet Maker still exposes a removed Studio tab\n", stderr)
    exit(1)
}

pressControl(configurationNavigationLabel, roles: [buttonRole])
waitFor("Pet Configuration page") { nodes in
    contains("响应来源", in: nodes)
        && contains("响应事件", in: nodes)
        && contains("透明区域穿透", in: nodes)
}

pressControl(connectionsNavigationLabel, roles: [buttonRole])
waitFor("Agent Connections page") { nodes in
    contains("连接状态", in: nodes)
        && contains("全部检查", in: nodes)
        && contains("连接检查", in: nodes)
        && contains("最近事件", in: nodes)
}

pressControl(diagnosticsNavigationLabel, roles: [buttonRole])
waitFor("Service & Diagnostics page") { nodes in
    contains("服务状态", in: nodes)
        && contains("日志打包下载", in: nodes)
        && contains("PetCore", in: nodes)
        && contains("本地 RPC", in: nodes)
        && contains("事件通道", in: nodes)
        && contains("桌宠渲染", in: nodes)
        && contains("打包并下载", in: nodes)
}

pressControl(libraryNavigationLabel, roles: [buttonRole])
waitFor("Pet Library page") { nodes in
    contains("宠物库", in: nodes)
        && contains("宠物详情", in: nodes)
        && contains("星雾团子", in: nodes)
        && contains("Bytebud 字节芽", in: nodes)
        && (contains("导入", in: nodes) || contains("Import", in: nodes))
}

func currentMainWindows() -> [AXUIElement] {
    let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
    return windows.filter {
        supportedMainWindowTitles.contains(string($0, kAXTitleAttribute))
    }
}

guard let closeButtonValue = copy(mainWindow, kAXCloseButtonAttribute as String) else {
    fputs("main window UI validation failed: control center close action is unavailable\n", stderr)
    exit(1)
}
let closeButton = closeButtonValue as! AXUIElement
guard AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success else {
    fputs("main window UI validation failed: control center close action failed\n", stderr)
    exit(1)
}

for _ in 0..<40 where !currentMainWindows().isEmpty {
    usleep(100_000)
}
guard currentMainWindows().isEmpty, !app.isTerminated else {
    fputs("main window UI validation failed: closing the control center terminated the UI host or left the window open\n", stderr)
    exit(1)
}

let activationHome = ProcessInfo.processInfo.environment["APC_HOME"] ?? ""
guard !activationHome.isEmpty else {
    fputs("main window UI validation failed: APC_HOME activation scope is unavailable\n", stderr)
    exit(1)
}
let activationScope = URL(
    fileURLWithPath: activationHome,
    isDirectory: true
).standardizedFileURL.path
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.agentpet.companion.activate-running-instance"),
    object: activationScope,
    userInfo: nil,
    deliverImmediately: true
)

var reopenedWindows: [AXUIElement] = []
for _ in 0..<40 {
    reopenedWindows = currentMainWindows()
    if reopenedWindows.count == 1 { break }
    usleep(100_000)
}
guard reopenedWindows.count == 1, !app.isTerminated else {
    fputs("main window UI validation failed: activation did not reopen exactly one control center\n", stderr)
    exit(1)
}

print("Main window UI and close/reopen lifecycle validation ok")
SWIFT
