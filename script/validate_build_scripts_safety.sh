#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_ONLY=0

if [[ "${1:-}" == "--static-only" ]]; then
  STATIC_ONLY=1
  shift
fi
if (($# > 0)); then
  echo 'usage: validate_build_scripts_safety.sh [--static-only]' >&2
  exit 2
fi

"$ROOT_DIR/script/validate_source_syntax.sh"

RELEASE_SCRIPTS=(
  "$ROOT_DIR/script/build_release.sh"
  "$ROOT_DIR/script/sign_and_notarize.sh"
)
if unsafe="$(rg -n \
  'security[[:space:]]+find-identity|notarytool[[:space:]]+store-credentials|(^|[[:space:]])source[[:space:]]+.*\.env|(^|[[:space:]])\.[[:space:]]+.*\.env|APC_CODESIGN_IDENTITY:-|APC_NOTARY_PROFILE:-' \
  "${RELEASE_SCRIPTS[@]}" || true)" && [[ -n "$unsafe" ]]; then
  printf 'release scripts contain credential discovery/default behavior:\n%s\n' "$unsafe" >&2
  exit 1
fi

rg -q -- '--configuration release' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--universal' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--options runtime' "$ROOT_DIR/script/sign_and_notarize.sh"
rg -q -- '--timestamp' "$ROOT_DIR/script/sign_and_notarize.sh"
rg -q 'notarytool submit' "$ROOT_DIR/script/sign_and_notarize.sh"
rg -q 'stapler staple' "$ROOT_DIR/script/sign_and_notarize.sh"
rg -q 'spctl --assess' "$ROOT_DIR/script/sign_and_notarize.sh"

"$ROOT_DIR/script/build_app_bundle.sh" --help >/dev/null
"$ROOT_DIR/script/build_release.sh" --help >/dev/null
"$ROOT_DIR/script/sign_and_notarize.sh" --help >/dev/null

if [[ "$STATIC_ONLY" == "0" ]]; then
  "$ROOT_DIR/script/validate_test_isolation.sh"
fi

echo 'Build and release script safety ok'
