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
  "$ROOT_DIR/script/build_app_bundle.sh"
)
if unsafe="$(rg -n \
  'security[[:space:]]+find-identity|notarytool|stapler|spctl[[:space:]]+--assess|(^|[[:space:]])source[[:space:]]+.*\.env|(^|[[:space:]])\.[[:space:]]+.*\.env|APC_CODESIGN_IDENTITY|APC_NOTARY_PROFILE' \
  "${RELEASE_SCRIPTS[@]}" || true)" && [[ -n "$unsafe" ]]; then
  printf 'development-stage release scripts contain unsupported distribution behavior:\n%s\n' \
    "$unsafe" >&2
  exit 1
fi

rg -q -- '--configuration release' "$ROOT_DIR/script/build_release.sh"
rg -Fq -- '--arch "$architecture"' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'ARCHITECTURES=(arm64 x86_64)' "$ROOT_DIR/script/build_release.sh"
rg -q 'SHA256SUMS' "$ROOT_DIR/script/build_release.sh"
rg -q 'ditto -c -k --norsrc --keepParent' "$ROOT_DIR/script/build_release.sh"
rg -q 'release builds require a clean worktree' "$ROOT_DIR/script/build_release.sh"
rg -q 'CHANGELOG.md must contain a frozen' "$ROOT_DIR/script/build_release.sh"
rg -q 'APC_BUILD_ID cannot override the commit-derived' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'STAGED_ARTIFACT_DIR="$TMP_DIR/artifacts"' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--release' "$ROOT_DIR/script/build_release.sh"
rg -Fq -- '--architecture "$architecture"' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'swift_args=(build -c release --product "$APP_NAME")' \
  "$ROOT_DIR/script/build_app_bundle.sh"
rg -Fq -- '--triple "$swift_triple"' "$ROOT_DIR/script/build_app_bundle.sh"
rg -Fq 'rust-toolchain.toml' "$ROOT_DIR/script/build_app_bundle.sh"
rg -Fq 'rustup run "$rustup_toolchain" cargo' "$ROOT_DIR/script/build_app_bundle.sh"
rg -q -- '--archive' "$ROOT_DIR/script/build_app_bundle.sh"
rg -q 'codesign --force --sign - --timestamp=none' \
  "$ROOT_DIR/script/build_app_bundle.sh"

"$ROOT_DIR/script/build_app_bundle.sh" --help >/dev/null
"$ROOT_DIR/script/build_release.sh" --help >/dev/null
"$ROOT_DIR/script/validate_app_bundle.sh" --help >/dev/null

if [[ "$STATIC_ONLY" == "0" ]]; then
  "$ROOT_DIR/script/validate_test_isolation.sh"
fi

echo 'Build and release script safety ok'
