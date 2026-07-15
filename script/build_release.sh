#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="distribution"

usage() {
  cat <<'EOF'
usage: build_release.sh [--unsigned|--distribution]

--unsigned builds and validates a universal Release candidate for local review.
--distribution (default) additionally requires explicit signing and notarization
environment values and produces the distributable ZIP plus SHA-256 file.
EOF
}

while (($# > 0)); do
  case "$1" in
    --unsigned)
      MODE="unsigned"
      shift
      ;;
    --distribution)
      MODE="distribution"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || {
  echo 'macOS release builds require Darwin' >&2
  exit 1
}

"$ROOT_DIR/script/validate_build_scripts_safety.sh" --static-only
"$ROOT_DIR/script/build_app_bundle.sh" \
  --configuration release \
  --universal \
  --unsigned \
  --output "$ROOT_DIR/dist/AgentPetCompanion.app"
"$ROOT_DIR/script/validate_app_bundle.sh" --development "$ROOT_DIR/dist/AgentPetCompanion.app"

if [[ "$MODE" == "unsigned" ]]; then
  cat <<'EOF'
Unsigned universal Release candidate built and validated.
This app is for local inspection only; it is not signed, notarized, stapled, or distributable.
EOF
  exit 0
fi

: "${APC_CODESIGN_IDENTITY:?Set APC_CODESIGN_IDENTITY to an explicit Developer ID Application identity}"
: "${APC_NOTARY_PROFILE:?Set APC_NOTARY_PROFILE to an explicit notarytool keychain profile name}"

"$ROOT_DIR/script/sign_and_notarize.sh" \
  "$ROOT_DIR/dist/AgentPetCompanion.app" \
  "$ROOT_DIR/dist/AgentPetCompanion-macos-universal.zip"
"$ROOT_DIR/script/validate_app_bundle.sh" --distribution "$ROOT_DIR/dist/AgentPetCompanion.app"

echo 'Distributable macOS archive is ready: dist/AgentPetCompanion-macos-universal.zip'
