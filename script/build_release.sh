#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH_SELECTION="all"
GITHUB_RELEASE=0
SOURCE_GATE_PROVEN=0

usage() {
  cat <<'EOF'
usage: build_release.sh --github-release [--arch all|arm64|x86_64] [--source-gate-proven]

Builds one or both official thin macOS archives for one clean, tagged GitHub
Release candidate. --arch all also creates and validates the shared checksum:

  AgentPetCompanion-X.Y.Z-macos-arm64.zip
  AgentPetCompanion-X.Y.Z-macos-x86_64.zip
  AgentPetCompanion-X.Y.Z-SHA256SUMS.txt

The Apps are ad-hoc signed. This command does not use Developer ID, submit to
Apple notarization, or claim Gatekeeper trust. Users may need to explicitly
allow the first launch in Finder or System Settings.

Development handoff archives are produced separately by:
  build_app_bundle.sh --archive
EOF
}

while (($# > 0)); do
  case "$1" in
    --github-release)
      GITHUB_RELEASE=1
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
    --source-gate-proven)
      SOURCE_GATE_PROVEN=1
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

if [[ "$GITHUB_RELEASE" != "1" ]]; then
  echo 'official release builds require the explicit --github-release mode' >&2
  exit 2
fi
case "$ARCH_SELECTION" in
  all) ARCHITECTURES=(arm64 x86_64) ;;
  arm64|x86_64) ARCHITECTURES=("$ARCH_SELECTION") ;;
  *) echo '--arch must be all, arm64, or x86_64' >&2; exit 2 ;;
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

if [[ "$SOURCE_GATE_PROVEN" == "1" && -z "${APC_INTERACTION_ATTESTATION_PATH:-}" ]]; then
  echo '--source-gate-proven requires APC_INTERACTION_ATTESTATION_PATH from the source gate' >&2
  exit 2
fi
if [[ "$SOURCE_GATE_PROVEN" == "0" ]]; then
  "$ROOT_DIR/script/validate_build_scripts_safety.sh" --static-only
fi

SOURCE_VERSION="$(
  awk -F'"' '/^version = / {print $2; exit}' "$ROOT_DIR/crates/petcore/Cargo.toml"
)"
RELEASE_VERSION="${APC_RELEASE_VERSION:-$SOURCE_VERSION}"
RELEASE_BUILD="${APC_RELEASE_BUILD:-1}"
RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
BUILD_ID="${RELEASE_VERSION}.${RELEASE_BUILD}.${RELEASE_COMMIT}"

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
  echo 'APC_BUILD_ID cannot override the full-commit-derived release build identity' >&2
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
TAG_COMMIT="$(git -C "$ROOT_DIR" rev-list -n 1 "$RELEASE_TAG" 2>/dev/null || true)"
if [[ "$TAG_COMMIT" != "$RELEASE_COMMIT" ]]; then
  printf 'GitHub Release distribution requires tag %s to point at the candidate commit\n' \
    "$RELEASE_TAG" >&2
  exit 1
fi

PREVIOUS_RELEASE_TAG="${APC_PREVIOUS_RELEASE_TAG:-}"
if [[ -z "$PREVIOUS_RELEASE_TAG" ]]; then
  PREVIOUS_RELEASE_TAG="$({
    git -C "$ROOT_DIR" describe \
      --tags \
      --match 'v[0-9]*.[0-9]*.[0-9]*' \
      --abbrev=0 \
      "$RELEASE_COMMIT^"
  } 2>/dev/null || true)"
fi
if [[ -z "$PREVIOUS_RELEASE_TAG" ]]; then
  echo 'GitHub Release distribution requires a previous version tag baseline' >&2
  exit 1
fi
if [[ ! "$PREVIOUS_RELEASE_TAG" =~ ^v[0-9]+([.][0-9]+){2}$ ]]; then
  echo 'previous GitHub Release tag baseline must be strict vX.Y.Z SemVer' >&2
  exit 1
fi
PREVIOUS_RELEASE_COMMIT="$({
  git -C "$ROOT_DIR" rev-parse --verify "$PREVIOUS_RELEASE_TAG^{commit}"
} 2>/dev/null || true)"
if [[ -z "$PREVIOUS_RELEASE_COMMIT" ]] \
  || ! git -C "$ROOT_DIR" merge-base \
    --is-ancestor "$PREVIOUS_RELEASE_COMMIT" "$RELEASE_COMMIT^"; then
  echo 'previous GitHub Release tag baseline must be an ancestor of the candidate' >&2
  exit 1
fi
"$ROOT_DIR/script/validate_codex_plugin_version.py" \
  --base-ref "$PREVIOUS_RELEASE_TAG"

DIST_DIR="$ROOT_DIR/dist"
CHECKSUM_NAME="AgentPetCompanion-$RELEASE_VERSION-SHA256SUMS.txt"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-github-release.XXXXXX")"
STAGED_ARTIFACT_DIR="$TMP_DIR/artifacts"
ARTIFACT_NAMES=()

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

INTERACTION_ATTESTATION="${APC_INTERACTION_ATTESTATION_PATH:-}"
if [[ -n "$INTERACTION_ATTESTATION" ]]; then
  [[ "$INTERACTION_ATTESTATION" == /* ]] || {
    echo 'APC_INTERACTION_ATTESTATION_PATH must be absolute' >&2
    exit 2
  }
  "$ROOT_DIR/script/validate_interaction_attestation.py" \
    "$INTERACTION_ATTESTATION" \
    --expected-build-id "$BUILD_ID"
else
  INTERACTION_ATTESTATION="$TMP_DIR/interaction-attestation.json"
  APC_BUILD_ID="$BUILD_ID" \
    "$ROOT_DIR/script/prepare_interaction_attestation.sh" \
      --output "$INTERACTION_ATTESTATION" \
      --swift-scope all
fi

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
      --interaction-attestation "$INTERACTION_ATTESTATION" \
      --validation static \
      --output "$app_bundle"

  ditto -c -k --norsrc --keepParent "$app_bundle" "$staged_zip"
  "$ROOT_DIR/script/validate_release_zip.py" --archive "$staged_zip"
  ditto -x -k "$staged_zip" "$verify_dir"

  "$ROOT_DIR/script/validate_release_identity.py" \
    --app "$verify_dir/AgentPetCompanion.app" \
    --architecture "$architecture" \
    --version "$RELEASE_VERSION" \
    --build "$RELEASE_BUILD" \
    --commit "$RELEASE_COMMIT"
  ARTIFACT_NAMES+=("$artifact_name")
}

for architecture in "${ARCHITECTURES[@]}"; do
  build_architecture "$architecture"
done

if [[ "$ARCH_SELECTION" == "all" ]]; then
  (
    cd "$STAGED_ARTIFACT_DIR"
    shasum -a 256 "${ARTIFACT_NAMES[@]}"
  ) >"$STAGED_ARTIFACT_DIR/$CHECKSUM_NAME"
  "$ROOT_DIR/script/validate_release_artifact_metadata.py" \
    --directory "$STAGED_ARTIFACT_DIR" \
    --version "$RELEASE_VERSION"

  host_arch="$(uname -m)"
  case "$host_arch" in
    aarch64) host_arch="arm64" ;;
    amd64) host_arch="x86_64" ;;
  esac
  if [[ "$host_arch" == "arm64" || "$host_arch" == "x86_64" ]]; then
    "$ROOT_DIR/script/validate_github_release_artifacts.sh" \
      --directory "$STAGED_ARTIFACT_DIR" \
      --version "$RELEASE_VERSION" \
      --build "$RELEASE_BUILD" \
      --commit "$RELEASE_COMMIT" \
      --require-native-architecture "$host_arch"
  fi
fi

# Publish only validated component files. Complete local mode waits for both
# architectures and the shared checksum; matrix mode uploads one component to
# the later exact-inventory assembly job.
mkdir -p "$DIST_DIR"
PUBLISH_NAMES=("${ARTIFACT_NAMES[@]}")
if [[ "$ARCH_SELECTION" == "all" ]]; then
  PUBLISH_NAMES+=("$CHECKSUM_NAME")
fi
for artifact_name in "${PUBLISH_NAMES[@]}"; do
  rm -f "$DIST_DIR/$artifact_name"
  mv "$STAGED_ARTIFACT_DIR/$artifact_name" "$DIST_DIR/$artifact_name"
done

printf 'GitHub Release archives ready for tag %s, commit %s (build %s):\n' \
  "$RELEASE_TAG" "$RELEASE_COMMIT" "$BUILD_ID"
for artifact_name in "${ARTIFACT_NAMES[@]}"; do
  printf '  dist/%s\n' "$artifact_name"
done
if [[ "$ARCH_SELECTION" == "all" ]]; then
  printf '  dist/%s\n' "$CHECKSUM_NAME"
else
  echo 'This is one validated architecture component; assemble both ZIPs and the shared checksum before publication.'
fi
echo 'Distribution policy: ad-hoc signed and not notarized; users may need to explicitly allow the first launch.'
