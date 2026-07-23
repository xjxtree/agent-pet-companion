#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH_SELECTION="all"
RELEASE_MODE="preview"
EXPLICIT_RELEASE_MODE=""

usage() {
  cat <<'EOF'
usage: build_release.sh [--preview|--public] [--arch arm64|x86_64|all]

Builds thin arm64 and x86_64 Release App archives from one clean, tagged
candidate commit.

--preview (default)
  Produces clearly named, ad-hoc-signed development-preview ZIPs. It does not
  claim Developer ID signing, notarization, stapling, or Gatekeeper acceptance.

--public
  Produces supported public ZIPs only after recursive Developer ID signing,
  hardened-runtime and entitlement verification, notarization, stapling,
  Gatekeeper assessment, final-ZIP extraction/revalidation, and checksums.
  It never falls back to preview output.

Public mode requires externally provisioned values and does not discover,
store, or print credentials:
  APC_CODESIGN_IDENTITY
  APC_DEVELOPER_TEAM_ID
  APC_NOTARY_PROFILE
EOF
}

while (($# > 0)); do
  case "$1" in
    --preview)
      if [[ -n "$EXPLICIT_RELEASE_MODE" && "$EXPLICIT_RELEASE_MODE" != "preview" ]]; then
        echo '--preview and --public cannot be combined' >&2
        exit 2
      fi
      EXPLICIT_RELEASE_MODE="preview"
      RELEASE_MODE="preview"
      shift
      ;;
    --public)
      if [[ -n "$EXPLICIT_RELEASE_MODE" && "$EXPLICIT_RELEASE_MODE" != "public" ]]; then
        echo '--preview and --public cannot be combined' >&2
        exit 2
      fi
      EXPLICIT_RELEASE_MODE="public"
      RELEASE_MODE="public"
      shift
      ;;
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
if [[ "$RELEASE_MODE" == "public" && "$ARCH_SELECTION" != "all" ]]; then
  echo 'supported public distribution requires --arch all' >&2
  exit 2
fi

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
if [[ "$RELEASE_MODE" == "public" ]]; then
  for dependency in file spctl xcrun xattr; do
    command -v "$dependency" >/dev/null 2>&1 || {
      printf 'supported public distribution requires %s\n' "$dependency" >&2
      exit 1
    }
  done
  if [[ -z "${APC_CODESIGN_IDENTITY:-}" \
    || -z "${APC_DEVELOPER_TEAM_ID:-}" \
    || -z "${APC_NOTARY_PROFILE:-}" ]]; then
    echo 'supported public distribution unavailable: externally provisioned signing identity, Team ID, and notary profile are required' >&2
    exit 78
  fi
fi

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

RELEASE_TAG="v$RELEASE_VERSION"
if [[ "$RELEASE_MODE" == "public" ]]; then
  TAG_COMMIT="$(git -C "$ROOT_DIR" rev-list -n 1 "$RELEASE_TAG" 2>/dev/null || true)"
  if [[ "$TAG_COMMIT" != "$RELEASE_COMMIT" ]]; then
    printf 'supported public distribution requires tag %s to point at the candidate commit\n' \
      "$RELEASE_TAG" >&2
    exit 1
  fi
fi

DIST_DIR="$ROOT_DIR/dist"
CHECKSUM_NAME="AgentPetCompanion-$RELEASE_VERSION-SHA256SUMS.txt"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-release.XXXXXX")"
STAGED_ARTIFACT_DIR="$TMP_DIR/artifacts"
ARTIFACT_NAMES=()

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

build_preview_architecture() {
  local architecture="$1"
  local work_dir="$TMP_DIR/work/$architecture"
  local app_bundle="$work_dir/AgentPetCompanion.app"
  local artifact_name="AgentPetCompanion-$RELEASE_VERSION-macos-$architecture-preview.zip"
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
    --preview \
    --architecture "$architecture" \
    "$app_bundle"

  ditto -c -k --norsrc --keepParent "$app_bundle" "$staged_zip"
  "$ROOT_DIR/script/validate_release_zip.py" --archive "$staged_zip"
  ditto -x -k "$staged_zip" "$verify_dir"
  "$ROOT_DIR/script/validate_app_bundle.sh" \
    --preview \
    --architecture "$architecture" \
    "$verify_dir/AgentPetCompanion.app"

  ARTIFACT_NAMES+=("$artifact_name")
}

build_public_architecture() {
  local architecture="$1"
  local work_dir="$TMP_DIR/work/$architecture"
  local app_bundle="$work_dir/AgentPetCompanion.app"
  local artifact_name="AgentPetCompanion-$RELEASE_VERSION-macos-$architecture.zip"
  local evidence_name="AgentPetCompanion-$RELEASE_VERSION-macos-$architecture-distribution.json"
  local submission_zip="$work_dir/notarization-submission.zip"

  mkdir -p "$work_dir" "$STAGED_ARTIFACT_DIR"
  APC_RELEASE_VERSION="$RELEASE_VERSION" \
  APC_RELEASE_BUILD="$RELEASE_BUILD" \
  APC_RELEASE_CHANNEL="release" \
  APC_BUILD_ID="$BUILD_ID" \
    "$ROOT_DIR/script/build_app_bundle.sh" \
      --configuration release \
      --arch "$architecture" \
      --unsigned \
      --output "$app_bundle"

  # The unsigned structural gate still exercises native packaged runtime
  # identity before distribution signing. The public pipeline then performs
  # the trust-policy gates against the exact signed and stapled payload.
  "$ROOT_DIR/script/validate_app_bundle.sh" \
    --development \
    --architecture "$architecture" \
    "$app_bundle"

  APC_RELEASE_VERSION="$RELEASE_VERSION" \
  APC_RELEASE_BUILD="$RELEASE_BUILD" \
  APC_RELEASE_COMMIT="$RELEASE_COMMIT" \
  APC_BUILD_ID="$BUILD_ID" \
  APC_CODESIGN_IDENTITY="$APC_CODESIGN_IDENTITY" \
  APC_DEVELOPER_TEAM_ID="$APC_DEVELOPER_TEAM_ID" \
  APC_NOTARY_PROFILE="$APC_NOTARY_PROFILE" \
    "$ROOT_DIR/script/public_distribution_pipeline.sh" \
      --app "$app_bundle" \
      --architecture "$architecture" \
      --submission-archive "$submission_zip" \
      --final-archive "$STAGED_ARTIFACT_DIR/$artifact_name" \
      --evidence "$STAGED_ARTIFACT_DIR/$evidence_name"

  "$ROOT_DIR/script/validate_app_bundle.sh" \
    --public \
    --architecture "$architecture" \
    "$app_bundle"
  rm -f "$submission_zip"

  ARTIFACT_NAMES+=("$artifact_name" "$evidence_name")
}

for architecture in "${ARCHITECTURES[@]}"; do
  if [[ "$RELEASE_MODE" == "public" ]]; then
    build_public_architecture "$architecture"
  else
    build_preview_architecture "$architecture"
  fi
done

CHECKSUM_TMP="$TMP_DIR/$CHECKSUM_NAME"
(
  cd "$STAGED_ARTIFACT_DIR"
  shasum -a 256 "${ARTIFACT_NAMES[@]}"
) >"$CHECKSUM_TMP"
mv "$CHECKSUM_TMP" "$STAGED_ARTIFACT_DIR/$CHECKSUM_NAME"

if [[ "$RELEASE_MODE" == "public" ]]; then
  APC_CODESIGN_IDENTITY="$APC_CODESIGN_IDENTITY" \
  APC_DEVELOPER_TEAM_ID="$APC_DEVELOPER_TEAM_ID" \
    "$ROOT_DIR/script/validate_public_release_artifacts.sh" \
      --directory "$STAGED_ARTIFACT_DIR" \
      --version "$RELEASE_VERSION" \
      --build "$RELEASE_BUILD" \
      --commit "$RELEASE_COMMIT"
fi

# Publish into dist only after every selected architecture and the shared
# checksum have passed. A failed build cannot leave a mixed public artifact set.
mkdir -p "$DIST_DIR"
for artifact_name in "${ARTIFACT_NAMES[@]}" "$CHECKSUM_NAME"; do
  rm -f "$DIST_DIR/$artifact_name"
  mv "$STAGED_ARTIFACT_DIR/$artifact_name" "$DIST_DIR/$artifact_name"
done

if [[ "$RELEASE_MODE" == "public" ]]; then
  printf 'Supported public release archives ready for tag %s, commit %s (build %s):\n' \
    "$RELEASE_TAG" "$RELEASE_COMMIT" "$BUILD_ID"
else
  printf 'Development-preview archives ready for commit %s (build %s):\n' \
    "$RELEASE_COMMIT" "$BUILD_ID"
fi
for artifact_name in "${ARTIFACT_NAMES[@]}"; do
  printf '  dist/%s\n' "$artifact_name"
done
printf '  dist/%s\n' "$CHECKSUM_NAME"
if [[ "$RELEASE_MODE" == "preview" ]]; then
  echo 'Preview only: ad-hoc signed; notarization, stapling, and Gatekeeper assessment were not performed.'
fi
