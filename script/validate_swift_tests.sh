#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/apps/macos"
DEVELOPER_BIN="/Library/Developer/CommandLineTools/usr/bin"
INTEROP_DIR="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
CPP_INCLUDE="${CPLUS_INCLUDE_PATH:-}"
SDK=""
ARGS=(test --disable-sandbox)

if command -v xcrun >/dev/null 2>&1; then
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
  DEVELOPER_GIT="$(xcrun --find git 2>/dev/null || true)"
  if [[ -n "$DEVELOPER_GIT" ]]; then
    DEVELOPER_BIN="$(dirname "$DEVELOPER_GIT")"
  fi
  if [[ -n "$SDK" && -f "$SDK/usr/include/c++/v1/atomic" ]]; then
    CPP_INCLUDE="$SDK/usr/include/c++/v1${CPP_INCLUDE:+:$CPP_INCLUDE}"
  fi
fi
if [[ -f "$INTEROP_DIR/lib_TestingInterop.dylib" ]]; then
  ARGS+=(-Xlinker "-L$INTEROP_DIR" -Xlinker -rpath -Xlinker "$INTEROP_DIR")
fi

cd "$SWIFT_DIR"
env \
  PATH="$DEVELOPER_BIN:/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
  SDKROOT="$SDK" \
  CPLUS_INCLUDE_PATH="$CPP_INCLUDE" \
  swift "${ARGS[@]}"
