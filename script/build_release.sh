#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH_SELECTION="all"

usage() {
  cat <<'EOF'
usage: build_release.sh [--arch arm64|x86_64|all]

Builds architecture-specific Release app bundles, applies ad-hoc signatures,
validates each package, runs functionality on the native host architecture, and
writes ZIP archives plus one SHA256SUMS file. The default is to build both
arm64 and x86_64 archives.

Developer ID signing, Apple notarization, stapling, Gatekeeper assessment, and
a universal binary are not required by this development-stage release flow.
EOF
}

while (($# > 0)); do
  case "$1" in
    --arch)
      (($# >= 2)) || { usage >&2; exit 2; }
      ARCH_SELECTION="$2"
      shift 2
      ;;
    --arch=*)
      ARCH_SELECTION="${1#--arch=}"
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

case "$ARCH_SELECTION" in
  arm64|aarch64)
    ARCH_SELECTION="arm64"
    ARCHITECTURES=(arm64)
    ;;
  x86_64|x64|amd64|intel)
    ARCH_SELECTION="x86_64"
    ARCHITECTURES=(x86_64)
    ;;
  all)
    ARCHITECTURES=(arm64 x86_64)
    ;;
  *)
    printf 'unsupported architecture selection: %s\n' "$ARCH_SELECTION" >&2
    exit 2
    ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || {
  echo 'macOS release builds require Darwin' >&2
  exit 1
}
for dependency in cargo codesign ditto lipo python3 shasum swift; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'required release tool is unavailable: %s\n' "$dependency" >&2
    exit 1
  }
done

"$ROOT_DIR/script/validate_build_scripts_safety.sh" --static-only

SOURCE_VERSION="$(
  awk -F'"' '/^version = / {print $2; exit}' "$ROOT_DIR/crates/petcore/Cargo.toml"
)"
RELEASE_VERSION="${APC_RELEASE_VERSION:-$SOURCE_VERSION}"
RELEASE_BUILD="${APC_RELEASE_BUILD:-1}"
RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
BUILD_ID="${RELEASE_VERSION}.${RELEASE_BUILD}.${RELEASE_COMMIT:0:12}"

if [[ "$RELEASE_VERSION" != "$SOURCE_VERSION" ]]; then
  printf 'release version %s does not match source version %s\n' \
    "$RELEASE_VERSION" "$SOURCE_VERSION" >&2
  exit 1
fi
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+([.][0-9]+){2}$ ]]; then
  echo 'release version must be a three-component semantic version' >&2
  exit 2
fi
if [[ ! "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]]; then
  echo 'APC_RELEASE_BUILD must be a positive integer' >&2
  exit 2
fi
if [[ -n "${APC_BUILD_ID:-}" ]]; then
  echo 'APC_BUILD_ID cannot override the commit-derived release build identity' >&2
  exit 2
fi
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  echo 'release builds require a clean worktree committed at the reported release commit' >&2
  exit 1
fi
if ! grep -q "^## \\[$RELEASE_VERSION\\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$" \
  "$ROOT_DIR/CHANGELOG.md"; then
  printf 'CHANGELOG.md must contain a frozen [%s] - YYYY-MM-DD section\n' \
    "$RELEASE_VERSION" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
CHECKSUM_FILE="$DIST_DIR/AgentPetCompanion-$RELEASE_VERSION-SHA256SUMS.txt"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-release.XXXXXX")"
STAGED_ARTIFACT_DIR="$TMP_DIR/artifacts"
ARTIFACT_NAMES=()

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

build_architecture() {
  local architecture="$1"
  local work_dir="$TMP_DIR/work/$architecture"
  local app_bundle="$work_dir/AgentPetCompanion.app"
  local artifact_name="AgentPetCompanion-$RELEASE_VERSION-macos-$architecture.zip"
  local staged_zip="$STAGED_ARTIFACT_DIR/$artifact_name"
  local verify_dir="$work_dir/verify"

  mkdir -p "$work_dir" "$verify_dir" "$STAGED_ARTIFACT_DIR"
  APC_RELEASE_VERSION="$RELEASE_VERSION" \
  APC_RELEASE_BUILD="$RELEASE_BUILD" \
  APC_RELEASE_CHANNEL="release" \
  APC_BUILD_ID="$BUILD_ID" \
    "$ROOT_DIR/script/build_app_bundle.sh" \
      --configuration release \
      --arch "$architecture" \
      --output "$app_bundle"

  "$ROOT_DIR/script/validate_app_bundle.sh" \
    --release \
    --architecture "$architecture" \
    "$app_bundle"

  ditto -c -k --norsrc --keepParent "$app_bundle" "$staged_zip"
  ditto -x -k "$staged_zip" "$verify_dir"
  "$ROOT_DIR/script/validate_app_bundle.sh" \
    --release \
    --architecture "$architecture" \
    "$verify_dir/AgentPetCompanion.app"

  ARTIFACT_NAMES+=("$artifact_name")
}

for architecture in "${ARCHITECTURES[@]}"; do
  build_architecture "$architecture"
done

CHECKSUM_TMP="$TMP_DIR/$(basename "$CHECKSUM_FILE")"
(
  cd "$STAGED_ARTIFACT_DIR"
  shasum -a 256 "${ARTIFACT_NAMES[@]}"
) >"$CHECKSUM_TMP"

# Publish only after every selected architecture and the shared checksum file
# have passed. A failed build therefore cannot leave a mixed old/new release
# set in dist.
mkdir -p "$DIST_DIR"
for artifact_name in "${ARTIFACT_NAMES[@]}"; do
  rm -f "$DIST_DIR/$artifact_name"
  mv "$STAGED_ARTIFACT_DIR/$artifact_name" "$DIST_DIR/$artifact_name"
done
rm -f "$CHECKSUM_FILE"
mv "$CHECKSUM_TMP" "$CHECKSUM_FILE"

printf 'Release archives ready for commit %s (build %s):\n' \
  "$RELEASE_COMMIT" "$BUILD_ID"
for artifact_name in "${ARTIFACT_NAMES[@]}"; do
  printf '  dist/%s\n' "$artifact_name"
done
printf '  dist/%s\n' "$(basename "$CHECKSUM_FILE")"
echo 'Signing: ad-hoc. Apple notarization and Gatekeeper assessment were not performed.'
