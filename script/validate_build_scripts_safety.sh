#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_ONLY=0

if [[ "${1:-}" == "--static-only" ]]; then
  STATIC_ONLY=1
  shift
fi
if (($# > 0)); then
  echo 'usage: validate_build_scripts_safety.sh [--static-only]' >&2
  exit 2
fi

"$ROOT_DIR/script/validate_source_syntax.sh"

RELEASE_SCRIPTS=(
  "$ROOT_DIR/script/build_release.sh"
  "$ROOT_DIR/script/build_app_bundle.sh"
  "$ROOT_DIR/script/public_distribution_pipeline.sh"
  "$ROOT_DIR/script/validate_distribution_signature.sh"
  "$ROOT_DIR/script/validate_macho_architectures.sh"
  "$ROOT_DIR/script/validate_release_zip.py"
  "$ROOT_DIR/script/validate_release_identity.py"
  "$ROOT_DIR/script/validate_release_artifact_metadata.py"
  "$ROOT_DIR/script/verify_release_candidate_digests.sh"
  "$ROOT_DIR/script/validate_public_release_artifacts.sh"
)

if unsafe="$(rg -n \
  '(^|[[:space:]])source[[:space:]]+.*[.]env|(^|[[:space:]])[.][[:space:]]+.*[.]env|set[[:space:]]+-x|APPLE_ID|APP_SPECIFIC_PASSWORD|NOTARY_PASSWORD|PRIVATE_KEY' \
  "${RELEASE_SCRIPTS[@]}" "$ROOT_DIR/.github/workflows/release.yml" 2>/dev/null || true)" \
  && [[ -n "$unsafe" ]]; then
  printf 'release tooling contains credential discovery, credential material, or command tracing:\n%s\n' \
    "$unsafe" >&2
  exit 1
fi
if rg -n 'security[[:space:]]+find-identity' "${RELEASE_SCRIPTS[@]}" >/dev/null; then
  echo 'release scripts must consume an explicit signing identity instead of discovering one' >&2
  exit 1
fi

# Development App assembly remains explicitly ad-hoc. Supported public
# distribution starts from --unsigned output and never mutates this local path.
rg -q 'codesign --force --sign - --timestamp=none' \
  "$ROOT_DIR/script/build_app_bundle.sh"
rg -q -- '--unsigned' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--preview' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--public' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'ARCHITECTURES=(arm64 x86_64)' "$ROOT_DIR/script/build_release.sh"
rg -q 'supported public distribution requires --arch all' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--preview and --public cannot be combined' "$ROOT_DIR/script/build_release.sh"
rg -q 'release builds require a clean worktree' "$ROOT_DIR/script/build_release.sh"
rg -q 'CHANGELOG.md must contain a frozen' "$ROOT_DIR/script/build_release.sh"
rg -q 'supported public distribution requires tag' "$ROOT_DIR/script/build_release.sh"
rg -q 'APC_BUILD_ID cannot override the commit-derived' "$ROOT_DIR/script/build_release.sh"
rg -q 'SHA256SUMS' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--configuration release' "$ROOT_DIR/script/build_release.sh"
rg -Fq -- '--arch "$architecture"' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'STAGED_ARTIFACT_DIR="$TMP_DIR/artifacts"' "$ROOT_DIR/script/build_release.sh"

# The public helper must use only externally named identity/profile values,
# hardened runtime and timestamping, inside-out signing, synchronous accepted
# notarization, stapling, Gatekeeper, and a newly created final ZIP.
rg -q 'APC_CODESIGN_IDENTITY' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'APC_DEVELOPER_TEAM_ID' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'APC_NOTARY_PROFILE' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'APC_NOTARY_KEYCHAIN' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q -- '--options runtime' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q -- '--timestamp' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'notarytool submit' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q -- '--keychain-profile' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q -- '--wait' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'stapler staple' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'stapler validate' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'spctl --assess --type execute' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'submission_archive_sha256' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'published_artifact' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'validate_release_zip.py' "$ROOT_DIR/script/public_distribution_pipeline.sh"
rg -q 'validate_macho_architectures.sh' "$ROOT_DIR/script/public_distribution_pipeline.sh"
if rg -n 'codesign .*--deep.*--sign|codesign .*--sign.*--deep' \
  "$ROOT_DIR/script/public_distribution_pipeline.sh" >/dev/null; then
  echo 'public distribution must sign explicit inner code instead of using codesign --deep' >&2
  exit 1
fi

python3 - "$ROOT_DIR/config/distribution/AgentPetCompanion.entitlements" <<'PY'
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("rb") as file:
    entitlements = plistlib.load(file)
if entitlements != {}:
    raise SystemExit("public distribution entitlements must remain the explicit empty allowlist")
PY

rg -q -- '--public-signed' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q -- '--public' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'validate_distribution_signature.sh' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'validate_macho_architectures.sh' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'stapler validate' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'spctl --assess --type execute' "$ROOT_DIR/script/validate_app_bundle.sh"
if rg -q -- '--release' "$ROOT_DIR/script/validate_app_bundle.sh"; then
  echo 'validate_app_bundle.sh must not retain the ambiguous --release alias' >&2
  exit 1
fi

rg -q 'push:' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'tags:' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'workflow_dispatch:' "$ROOT_DIR/.github/workflows/release.yml"
if rg -q 'self-hosted' "$ROOT_DIR/.github/workflows/release.yml"; then
  echo 'release workflow must use fresh GitHub-hosted native macOS runners' >&2
  exit 1
fi
rg -q 'APC_CODESIGN_IDENTITY.*vars[.]APC_CODESIGN_IDENTITY' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'APC_NOTARY_PROFILE: agent-pet-companion-ci' \
  "$ROOT_DIR/.github/workflows/release.yml"
for secret in \
  APC_DEVELOPER_ID_P12_BASE64 \
  APC_DEVELOPER_ID_P12_PASSWORD \
  APC_NOTARY_API_KEY_P8_BASE64 \
  APC_NOTARY_API_KEY_ID \
  APC_NOTARY_API_ISSUER_ID; do
  rg -Fq '${{ secrets.'"$secret"' }}' "$ROOT_DIR/.github/workflows/release.yml"
done
rg -q 'security create-keychain' "$ROOT_DIR/.github/workflows/release.yml"
rg -Fq 'security find-identity -v -p codesigning "$keychain_path"' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'notarytool store-credentials' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'APC_NOTARY_KEYCHAIN=' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'security delete-keychain' "$ROOT_DIR/.github/workflows/release.yml"
rg -Fq 'if: ${{ always() }}' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'validate_public_release_artifacts.sh' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'gh release download' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'persist-credentials: false' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'git merge-base --is-ancestor "\$commit" refs/remotes/origin/main' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'needs: \[build, validate_arm64, validate_x86_64\]' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'runs-on: macos-15$' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'runs-on: macos-15-intel$' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'verify_release_candidate_digests.sh' \
  "$ROOT_DIR/.github/workflows/release.yml"
if rg -n 'uses:[[:space:]]+[^#[:space:]]+@v[0-9]' \
  "$ROOT_DIR/.github/workflows/release.yml" >/dev/null; then
  echo 'release workflow actions must be pinned to full commit SHAs' >&2
  exit 1
fi

python3 - "$ROOT_DIR/.github/workflows/release.yml" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
build_end = source.index("\n  validate_arm64:")
arm_end = source.index("\n  validate_x86_64:")
x86_end = source.index("\n  publish:")
build = source[:build_end]
arm = source[build_end:arm_end]
x86 = source[arm_end:x86_end]

for secret in (
    "APC_DEVELOPER_ID_P12_BASE64",
    "APC_DEVELOPER_ID_P12_PASSWORD",
    "APC_NOTARY_API_KEY_P8_BASE64",
    "APC_NOTARY_API_KEY_ID",
    "APC_NOTARY_API_ISSUER_ID",
):
    reference = f"${{{{ secrets.{secret} }}}}"
    if build.count(reference) != 1 or reference in source[build_end:]:
        raise SystemExit(f"{secret} must be scoped only to the signing build job")

source_gate = build.index("run: ./script/test_all.sh")
provision = build.index("Provision ephemeral Developer ID and notarization credentials")
raw_cleanup = build.index('rm -f "$certificate_path" "$api_key_path"')
keychain_export = build.index('echo "APC_NOTARY_KEYCHAIN=$keychain_path"')
public_build = build.index("run: ./script/build_release.sh --public --arch all")
keychain_cleanup = build.index("Remove ephemeral signing material")
revalidation = build.index("Revalidate final local artifact set")
upload = build.index("Upload immutable release candidate")
if not (
    source_gate
    < provision
    < raw_cleanup
    < keychain_export
    < public_build
    < keychain_cleanup
    < revalidation
    < upload
):
    raise SystemExit("release credentials are not provisioned and removed at bounded steps")
if "if: ${{ always() }}" not in build[keychain_cleanup:revalidation]:
    raise SystemExit("ephemeral signing material cleanup must run after failure")
cleanup_block = build[keychain_cleanup:revalidation]
if "${APC_NOTARY_KEYCHAIN" in cleanup_block:
    raise SystemExit("credential cleanup must not trust a mutable environment path")
if 'keychain_path="$RUNNER_TEMP/apc-signing.keychain-db"' not in cleanup_block:
    raise SystemExit("credential cleanup must target the fixed runner-temporary Keychain")
if 'run: test "$(uname -m)" = "arm64"' not in arm:
    raise SystemExit("arm64 validation job does not prove its native architecture")
if 'run: test "$(uname -m)" = "x86_64"' not in x86:
    raise SystemExit("x86_64 validation job does not prove its native architecture")
PY

"$ROOT_DIR/script/build_app_bundle.sh" --help >/dev/null
"$ROOT_DIR/script/build_release.sh" --help >/dev/null
"$ROOT_DIR/script/public_distribution_pipeline.sh" --help >/dev/null
"$ROOT_DIR/script/validate_distribution_signature.sh" --help >/dev/null
"$ROOT_DIR/script/validate_macho_architectures.sh" --help >/dev/null
"$ROOT_DIR/script/validate_release_zip.py" --help >/dev/null
"$ROOT_DIR/script/validate_release_identity.py" --help >/dev/null
"$ROOT_DIR/script/validate_release_artifact_metadata.py" --help >/dev/null
"$ROOT_DIR/script/verify_release_candidate_digests.sh" --help >/dev/null
"$ROOT_DIR/script/validate_public_release_artifacts.sh" --help >/dev/null
"$ROOT_DIR/script/validate_app_bundle.sh" --help >/dev/null

if [[ "$STATIC_ONLY" == "0" ]]; then
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT_DIR/script/tests/test_release_distribution_contracts.py"
  "$ROOT_DIR/script/tests/test_release_shell_contracts.sh"
  "$ROOT_DIR/script/tests/test_public_distribution_pipeline.sh"
  "$ROOT_DIR/script/validate_test_isolation.sh"
fi

echo 'Build and distribution script safety ok'
