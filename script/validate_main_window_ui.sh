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
"$PETCORE_CLI" petpack sample --output "$PET_SOURCE" --quality high >/dev/null
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
    let identifier: String
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
        identifier: string(element, kAXIdentifierAttribute),
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
    "AI宠物制作", "AI 宠物制作", "AI Pet Maker",
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

// A fresh production home presents onboarding before the five-page control
// center. Finish that isolated flow through its stable semantic Skip action;
// the onboarding-specific scene progression is validated separately.
var onboardingWasPresented = false
for _ in 0..<80 {
    let currentNodes = snapshotNodes(mainWindow)
    if currentNodes.contains(where: {
        $0.identifier == "onboarding.root"
    }) {
        onboardingWasPresented = true
        guard let skip = currentNodes.first(where: {
            $0.identifier == "onboarding.skip"
                && actions($0.element).contains(kAXPressAction as String)
        }) else {
            fputs("main window UI validation failed: onboarding has no semantic Skip action\n", stderr)
            exit(1)
        }
        let result = AXUIElementPerformAction(
            skip.element,
            kAXPressAction as CFString
        )
        if result != .success {
            fputs("main window UI validation failed: onboarding Skip action failed: \(result.rawValue)\n", stderr)
            exit(1)
        }
        break
    }
    usleep(100_000)
}
if onboardingWasPresented {
    for _ in 0..<40 {
        if !snapshotNodes(mainWindow).contains(where: {
            $0.identifier == "onboarding.root"
        }) {
            break
        }
        usleep(100_000)
    }
    if snapshotNodes(mainWindow).contains(where: {
        $0.identifier == "onboarding.root"
    }) {
        fputs("main window UI validation failed: onboarding remained after Skip\n", stderr)
        exit(1)
    }
}

guard let mainSize = size(mainWindow, kAXSizeAttribute) else {
    fputs("main window UI validation failed: main window has no AX size\n", stderr)
    exit(1)
}
let supportedMinimumSize = CGSize(width: 760, height: 520)
if mainSize.width < supportedMinimumSize.width
    || mainSize.height < supportedMinimumSize.height {
    fputs("main window UI validation failed: main window is below the supported minimum size: \(mainSize.width)x\(mainSize.height)\n", stderr)
    exit(1)
}

func setMainWindowSize(_ requestedSize: CGSize, context: String) {
    var validationSize = requestedSize
    if let sizeValue = AXValueCreate(.cgSize, &validationSize) {
        let result = AXUIElementSetAttributeValue(
            mainWindow,
            kAXSizeAttribute as CFString,
            sizeValue
        )
        if result != .success {
            fputs("main window UI validation failed: could not set \(context) size: \(result.rawValue)\n", stderr)
            exit(1)
        }
        usleep(300_000)
    }
}

// Exercise the real supported minimum before expanding to the all-column
// structure used to validate navigation order across all five pages.
setMainWindowSize(supportedMinimumSize, context: "supported minimum")
guard let compactSize = size(mainWindow, kAXSizeAttribute),
      abs(compactSize.width - supportedMinimumSize.width) <= 1,
      abs(compactSize.height - supportedMinimumSize.height) <= 1 else {
    fputs("main window UI validation failed: supported minimum size was not applied\n", stderr)
    exit(1)
}

var nodes: [Node] = []
for _ in 0..<300 {
    nodes = snapshotNodes(mainWindow)
    let libraryIsVisible = nodes.contains { $0.identifier == "pet-library.page" }
        && nodes.contains { $0.identifier == "product.pet-library.page-header" }
        && nodes.contains { $0.identifier == "pet-library.hero" }
    if libraryIsVisible {
        break
    }
    usleep(100_000)
}

func contains(_ text: String, in nodes: [Node]) -> Bool {
    nodes.flatMap(\.strings).contains { $0 == text || $0.contains(text) }
}

func containsAny(_ candidates: [String], in nodes: [Node]) -> Bool {
    candidates.contains { contains($0, in: nodes) }
}

func containsIdentifier(_ identifier: String, in nodes: [Node]) -> Bool {
    nodes.contains { $0.identifier == identifier }
}

func mainWindowTitleMatches(_ candidates: [String]) -> Bool {
    candidates.contains(string(mainWindow, kAXTitleAttribute))
}

func requireAny(_ candidates: [String], _ context: String) {
    if !containsAny(candidates, in: nodes) {
        fputs("main window UI validation failed: missing \(context): \(candidates.joined(separator: " / "))\n", stderr)
        exit(1)
    }
}

func requireIdentifier(_ identifier: String, _ context: String) {
    if !containsIdentifier(identifier, in: nodes) {
        fputs("main window UI validation failed: missing \(context) identifier: \(identifier)\n", stderr)
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

requireIdentifier("pet-library.page", "library page")
requireIdentifier("product.pet-library.page-header", "library page header")
requireIdentifier("pet-library.hero", "library primary experience")
requireIdentifier(
    "product.pet-library.featured.primary-experience-card",
    "library primary experience card"
)
requireIdentifier(
    "product.pet-library.featured.pet-preview-stage",
    "library pet preview"
)
requireAny(["宠物库", "Pet Library"], "library heading")

guard let compactPage = nodes.first(where: {
    $0.identifier == "pet-library.page"
}), let compactPageFrame = compactPage.frame,
compactPageFrame.width > 0,
compactPageFrame.width <= supportedMinimumSize.width + 1 else {
    fputs("main window UI validation failed: library did not resolve inside the supported minimum width\n", stderr)
    exit(1)
}

setMainWindowSize(
    CGSize(width: 1_120, height: max(720, compactSize.height)),
    context: "all-column validation"
)
for _ in 0..<80 {
    nodes = snapshotNodes(mainWindow)
    let strings = nodes.flatMap(\.strings)
    let libraryInventoryIsVisible =
        containsIdentifier("pet-library.collection-title", in: nodes)
        && containsIdentifier("pet-library.grid", in: nodes)
        && ["星雾团子", "Bytebud 字节芽"].allSatisfy { petName in
            strings.contains { $0 == petName || $0.contains(petName) }
        }
    if libraryInventoryIsVisible {
        break
    }
    usleep(100_000)
}
requireIdentifier("pet-library.collection-title", "library collection title")
requireIdentifier("pet-library.grid", "library grid")
requireAny(["星雾团子"], "bundled pet")
requireAny(["Bytebud 字节芽"], "bundled pet")

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

func pressControl(identifier: String) {
    let currentNodes = snapshotNodes(mainWindow)
    guard let node = currentNodes.first(where: {
        $0.identifier == identifier
            && actions($0.element).contains(kAXPressAction as String)
    }) else {
        fputs("main window UI validation failed: actionable control identifier not found: \(identifier)\n", stderr)
        exit(1)
    }
    let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
    if result != .success {
        fputs("main window UI validation failed: AXPress failed for \(identifier): \(result.rawValue)\n", stderr)
        exit(1)
    }
}

func waitFor(_ description: String, _ predicate: ([Node]) -> Bool) {
    var lastNodes: [Node] = []
    for _ in 0..<40 {
        let currentNodes = snapshotNodes(mainWindow)
        lastNodes = currentNodes
        if predicate(currentNodes) {
            return
        }
        usleep(100_000)
    }
    fputs("main window UI validation failed: timed out waiting for \(description)\n", stderr)
    fputs("current main window title: \(string(mainWindow, kAXTitleAttribute))\n", stderr)
    let visibleIdentifiers = Array(Set(lastNodes.map(\.identifier).filter { !$0.isEmpty }))
        .sorted()
        .prefix(80)
        .joined(separator: " | ")
    if !visibleIdentifiers.isEmpty {
        fputs("visible identifiers: \(visibleIdentifiers)\n", stderr)
    }
    let visibleStrings = Array(Set(lastNodes.flatMap(\.strings).filter { !$0.isEmpty }))
        .sorted()
        .prefix(60)
        .joined(separator: " | ")
    if !visibleStrings.isEmpty {
        fputs("visible strings: \(visibleStrings)\n", stderr)
    }
    exit(1)
}

let buttonRole = kAXButtonRole as String

pressControl(identifier: "sidebar.navigation.maker")
waitFor("AI Pet Maker page") { nodes in
    containsIdentifier("maker.page", in: nodes)
        && containsIdentifier("product.maker.page-header", in: nodes)
        && containsIdentifier("maker.layout.describe", in: nodes)
        && containsIdentifier("maker.brief", in: nodes)
        && containsIdentifier("maker.brief.description", in: nodes)
        && containsIdentifier("product.maker.primary-experience-card", in: nodes)
        && containsIdentifier(
            "product.maker.primary-experience-card.primary-action",
            in: nodes
        )
        && containsAny(["新宠物", "New Pet"], in: nodes)
        && containsAny(["参考图（可选）", "Reference Images (Optional)"], in: nodes)
        && containsAny(["开始制作", "Create Pet"], in: nodes)
        && !containsIdentifier("pet-library.page", in: nodes)
        && mainWindowTitleMatches(["AI宠物制作", "AI Pet Maker"])
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

pressControl(identifier: "sidebar.navigation.configuration")
waitFor("Pet Configuration page") { nodes in
    containsIdentifier("configuration.root", in: nodes)
        && containsIdentifier("product.configuration.page-header", in: nodes)
        && containsIdentifier("configuration.subpage-picker", in: nodes)
        && containsIdentifier("configuration.page.appearance", in: nodes)
        && containsIdentifier("configuration.appearance.status-bubble", in: nodes)
        && containsIdentifier("configuration.appearance.theme", in: nodes)
        && containsIdentifier("configuration.appearance.fps", in: nodes)
        && (
            containsIdentifier("configuration.layout.wide", in: nodes)
                || containsIdentifier("configuration.layout.compact", in: nodes)
        )
        && mainWindowTitleMatches(["宠物配置", "Pet Configuration"])
}

pressControl(identifier: "sidebar.navigation.connections")
waitFor("Agent Connections page") { nodes in
    containsIdentifier("connections.root", in: nodes)
        && containsIdentifier("product.connections.page-header", in: nodes)
        && containsIdentifier("connections.agent-section.codex", in: nodes)
        && containsIdentifier("product.connections.codex.agent-health-row", in: nodes)
        && containsIdentifier(
            "product.connections.codex.advanced-details-disclosure",
            in: nodes
        )
        && mainWindowTitleMatches(["Agent 连接", "Agent Connections"])
}

pressControl(identifier: "sidebar.navigation.diagnostics")
waitFor("Service & Diagnostics page") { nodes in
    containsIdentifier("diagnostics.page", in: nodes)
        && containsIdentifier("diagnostics.layout.single-column", in: nodes)
        && containsIdentifier("diagnostics.service-summary", in: nodes)
        && containsIdentifier(
            "product.diagnostics.service.primary-experience-card",
            in: nodes
        )
        && containsIdentifier(
            "product.diagnostics.service.primary-experience-card.primary-action",
            in: nodes
        )
        && containsIdentifier("diagnostics.log-package", in: nodes)
        && containsIdentifier("diagnostics.export", in: nodes)
        && containsIdentifier("diagnostics.technical-details", in: nodes)
        && containsAny(["服务状态", "Service Status"], in: nodes)
        && containsAny(["日志打包下载", "Diagnostic Download"], in: nodes)
        && containsAny(["打包并下载", "Package and Download"], in: nodes)
        && mainWindowTitleMatches(["服务与诊断", "Service & Diagnostics"])
}

pressControl(identifier: "sidebar.navigation.library")
waitFor("Pet Library page") { nodes in
    containsIdentifier("pet-library.page", in: nodes)
        && containsIdentifier("product.pet-library.page-header", in: nodes)
        && containsIdentifier("pet-library.hero", in: nodes)
        && containsIdentifier("pet-library.grid", in: nodes)
        && contains("星雾团子", in: nodes)
        && contains("Bytebud 字节芽", in: nodes)
        && (contains("导入", in: nodes) || contains("Import", in: nodes))
        && mainWindowTitleMatches(["宠物库", "Pet Library"])
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
