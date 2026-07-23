#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentPetCompanion"
BUNDLE_ID="dev.agentpet.companion"
APP_ICON_NAME="AgentPetCompanion.icns"
MIN_SYSTEM_VERSION="14.0"
CONFIGURATION="debug"
UNIVERSAL=0
TARGET_ARCH=""
OUTPUT_PATH=""
SOURCE_VERSION="$(
  awk -F'"' '/^version = / {print $2; exit}' "$ROOT_DIR/crates/petcore/Cargo.toml"
)"
RELEASE_VERSION="${APC_RELEASE_VERSION:-$SOURCE_VERSION}"
RELEASE_BUILD="${APC_RELEASE_BUILD:-1}"
BUILD_ID="${APC_BUILD_ID:-${RELEASE_VERSION}.${RELEASE_BUILD}.$(date -u +%Y%m%d%H%M%S).$$}"
RELEASE_CHANNEL="${APC_RELEASE_CHANNEL:-develop}"
SIGN_DEVELOPMENT=1
CREATE_DEVELOP_ARCHIVE=0
CARGO_COMMAND=(cargo)
CARGO_RUSTC=""

usage() {
  cat <<'EOF'
usage: build_app_bundle.sh [--configuration debug|release] [--arch arm64|x86_64] [--universal] [--archive] [--unsigned] [--output PATH]

Builds an ad-hoc signed development app bundle by default. --archive also
creates and verifies a `-develop.zip` for informal handoff. --unsigned disables
development signing and cannot be combined with --archive. --arch cross-builds
one thin architecture-specific bundle. --universal remains available for local
inspection, requires release mode, and cannot be combined with --arch. This
script never launches the app.
EOF
}

while (($# > 0)); do
  case "$1" in
    --configuration)
      (($# >= 2)) || { usage >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --universal)
      UNIVERSAL=1
      shift
      ;;
    --arch)
      (($# >= 2)) || { usage >&2; exit 2; }
      TARGET_ARCH="$2"
      shift 2
      ;;
    --arch=*)
      TARGET_ARCH="${1#--arch=}"
      shift
      ;;
    --archive)
      CREATE_DEVELOP_ARCHIVE=1
      shift
      ;;
    --unsigned)
      SIGN_DEVELOPMENT=0
      shift
      ;;
    --output)
      (($# >= 2)) || { usage >&2; exit 2; }
      OUTPUT_PATH="$2"
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

if [[ "$CREATE_DEVELOP_ARCHIVE" == "1" && "$SIGN_DEVELOPMENT" != "1" ]]; then
  echo '--archive cannot be combined with --unsigned' >&2
  exit 2
fi
if [[ "$UNIVERSAL" == "1" && -n "$TARGET_ARCH" ]]; then
  echo '--universal cannot be combined with --arch' >&2
  exit 2
fi

case "$CONFIGURATION" in
  debug|release) ;;
  *) printf 'invalid configuration: %s\n' "$CONFIGURATION" >&2; exit 2 ;;
esac
case "$TARGET_ARCH" in
  "")
    ;;
  arm64|aarch64)
    TARGET_ARCH="arm64"
    ;;
  x86_64|x64|amd64|intel)
    TARGET_ARCH="x86_64"
    ;;
  *)
    printf 'unsupported architecture: %s\n' "$TARGET_ARCH" >&2
    exit 2
    ;;
esac
if [[ "$UNIVERSAL" == "1" && "$CONFIGURATION" != "release" ]]; then
  echo '--universal requires --configuration release' >&2
  exit 2
fi
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  echo 'APC_RELEASE_VERSION must contain one to three dot-separated numeric components' >&2
  exit 2
fi
if [[ ! "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]]; then
  echo 'APC_RELEASE_BUILD must be a positive integer' >&2
  exit 2
fi
if [[ ! "$BUILD_ID" =~ ^[A-Za-z0-9._+-]{1,128}$ ]]; then
  echo 'APC_BUILD_ID must be 1-128 ASCII letters, digits, dots, underscores, pluses, or hyphens' >&2
  exit 2
fi
case "$RELEASE_CHANNEL" in
  develop|release) ;;
  *) echo 'APC_RELEASE_CHANNEL must be develop or release' >&2; exit 2 ;;
esac

SWIFT_DIR="$ROOT_DIR/apps/macos"
APP_ICON_SOURCE="$ROOT_DIR/logo/macos/AgentPetCompanionTransparent.icns"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="${OUTPUT_PATH:-$DIST_DIR/$APP_NAME.app}"
case "$APP_BUNDLE" in
  *.app) ;;
  *) echo 'bundle output must end in .app' >&2; exit 2 ;;
esac

APP_PARENT="$(dirname "$APP_BUNDLE")"
mkdir -p "$APP_PARENT"
# Always assemble and sign outside the repository so the bundle copied into
# dist is complete before local validation. An optional handoff archive is also
# produced from this clean staging area.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-app-bundle.XXXXXX")"
STAGED_APP="$TMP_DIR/$APP_NAME.app"
APP_CONTENTS="$STAGED_APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RUNTIME_MANIFEST="$APP_RESOURCES/runtime-manifest.json"
DEVELOP_ARCHIVE="${APP_BUNDLE%.app}-develop.zip"
STAGED_DEVELOP_ARCHIVE="$TMP_DIR/$APP_NAME-develop.zip"
ARCHIVE_VERIFY_DIR=""

verify_destination_development_bundle() {
  local attempt
  local forbidden_xattrs
  local diff_log="$TMP_DIR/destination-diff.log"
  local verify_log="$TMP_DIR/destination-codesign.log"

  # Require a clean, valid destination and give filesystem metadata a bounded
  # settling window before accepting the local App bundle.
  for attempt in 1 2 3; do
    xattr -cr "$APP_BUNDLE"
    if ! codesign --verify --deep --strict "$APP_BUNDLE" >"$verify_log" 2>&1; then
      forbidden_xattrs="$(xattr -lr "$APP_BUNDLE" 2>/dev/null \
        | grep -E 'com[.]apple[.](FinderInfo|ResourceFork):' || true)"
      if [[ -z "$forbidden_xattrs" ]]; then
        cat "$verify_log" >&2
        echo 'destination app signature is invalid after clearing extended attributes' >&2
        return 1
      fi
      continue
    fi
    sleep 0.25
    if codesign --verify --deep --strict "$APP_BUNDLE" >"$verify_log" 2>&1; then
      return 0
    fi

    forbidden_xattrs="$(xattr -lr "$APP_BUNDLE" 2>/dev/null \
      | grep -E 'com[.]apple[.](FinderInfo|ResourceFork):' || true)"
    if [[ -z "$forbidden_xattrs" ]]; then
      cat "$verify_log" >&2
      echo 'destination app signature changed after a clean copy for an unknown reason' >&2
      return 1
    fi
  done

  # A File Provider may repeatedly re-attach package metadata. Only an explicit
  # handoff archive gives us an independently verified fallback in that case.
  xattr -cr "$APP_BUNDLE"
  if ! codesign --verify --deep --strict "$APP_BUNDLE" >"$verify_log" 2>&1; then
    forbidden_xattrs="$(xattr -lr "$APP_BUNDLE" 2>/dev/null \
      | grep -E 'com[.]apple[.](FinderInfo|ResourceFork):' || true)"
    if [[ -z "$forbidden_xattrs" ]]; then
      cat "$verify_log" >&2
      echo 'destination app signature is invalid after final extended-attribute cleanup' >&2
      return 1
    fi
  fi
  if [[ "$CREATE_DEVELOP_ARCHIVE" != "1" ]]; then
    echo 'destination app metadata did not remain stable; move the workspace out of File Provider storage or rerun with --archive' >&2
    return 1
  fi
  if ! diff -qr "$ARCHIVE_VERIFY_DIR/$APP_NAME.app" "$APP_BUNDLE" >"$diff_log"; then
    cat "$diff_log" >&2
    echo 'destination app payload differs from the strictly verified development archive' >&2
    return 1
  fi
  printf '%s\n' \
    'warning: File Provider repeatedly attached FinderInfo to the destination .app; use the strictly verified -develop.zip as the supported handoff' >&2
}

cleanup() {
  rm -rf "$TMP_DIR"
  if [[ -n "$ARCHIVE_VERIFY_DIR" ]]; then
    rm -rf "$ARCHIVE_VERIFY_DIR"
  fi
}
trap cleanup EXIT

copy_swift_resource_bundles() {
  local swift_bin_path="$1"
  while IFS= read -r -d '' bundle; do
    cp -R "$bundle" "$APP_RESOURCES/"
  done < <(find "$swift_bin_path" -maxdepth 1 -type d -name "${APP_NAME}_*.bundle" -print0)
}

select_cargo_for_target() {
  local rust_target="$1"
  local target_libdir
  local rustup_toolchain

  # Architecture-specific repository builds must use the toolchain pinned by
  # rust-toolchain.toml for every target, even when a Homebrew compiler appears
  # first on PATH. This keeps arm64 and x86_64 release artifacts reproducible.
  if [[ -f "$ROOT_DIR/rust-toolchain.toml" ]] \
    && command -v rustup >/dev/null 2>&1; then
    rustup_toolchain="$(
      cd "$ROOT_DIR"
      rustup show active-toolchain 2>/dev/null | awk 'NR == 1 {print $1}'
    )"
    if [[ -n "$rustup_toolchain" ]]; then
      target_libdir="$(
        rustup run "$rustup_toolchain" \
          rustc --print target-libdir --target "$rust_target" 2>/dev/null || true
      )"
      if [[ -d "$target_libdir" ]]; then
        CARGO_COMMAND=(rustup run "$rustup_toolchain" cargo)
        CARGO_RUSTC="$(rustup which --toolchain "$rustup_toolchain" rustc)"
        return
      fi
      printf 'missing Rust target %s for %s; run: rustup target add --toolchain %s %s\n' \
        "$rust_target" "$rustup_toolchain" "$rustup_toolchain" "$rust_target" >&2
      exit 1
    fi
  fi

  target_libdir="$(rustc --print target-libdir --target "$rust_target" 2>/dev/null || true)"
  if [[ -d "$target_libdir" ]]; then
    CARGO_COMMAND=(cargo)
    CARGO_RUSTC=""
    return
  fi

  # A workspace without rust-toolchain.toml may still have a usable active
  # rustup toolchain even when another compiler appears first on PATH.
  if command -v rustup >/dev/null 2>&1; then
    rustup_toolchain="$(rustup show active-toolchain 2>/dev/null | awk 'NR == 1 {print $1}')"
    if [[ -n "$rustup_toolchain" ]]; then
      target_libdir="$(
        rustup run "$rustup_toolchain" \
          rustc --print target-libdir --target "$rust_target" 2>/dev/null || true
      )"
      if [[ -d "$target_libdir" ]]; then
        CARGO_COMMAND=(rustup run "$rustup_toolchain" cargo)
        CARGO_RUSTC="$(rustup which --toolchain "$rustup_toolchain" rustc)"
        return
      fi
    fi
  fi

  printf 'missing Rust target %s; run: rustup target add %s\n' \
    "$rust_target" "$rust_target" >&2
  exit 1
}

run_cargo() {
  if [[ -n "$CARGO_RUSTC" ]]; then
    RUSTC="$CARGO_RUSTC" "${CARGO_COMMAND[@]}" "$@"
  else
    "${CARGO_COMMAND[@]}" "$@"
  fi
}

build_native() {
  local cargo_args=(build --workspace --locked)
  local swift_args=(build --product "$APP_NAME")
  local rust_target=""
  local swift_triple=""
  local rust_binary_root="$ROOT_DIR/target/$CONFIGURATION"

  case "$TARGET_ARCH" in
    arm64)
      rust_target="aarch64-apple-darwin"
      swift_triple="arm64-apple-macosx$MIN_SYSTEM_VERSION"
      ;;
    x86_64)
      rust_target="x86_64-apple-darwin"
      swift_triple="x86_64-apple-macosx$MIN_SYSTEM_VERSION"
      ;;
  esac

  if [[ "$CONFIGURATION" == "release" ]]; then
    cargo_args+=(--release)
    swift_args=(build -c release --product "$APP_NAME")
  fi
  if [[ -n "$rust_target" ]]; then
    select_cargo_for_target "$rust_target"
    cargo_args+=(--target "$rust_target")
    swift_args+=(--triple "$swift_triple")
    rust_binary_root="$ROOT_DIR/target/$rust_target/$CONFIGURATION"
  fi
  (cd "$ROOT_DIR" && \
    APC_BUILD_ID="$BUILD_ID" \
    APC_APP_VERSION="$RELEASE_VERSION" \
    APC_APP_BUILD="$RELEASE_BUILD" \
    APC_RELEASE_CHANNEL="$RELEASE_CHANNEL" \
    run_cargo "${cargo_args[@]}")
  (cd "$SWIFT_DIR" && swift "${swift_args[@]}")

  local swift_bin_path
  swift_bin_path="$(cd "$SWIFT_DIR" && swift "${swift_args[@]}" --show-bin-path)"
  cp "$swift_bin_path/$APP_NAME" "$APP_BINARY"
  copy_swift_resource_bundles "$swift_bin_path"
  cp "$rust_binary_root/petcore" "$APP_RESOURCES/bin/petcore"
  cp "$rust_binary_root/petcore-cli" "$APP_RESOURCES/bin/petcore-cli"
}

write_runtime_manifest() {
  local host_arch
  host_arch="$(uname -m)"
  case "$host_arch" in
    aarch64) host_arch="arm64" ;;
    amd64) host_arch="x86_64" ;;
  esac

  if [[ -z "$TARGET_ARCH" || "$TARGET_ARCH" == "$host_arch" || "$UNIVERSAL" == "1" ]]; then
    "$APP_RESOURCES/bin/petcore" runtime-manifest >"$RUNTIME_MANIFEST"
    return
  fi

  # A thin cross-built PetCore may not be executable on the build host. Build
  # the small host-native manifest authority with the same release identity so
  # architecture-specific archives do not depend on Rosetta merely to assemble.
  local cargo_args=(build --locked -p petcore)
  local host_petcore="$ROOT_DIR/target/debug/petcore"
  if [[ "$CONFIGURATION" == "release" ]]; then
    cargo_args+=(--release)
    host_petcore="$ROOT_DIR/target/release/petcore"
  fi
  (cd "$ROOT_DIR" && \
    APC_BUILD_ID="$BUILD_ID" \
    APC_APP_VERSION="$RELEASE_VERSION" \
    APC_APP_BUILD="$RELEASE_BUILD" \
    APC_RELEASE_CHANNEL="$RELEASE_CHANNEL" \
    run_cargo "${cargo_args[@]}")
  "$host_petcore" runtime-manifest >"$RUNTIME_MANIFEST"
}

build_universal() {
  [[ "$(uname -s)" == "Darwin" ]] || {
    echo 'universal macOS builds require Darwin' >&2
    exit 1
  }
  command -v lipo >/dev/null 2>&1 || {
    echo 'universal macOS builds require lipo from Xcode command-line tools' >&2
    exit 1
  }

  local targets=(aarch64-apple-darwin x86_64-apple-darwin)
  local target
  for target in "${targets[@]}"; do
    select_cargo_for_target "$target"
    if ! (cd "$ROOT_DIR" && \
      APC_BUILD_ID="$BUILD_ID" \
      APC_APP_VERSION="$RELEASE_VERSION" \
      APC_APP_BUILD="$RELEASE_BUILD" \
      APC_RELEASE_CHANNEL="$RELEASE_CHANNEL" \
      run_cargo build --workspace --locked --release --target "$target"); then
      printf 'Rust target %s is unavailable; install both Apple targets before release\n' "$target" >&2
      exit 1
    fi
  done

  (cd "$SWIFT_DIR" && swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME")
  local swift_bin_path
  swift_bin_path="$(cd "$SWIFT_DIR" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  cp "$swift_bin_path/$APP_NAME" "$APP_BINARY"
  copy_swift_resource_bundles "$swift_bin_path"

  lipo -create \
    "$ROOT_DIR/target/aarch64-apple-darwin/release/petcore" \
    "$ROOT_DIR/target/x86_64-apple-darwin/release/petcore" \
    -output "$APP_RESOURCES/bin/petcore"
  lipo -create \
    "$ROOT_DIR/target/aarch64-apple-darwin/release/petcore-cli" \
    "$ROOT_DIR/target/x86_64-apple-darwin/release/petcore-cli" \
    -output "$APP_RESOURCES/bin/petcore-cli"

  for binary in "$APP_BINARY" "$APP_RESOURCES/bin/petcore" "$APP_RESOURCES/bin/petcore-cli"; do
    architectures="$(lipo -archs "$binary")"
    [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || {
      printf 'universal build is missing a required slice: %s (%s)\n' "$binary" "$architectures" >&2
      exit 1
    }
  done
}

mkdir -p "$APP_MACOS" "$APP_RESOURCES/bin" "$APP_RESOURCES/skills"
[[ -f "$APP_ICON_SOURCE" ]] || {
  echo "missing app icon source: $APP_ICON_SOURCE" >&2
  exit 1
}
if [[ "$UNIVERSAL" == "1" ]]; then
  build_universal
else
  build_native
fi

cp -R "$ROOT_DIR/skills/agent-pet-studio" "$APP_RESOURCES/skills/agent-pet-studio"
cp -R "$ROOT_DIR/skills/agent-pet-maker" "$APP_RESOURCES/skills/agent-pet-maker"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME"
find "$APP_RESOURCES/skills" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$APP_RESOURCES/skills" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
chmod +x "$APP_BINARY" "$APP_RESOURCES/bin/petcore" "$APP_RESOURCES/bin/petcore-cli"
write_runtime_manifest

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$RELEASE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$RELEASE_BUILD</string>
  <key>APCBuildID</key>
  <string>$BUILD_ID</string>
  <key>APCReleaseChannel</key>
  <string>$RELEASE_CHANNEL</string>
  <key>APCRuntimeManifestSchemaVersion</key>
  <string>apc.runtime-manifest.v1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>dev.agentpet.petpack</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeDescription</key>
      <string>Agent Pet Companion Pet Pack</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>petpack</string>
        </array>
        <key>public.mime-type</key>
        <string>application/vnd.agentpet.petpack+zip</string>
      </dict>
    </dict>
  </array>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_DEVELOPMENT" == "1" ]]; then
  command -v codesign >/dev/null 2>&1 || {
    echo 'development signing requires codesign' >&2
    exit 1
  }
  # Finder and copy operations can attach metadata that invalidates even an
  # ad-hoc signature. Strip it from the staged bundle before signing so the
  # exact artifact moved into dist is verifiable with --deep --strict.
  xattr -cr "$STAGED_APP"
  codesign --force --sign - --timestamp=none "$APP_BINARY"
  codesign --force --sign - --timestamp=none "$APP_RESOURCES/bin/petcore"
  codesign --force --sign - --timestamp=none "$APP_RESOURCES/bin/petcore-cli"
  codesign --force --sign - --timestamp=none "$STAGED_APP"
fi

VALIDATE_ARGS=(--development)
if [[ -n "$TARGET_ARCH" ]]; then
  VALIDATE_ARGS+=(--architecture "$TARGET_ARCH")
fi
"$ROOT_DIR/script/validate_app_bundle.sh" "${VALIDATE_ARGS[@]}" "$STAGED_APP" >/dev/null

if [[ "$CREATE_DEVELOP_ARCHIVE" == "1" ]]; then
  # Archive the clean, signed staging bundle before anything crosses into the
  # File Provider workspace. Verify the exact archive payload independently.
  command -v ditto >/dev/null 2>&1 || {
    echo 'development packaging requires ditto' >&2
    exit 1
  }
  ditto -c -k --norsrc --keepParent "$STAGED_APP" "$STAGED_DEVELOP_ARCHIVE"
  ARCHIVE_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-develop-archive.XXXXXX")"
  ditto -x -k "$STAGED_DEVELOP_ARCHIVE" "$ARCHIVE_VERIFY_DIR"
  codesign --verify --deep --strict "$ARCHIVE_VERIFY_DIR/$APP_NAME.app"
fi

mkdir -p "$(dirname "$APP_BUNDLE")"
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"
if [[ "$CREATE_DEVELOP_ARCHIVE" == "1" ]]; then
  rm -f "$DEVELOP_ARCHIVE"
  mv "$STAGED_DEVELOP_ARCHIVE" "$DEVELOP_ARCHIVE"

  # Re-extract the final archive path and verify its payload, not only the
  # temporary file that preceded the move into dist.
  rm -rf "$ARCHIVE_VERIFY_DIR/$APP_NAME.app"
  ditto -x -k "$DEVELOP_ARCHIVE" "$ARCHIVE_VERIFY_DIR"
  codesign --verify --deep --strict "$ARCHIVE_VERIFY_DIR/$APP_NAME.app"

else
  # Do not leave a stale handoff artifact that no longer corresponds to the
  # App produced by this successful build.
  rm -f "$DEVELOP_ARCHIVE"
fi
if [[ "$SIGN_DEVELOPMENT" == "1" ]]; then
  verify_destination_development_bundle
fi

printf 'Built %s (%s%s, build %s)\n' \
  "$APP_BUNDLE" \
  "$CONFIGURATION" \
  "$(
    if [[ "$UNIVERSAL" == "1" ]]; then
      printf ', universal'
    elif [[ -n "$TARGET_ARCH" ]]; then
      printf ', %s' "$TARGET_ARCH"
    fi
  )" \
  "$BUILD_ID"
if [[ "$CREATE_DEVELOP_ARCHIVE" == "1" ]]; then
  printf 'Packaged %s (ad-hoc development signature)\n' "$DEVELOP_ARCHIVE"
fi
