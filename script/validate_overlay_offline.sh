#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v rg >/dev/null 2>&1; then
  rg() {
    local mode="${1:-}"
    shift || true
    if [[ "$mode" != "-n" ]]; then
      printf 'unsupported portable search mode: %s\n' "$mode" >&2
      return 2
    fi
    grep -ERn "$@"
  }
fi
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

BIN_DIR="$(swift build --package-path "$MACOS_DIR" --show-bin-path)"
SWIFT_TEST_BUILD_ARGS=()
if [[ -n "$INTERACTION_ATTESTATION" ]]; then
  [[ -x "$BIN_DIR/AgentPetCompanion" ]] || {
    echo 'validated Swift artifact is missing the AgentPetCompanion executable' >&2
    exit 1
  }
  [[ -d "$BIN_DIR/AgentPetCompanionPackageTests.xctest" ]] || {
    echo 'validated Swift artifact is missing the package test bundle' >&2
    exit 1
  }
  SWIFT_TEST_BUILD_ARGS+=(--skip-build)
else
  swift build \
    --package-path "$MACOS_DIR" \
    --product AgentPetCompanion \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors >/dev/null
fi

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
suite_filter="$(IFS='|'; printf '%s' "${SUITES[*]}")"
swift test \
  --package-path "$MACOS_DIR" \
  "${SWIFT_TEST_BUILD_ARGS[@]}" \
  --filter "$suite_filter" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

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
