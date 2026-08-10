#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-release-shell-contracts.XXXXXX")"
SHIM_DIR="$TMP_DIR/shims"
APP="$TMP_DIR/AgentPetCompanion.app"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$SHIM_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
touch \
  "$APP/Contents/MacOS/AgentPetCompanion" \
  "$APP/Contents/Resources/bin/petcore" \
  "$APP/Contents/Resources/bin/petcore-cli" \
  "$APP/Contents/Resources/bin/unexpected-helper"

cat >"$SHIM_DIR/file" <<'SH'
#!/usr/bin/env bash
echo 'Mach-O 64-bit executable'
SH
cat >"$SHIM_DIR/lipo" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-archs" ]] || exit 2
case "${2:-}" in
  *unexpected-helper) echo "${APC_FAKE_EXTRA_ARCH:-x86_64}" ;;
  *) echo arm64 ;;
esac
SH
chmod +x "$SHIM_DIR/file" "$SHIM_DIR/lipo"

if PATH="$SHIM_DIR:$PATH" \
  "$ROOT_DIR/script/validate_macho_architectures.sh" \
    --app "$APP" \
    --architecture arm64 \
    >"$TMP_DIR/macho.log" 2>&1; then
  echo 'extra wrong-architecture Mach-O unexpectedly passed' >&2
  exit 1
fi
grep -F 'unexpected-helper' "$TMP_DIR/macho.log" >/dev/null

PATH="$SHIM_DIR:$PATH" APC_FAKE_EXTRA_ARCH=arm64 \
  "$ROOT_DIR/script/validate_macho_architectures.sh" \
    --app "$APP" \
    --architecture arm64 \
    >"$TMP_DIR/macho.log"

if "$ROOT_DIR/script/build_release.sh" >"$TMP_DIR/mode.log" 2>&1; then
  echo 'implicit GitHub Release mode unexpectedly passed' >&2
  exit 1
fi
grep -F 'official release builds require the explicit --github-release mode' \
  "$TMP_DIR/mode.log" >/dev/null

if "$ROOT_DIR/script/build_release.sh" --github-release --arch sparc \
  >"$TMP_DIR/arch.log" 2>&1; then
  echo 'unknown GitHub Release architecture unexpectedly passed' >&2
  exit 1
fi
grep -F -- '--arch must be all, arm64, or x86_64' \
  "$TMP_DIR/arch.log" >/dev/null
grep -F -- '--arch all|arm64|x86_64' < <(
  "$ROOT_DIR/script/build_release.sh" --help
) >/dev/null

if "$ROOT_DIR/script/build_release.sh" \
  --github-release --source-gate-proven --arch arm64 \
  >"$TMP_DIR/source-proof.log" 2>&1; then
  echo 'source-proven release component passed without its attestation' >&2
  exit 1
fi
grep -F -- '--source-gate-proven requires APC_INTERACTION_ATTESTATION_PATH' \
  "$TMP_DIR/source-proof.log" >/dev/null

for legacy_mode in --preview --public --public-signed; do
  if "$ROOT_DIR/script/build_release.sh" "$legacy_mode" \
    >"$TMP_DIR/build-legacy.log" 2>&1; then
    printf 'removed build mode %s unexpectedly passed\n' "$legacy_mode" >&2
    exit 1
  fi
  grep -F "unknown argument: $legacy_mode" \
    "$TMP_DIR/build-legacy.log" >/dev/null

  if "$ROOT_DIR/script/validate_app_bundle.sh" "$legacy_mode" \
    >"$TMP_DIR/validate-legacy.log" 2>&1; then
    printf 'removed validation mode %s unexpectedly passed\n' "$legacy_mode" >&2
    exit 1
  fi
  grep -F "unknown argument: $legacy_mode" \
    "$TMP_DIR/validate-legacy.log" >/dev/null
done

if "$ROOT_DIR/script/validate_app_bundle.sh" --release \
  >"$TMP_DIR/alias.log" 2>&1; then
  echo 'removed --release alias unexpectedly passed' >&2
  exit 1
fi
grep -F 'unknown argument: --release' "$TMP_DIR/alias.log" >/dev/null

cat >"$SHIM_DIR/git" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "ls-remote" ]] || exit 2
printf '%s\trefs/tags/%s\n' "$APC_FAKE_TAG_OBJECT" "$APC_FAKE_TAG"
if [[ -n "${APC_FAKE_TAG_COMMIT:-}" ]]; then
  printf '%s\trefs/tags/%s^{}\n' "$APC_FAKE_TAG_COMMIT" "$APC_FAKE_TAG"
fi
SH
chmod +x "$SHIM_DIR/git"

EXPECTED_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PATH="$SHIM_DIR:$PATH" \
  APC_FAKE_TAG=v1.2.3 \
  APC_FAKE_TAG_OBJECT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  APC_FAKE_TAG_COMMIT="$EXPECTED_COMMIT" \
  "$ROOT_DIR/script/verify_remote_release_tag.sh" \
    --tag v1.2.3 \
    --commit "$EXPECTED_COMMIT" \
    >"$TMP_DIR/tag.log"

if PATH="$SHIM_DIR:$PATH" \
  APC_FAKE_TAG=v1.2.3 \
  APC_FAKE_TAG_OBJECT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  "$ROOT_DIR/script/verify_remote_release_tag.sh" \
    --tag v1.2.3 \
    --commit "$EXPECTED_COMMIT" \
    >"$TMP_DIR/tag-moved.log" 2>&1; then
  echo 'moved remote release tag unexpectedly passed' >&2
  exit 1
fi
grep -F 'no longer targets the protected candidate commit' \
  "$TMP_DIR/tag-moved.log" >/dev/null

DIGEST_DIR="$TMP_DIR/digest-candidate"
mkdir -p "$DIGEST_DIR"
printf 'arm\n' >"$DIGEST_DIR/AgentPetCompanion-1.2.3-macos-arm64.zip"
printf 'intel\n' >"$DIGEST_DIR/AgentPetCompanion-1.2.3-macos-x86_64.zip"
printf 'checksums\n' >"$DIGEST_DIR/AgentPetCompanion-1.2.3-SHA256SUMS.txt"
digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}
DIGEST_ARGS=(
  --directory "$DIGEST_DIR"
  --version 1.2.3
  --arm64-zip-sha256 "$(digest "$DIGEST_DIR/AgentPetCompanion-1.2.3-macos-arm64.zip")"
  --x86_64-zip-sha256 "$(digest "$DIGEST_DIR/AgentPetCompanion-1.2.3-macos-x86_64.zip")"
  --checksum-sha256 "$(digest "$DIGEST_DIR/AgentPetCompanion-1.2.3-SHA256SUMS.txt")"
)
"$ROOT_DIR/script/verify_release_candidate_digests.sh" "${DIGEST_ARGS[@]}" \
  >"$TMP_DIR/digest.log"
: >"$DIGEST_DIR/unexpected.txt"
if "$ROOT_DIR/script/verify_release_candidate_digests.sh" "${DIGEST_ARGS[@]}" \
  >"$TMP_DIR/digest-extra.log" 2>&1; then
  echo 'trusted digest verifier accepted an extra candidate file' >&2
  exit 1
fi
grep -F 'must contain exactly three files' "$TMP_DIR/digest-extra.log" >/dev/null

echo 'Release shell contract tests ok'
