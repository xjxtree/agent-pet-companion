#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/apps/macos"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-overlay-offline.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
INTERACTION_ATTESTATION=""

usage() {
  echo 'usage: validate_overlay_offline.sh [--interaction-attestation ABSOLUTE_PATH]'
}

while (($# > 0)); do
  case "$1" in
    --interaction-attestation)
      (($# >= 2)) || { usage >&2; exit 2; }
      INTERACTION_ATTESTATION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$INTERACTION_ATTESTATION" ]]; then
  [[ "$INTERACTION_ATTESTATION" == /* ]] || {
    echo 'interaction attestation input must be an absolute path' >&2
    exit 2
  }
  "$ROOT_DIR/script/validate_interaction_attestation.py" "$INTERACTION_ATTESTATION"
  VERIFIED_INTERACTION_ATTESTATION="$TMP_DIR/interaction-attestation.json"
  cp "$INTERACTION_ATTESTATION" "$VERIFIED_INTERACTION_ATTESTATION"
  "$ROOT_DIR/script/validate_interaction_attestation.py" "$VERIFIED_INTERACTION_ATTESTATION"
fi

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

SUITES=(FrameTimelineTests PetFramePipelineTests)
if [[ -z "$INTERACTION_ATTESTATION" ]]; then
  SUITES=(
    OverlayPlacementAuthorityTests
    AppStoreOverlaySnapshotTests
    OverlayGeometryTests
    OverlayDisplayWidthTests
    OverlayInteractionTelemetryTests
    "${SUITES[@]}"
  )
fi
for suite in "${SUITES[@]}"; do
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
