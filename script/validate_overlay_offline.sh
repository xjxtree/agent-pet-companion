#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/apps/macos"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-overlay-offline.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swift build \
  --package-path "$MACOS_DIR" \
  --product AgentPetCompanion \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors >/dev/null

BIN_DIR="$(swift build --package-path "$MACOS_DIR" --show-bin-path)"
APC_HOME="$TMP_DIR/ui-validation-home" \
APC_DISABLE_LAUNCH_AGENT=1 \
APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  "$BIN_DIR/AgentPetCompanion" --run-ui-validation

for suite in \
  OverlayPlacementAuthorityTests \
  AppStoreOverlaySnapshotTests \
  OverlayGeometryTests \
  OverlayDisplayWidthTests \
  OverlayInteractionTelemetryTests \
  FrameTimelineTests \
  PetFramePipelineTests; do
  swift test \
    --package-path "$MACOS_DIR" \
    --filter "$suite" \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors
done

if rg -n 'Timer\.publish|pointerTimer|1\.0 / (24|30)\.0' \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift" \
  "$MACOS_DIR/Sources/AgentPetCompanion/Overlay/PetOverlayController.swift"; then
  echo "overlay offline validation failed: high-frequency pointer polling remains" >&2
  exit 1
fi

if rg -n 'OverlayResizeAccessibility|resizePanel|resizeHitSize|resizeVisualSize|overlayResize|fpsProfile|FpsProfile|FrameSamplingPlan' \
  "$MACOS_DIR/Sources" "$MACOS_DIR/Tests"; then
  echo "overlay offline validation failed: removed resize or FPS-profile contract remains" >&2
  exit 1
fi

echo "Overlay offline V3 validation ok"
