#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE=""
ARCHITECTURE=""
SUBMISSION_ARCHIVE=""
FINAL_ARCHIVE=""
EVIDENCE_FILE=""
ENTITLEMENTS="$ROOT_DIR/config/distribution/AgentPetCompanion.entitlements"

usage() {
  cat <<'EOF'
usage: public_distribution_pipeline.sh \
  --app APP_BUNDLE \
  --architecture arm64|x86_64 \
  --submission-archive PATH \
  --final-archive PATH \
  --evidence PATH

Signs a staged App with an externally provisioned Developer ID identity,
submits a pre-staple ZIP to Apple notarization, staples and assesses the App,
then creates and revalidates the distinct final ZIP. It never discovers,
stores, or prints credentials.

Required environment:
  APC_CODESIGN_IDENTITY    Exact Developer ID Application identity
  APC_DEVELOPER_TEAM_ID    Ten-character Apple Developer Team ID
  APC_NOTARY_PROFILE       Name of the notarytool keychain profile
  APC_RELEASE_VERSION      Three-component semantic version
  APC_RELEASE_BUILD        Positive build number
  APC_RELEASE_COMMIT       Full candidate commit
  APC_BUILD_ID             Shared App/PetCore/CLI build ID

Optional environment:
  APC_NOTARY_KEYCHAIN      Absolute path to the regular Keychain containing the
                           notarytool profile (required for an ephemeral CI Keychain)
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
      ARCHITECTURE="$2"
      shift 2
      ;;
    --submission-archive)
      (($# >= 2)) || { usage >&2; exit 2; }
      SUBMISSION_ARCHIVE="$2"
      shift 2
      ;;
    --final-archive)
      (($# >= 2)) || { usage >&2; exit 2; }
      FINAL_ARCHIVE="$2"
      shift 2
      ;;
    --evidence)
      (($# >= 2)) || { usage >&2; exit 2; }
      EVIDENCE_FILE="$2"
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

[[ -n "$APP_BUNDLE" && -n "$SUBMISSION_ARCHIVE" \
  && -n "$FINAL_ARCHIVE" && -n "$EVIDENCE_FILE" ]] || {
  usage >&2
  exit 2
}
case "$ARCHITECTURE" in
  arm64|x86_64) ;;
  *) echo '--architecture must be arm64 or x86_64' >&2; exit 2 ;;
esac
[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || {
  echo 'public distribution requires a regular staged App bundle directory' >&2
  exit 1
}
for output in "$SUBMISSION_ARCHIVE" "$FINAL_ARCHIVE" "$EVIDENCE_FILE"; do
  [[ "$output" != "$APP_BUNDLE" && "$output" != "$APP_BUNDLE/"* ]] || {
    echo 'public distribution outputs must be outside the App bundle' >&2
    exit 2
  }
done

CODESIGN_IDENTITY="${APC_CODESIGN_IDENTITY:-}"
TEAM_ID="${APC_DEVELOPER_TEAM_ID:-}"
NOTARY_PROFILE="${APC_NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${APC_NOTARY_KEYCHAIN:-}"
RELEASE_VERSION="${APC_RELEASE_VERSION:-}"
RELEASE_BUILD="${APC_RELEASE_BUILD:-}"
RELEASE_COMMIT="${APC_RELEASE_COMMIT:-}"
BUILD_ID="${APC_BUILD_ID:-}"

if [[ ! "$CODESIGN_IDENTITY" =~ ^Developer[[:space:]]ID[[:space:]]Application:[[:space:]].+ \
  || "$CODESIGN_IDENTITY" == *$'\n'* \
  || "$CODESIGN_IDENTITY" == *$'\r'* \
  || ${#CODESIGN_IDENTITY} -gt 256 ]]; then
  echo 'supported public distribution unavailable: APC_CODESIGN_IDENTITY is not provisioned' >&2
  exit 78
fi
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'supported public distribution unavailable: APC_DEVELOPER_TEAM_ID is not provisioned' >&2
  exit 78
fi
if [[ -z "$NOTARY_PROFILE" \
  || "$NOTARY_PROFILE" == *$'\n'* \
  || "$NOTARY_PROFILE" == *$'\r'* \
  || ${#NOTARY_PROFILE} -gt 128 ]]; then
  echo 'supported public distribution unavailable: APC_NOTARY_PROFILE is not provisioned' >&2
  exit 78
fi
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  if [[ "$NOTARY_KEYCHAIN" != /* \
    || "$NOTARY_KEYCHAIN" == *$'\n'* \
    || "$NOTARY_KEYCHAIN" == *$'\r'* \
    || ${#NOTARY_KEYCHAIN} -gt 1024 \
    || ! -f "$NOTARY_KEYCHAIN" \
    || -L "$NOTARY_KEYCHAIN" ]]; then
    echo 'supported public distribution unavailable: APC_NOTARY_KEYCHAIN is invalid' >&2
    exit 78
  fi
fi
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+([.][0-9]+){2}$ \
  || ! "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ \
  || ! "$RELEASE_COMMIT" =~ ^[0-9a-f]{40}$ \
  || ! "$BUILD_ID" =~ ^[A-Za-z0-9._+-]{1,128}$ ]]; then
  echo 'public distribution identity environment is incomplete or invalid' >&2
  exit 2
fi

for dependency in codesign ditto file python3 shasum spctl xcrun; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'public distribution requires %s\n' "$dependency" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-public-distribution.XXXXXX")"
STAGED_SUBMISSION="$TMP_DIR/submission.zip"
STAGED_FINAL="$TMP_DIR/final.zip"
STAGED_EVIDENCE="$TMP_DIR/evidence.json"
NOTARY_RESULT="$TMP_DIR/notary-result.json"
SIGNED_ITEMS="$TMP_DIR/signed-items"
VERIFY_DIR="$TMP_DIR/final-verify"
COMPLETED=0

cleanup() {
  rm -rf "$TMP_DIR"
  if [[ "$COMPLETED" != "1" ]]; then
    rm -f "$SUBMISSION_ARCHIVE" "$FINAL_ARCHIVE" "$EVIDENCE_FILE"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$(dirname "$SUBMISSION_ARCHIVE")" \
  "$(dirname "$FINAL_ARCHIVE")" \
  "$(dirname "$EVIDENCE_FILE")" \
  "$VERIFY_DIR"
rm -f "$SUBMISSION_ARCHIVE" "$FINAL_ARCHIVE" "$EVIDENCE_FILE"

# Strip mutable Finder metadata before the first signature. Sign every Mach-O
# leaf, then nested code containers deepest-first, and the outer App last.
xattr -cr "$APP_BUNDLE"
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
done < <(
  find "$APP_BUNDLE/Contents" -type f -print \
    | awk '{ print length($0) "\t" $0 }' \
    | LC_ALL=C sort -rn \
    | cut -f2-
)
while IFS= read -r nested_code; do
  if contains_macho "$nested_code"; then
    printf '%s\n' "$nested_code" >>"$SIGNED_ITEMS"
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

if [[ "$(wc -l <"$SIGNED_ITEMS" | tr -d ' ')" -lt 3 ]]; then
  echo 'public distribution signing failed: expected UI, PetCore, and CLI Mach-O code' >&2
  exit 1
fi
while IFS= read -r signed_item; do
  codesign \
    --force \
    --sign "$CODESIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$signed_item"
done <"$SIGNED_ITEMS"
codesign \
  --force \
  --sign "$CODESIGN_IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP_BUNDLE"

APC_CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
APC_DEVELOPER_TEAM_ID="$TEAM_ID" \
  "$ROOT_DIR/script/validate_distribution_signature.sh" \
    --app "$APP_BUNDLE" \
    --entitlements "$ENTITLEMENTS"

# The notarization service sees this pre-staple archive. Its digest is evidence
# for the submitted payload and is intentionally not reused as the final
# downloadable artifact digest.
ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$STAGED_SUBMISSION"
SUBMISSION_SHA256="$(shasum -a 256 "$STAGED_SUBMISSION" | awk '{print $1}')"

if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  xcrun notarytool submit "$STAGED_SUBMISSION" \
    --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$NOTARY_KEYCHAIN" \
    --wait \
    --output-format json \
    >"$NOTARY_RESULT"
else
  xcrun notarytool submit "$STAGED_SUBMISSION" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json \
    >"$NOTARY_RESULT"
fi

read -r NOTARY_ID NOTARY_STATUS < <(
  python3 - "$NOTARY_RESULT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    result = json.load(file)
submission_id = result.get("id")
status = result.get("status")
if not isinstance(submission_id, str) or not submission_id:
    raise SystemExit("notarytool response is missing the submission ID")
if status != "Accepted":
    raise SystemExit(f"notarization was not accepted: {status!r}")
print(submission_id, status)
PY
)

xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

# Stapling mutates the App, so create a new final archive and verify the exact
# extracted payload before making any caller-visible output.
ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$STAGED_FINAL"
"$ROOT_DIR/script/validate_release_zip.py" --archive "$STAGED_FINAL"
ditto -x -k "$STAGED_FINAL" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/$(basename "$APP_BUNDLE")"
"$ROOT_DIR/script/validate_macho_architectures.sh" \
  --app "$EXTRACTED_APP" \
  --architecture "$ARCHITECTURE"
APC_CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
APC_DEVELOPER_TEAM_ID="$TEAM_ID" \
  "$ROOT_DIR/script/validate_distribution_signature.sh" \
    --app "$EXTRACTED_APP" \
    --entitlements "$ENTITLEMENTS"
xcrun stapler validate "$EXTRACTED_APP"
spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"

FINAL_SHA256="$(shasum -a 256 "$STAGED_FINAL" | awk '{print $1}')"
[[ "$SUBMISSION_SHA256" != "$FINAL_SHA256" ]] || {
  echo 'public distribution failed: pre-staple and final archive digests unexpectedly match' >&2
  exit 1
}

python3 - \
  "$STAGED_EVIDENCE" \
  "$ARCHITECTURE" \
  "$RELEASE_VERSION" \
  "$RELEASE_BUILD" \
  "$RELEASE_COMMIT" \
  "$BUILD_ID" \
  "$(basename "$FINAL_ARCHIVE")" \
  "$SUBMISSION_SHA256" \
  "$FINAL_SHA256" \
  "$NOTARY_ID" \
  "$NOTARY_STATUS" <<'PY'
import json
import pathlib
import sys

(
    output,
    architecture,
    version,
    build,
    commit,
    build_id,
    final_name,
    submission_sha256,
    final_sha256,
    notarization_id,
    notarization_status,
) = sys.argv[1:]

evidence = {
    "schema_version": "apc.public-distribution-evidence.v1",
    "architecture": architecture,
    "version": version,
    "build": build,
    "commit": commit,
    "build_id": build_id,
    "notarization": {
        "submission_id": notarization_id,
        "status": notarization_status,
        "submission_archive_sha256": submission_sha256,
    },
    "published_artifact": {
        "filename": final_name,
        "sha256": final_sha256,
        "stapled": True,
        "gatekeeper_accepted": True,
    },
}
pathlib.Path(output).write_text(
    json.dumps(evidence, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

mv "$STAGED_SUBMISSION" "$SUBMISSION_ARCHIVE"
mv "$STAGED_FINAL" "$FINAL_ARCHIVE"
mv "$STAGED_EVIDENCE" "$EVIDENCE_FILE"
COMPLETED=1

echo 'Supported public distribution artifact prepared and revalidated'
