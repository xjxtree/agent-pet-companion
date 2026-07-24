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
  "$ROOT_DIR/script/validate_app_bundle.sh"
  "$ROOT_DIR/script/validate_macho_architectures.sh"
  "$ROOT_DIR/script/validate_release_zip.py"
  "$ROOT_DIR/script/validate_release_identity.py"
  "$ROOT_DIR/script/validate_release_artifact_metadata.py"
  "$ROOT_DIR/script/validate_github_release_api.py"
  "$ROOT_DIR/script/validate_codex_plugin_version.py"
  "$ROOT_DIR/script/verify_release_candidate_digests.sh"
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
)
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

for obsolete_path in \
  "$ROOT_DIR/config/distribution/AgentPetCompanion.entitlements" \
  "$ROOT_DIR/script/public_distribution_pipeline.sh" \
  "$ROOT_DIR/script/validate_distribution_signature.sh" \
  "$ROOT_DIR/script/validate_public_release_artifacts.sh" \
  "$ROOT_DIR/script/tests/test_public_distribution_pipeline.sh"; do
  if [[ -e "$obsolete_path" || -L "$obsolete_path" ]]; then
    printf 'obsolete Developer ID distribution path still exists: %s\n' \
      "$obsolete_path" >&2
    exit 1
  fi
done

if unsafe="$(rg -n \
  '(^|[[:space:]])source[[:space:]]+.*[.]env|(^|[[:space:]])[.][[:space:]]+.*[.]env|set[[:space:]]+-x|APPLE_ID|APP_SPECIFIC_PASSWORD|NOTARY_PASSWORD|PRIVATE_KEY|APC_CODESIGN_IDENTITY|APC_DEVELOPER_TEAM_ID|APC_NOTARY_|P12_BASE64' \
  "${RELEASE_SCRIPTS[@]}" "$WORKFLOW" 2>/dev/null || true)" \
  && [[ -n "$unsafe" ]]; then
  printf 'GitHub Release tooling contains credential discovery, credential material, or command tracing:\n%s\n' \
    "$unsafe" >&2
  exit 1
fi

if forbidden_workflow="$(rg -n \
  '^[[:space:]]*environment:|[$][{][{][[:space:]]*(vars|secrets)[.]|Developer ID Application|notarytool|stapler|spctl|security[[:space:]]+(create-keychain|delete-keychain|find-identity)' \
  "$WORKFLOW" || true)" \
  && [[ -n "$forbidden_workflow" ]]; then
  printf 'GitHub Release workflow must not use signing environments, credentials, or Apple trust tooling:\n%s\n' \
    "$forbidden_workflow" >&2
  exit 1
fi

if legacy_mode="$(rg -n -- '--(preview|public|public-signed)([=[:space:]]|$)' \
  "$ROOT_DIR/script/build_release.sh" "$ROOT_DIR/script/validate_app_bundle.sh" || true)" \
  && [[ -n "$legacy_mode" ]]; then
  printf 'removed release modes remain in active tooling:\n%s\n' "$legacy_mode" >&2
  exit 1
fi

# Local and GitHub Release Apps are ad-hoc signed. The official path is
# explicit, dual-architecture, protected-source-bound, and three-file-only.
rg -Fq 'codesign --force --sign - --timestamp=none' \
  "$ROOT_DIR/script/build_app_bundle.sh"
rg -q -- '--github-release' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'ARCHITECTURES=(arm64 x86_64)' "$ROOT_DIR/script/build_release.sh"
rg -q 'official release builds require the explicit --github-release mode' \
  "$ROOT_DIR/script/build_release.sh"
rg -q 'GitHub Release distribution requires --arch all' \
  "$ROOT_DIR/script/build_release.sh"
rg -q 'release builds require a clean worktree' "$ROOT_DIR/script/build_release.sh"
rg -q 'CHANGELOG.md must contain a frozen' "$ROOT_DIR/script/build_release.sh"
rg -q 'GitHub Release distribution requires tag' "$ROOT_DIR/script/build_release.sh"
rg -q 'full-commit-derived release build identity' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'BUILD_ID="${RELEASE_VERSION}.${RELEASE_BUILD}.${RELEASE_COMMIT}"' \
  "$ROOT_DIR/script/build_release.sh"
rg -q 'SHA256SUMS' "$ROOT_DIR/script/build_release.sh"
rg -q -- '--configuration release' "$ROOT_DIR/script/build_release.sh"
rg -Fq -- '--arch "$architecture"' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'STAGED_ARTIFACT_DIR="$TMP_DIR/artifacts"' \
  "$ROOT_DIR/script/build_release.sh"
rg -q 'validate_github_release_artifacts.sh' "$ROOT_DIR/script/build_release.sh"
if rg -q -- '--unsigned' "$ROOT_DIR/script/build_release.sh"; then
  echo 'GitHub Release build must not stage an unsigned App' >&2
  exit 1
fi

rg -q -- '--github-release' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'validate_github_release_signature_before_runtime' \
  "$ROOT_DIR/script/validate_app_bundle.sh"
rg -Fq "grep -Fx 'Signature=adhoc'" "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'validate_macho_architectures.sh' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'SOURCE_CODEX_PLUGIN_MANIFEST' "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'packaged PetCore emitted a stale Codex plugin manifest' \
  "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'packaged PetCore emitted a stale Studio Skill' \
  "$ROOT_DIR/script/validate_app_bundle.sh"
rg -q 'packaged PetCore emitted stale Maker Skill file' \
  "$ROOT_DIR/script/validate_app_bundle.sh"
if rg -q -- '--release([=[:space:]]|$)' "$ROOT_DIR/script/validate_app_bundle.sh"; then
  echo 'validate_app_bundle.sh must not retain the ambiguous --release alias' >&2
  exit 1
fi

rg -q 'artifact inventory must contain exactly three files' \
  "$ROOT_DIR/script/validate_release_artifact_metadata.py"
rg -q 'checksum inventory must contain exactly two archive lines' \
  "$ROOT_DIR/script/validate_release_artifact_metadata.py"
rg -Fq 'expected_build_id = f"{version}.{build}.{commit}"' \
  "$ROOT_DIR/script/validate_release_identity.py"
rg -q -- '--commit must be a full lowercase Git commit' \
  "$ROOT_DIR/script/validate_release_identity.py"
rg -q -- '--commit must be a full lowercase Git commit' \
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
rg -q 'for architecture in arm64 x86_64' \
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
rg -q 'validate_release_zip.py' \
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
rg -q 'validate_release_identity.py' \
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
rg -q 'validate_app_bundle.sh' \
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
rg -q -- '--github-release' \
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"

for digest_option in \
  --arm64-zip-sha256 \
  --x86_64-zip-sha256 \
  --checksum-sha256; do
  rg -q -- "$digest_option" "$ROOT_DIR/script/verify_release_candidate_digests.sh"
done
if rg -q -- '--(arm64|x86_64)-evidence-sha256' \
  "$ROOT_DIR/script/verify_release_candidate_digests.sh"; then
  echo 'trusted digest contract must not retain notarization evidence files' >&2
  exit 1
fi

rg -q 'push:' "$WORKFLOW"
rg -q 'tags:' "$WORKFLOW"
rg -q 'workflow_dispatch:' "$WORKFLOW"
if rg -q 'self-hosted' "$WORKFLOW"; then
  echo 'release workflow must use fresh GitHub-hosted native macOS runners' >&2
  exit 1
fi
rg -Fq 'run: ./script/build_release.sh --github-release --arch all' "$WORKFLOW"
rg -q 'validate_github_release_artifacts.sh' "$WORKFLOW"
rg -q 'gh release download' "$WORKFLOW"
rg -q 'persist-credentials: false' "$WORKFLOW"
rg -q 'git merge-base --is-ancestor "\$commit" refs/remotes/origin/main' \
  "$WORKFLOW"
rg -q 'needs: \[build, validate_arm64, validate_x86_64\]' "$WORKFLOW"
rg -q 'runs-on: macos-15$' "$WORKFLOW"
rg -q 'runs-on: macos-15-intel$' "$WORKFLOW"
rg -q 'verify_release_candidate_digests.sh' "$WORKFLOW"
rg -q 'validate_github_release_api.py' "$WORKFLOW"
rg -q 'validate_codex_plugin_version.py' "$WORKFLOW"
rg -Fq 'gh release edit "$RELEASE_TAG" --draft=false --latest' "$WORKFLOW"
rg -Fq '"repos/$GITHUB_REPOSITORY/releases/latest"' "$WORKFLOW"
if rg -q 'published_immutable|value[.]get[(]"immutable"|immutable-releases' "$WORKFLOW"; then
  echo 'release workflow must not require GitHub Immutable Releases' >&2
  exit 1
fi
rg -q 'Update in three steps / 三步更新' "$WORKFLOW"
rg -q 'Your pets, settings, history, and active work stay on this Mac and are preserved[.]' \
  "$WORKFLOW"
rg -q '你的宠物、设置、历史和正在进行的工作会留在这台 Mac 上并保持不变。' \
  "$WORKFLOW"
rg -q 'move the new App to Applications, and choose Replace' "$WORKFLOW"
rg -q '将新版移入“应用程序”，并选择“替换”' "$WORKFLOW"
rg -q 'Control-click' "$WORKFLOW"
rg -q 'Open Anyway' "$WORKFLOW"
rg -q 'ad-hoc signed' "$WORKFLOW"
if rg -n 'uses:[[:space:]]+[^#[:space:]]+@v[0-9]' "$WORKFLOW" >/dev/null; then
  echo 'release workflow actions must be pinned to full commit SHAs' >&2
  exit 1
fi

python3 - "$WORKFLOW" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
build_end = source.index("\n  validate_arm64:")
arm_end = source.index("\n  validate_x86_64:")
x86_end = source.index("\n  publish:")
build = source[:build_end]
arm = source[build_end:arm_end]
x86 = source[arm_end:x86_end]
publish = source[x86_end:]

if source.count("contents: write") != 1 or "contents: write" not in publish:
    raise SystemExit("only the publish job may have contents: write")
if any("contents: write" in job for job in (build, arm, x86)):
    raise SystemExit("build and validation jobs must remain read-only")
if source.count("ref: ${{ needs.build.outputs.commit }}") != 3:
    raise SystemExit("every downstream job must check out the proven commit")
if source.count("./script/verify_remote_release_tag.sh") < 3:
    raise SystemExit("remote tag identity must be rechecked before and after publication")

source_gate = build.index("run: ./script/test_all.sh")
official_build = build.index(
    "run: ./script/build_release.sh --github-release --arch all"
)
local_revalidation = build.index("Revalidate final local artifact set")
digest_emission = build.index("Emit trusted digest for every candidate file")
upload = build.index("Upload release candidate")
if not source_gate < official_build < local_revalidation < digest_emission < upload:
    raise SystemExit("release build, revalidation, digest, and upload order is unsafe")

if 'run: test "$(uname -m)" = "arm64"' not in arm:
    raise SystemExit("arm64 validation job does not prove its native architecture")
if 'run: test "$(uname -m)" = "x86_64"' not in x86:
    raise SystemExit("x86_64 validation job does not prove its native architecture")

download = publish.index('gh release download "$RELEASE_TAG"')
digest_recheck = publish.index(
    "./script/verify_release_candidate_digests.sh", download
)
package_recheck = publish.index(
    "./script/validate_github_release_artifacts.sh", digest_recheck
)
tag_recheck = publish.index(
    "./script/verify_remote_release_tag.sh", package_recheck
)
go_live = publish.index(
    'gh release edit "$RELEASE_TAG" --draft=false', tag_recheck
)
if not download < digest_recheck < package_recheck < tag_recheck < go_live:
    raise SystemExit("downloaded GitHub Release candidate is not revalidated before publish")

uses = re.findall(r"(?m)^\s*-\s+uses:\s+([^#\s]+)", source)
if not uses or any(
    re.fullmatch(r"[^@]+@[0-9a-f]{40}", action) is None for action in uses
):
    raise SystemExit("every workflow action must be pinned to a full commit SHA")
PY

"$ROOT_DIR/script/build_app_bundle.sh" --help >/dev/null
"$ROOT_DIR/script/build_release.sh" --help >/dev/null
"$ROOT_DIR/script/validate_app_bundle.sh" --help >/dev/null
"$ROOT_DIR/script/validate_macho_architectures.sh" --help >/dev/null
"$ROOT_DIR/script/validate_release_zip.py" --help >/dev/null
"$ROOT_DIR/script/validate_release_identity.py" --help >/dev/null
"$ROOT_DIR/script/validate_release_artifact_metadata.py" --help >/dev/null
"$ROOT_DIR/script/validate_github_release_api.py" --help >/dev/null
"$ROOT_DIR/script/validate_codex_plugin_version.py" --help >/dev/null
"$ROOT_DIR/script/verify_release_candidate_digests.sh" --help >/dev/null
"$ROOT_DIR/script/validate_github_release_artifacts.sh" --help >/dev/null

if [[ "$STATIC_ONLY" == "0" ]]; then
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT_DIR/script/tests/test_release_distribution_contracts.py"
  "$ROOT_DIR/script/tests/test_release_shell_contracts.sh"
  "$ROOT_DIR/script/validate_test_isolation.sh"
fi

echo 'Build and GitHub Release script safety ok'
