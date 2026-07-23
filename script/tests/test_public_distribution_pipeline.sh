#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-public-pipeline-test.XXXXXX")"
SHIM_DIR="$TMP_DIR/shims"
APP_BUNDLE="$TMP_DIR/AgentPetCompanion.app"
COMMAND_LOG="$TMP_DIR/commands.log"
OUTPUT_LOG="$TMP_DIR/output.log"
SUBMISSION="$TMP_DIR/submission.zip"
FINAL="$TMP_DIR/final.zip"
EVIDENCE="$TMP_DIR/evidence.json"
NOTARY_KEYCHAIN="$TMP_DIR/notary.keychain-db"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

write_executable() {
  local path="$1"
  shift
  printf '%s\n' "$@" >"$path"
  chmod +x "$path"
}

mkdir -p \
  "$SHIM_DIR" \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources/bin"
for binary in \
  "$APP_BUNDLE/Contents/MacOS/AgentPetCompanion" \
  "$APP_BUNDLE/Contents/Resources/bin/petcore" \
  "$APP_BUNDLE/Contents/Resources/bin/petcore-cli"; do
  printf 'fake Mach-O\n' >"$binary"
  chmod +x "$binary"
done
: >"$COMMAND_LOG"
: >"$NOTARY_KEYCHAIN"

write_executable "$SHIM_DIR/file" \
  '#!/usr/bin/env bash' \
  'case "${@: -1}" in' \
  '  */AgentPetCompanion|*/petcore|*/petcore-cli) echo "Mach-O 64-bit executable" ;;' \
  '  *) echo "data" ;;' \
  'esac'

write_executable "$SHIM_DIR/xattr" \
  '#!/usr/bin/env bash' \
  'printf '\''xattr\t%s\n'\'' "$*" >>"$APC_FAKE_COMMAND_LOG"'

write_executable "$SHIM_DIR/codesign" \
  '#!/usr/bin/env bash' \
  'printf '\''codesign\t%s\n'\'' "$*" >>"$APC_FAKE_COMMAND_LOG"' \
  'if [[ "${1:-}" == "--display" && "${2:-}" == "--verbose=4" ]]; then' \
  '  {' \
  '    echo "Authority=$APC_CODESIGN_IDENTITY"' \
  '    echo "TeamIdentifier=$APC_DEVELOPER_TEAM_ID"' \
  '    echo "CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+0 location=embedded"' \
  '    echo "Timestamp=Jul 23, 2026 at 12:00:00"' \
  '  } >&2' \
  'elif [[ "${1:-}" == "-d" && "${2:-}" == "-r-" ]]; then' \
  '  case "${@: -1}" in' \
  '    *.app) identifier="dev.agentpet.companion" ;;' \
  '    *) identifier="$(basename "${@: -1}")" ;;' \
  '  esac' \
  '  echo "designated => identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.OU] = \"$APC_DEVELOPER_TEAM_ID\"" >&2' \
  'elif [[ "${1:-}" == "-d" && "${2:-}" == "--entitlements" ]]; then' \
  '  printf '\''%s\n'\'' '\''<?xml version="1.0" encoding="UTF-8"?>'\'' '\''<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'\'' '\''<plist version="1.0"><dict/></plist>'\''' \
  'fi'

write_executable "$SHIM_DIR/ditto" \
  '#!/usr/bin/env bash' \
  'printf '\''ditto\t%s\n'\'' "$*" >>"$APC_FAKE_COMMAND_LOG"' \
  'if [[ "${1:-}" == "-c" ]]; then' \
  '  source_path="${@: -2:1}"' \
  '  archive="${@: -1}"' \
  '  rm -rf "$archive.payload"' \
  '  mkdir -p "$archive.payload"' \
  '  cp -R "$source_path" "$archive.payload/"' \
  '  python3 - "$source_path" "$archive" <<'\''PY'\''' \
  'import pathlib' \
  'import sys' \
  'import zipfile' \
  'source = pathlib.Path(sys.argv[1])' \
  'destination = pathlib.Path(sys.argv[2])' \
  'with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as output:' \
  '    root = zipfile.ZipInfo(source.name + "/")' \
  '    root.external_attr = (0o40755 << 16) | 0x10' \
  '    output.writestr(root, b"")' \
  '    for item in sorted(source.rglob("*")):' \
  '        relative = item.relative_to(source).as_posix()' \
  '        name = source.name + "/" + relative' \
  '        if item.is_dir():' \
  '            info = zipfile.ZipInfo(name + "/")' \
  '            info.external_attr = (0o40755 << 16) | 0x10' \
  '            output.writestr(info, b"")' \
  '        else:' \
  '            info = zipfile.ZipInfo(name)' \
  '            info.external_attr = 0o100755 << 16' \
  '            output.writestr(info, item.read_bytes())' \
  '    output.comment = destination.name.encode("utf-8")' \
  'PY' \
  'elif [[ "${1:-}" == "-x" ]]; then' \
  '  archive="${@: -2:1}"' \
  '  destination="${@: -1}"' \
  '  mkdir -p "$destination"' \
  '  cp -R "$archive.payload/." "$destination/"' \
  'else' \
  '  exit 2' \
  'fi'

write_executable "$SHIM_DIR/lipo" \
  '#!/usr/bin/env bash' \
  '[[ "${1:-}" == "-archs" ]] || exit 2' \
  'echo arm64'

write_executable "$SHIM_DIR/xcrun" \
  '#!/usr/bin/env bash' \
  'printf '\''xcrun\t%s\n'\'' "$*" >>"$APC_FAKE_COMMAND_LOG"' \
  'if [[ "${1:-}" == "notarytool" ]]; then' \
  '  if [[ "${APC_FAKE_NOTARY_FAIL:-0}" == "1" ]]; then' \
  '    echo "simulated notary failure" >&2' \
  '    exit 42' \
  '  fi' \
  '  printf '\''{"id":"00000000-0000-0000-0000-000000000001","status":"Accepted"}\n'\''' \
  'fi'

write_executable "$SHIM_DIR/spctl" \
  '#!/usr/bin/env bash' \
  'printf '\''spctl\t%s\n'\'' "$*" >>"$APC_FAKE_COMMAND_LOG"' \
  'if [[ "${APC_FAKE_GATEKEEPER_FAIL:-0}" == "1" ]]; then' \
  '  echo "simulated Gatekeeper failure" >&2' \
  '  exit 43' \
  'fi'

run_pipeline() {
  PATH="$SHIM_DIR:$PATH" \
  APC_FAKE_COMMAND_LOG="$COMMAND_LOG" \
  APC_FAKE_NOTARY_FAIL="${APC_FAKE_NOTARY_FAIL:-0}" \
  APC_FAKE_GATEKEEPER_FAIL="${APC_FAKE_GATEKEEPER_FAIL:-0}" \
  APC_CODESIGN_IDENTITY='Developer ID Application: Example Company (ABCDEFGHIJ)' \
  APC_DEVELOPER_TEAM_ID='ABCDEFGHIJ' \
  APC_NOTARY_PROFILE='fake-notary-profile' \
  APC_NOTARY_KEYCHAIN="${APC_TEST_NOTARY_KEYCHAIN_VALUE-$NOTARY_KEYCHAIN}" \
  APC_RELEASE_VERSION='1.2.3' \
  APC_RELEASE_BUILD='45' \
  APC_RELEASE_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  APC_BUILD_ID='1.2.3.45.aaaaaaaaaaaa' \
    "$ROOT_DIR/script/public_distribution_pipeline.sh" \
      --app "$APP_BUNDLE" \
      --architecture arm64 \
      --submission-archive "$SUBMISSION" \
      --final-archive "$FINAL" \
      --evidence "$EVIDENCE"
}

run_pipeline >"$OUTPUT_LOG" 2>&1
[[ -f "$SUBMISSION" && -f "$FINAL" && -f "$EVIDENCE" ]]
if grep -F 'fake-notary-profile' "$OUTPUT_LOG" >/dev/null; then
  echo 'public distribution pipeline leaked the keychain profile name' >&2
  exit 1
fi

python3 - "$COMMAND_LOG" "$EVIDENCE" "$NOTARY_KEYCHAIN" <<'PY'
import json
import pathlib
import sys

commands = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()

def first(fragment):
    for index, command in enumerate(commands):
        if fragment in command:
            return index
    raise SystemExit(f"missing command fragment: {fragment}")

leaf_signs = []
for suffix in (
    "AgentPetCompanion.app/Contents/MacOS/AgentPetCompanion",
    "AgentPetCompanion.app/Contents/Resources/bin/petcore",
    "AgentPetCompanion.app/Contents/Resources/bin/petcore-cli",
):
    leaf_signs.append(
        next(
            index
            for index, command in enumerate(commands)
            if "--options runtime --timestamp " in command and command.endswith(suffix)
        )
    )
outer_sign = first("--timestamp --entitlements")
submission_zip = first("ditto\t-c -k --norsrc --keepParent")
notary = first("xcrun\tnotarytool submit")
if f"--keychain {sys.argv[3]}" not in commands[notary]:
    raise SystemExit("notarytool did not receive the explicit ephemeral Keychain")
staple = first("xcrun\tstapler staple")
gatekeeper = first("spctl\t--assess --type execute")
final_zip = next(
    index
    for index, command in enumerate(commands[submission_zip + 1 :], submission_zip + 1)
    if "ditto\t-c -k --norsrc --keepParent" in command
)
extract = first("ditto\t-x -k")

if not (
    max(leaf_signs)
    < outer_sign
    < submission_zip
    < notary
    < staple
    < gatekeeper
    < final_zip
    < extract
):
    raise SystemExit("public distribution command order is not inside-out and fail-closed")

with open(sys.argv[2], encoding="utf-8") as file:
    evidence = json.load(file)
if evidence["schema_version"] != "apc.public-distribution-evidence.v1":
    raise SystemExit("unexpected evidence schema")
if evidence["notarization"]["status"] != "Accepted":
    raise SystemExit("accepted notarization was not recorded")
if evidence["notarization"]["submission_archive_sha256"] == evidence["published_artifact"]["sha256"]:
    raise SystemExit("submission and final archive digests were conflated")
if not evidence["published_artifact"]["stapled"]:
    raise SystemExit("stapling evidence is absent")
if not evidence["published_artifact"]["gatekeeper_accepted"]:
    raise SystemExit("Gatekeeper evidence is absent")
PY

# The optional explicit Keychain path must remain optional on the macOS system
# Bash. An empty value exercises the ordinary login-Keychain profile path and
# must not add a bare or empty --keychain argument.
: >"$COMMAND_LOG"
rm -f "$SUBMISSION" "$FINAL" "$EVIDENCE"
APC_TEST_NOTARY_KEYCHAIN_VALUE='' run_pipeline >"$OUTPUT_LOG" 2>&1
notary_command="$(grep -F $'xcrun\tnotarytool submit' "$COMMAND_LOG")"
if [[ "$notary_command" == *'--keychain '* ]]; then
  echo 'notarytool received an explicit Keychain when the optional path was omitted' >&2
  exit 1
fi
[[ -f "$SUBMISSION" && -f "$FINAL" && -f "$EVIDENCE" ]]

# Notarization failure must stop before staple, Gatekeeper, final archive, or
# evidence publication. Public mode never degrades into a preview artifact.
: >"$COMMAND_LOG"
rm -f "$SUBMISSION" "$FINAL" "$EVIDENCE"
if APC_FAKE_NOTARY_FAIL=1 run_pipeline >"$OUTPUT_LOG" 2>&1; then
  echo 'simulated notarization failure unexpectedly succeeded' >&2
  exit 1
fi
grep -F $'xcrun\tnotarytool submit' "$COMMAND_LOG" >/dev/null
if grep -E $'xcrun\tstapler staple|spctl\t--assess|ditto\t-x -k' "$COMMAND_LOG" >/dev/null; then
  echo 'public distribution continued after notarization failure' >&2
  exit 1
fi
[[ ! -e "$SUBMISSION" && ! -e "$FINAL" && ! -e "$EVIDENCE" ]]

# A rejected Gatekeeper assessment also stops before the final ZIP and
# evidence. An accepted notarization alone is never reported as a release.
: >"$COMMAND_LOG"
rm -f "$SUBMISSION" "$FINAL" "$EVIDENCE"
if APC_FAKE_GATEKEEPER_FAIL=1 run_pipeline >"$OUTPUT_LOG" 2>&1; then
  echo 'simulated Gatekeeper failure unexpectedly succeeded' >&2
  exit 1
fi
grep -F $'xcrun\tstapler staple' "$COMMAND_LOG" >/dev/null
grep -F $'spctl\t--assess --type execute' "$COMMAND_LOG" >/dev/null
if grep -E $'ditto\t-x -k' "$COMMAND_LOG" >/dev/null; then
  echo 'public distribution created a final archive after Gatekeeper failure' >&2
  exit 1
fi
[[ ! -e "$SUBMISSION" && ! -e "$FINAL" && ! -e "$EVIDENCE" ]]

# Missing external provisioning is an explicit unavailable result and performs
# no signing or network-facing command.
: >"$COMMAND_LOG"
set +e
PATH="$SHIM_DIR:$PATH" \
APC_FAKE_COMMAND_LOG="$COMMAND_LOG" \
APC_RELEASE_VERSION='1.2.3' \
APC_RELEASE_BUILD='45' \
APC_RELEASE_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
APC_BUILD_ID='1.2.3.45.aaaaaaaaaaaa' \
  "$ROOT_DIR/script/public_distribution_pipeline.sh" \
    --app "$APP_BUNDLE" \
    --architecture arm64 \
    --submission-archive "$SUBMISSION" \
    --final-archive "$FINAL" \
    --evidence "$EVIDENCE" \
    >"$OUTPUT_LOG" 2>&1
missing_status=$?
set -e
[[ "$missing_status" == "78" ]]
grep -F 'supported public distribution unavailable' "$OUTPUT_LOG" >/dev/null
[[ ! -s "$COMMAND_LOG" ]]

# An explicit notary Keychain must be an absolute, regular, non-symlink file
# without line-control characters. Invalid CI provisioning fails before
# signing or a network-facing command.
assert_invalid_notary_keychain() {
  local invalid_keychain="$1"
  : >"$COMMAND_LOG"
  set +e
  PATH="$SHIM_DIR:$PATH" \
  APC_FAKE_COMMAND_LOG="$COMMAND_LOG" \
  APC_CODESIGN_IDENTITY='Developer ID Application: Example Company (ABCDEFGHIJ)' \
  APC_DEVELOPER_TEAM_ID='ABCDEFGHIJ' \
  APC_NOTARY_PROFILE='fake-notary-profile' \
  APC_NOTARY_KEYCHAIN="$invalid_keychain" \
  APC_RELEASE_VERSION='1.2.3' \
  APC_RELEASE_BUILD='45' \
  APC_RELEASE_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  APC_BUILD_ID='1.2.3.45.aaaaaaaaaaaa' \
    "$ROOT_DIR/script/public_distribution_pipeline.sh" \
      --app "$APP_BUNDLE" \
      --architecture arm64 \
      --submission-archive "$SUBMISSION" \
      --final-archive "$FINAL" \
      --evidence "$EVIDENCE" \
      >"$OUTPUT_LOG" 2>&1
  invalid_keychain_status=$?
  set -e
  [[ "$invalid_keychain_status" == "78" ]]
  grep -F 'APC_NOTARY_KEYCHAIN is invalid' "$OUTPUT_LOG" >/dev/null
  [[ ! -s "$COMMAND_LOG" ]]
}

NOTARY_KEYCHAIN_SYMLINK="$TMP_DIR/notary-symlink.keychain-db"
ln -s "$NOTARY_KEYCHAIN" "$NOTARY_KEYCHAIN_SYMLINK"
assert_invalid_notary_keychain 'relative-or-missing.keychain-db'
assert_invalid_notary_keychain "$NOTARY_KEYCHAIN_SYMLINK"
assert_invalid_notary_keychain "$NOTARY_KEYCHAIN"$'\r'

# Profile names are also bounded single-line values because they are passed
# directly to notarytool.
: >"$COMMAND_LOG"
set +e
PATH="$SHIM_DIR:$PATH" \
APC_FAKE_COMMAND_LOG="$COMMAND_LOG" \
APC_CODESIGN_IDENTITY='Developer ID Application: Example Company (ABCDEFGHIJ)' \
APC_DEVELOPER_TEAM_ID='ABCDEFGHIJ' \
APC_NOTARY_PROFILE=$'fake-notary-profile\r' \
APC_NOTARY_KEYCHAIN="$NOTARY_KEYCHAIN" \
APC_RELEASE_VERSION='1.2.3' \
APC_RELEASE_BUILD='45' \
APC_RELEASE_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
APC_BUILD_ID='1.2.3.45.aaaaaaaaaaaa' \
  "$ROOT_DIR/script/public_distribution_pipeline.sh" \
    --app "$APP_BUNDLE" \
    --architecture arm64 \
    --submission-archive "$SUBMISSION" \
    --final-archive "$FINAL" \
    --evidence "$EVIDENCE" \
    >"$OUTPUT_LOG" 2>&1
invalid_profile_status=$?
set -e
[[ "$invalid_profile_status" == "78" ]]
grep -F 'APC_NOTARY_PROFILE is not provisioned' "$OUTPUT_LOG" >/dev/null
[[ ! -s "$COMMAND_LOG" ]]

echo 'Public distribution pipeline tests ok'
