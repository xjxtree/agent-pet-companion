#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE=""
ENTITLEMENTS="$ROOT_DIR/config/distribution/AgentPetCompanion.entitlements"

usage() {
  cat <<'EOF'
usage: validate_distribution_signature.sh --app APP_BUNDLE [--entitlements PLIST]

Validates the Developer ID authority, Team ID, hardened runtime, designated
requirements, and minimal entitlements of an already signed App bundle.

Required environment:
  APC_CODESIGN_IDENTITY    Exact Developer ID Application identity
  APC_DEVELOPER_TEAM_ID    Ten-character Apple Developer Team ID
EOF
}

while (($# > 0)); do
  case "$1" in
    --app)
      (($# >= 2)) || { usage >&2; exit 2; }
      APP_BUNDLE="$2"
      shift 2
      ;;
    --entitlements)
      (($# >= 2)) || { usage >&2; exit 2; }
      ENTITLEMENTS="$2"
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

[[ -n "$APP_BUNDLE" ]] || { usage >&2; exit 2; }
[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || {
  echo 'distribution signature validation requires a regular App bundle directory' >&2
  exit 1
}
[[ -f "$ENTITLEMENTS" && ! -L "$ENTITLEMENTS" ]] || {
  echo 'distribution signature validation requires the repository entitlements plist' >&2
  exit 1
}

CODESIGN_IDENTITY="${APC_CODESIGN_IDENTITY:-}"
TEAM_ID="${APC_DEVELOPER_TEAM_ID:-}"
if [[ ! "$CODESIGN_IDENTITY" =~ ^Developer[[:space:]]ID[[:space:]]Application:[[:space:]].+ \
  || "$CODESIGN_IDENTITY" == *$'\n'* \
  || ${#CODESIGN_IDENTITY} -gt 256 ]]; then
  echo 'APC_CODESIGN_IDENTITY must name an externally provisioned Developer ID Application identity' >&2
  exit 78
fi
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'APC_DEVELOPER_TEAM_ID must be a ten-character Apple Developer Team ID' >&2
  exit 78
fi

for dependency in codesign file python3; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'distribution signature validation requires %s\n' "$dependency" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-signature-validation.XXXXXX")"
SIGNED_ITEMS="$TMP_DIR/signed-items"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

python3 - "$ENTITLEMENTS" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as file:
    entitlements = plistlib.load(file)
if entitlements != {}:
    raise SystemExit(
        "distribution signature validation failed: public App entitlements "
        "must remain the explicit empty allowlist"
    )
PY

: >"$SIGNED_ITEMS"
contains_macho() {
  local container="$1"
  local contained_file
  while IFS= read -r contained_file; do
    if file -b "$contained_file" 2>/dev/null | grep -F 'Mach-O' >/dev/null; then
      return 0
    fi
  done < <(find "$container" -type f -print)
  return 1
}

while IFS= read -r candidate; do
  if file -b "$candidate" 2>/dev/null | grep -F 'Mach-O' >/dev/null; then
    printf '%s\n' "$candidate" >>"$SIGNED_ITEMS"
  fi
done < <(find "$APP_BUNDLE/Contents" -type f -print | LC_ALL=C sort)

# Code containers are verified after their inner Mach-O files. Resource-only
# Swift bundles are intentionally excluded; they are sealed by the outer App.
while IFS= read -r candidate; do
  if contains_macho "$candidate"; then
    printf '%s\n' "$candidate" >>"$SIGNED_ITEMS"
  fi
done < <(
  find "$APP_BUNDLE/Contents" -type d \
    \( -name '*.app' -o -name '*.appex' -o -name '*.bundle' \
      -o -name '*.framework' -o -name '*.xpc' \) \
    -print \
    | awk '{ print length($0) "\t" $0 }' \
    | LC_ALL=C sort -rn \
    | cut -f2-
)
printf '%s\n' "$APP_BUNDLE" >>"$SIGNED_ITEMS"

if [[ "$(wc -l <"$SIGNED_ITEMS" | tr -d ' ')" -lt 4 ]]; then
  echo 'distribution signature validation failed: expected App, PetCore, CLI, and UI executable code' >&2
  exit 1
fi

verify_item() {
  local item="$1"
  local metadata="$TMP_DIR/metadata"
  local requirement="$TMP_DIR/requirement"

  codesign --verify --strict --verbose=4 "$item"
  codesign --display --verbose=4 "$item" >"$metadata" 2>&1
  grep -Fx "Authority=$CODESIGN_IDENTITY" "$metadata" >/dev/null || {
    echo 'distribution signature validation failed: unexpected signing authority' >&2
    exit 1
  }
  grep -Fx "TeamIdentifier=$TEAM_ID" "$metadata" >/dev/null || {
    echo 'distribution signature validation failed: unexpected signing Team ID' >&2
    exit 1
  }
  grep -E '^CodeDirectory .*flags=.*\(.*runtime.*\)' "$metadata" >/dev/null || {
    echo 'distribution signature validation failed: hardened runtime is absent' >&2
    exit 1
  }
  grep -E '^Timestamp=.+$' "$metadata" >/dev/null || {
    echo 'distribution signature validation failed: secure signing timestamp is absent' >&2
    exit 1
  }

  codesign -d -r- "$item" >"$requirement" 2>&1
  grep -F 'anchor apple generic' "$requirement" >/dev/null || {
    echo 'distribution signature validation failed: designated requirement lacks the Apple anchor' >&2
    exit 1
  }
  grep -F "certificate leaf[subject.OU] = \"$TEAM_ID\"" "$requirement" >/dev/null || {
    echo 'distribution signature validation failed: designated requirement has the wrong Team ID' >&2
    exit 1
  }
}

while IFS= read -r signed_item; do
  verify_item "$signed_item"
done <"$SIGNED_ITEMS"

codesign -d -r- "$APP_BUNDLE" >"$TMP_DIR/app-requirement" 2>&1
grep -F 'identifier "dev.agentpet.companion"' "$TMP_DIR/app-requirement" >/dev/null || {
  echo 'distribution signature validation failed: App designated requirement has the wrong identifier' >&2
  exit 1
}

codesign -d --entitlements :- "$APP_BUNDLE" \
  >"$TMP_DIR/actual-entitlements.plist" 2>"$TMP_DIR/entitlements-display.log"
python3 - "$ENTITLEMENTS" "$TMP_DIR/actual-entitlements.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as file:
    expected = plistlib.load(file)
with open(sys.argv[2], "rb") as file:
    actual = plistlib.load(file)
if actual != expected:
    raise SystemExit(
        "distribution signature validation failed: embedded App entitlements "
        "do not match the repository allowlist"
    )
PY

echo 'Developer ID signature validation ok'
