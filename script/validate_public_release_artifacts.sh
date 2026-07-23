#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR=""
VERSION=""
BUILD=""
COMMIT=""
REQUIRE_NATIVE_ARCHITECTURE=""

usage() {
  cat <<'EOF'
usage: validate_public_release_artifacts.sh \
  --directory PATH \
  --version X.Y.Z \
  --build POSITIVE_INTEGER \
  --commit FULL_LOWERCASE_GIT_COMMIT \
  [--require-native-architecture arm64|x86_64]

Validates the exact five-file public set: two final ZIPs, their two distribution
evidence sidecars, and one checksum inventory covering exactly the four data
assets. Every ZIP receives a bounded safety preflight before extraction.

The required version, build, and commit are bound to evidence, Info.plist,
runtime-manifest.json, and the shared two-architecture build identity.

Required environment:
  APC_CODESIGN_IDENTITY    Exact Developer ID Application identity
  APC_DEVELOPER_TEAM_ID    Ten-character Apple Developer Team ID
EOF
}

while (($# > 0)); do
  case "$1" in
    --directory)
      (($# >= 2)) || { usage >&2; exit 2; }
      ARTIFACT_DIR="$2"
      shift 2
      ;;
    --version)
      (($# >= 2)) || { usage >&2; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --build)
      (($# >= 2)) || { usage >&2; exit 2; }
      BUILD="$2"
      shift 2
      ;;
    --commit)
      (($# >= 2)) || { usage >&2; exit 2; }
      COMMIT="$2"
      shift 2
      ;;
    --require-native-architecture)
      (($# >= 2)) || { usage >&2; exit 2; }
      REQUIRE_NATIVE_ARCHITECTURE="$2"
      shift 2
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

[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] || {
  echo 'public release validation requires a regular artifact directory' >&2
  exit 2
}
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){2}$ ]] || {
  echo '--version must be a three-component semantic version' >&2
  exit 2
}
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
  echo '--build must be a positive integer' >&2
  exit 2
}
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo '--commit must be a full lowercase Git commit' >&2
  exit 2
}
case "$REQUIRE_NATIVE_ARCHITECTURE" in
  "") ;;
  arm64|x86_64) ;;
  *) echo '--require-native-architecture must be arm64 or x86_64' >&2; exit 2 ;;
esac

for dependency in ditto python3 shasum; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'public release artifact validation requires %s\n' "$dependency" >&2
    exit 1
  }
done

if [[ -n "$REQUIRE_NATIVE_ARCHITECTURE" ]]; then
  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    aarch64) HOST_ARCH="arm64" ;;
    amd64) HOST_ARCH="x86_64" ;;
  esac
  [[ "$HOST_ARCH" == "$REQUIRE_NATIVE_ARCHITECTURE" ]] || {
    printf 'native packaged validation requires %s hardware; runner reports %s\n' \
      "$REQUIRE_NATIVE_ARCHITECTURE" "$HOST_ARCH" >&2
    exit 1
  }
fi

"$ROOT_DIR/script/validate_release_artifact_metadata.py" \
  --directory "$ARTIFACT_DIR" \
  --version "$VERSION"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-public-artifact-validation.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for architecture in arm64 x86_64; do
  archive_name="AgentPetCompanion-$VERSION-macos-$architecture.zip"
  evidence_name="AgentPetCompanion-$VERSION-macos-$architecture-distribution.json"
  archive="$ARTIFACT_DIR/$archive_name"
  evidence="$ARTIFACT_DIR/$evidence_name"
  extract_dir="$TMP_DIR/$architecture"
  archive_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"

  # This must remain before every extraction of downloaded release content.
  "$ROOT_DIR/script/validate_release_zip.py" --archive "$archive"
  mkdir -p "$extract_dir"
  ditto -x -k "$archive" "$extract_dir"
  extracted_app="$extract_dir/AgentPetCompanion.app"
  [[ -d "$extracted_app" && ! -L "$extracted_app" ]] || {
    echo 'public release ZIP did not extract the expected regular App bundle' >&2
    exit 1
  }

  "$ROOT_DIR/script/validate_release_identity.py" \
    --app "$extracted_app" \
    --evidence "$evidence" \
    --architecture "$architecture" \
    --version "$VERSION" \
    --build "$BUILD" \
    --commit "$COMMIT" \
    --archive-name "$archive_name" \
    --archive-sha256 "$archive_sha256"

  APC_CODESIGN_IDENTITY="${APC_CODESIGN_IDENTITY:-}" \
  APC_DEVELOPER_TEAM_ID="${APC_DEVELOPER_TEAM_ID:-}" \
    "$ROOT_DIR/script/validate_app_bundle.sh" \
      --public \
      --architecture "$architecture" \
      "$extracted_app"
done

echo 'Supported public release artifacts validated for both architectures and one identity'
