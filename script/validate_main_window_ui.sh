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
"$PETCORE_CLI" petpack sample --output "$PET_SOURCE" --quality standard >/dev/null
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
let controlCenterWindowIdentifier = "dev.agentpet.companion.control-center"
func isControlCenterWindow(_ window: AXUIElement) -> Bool {
    string(window, kAXIdentifierAttribute) == controlCenterWindowIdentifier
        || supportedMainWindowTitles.contains(string(window, kAXTitleAttribute))
}
var resolvedMainWindow: AXUIElement?
for _ in 0..<40 {
    let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
    resolvedMainWindow = windows.first(where: isControlCenterWindow)
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
var onboardingSkipAction: AXUIElement?
for _ in 0..<80 {
    let currentNodes = snapshotNodes(mainWindow)
    if currentNodes.contains(where: {
        $0.identifier == "onboarding.root"
    }) {
        onboardingWasPresented = true
        if let skip = currentNodes.first(where: {
            $0.identifier == "onboarding.skip"
                && actions($0.element).contains(kAXPressAction as String)
        }) {
            onboardingSkipAction = skip.element
            break
        }
    }
    usleep(100_000)
}
if onboardingWasPresented {
    guard let onboardingSkipAction else {
        fputs("main window UI validation failed: onboarding has no enabled semantic Skip action\n", stderr)
        let onboardingNodes = snapshotNodes(mainWindow)
            .filter {
                $0.identifier.hasPrefix("onboarding.")
                    || $0.strings.contains(where: { $0.localizedCaseInsensitiveContains("skip") })
            }
            .map {
                "\($0.role):\($0.identifier):\($0.strings.joined(separator: "/")):actions=\(actions($0.element).joined(separator: ","))"
            }
            .joined(separator: " | ")
        if !onboardingNodes.isEmpty {
            fputs("onboarding nodes: \(onboardingNodes)\n", stderr)
        }
        exit(1)
    }
    let result = AXUIElementPerformAction(
        onboardingSkipAction,
        kAXPressAction as CFString
    )
    if result != .success {
        fputs("main window UI validation failed: onboarding Skip action failed: \(result.rawValue)\n", stderr)
        exit(1)
    }
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
// structure used to validate navigation order across all five pages. AXSize
// measures the whole NSWindow, so its height includes titlebar/toolbar chrome
// above the 520-point SwiftUI content minimum.
setMainWindowSize(supportedMinimumSize, context: "supported minimum")
guard let compactSize = size(mainWindow, kAXSizeAttribute),
      abs(compactSize.width - supportedMinimumSize.width) <= 1,
      compactSize.height >= supportedMinimumSize.height else {
    let observed = size(mainWindow, kAXSizeAttribute)
        .map { "\($0.width)x\($0.height)" }
        ?? "missing"
    fputs("main window UI validation failed: supported minimum size was not applied; observed \(observed)\n", stderr)
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

func requireAny(_ candidates: [String], _ context: String) {
    if !containsAny(candidates, in: nodes) {
        fputs("main window UI validation failed: missing \(context): \(candidates.joined(separator: " / "))\n", stderr)
        if context == "bundled pet" {
            let visiblePetNodes = nodes
                .filter { $0.identifier.hasPrefix("pet-library.card.") }
                .map {
                    "\($0.role):\($0.identifier):\($0.strings.joined(separator: "/"))"
                }
                .joined(separator: " | ")
            if !visiblePetNodes.isEmpty {
                fputs("visible pet cards: \(visiblePetNodes)\n", stderr)
            }
        }
        exit(1)
    }
}

func requireIdentifier(_ identifier: String, _ context: String) {
    if !containsIdentifier(identifier, in: nodes) {
        fputs("main window UI validation failed: missing \(context) identifier: \(identifier)\n", stderr)
        let relatedNodes = nodes
            .filter {
                let prefix = identifier.split(separator: ".").first.map(String.init) ?? identifier
                return $0.identifier.hasPrefix(prefix)
            }
            .map {
                "\($0.role):\($0.identifier):frame=\($0.frame.map(String.init(describing:)) ?? "missing")"
            }
            .prefix(40)
            .joined(separator: " | ")
        if !relatedNodes.isEmpty {
            fputs("related nodes: \(relatedNodes)\n", stderr)
        }
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
    let libraryInventoryIsVisible =
        containsIdentifier("pet-library.grid", in: nodes)
        && containsAny(["全部宠物 · 4", "All Pets · 4"], in: nodes)
    if libraryInventoryIsVisible {
        break
    }
    usleep(100_000)
}
requireIdentifier("pet-library.grid", "library grid")
requireIdentifier("sidebar.navigation-list", "sidebar navigation list")
requireIdentifier("sidebar.configuration-live-preview", "sidebar live preview")
requireIdentifier("sidebar.current-pet", "sidebar current-pet row")
requireAny(["全部宠物 · 4", "All Pets · 4"], "seeded and imported pet count")
requireAny(["星雾团子"], "bundled pet")

guard let navigationFrame = nodes.first(where: {
    $0.identifier == "sidebar.navigation-list"
})?.frame,
let previewFrame = nodes.first(where: {
    $0.identifier == "sidebar.configuration-live-preview"
})?.frame,
let identityFrame = nodes.first(where: {
    $0.identifier == "sidebar.current-pet"
})?.frame,
navigationFrame.width > 0,
previewFrame.width > 0,
previewFrame.height > 0,
identityFrame.height > 0,
previewFrame.minX >= navigationFrame.minX - 1,
previewFrame.maxX <= navigationFrame.maxX + 1,
previewFrame.maxY <= identityFrame.minY + 1,
identityFrame.minX >= navigationFrame.minX - 1,
identityFrame.maxX <= navigationFrame.maxX + 1 else {
    fputs("main window UI validation failed: sidebar preview is not pinned above its identity row\n", stderr)
    exit(1)
}

guard let libraryGrid = nodes.first(where: {
    $0.identifier == "pet-library.grid"
}), actions(libraryGrid.element).contains("AXScrollToBottom") else {
    fputs("main window UI validation failed: pet grid does not expose scroll-to-bottom\n", stderr)
    exit(1)
}
let scrollToBottomResult = AXUIElementPerformAction(
    libraryGrid.element,
    "AXScrollToBottom" as CFString
)
if scrollToBottomResult != .success {
    fputs("main window UI validation failed: pet grid could not scroll to bottom: \(scrollToBottomResult.rawValue)\n", stderr)
    exit(1)
}
for _ in 0..<40 {
    nodes = snapshotNodes(mainWindow)
    let lastBundledRowIsVisible =
        containsAny(["Bytebud 字节芽"], in: nodes)
        && containsAny(["桃蕾"], in: nodes)
    if lastBundledRowIsVisible {
        break
    }
    usleep(100_000)
}
requireAny(["Bytebud 字节芽"], "bottom pet row")
requireAny(["桃蕾"], "bottom pet row")

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

func subtreeContainsIdentifier(_ element: AXUIElement, _ identifier: String) -> Bool {
    if string(element, kAXIdentifierAttribute) == identifier {
        return true
    }
    let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return children.contains { subtreeContainsIdentifier($0, identifier) }
}

func requireScrollToBottom(
    identifier: String,
    visibleTargetIdentifier: String,
    context: String
) {
    let currentNodes = snapshotNodes(mainWindow)
    let directScrollNode = currentNodes.first(where: {
        $0.identifier == identifier
            && actions($0.element).contains("AXScrollToBottom")
    })
    let pagedScrollNode = currentNodes.first(where: {
        $0.role == kAXScrollAreaRole as String
            && actions($0.element).contains("AXScrollDownByPage")
            && subtreeContainsIdentifier($0.element, visibleTargetIdentifier)
    })
    guard let scrollNode = directScrollNode ?? pagedScrollNode,
          let scrollFrame = scrollNode.frame else {
        fputs("main window UI validation failed: \(context) does not expose scroll-to-bottom\n", stderr)
        let prefix = identifier.split(separator: ".").first.map(String.init) ?? identifier
        let relatedNodes = currentNodes
            .filter { $0.identifier.hasPrefix(prefix) || $0.role == kAXScrollAreaRole as String }
            .map {
                "\($0.role):\($0.identifier):frame=\($0.frame.map(String.init(describing:)) ?? "missing"):actions=\(actions($0.element).joined(separator: ","))"
            }
            .prefix(48)
            .joined(separator: " | ")
        if !relatedNodes.isEmpty {
            fputs("related scroll nodes: \(relatedNodes)\n", stderr)
        }
        exit(1)
    }
    let scrollAction = directScrollNode == nil ? "AXScrollDownByPage" : "AXScrollToBottom"
    let scrollTargetToVisibleAction = "AXScrollToVisible"

    guard let windowFrame = point(mainWindow, kAXPositionAttribute).flatMap({ origin in
        size(mainWindow, kAXSizeAttribute).map { CGRect(origin: origin, size: $0) }
    }) else {
        fputs("main window UI validation failed: control center has no frame during \(context)\n", stderr)
        exit(1)
    }

    for _ in 0..<12 {
        let refreshedNodes = snapshotNodes(mainWindow)
        let targetNode = refreshedNodes.first(where: {
            $0.identifier == visibleTargetIdentifier
        })
        if let targetFrame = targetNode?.frame,
           targetFrame.width > 0,
           targetFrame.height > 0,
           windowFrame.intersects(targetFrame),
           scrollFrame.intersects(targetFrame) {
            return
        }

        if let targetNode,
           actions(targetNode.element).contains(scrollTargetToVisibleAction) {
            let targetResult = AXUIElementPerformAction(
                targetNode.element,
                scrollTargetToVisibleAction as CFString
            )
            if targetResult == .success {
                usleep(150_000)
                continue
            }
        }

        let pageResult = AXUIElementPerformAction(
            scrollNode.element,
            scrollAction as CFString
        )
        if pageResult != .success {
            if let scrollBarValue = copy(
                scrollNode.element,
                kAXVerticalScrollBarAttribute
            ) {
                let scrollBar = scrollBarValue as! AXUIElement
                let setResult = AXUIElementSetAttributeValue(
                    scrollBar,
                    kAXValueAttribute as CFString,
                    NSNumber(value: 1)
                )
                if setResult == .success {
                    usleep(150_000)
                    continue
                }
            }
            let targetActions = targetNode
                .map { actions($0.element).joined(separator: ",") }
                ?? "missing"
            fputs(
                "main window UI validation failed: \(context) could not scroll down: \(pageResult.rawValue); target actions: \(targetActions)\n",
                stderr
            )
            exit(1)
        }
        usleep(150_000)
    }
    fputs("main window UI validation failed: \(context) bottom target remained outside the window\n", stderr)
    exit(1)
}

let buttonRole = kAXButtonRole as String

pressControl(identifier: "sidebar.navigation.maker")
waitFor("AI Pet Maker page") { nodes in
    containsIdentifier("maker.page", in: nodes)
        && containsIdentifier("maker.session-list", in: nodes)
        && containsIdentifier("maker.session-list.new", in: nodes)
        && containsIdentifier("maker.session-list.draft", in: nodes)
        && containsIdentifier("maker.draft", in: nodes)
        && containsIdentifier("maker.draft.discard", in: nodes)
        && containsIdentifier("maker.draft.submit", in: nodes)
        && containsIdentifier("product.maker.draft.page-header", in: nodes)
        && containsIdentifier("maker.brief", in: nodes)
        && containsIdentifier("maker.brief.description", in: nodes)
        && containsAny(["新宠物", "New Pet"], in: nodes)
        && containsAny(["参考图（可选）", "Reference Images (Optional)"], in: nodes)
        && containsAny(["开始制作", "Create Pet"], in: nodes)
        && !containsIdentifier("pet-library.page", in: nodes)
}
requireScrollToBottom(
    identifier: "maker.draft",
    visibleTargetIdentifier: "maker.brief.references.dropzone",
    context: "AI Pet Maker draft"
)
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
        && containsIdentifier("configuration.appearance.enabled", in: nodes)
        && containsIdentifier("configuration.appearance.status-bubble", in: nodes)
        && containsIdentifier("configuration.appearance.theme", in: nodes)
        && containsIdentifier("configuration.appearance.pet-size", in: nodes)
        && containsIdentifier(
            "product.configuration.appearance.advanced-details-disclosure",
            in: nodes
        )
}

pressControl(identifier: "sidebar.navigation.connections")
waitFor("Agent Connections page") { nodes in
    containsIdentifier("connections.root", in: nodes)
        && containsIdentifier("product.connections.page-header", in: nodes)
        && containsIdentifier("connections.agent-section.codex", in: nodes)
        && containsIdentifier("connections.primary.check-all", in: nodes)
        && containsIdentifier("connections.secondary.setup-all", in: nodes)
}
requireScrollToBottom(
    identifier: "connections.root",
    visibleTargetIdentifier: "connections.agent-section.opencode",
    context: "Agent Connections"
)

pressControl(identifier: "sidebar.navigation.diagnostics")
waitFor("Service & Diagnostics page") { nodes in
    containsIdentifier("diagnostics.page", in: nodes)
        && containsIdentifier("diagnostics.layout.single-column", in: nodes)
        && containsIdentifier("diagnostics.service-details", in: nodes)
        && containsIdentifier(
            "product.diagnostics.service.primary-experience-card.primary-action",
            in: nodes
        )
        && containsAny(["服务状态", "Service Status"], in: nodes)
        && containsAny(["诊断日志包", "Diagnostic Archive"], in: nodes)
        && containsAny(["打包并下载", "Package and Download"], in: nodes)
}

pressControl(identifier: "sidebar.navigation.library")
waitFor("Pet Library page") { nodes in
    containsIdentifier("pet-library.page", in: nodes)
        && containsIdentifier("pet-library.hero", in: nodes)
        && containsIdentifier("pet-library.grid", in: nodes)
        && contains("星雾团子", in: nodes)
        && (contains("导入", in: nodes) || contains("Import", in: nodes))
}
requireScrollToBottom(
    identifier: "pet-library.detail-scroll",
    visibleTargetIdentifier: "pet-library.hero.technical",
    context: "Pet Library detail"
)

func currentMainWindows() -> [AXUIElement] {
    let windows = copy(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
    return windows.filter(isControlCenterWindow)
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
