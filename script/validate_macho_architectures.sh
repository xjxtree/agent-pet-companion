#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE=""
EXPECTED_ARCH=""

usage() {
  cat <<'EOF'
usage: validate_macho_architectures.sh \
  --app APP_BUNDLE \
  --architecture arm64|x86_64

Requires every Mach-O file in an App bundle to be exactly one requested thin
architecture. Unknown extra Mach-O files are included in the validation.
EOF
}

while (($# > 0)); do
  case "$1" in
    --app)
      (($# >= 2)) || { usage >&2; exit 2; }
      APP_BUNDLE="$2"
      shift 2
      ;;
    --architecture)
      (($# >= 2)) || { usage >&2; exit 2; }
      EXPECTED_ARCH="$2"
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

case "$EXPECTED_ARCH" in
  arm64|x86_64) ;;
  *) echo '--architecture must be arm64 or x86_64' >&2; exit 2 ;;
esac
[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || {
  echo 'Mach-O architecture validation requires a regular App bundle directory' >&2
  exit 1
}
for dependency in file lipo; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'Mach-O architecture validation requires %s\n' "$dependency" >&2
    exit 1
  }
done

MACHO_COUNT=0
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" 2>/dev/null | grep -F 'Mach-O' >/dev/null; then
    MACHO_COUNT=$((MACHO_COUNT + 1))
    architectures="$(lipo -archs "$candidate")"
    [[ "$architectures" == "$EXPECTED_ARCH" ]] || {
      printf 'Mach-O architecture validation failed: %s is %s, expected exact thin %s\n' \
        "$candidate" "$architectures" "$EXPECTED_ARCH" >&2
      exit 1
    }
  fi
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

if ((MACHO_COUNT < 3)); then
  echo 'Mach-O architecture validation failed: expected App, PetCore, and CLI code' >&2
  exit 1
fi
printf 'Mach-O architecture validation ok (%s files, thin %s)\n' \
  "$MACHO_COUNT" "$EXPECTED_ARCH"
