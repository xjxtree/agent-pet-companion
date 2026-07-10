#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentPetCompanion"
BUNDLE_ID="dev.agentpet.companion"
MIN_SYSTEM_VERSION="14.0"
CONFIGURATION="debug"
UNIVERSAL=0
OUTPUT_PATH=""
RELEASE_VERSION="${APC_RELEASE_VERSION:-0.1.0}"
RELEASE_BUILD="${APC_RELEASE_BUILD:-1}"

usage() {
  cat <<'EOF'
usage: build_app_bundle.sh [--configuration debug|release] [--universal] [--output PATH]

Builds a development app bundle by default. --universal requires release mode
and builds arm64 plus x86_64 slices. This script never signs or launches the app.
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

case "$CONFIGURATION" in
  debug|release) ;;
  *) printf 'invalid configuration: %s\n' "$CONFIGURATION" >&2; exit 2 ;;
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/apps/macos"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="${OUTPUT_PATH:-$DIST_DIR/$APP_NAME.app}"
case "$APP_BUNDLE" in
  *.app) ;;
  *) echo 'bundle output must end in .app' >&2; exit 2 ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-app-bundle.XXXXXX")"
STAGED_APP="$TMP_DIR/$APP_NAME.app"
APP_CONTENTS="$STAGED_APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

copy_swift_resource_bundles() {
  local swift_bin_path="$1"
  while IFS= read -r -d '' bundle; do
    cp -R "$bundle" "$APP_RESOURCES/"
  done < <(find "$swift_bin_path" -maxdepth 1 -type d -name "${APP_NAME}_*.bundle" -print0)
}

build_native() {
  local cargo_args=(build --workspace --locked)
  local swift_args=(build --product "$APP_NAME")
  if [[ "$CONFIGURATION" == "release" ]]; then
    cargo_args+=(--release)
    swift_args=(-c release "${swift_args[@]}")
  fi
  (cd "$ROOT_DIR" && cargo "${cargo_args[@]}")
  (cd "$SWIFT_DIR" && swift "${swift_args[@]}")

  local swift_bin_path
  local rust_profile="$CONFIGURATION"
  if [[ "$CONFIGURATION" == "debug" ]]; then
    swift_bin_path="$(cd "$SWIFT_DIR" && swift build --show-bin-path)"
  else
    swift_bin_path="$(cd "$SWIFT_DIR" && swift build -c release --show-bin-path)"
  fi
  cp "$swift_bin_path/$APP_NAME" "$APP_BINARY"
  copy_swift_resource_bundles "$swift_bin_path"
  cp "$ROOT_DIR/target/$rust_profile/petcore" "$APP_RESOURCES/bin/petcore"
  cp "$ROOT_DIR/target/$rust_profile/petcore-cli" "$APP_RESOURCES/bin/petcore-cli"
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
    if ! (cd "$ROOT_DIR" && cargo build --workspace --locked --release --target "$target"); then
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
if [[ "$UNIVERSAL" == "1" ]]; then
  build_universal
else
  build_native
fi

cp -R "$ROOT_DIR/skills/agent-pet-studio" "$APP_RESOURCES/skills/agent-pet-studio"
find "$APP_RESOURCES/skills" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$APP_RESOURCES/skills" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
chmod +x "$APP_BINARY" "$APP_RESOURCES/bin/petcore" "$APP_RESOURCES/bin/petcore-cli"

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
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$RELEASE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$RELEASE_BUILD</string>
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

"$ROOT_DIR/script/validate_app_bundle.sh" --development "$STAGED_APP" >/dev/null

mkdir -p "$(dirname "$APP_BUNDLE")"
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"

printf 'Built %s (%s%s)\n' \
  "$APP_BUNDLE" \
  "$CONFIGURATION" \
  "$([[ "$UNIVERSAL" == "1" ]] && printf ', universal' || true)"
