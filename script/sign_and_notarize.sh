#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: sign_and_notarize.sh APP_BUNDLE [OUTPUT_ZIP]

Requires APC_CODESIGN_IDENTITY and APC_NOTARY_PROFILE. The script uses those
explicit values without discovering certificates or reading credential files.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if (($# < 1 || $# > 2)); then
  usage >&2
  exit 2
fi

APP_BUNDLE="$1"
OUTPUT_ZIP="${2:-$(dirname "$APP_BUNDLE")/AgentPetCompanion-macos-universal.zip}"
: "${APC_CODESIGN_IDENTITY:?Set APC_CODESIGN_IDENTITY to an explicit Developer ID Application identity}"
: "${APC_NOTARY_PROFILE:?Set APC_NOTARY_PROFILE to an explicit notarytool keychain profile name}"

[[ "$(uname -s)" == "Darwin" ]] || { echo 'signing and notarization require Darwin' >&2; exit 1; }
[[ -d "$APP_BUNDLE" ]] || { printf 'missing app bundle: %s\n' "$APP_BUNDLE" >&2; exit 1; }
case "$OUTPUT_ZIP" in
  *.zip) ;;
  *) echo 'output archive must end in .zip' >&2; exit 2 ;;
esac
for dependency in codesign ditto lipo shasum spctl xcrun; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'required release tool is unavailable: %s\n' "$dependency" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-notarize.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="$APP_BUNDLE/Contents/Resources/bin/petcore-cli"
for binary in "$APP_BINARY" "$PETCORE" "$PETCORE_CLI"; do
  [[ -x "$binary" ]] || { printf 'missing nested executable: %s\n' "$binary" >&2; exit 1; }
  architectures="$(lipo -archs "$binary")"
  [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || {
    printf 'refusing to sign non-universal executable: %s (%s)\n' "$binary" "$architectures" >&2
    exit 1
  }
  codesign --force --timestamp --options runtime --generate-entitlement-der \
    --sign "$APC_CODESIGN_IDENTITY" "$binary"
done

codesign --force --timestamp --options runtime --generate-entitlement-der \
  --sign "$APC_CODESIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

NOTARY_ZIP="$TMP_DIR/AgentPetCompanion-notary.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$APC_NOTARY_PROFILE" \
  --wait \
  --output-format json >"$TMP_DIR/notary-result.json"

python3 - "$TMP_DIR/notary-result.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    result = json.load(file)
status = str(result.get("status", "")).lower()
request_id = result.get("id", "unknown")
if status != "accepted":
    raise SystemExit(f"notarization was not accepted: status={status!r}, id={request_id}")
print(f"Notarization accepted: request_id={request_id}")
PY

xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

mkdir -p "$(dirname "$OUTPUT_ZIP")"
rm -f "$OUTPUT_ZIP" "$OUTPUT_ZIP.sha256"
ditto -c -k --keepParent "$APP_BUNDLE" "$OUTPUT_ZIP"
(
  cd "$(dirname "$OUTPUT_ZIP")"
  shasum -a 256 "$(basename "$OUTPUT_ZIP")" >"$(basename "$OUTPUT_ZIP").sha256"
)

printf 'Signed, notarized and stapled archive: %s\n' "$OUTPUT_ZIP"
