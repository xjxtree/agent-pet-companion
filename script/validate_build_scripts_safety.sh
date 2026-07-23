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
  '(^|[[:space:]])source[[:space:]]+.*[.]env|(^|[[:space:]])[.][[:space:]]+.*[.]env|security[[:space:]]+find-identity|set[[:space:]]+-x|APPLE_ID|APP_SPECIFIC_PASSWORD|NOTARY_PASSWORD|PRIVATE_KEY' \
  "${RELEASE_SCRIPTS[@]}" "$ROOT_DIR/.github/workflows/release.yml" 2>/dev/null || true)" \
  && [[ -n "$unsafe" ]]; then
  printf 'release tooling contains credential discovery, credential material, or command tracing:\n%s\n' \
    "$unsafe" >&2
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
rg -q 'self-hosted' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'APC_CODESIGN_IDENTITY.*vars[.]APC_CODESIGN_IDENTITY' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'APC_NOTARY_PROFILE.*vars[.]APC_NOTARY_PROFILE' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'validate_public_release_artifacts.sh' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'gh release download' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'persist-credentials: false' "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'git merge-base --is-ancestor "\$commit" refs/remotes/origin/main' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'needs: \[build, validate_arm64, validate_x86_64\]' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'runs-on: \[self-hosted, macOS, ARM64, apc-public-validation\]' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'runs-on: \[self-hosted, macOS, X64, apc-public-validation\]' \
  "$ROOT_DIR/.github/workflows/release.yml"
rg -q 'verify_release_candidate_digests.sh' \
  "$ROOT_DIR/.github/workflows/release.yml"
if rg -n 'uses:[[:space:]]+[^#[:space:]]+@v[0-9]' \
  "$ROOT_DIR/.github/workflows/release.yml" >/dev/null; then
  echo 'release workflow actions must be pinned to full commit SHAs' >&2
  exit 1
fi

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
