#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/apps/macos"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-overlay-offline.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

(
  cd "$MACOS_DIR"
  swift build \
    --product AgentPetCompanion \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors >/dev/null
)

BIN_DIR="$(cd "$MACOS_DIR" && swift build --show-bin-path)"
APC_HOME="$TMP_DIR/ui-validation-home" \
APC_DISABLE_LAUNCH_AGENT=1 \
APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  "$BIN_DIR/AgentPetCompanion" --run-ui-validation
CORE_OBJECT_DIR="$BIN_DIR/AgentPetCompanionCore.build"
CORE_OBJECTS=(
  "$CORE_OBJECT_DIR/AppModels.swift.o"
  "$CORE_OBJECT_DIR/FrameScheduler.swift.o"
)
LOCALIZATION_ACCESSOR="$BIN_DIR/AgentPetCompanion.build/DerivedSources/resource_bundle_accessor.swift"

swiftc \
  -parse-as-library \
  -enable-testing \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -emit-module \
  -emit-library \
  -module-name OverlayGeometryValidation \
  -I "$BIN_DIR/Modules" \
  "$MACOS_DIR/Sources/AgentPetCompanion/App/Localization.swift" \
  "$MACOS_DIR/Sources/AgentPetCompanion/App/PackagedResourceBundle.swift" \
  "$LOCALIZATION_ACCESSOR" \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/OverlayGeometry.swift" \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/OverlayResizeAccessibility.swift" \
  "${CORE_OBJECTS[@]}" \
  -emit-module-path "$TMP_DIR/OverlayGeometryValidation.swiftmodule" \
  -o "$TMP_DIR/libOverlayGeometryValidation.dylib"

swiftc \
  -I "$TMP_DIR" \
  -I "$BIN_DIR/Modules" \
  -L "$TMP_DIR" \
  -lOverlayGeometryValidation \
  -o "$TMP_DIR/geometry-check" \
  - <<'SWIFT'
@testable import OverlayGeometryValidation
import AppKit
import CoreGraphics

let displays = [
    OverlayDisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 934),
        backingScaleFactor: 2
    ),
    OverlayDisplayGeometry(
        frame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
        visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 775),
        backingScaleFactor: 1
    )
]

for display in displays {
    let frame = display.visibleFrame
    for scale: CGFloat in [0.10, 0.72, 1.8] {
        for point in [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY)
        ] {
            let center = OverlayGeometry.clampedPetScreenCenter(
                point,
                scale: scale,
                visibleFrame: frame,
                clickMenuEnabled: true
            )
            // Drag clamping intentionally follows the visible pet pixels and
            // reachable controls, not the larger transparent render panel.
            // The latter may extend beyond the movement frame for shadows.
            let bounds = OverlayGeometry.petMovementScreenBounds(
                scale: scale,
                petScreenCenter: center,
                clickMenuEnabled: true,
                includeResize: true
            )
            precondition(frame.insetBy(dx: -0.5, dy: -0.5).contains(bounds))
        }
    }
}

let target = OverlayGeometry.dragTargetDisplay(
    pointer: CGPoint(x: -640, y: 400),
    proposedPetCenter: CGPoint(x: 20, y: 400),
    displays: displays,
    fallback: displays[0]
)
precondition(target == displays[1])
precondition(OverlayGeometry.clampedScale(0.01) == OverlayGeometry.minimumScale)
precondition(OverlayGeometry.clampedScale(9) == OverlayGeometry.maximumScale)
precondition(OverlayGeometry.resolvedInitialScale(persistedScale: 0.12, hasPersistedPosition: false) == 0.72)
precondition(OverlayGeometry.resolvedInitialScale(persistedScale: 0.12, hasPersistedPosition: true) == 0.12)

let resizeValidation = await MainActor.run {
    let view = OverlayResizeAccessibilityView(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
    var steps: [CGFloat] = []
    view.scale = 0.72
    view.onScaleStep = { steps.append($0) }
    precondition(view.acceptsFirstResponder)
    precondition(view.accessibilityRole() == .slider)
    precondition(view.accessibilityPerformIncrement())
    precondition(view.accessibilityPerformDecrement())
    let value = (view.accessibilityValue() as? NSNumber)?.doubleValue
    return (steps, value)
}
precondition(resizeValidation.0 == [0.05, -0.05])
precondition(resizeValidation.1 == 0.72)
print("Overlay geometry offline validation ok")
SWIFT
DYLD_LIBRARY_PATH="$TMP_DIR" "$TMP_DIR/geometry-check"

swiftc \
  -parse-as-library \
  -enable-testing \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -emit-library \
  -emit-module \
  -module-name PetFramePipelineValidation \
  -I "$BIN_DIR/Modules" \
  "$MACOS_DIR/Sources/AgentPetCompanion/App/Localization.swift" \
  "$MACOS_DIR/Sources/AgentPetCompanion/App/PackagedResourceBundle.swift" \
  "$LOCALIZATION_ACCESSOR" \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/OverlayGeometry.swift" \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/PetFramePipeline.swift" \
  "$MACOS_DIR/Sources/AgentPetCompanion/App/PetAssetLocator.swift" \
  "${CORE_OBJECTS[@]}" \
  -emit-module-path "$TMP_DIR/PetFramePipelineValidation.swiftmodule" \
  -o "$TMP_DIR/libPetFramePipelineValidation.dylib"

swiftc \
  -I "$TMP_DIR" \
  -I "$BIN_DIR/Modules" \
  -L "$TMP_DIR" \
  -lPetFramePipelineValidation \
  -o "$TMP_DIR/pipeline-check" \
  - <<'SWIFT'
@testable import PetFramePipelineValidation
import AgentPetCompanionCore
import CoreImage
import Foundation

final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var decodedOnMain = false

    func decode(_ url: URL) -> PetDecodedFrame {
        lock.lock()
        count += 1
        decodedOnMain = decodedOnMain || Thread.isMainThread
        lock.unlock()
        return PetDecodedFrame(
            image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
            pixelWidth: 2,
            pixelHeight: 2
        )
    }

    func snapshot() -> (count: Int, decodedOnMain: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (count, decodedOnMain)
    }
}

let urls = (0..<20).map { URL(fileURLWithPath: "/virtual/\($0).png") }
let probe = DecodeProbe()
let pipeline = PetFramePipeline(
    memoryBudgetBytes: 32,
    originalWindowSize: 7,
    catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
    decoder: { probe.decode($0) }
)
let quality = QualityLevel.original
let pet = PetSummary(
    id: "pet_test",
    name: "Test",
    style: "pixel",
    quality: quality,
    renderSize: quality.renderSize,
    petpackPath: "/virtual/test.petpack",
    coverPath: "",
    active: true,
    createdAt: "2026-07-10T00:00:00Z"
)
let prepared = try await pipeline.prepare(PetFrameLoadRequest(
    pet: pet,
    stateName: "tool",
    requestedFPS: 10,
    nativeFPS: 10,
    durationMS: 2_000,
    loops: true
))
precondition(prepared.sourceKind == .ring)
precondition(prepared.readyFrameCount <= 7)
let readsAfterPrepare = probe.snapshot().count
for index in 0..<100 {
    _ = prepared.readyFrame(at: index % max(1, prepared.frameCount))
}
precondition(probe.snapshot().count == readsAfterPrepare)

let advanced = try await pipeline.prefetch(prepared, around: 12)
precondition(advanced.readyFrame(at: 12) != nil)
precondition(advanced.readyFrameCount <= 7)
let metrics = await pipeline.cacheMetrics()
precondition(metrics.byteCount <= 32)
precondition(metrics.maximumConcurrentDecodes == 1)
precondition(!probe.snapshot().decodedOnMain)
print("Pet frame pipeline offline validation ok")
SWIFT
DYLD_LIBRARY_PATH="$TMP_DIR" "$TMP_DIR/pipeline-check"

if rg -n 'Timer\.publish|pointerTimer|1\.0 / (24|30)\.0' \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift" \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/PetOverlayController.swift"; then
  echo "overlay offline validation failed: high-frequency pointer polling remains" >&2
  exit 1
fi

DRAW_BODY="$(awk '
  /func draw\(in view: MTKView\)/ { capture=1 }
  capture { print }
  capture && /@MainActor/ { exit }
' "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/PetFramePipeline.swift")"
if rg -n 'CGImageSource|contentsOfDirectory|Data\(contentsOf|FileHandle' <<<"$DRAW_BODY"; then
  echo "overlay offline validation failed: draw path performs file I/O or decode" >&2
  exit 1
fi

echo "Overlay offline validation ok"
