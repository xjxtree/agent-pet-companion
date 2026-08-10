#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_ONLY=0
SKIP_SOURCE_SYNTAX=0

while (($# > 0)); do
  case "$1" in
    --static-only)
      STATIC_ONLY=1
      shift
      ;;
    --skip-source-syntax)
      SKIP_SOURCE_SYNTAX=1
      shift
      ;;
    -h|--help)
      echo 'usage: validate_build_scripts_safety.sh [--static-only] [--skip-source-syntax]'
      exit 0
      ;;
    *)
      echo 'usage: validate_build_scripts_safety.sh [--static-only] [--skip-source-syntax]' >&2
      exit 2
      ;;
  esac
done

if [[ "$SKIP_SOURCE_SYNTAX" == "0" ]]; then
  "$ROOT_DIR/script/validate_source_syntax.sh"
fi

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
  "$ROOT_DIR/script/validate_overlay_interaction.sh"
  "$ROOT_DIR/script/prepare_interaction_attestation.sh"
  "$ROOT_DIR/script/verify_release_candidate_digests.sh"
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
)
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
TEST_ALL="$ROOT_DIR/script/test_all.sh"
OVERLAY_INTERACTION_VALIDATOR="$ROOT_DIR/script/validate_overlay_interaction.sh"
PRE_PUSH_VALIDATOR="$ROOT_DIR/script/validate_pre_push.sh"
LOCALIZATION_VALIDATOR="$ROOT_DIR/script/validate_localizations.py"

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

# Local pre-push and ordinary CI share one path classifier. CI may assemble a
# full development bundle only when that classifier marks runtime inputs.
rg -Fq './script/validation_scope.py' "$CI_WORKFLOW"
rg -Fq './script/validate_pre_push.sh' "$CI_WORKFLOW"
rg -Fq -- '--ci' "$CI_WORKFLOW"
rg -Fq "if: steps.validation_scope.outputs.bundle == '1'" "$CI_WORKFLOW"
rg -Fq "steps.validation_scope.outputs.producer == '1'" "$CI_WORKFLOW"
rg -Fq 'Pillow==11.3.0' "$CI_WORKFLOW"
rg -Fq 'features.check("webp_anim")' "$CI_WORKFLOW"
rg -Fq -- '--validation full' "$CI_WORKFLOW"
if rg -q 'APC_VALIDATE_HOST_UI:[[:space:]]+"1"|computer-use|Computer Use.*run:' \
  "$CI_WORKFLOW"; then
  echo 'ordinary CI must not auto-enable live UI or Computer Use' >&2
  exit 1
fi

if legacy_mode="$(rg -n -- '--(preview|public|public-signed)([=[:space:]]|$)' \
  "$ROOT_DIR/script/build_release.sh" "$ROOT_DIR/script/validate_app_bundle.sh" || true)" \
  && [[ -n "$legacy_mode" ]]; then
  printf 'removed release modes remain in active tooling:\n%s\n' "$legacy_mode" >&2
  exit 1
fi

# The official release source gate must execute the deterministic native
# interaction suites, not infer their result from a runtime-produced boolean.
rg -Fq '"$ROOT_DIR/script/prepare_interaction_attestation.sh"' "$TEST_ALL"
rg -Fq '"$ROOT_DIR/script/validate_overlay_interaction.sh"' \
  "$ROOT_DIR/script/prepare_interaction_attestation.sh"
for interaction_suite in \
  OverlayPlacementAuthorityTests \
  AppStoreOverlaySnapshotTests \
  OverlayGeometryTests \
  OverlayDisplayWidthTests \
  OverlayInteractionTelemetryTests; do
  rg -Fq "$interaction_suite" "$OVERLAY_INTERACTION_VALIDATOR"
done
rg -Fq '"$ROOT_DIR/script/validate_swift_tests.sh" --scope "$SWIFT_SCOPE"' \
  "$OVERLAY_INTERACTION_VALIDATOR"
rg -Fq 'swift "${ARGS[@]}"' "$ROOT_DIR/script/validate_swift_tests.sh"
rg -Fq -- '--attestation-out' "$OVERLAY_INTERACTION_VALIDATOR"
rg -Fq 'interaction-contract-files.txt' "$OVERLAY_INTERACTION_VALIDATOR"
rg -Fq 'petpack verify-production-interaction' \
  "$ROOT_DIR/script/validate_app_bundle.sh"
rg -Fq 'interaction-attestation.json' "$ROOT_DIR/script/build_app_bundle.sh"
rg -Fq -- '--interaction-attestation "$APC_INTERACTION_ATTESTATION_PATH"' "$TEST_ALL"
rg -Fq 'validate_interaction_attestation.py' "$ROOT_DIR/script/build_app_bundle.sh"
rg -Fq 'validate_interaction_attestation.py' "$ROOT_DIR/script/validate_overlay_offline.sh"
rg -Fq 'validate_localizations.py' "$TEST_ALL"
rg -Fq 'validation_fingerprint.py' "$TEST_ALL"
rg -Fq -- '--resume' "$TEST_ALL"
rg -Fq 'test_all.sh" --resume' "$PRE_PUSH_VALIDATOR"
if rg -Fq 'test_all.sh --resume' "$WORKFLOW"; then
  echo 'GitHub Release must not consume local validation checkpoints' >&2
  exit 1
fi
python3 - "$TEST_ALL" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
localization = source.index('"localization-parity"')
rust_tests = source.index('"rust-tests"')
if localization >= rust_tests:
    raise SystemExit("localization parity must run before expensive Rust tests")
PY
rg -Fq 'Run source, complete Swift interaction, integration, and stress gates' \
  "$WORKFLOW"

# Local and GitHub Release Apps are ad-hoc signed. The official path is
# explicit, dual-architecture, protected-source-bound, and three-file-only.
rg -Fq 'codesign --force --sign - --timestamp=none' \
  "$ROOT_DIR/script/build_app_bundle.sh"
rg -q -- '--github-release' "$ROOT_DIR/script/build_release.sh"
rg -Fq 'ARCHITECTURES=(arm64 x86_64)' "$ROOT_DIR/script/build_release.sh"
rg -q 'official release builds require the explicit --github-release mode' \
  "$ROOT_DIR/script/build_release.sh"
rg -Fq -- '--arch must be all, arm64, or x86_64' \
  "$ROOT_DIR/script/build_release.sh"
rg -q 'release builds require a clean worktree' "$ROOT_DIR/script/build_release.sh"
rg -q 'CHANGELOG.md must contain a frozen' "$ROOT_DIR/script/build_release.sh"
rg -q 'GitHub Release distribution requires tag' "$ROOT_DIR/script/build_release.sh"
rg -q 'GitHub Release distribution requires a previous version tag baseline' \
  "$ROOT_DIR/script/build_release.sh"
rg -Fq 'PREVIOUS_RELEASE_TAG="${APC_PREVIOUS_RELEASE_TAG:-}"' \
  "$ROOT_DIR/script/build_release.sh"
rg -Fq '"$ROOT_DIR/script/validate_codex_plugin_version.py"' \
  "$ROOT_DIR/script/build_release.sh"
rg -Fq -- '--base-ref "$PREVIOUS_RELEASE_TAG"' \
  "$ROOT_DIR/script/build_release.sh"
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
rg -Fq 'for architecture in "${ARCHITECTURES[@]}"' \
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
rg -q 'must contain exactly three files' \
  "$ROOT_DIR/script/verify_release_candidate_digests.sh"
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
rg -Fq 'architecture: [arm64, x86_64]' "$WORKFLOW"
rg -Fq 'run: ./script/build_release.sh --github-release --source-gate-proven --arch "${{ matrix.architecture }}"' \
  "$WORKFLOW"
rg -q 'validate_github_release_artifacts.sh' "$WORKFLOW"
rg -q 'gh release download' "$WORKFLOW"
rg -q 'persist-credentials: false' "$WORKFLOW"
rg -q 'git merge-base --is-ancestor "\$commit" refs/remotes/origin/main' \
  "$WORKFLOW"
rg -q 'needs: \[prepare, assemble, validate_arm64, validate_x86_64\]' "$WORKFLOW"
rg -q 'runs-on: macos-15$' "$WORKFLOW"
rg -q 'runs-on: macos-15-intel$' "$WORKFLOW"
rg -q 'verify_release_candidate_digests.sh' "$WORKFLOW"
rg -q 'validate_github_release_api.py' "$WORKFLOW"
rg -q 'validate_codex_plugin_version.py' "$WORKFLOW"
rg -Fq 'APC_PREVIOUS_RELEASE_TAG: ${{ needs.prepare.outputs.previous_tag }}' \
  "$WORKFLOW"
rg -q 'VERSIONED_SKILLS' "$ROOT_DIR/script/validate_codex_plugin_version.py"
rg -q 'HOOKS_VERSION_PLACEHOLDER' "$ROOT_DIR/script/validate_codex_plugin_version.py"
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
build_start = source.index("\n  build_archives:")
assemble_start = source.index("\n  assemble:")
arm_start = source.index("\n  validate_arm64:")
x86_start = source.index("\n  validate_x86_64:")
publish_start = source.index("\n  publish:")
prepare = source[:build_start]
build = source[build_start:assemble_start]
assemble = source[assemble_start:arm_start]
arm = source[arm_start:x86_start]
x86 = source[x86_start:publish_start]
publish = source[publish_start:]

if source.count("contents: write") != 1 or "contents: write" not in publish:
    raise SystemExit("only the publish job may have contents: write")
if any("contents: write" in job for job in (prepare, build, assemble, arm, x86)):
    raise SystemExit("build and validation jobs must remain read-only")
if source.count("ref: ${{ needs.prepare.outputs.commit }}") < 5:
    raise SystemExit("every downstream job must check out the proven commit")
if source.count("./script/verify_remote_release_tag.sh") < 3:
    raise SystemExit("remote tag identity must be rechecked before and after publication")

source_gate = prepare.index("./script/test_all.sh --source-only --include-stress")
proof_upload = prepare.index("Upload source-bound interaction proof", source_gate)
official_build = build.index(
    'run: ./script/build_release.sh --github-release --source-gate-proven --arch "${{ matrix.architecture }}"'
)
metadata = assemble.index("validate_release_artifact_metadata.py")
digest_emission = assemble.index("Emit trusted digest for every candidate file", metadata)
upload = assemble.index("Upload exact release candidate", digest_emission)
if not source_gate < proof_upload or not metadata < digest_emission < upload:
    raise SystemExit("release source proof, assembly, digest, and upload order is unsafe")
if "architecture: [arm64, x86_64]" not in build or official_build < 0:
    raise SystemExit("official architectures must build as a parallel matrix")

if 'run: test "$(uname -m)" = "arm64"' not in arm:
    raise SystemExit("arm64 validation job does not prove its native architecture")
if 'run: test "$(uname -m)" = "x86_64"' not in x86:
    raise SystemExit("x86_64 validation job does not prove its native architecture")

download = publish.index('gh release download "$RELEASE_TAG"')
digest_recheck = publish.index(
    "./script/verify_release_candidate_digests.sh", download
)
tag_recheck = publish.index(
    "./script/verify_remote_release_tag.sh", digest_recheck
)
go_live = publish.index(
    'gh release edit "$RELEASE_TAG" --draft=false', tag_recheck
)
if not download < digest_recheck < tag_recheck < go_live:
    raise SystemExit("downloaded GitHub Release bytes are not verified before publish")
if "validate_github_release_artifacts.sh" in publish:
    raise SystemExit("publish must not repeat native packaged execution")
if arm.count("validate_github_release_artifacts.sh") != 1:
    raise SystemExit("arm64 job must run one native packaged validation")
if x86.count("validate_github_release_artifacts.sh") != 1:
    raise SystemExit("x86_64 job must run one native packaged validation")

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
"$ROOT_DIR/script/validate_pre_push.sh" --help >/dev/null
"$ROOT_DIR/script/test_all.sh" --help >/dev/null
"$ROOT_DIR/script/validate_overlay_offline.sh" --help >/dev/null
"$ROOT_DIR/script/validate_localizations.py" --help >/dev/null
"$ROOT_DIR/script/validation_fingerprint.py" --help >/dev/null
"$ROOT_DIR/script/validate_interaction_attestation.py" --help >/dev/null
"$ROOT_DIR/script/validation_scope.py" --help >/dev/null

PYTHONDONTWRITEBYTECODE=1 \
  python3 "$ROOT_DIR/script/tests/test_validation_tooling.py"

if [[ "$STATIC_ONLY" == "0" ]]; then
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT_DIR/script/tests/test_release_distribution_contracts.py"
  "$ROOT_DIR/script/tests/test_release_shell_contracts.sh"
  "$ROOT_DIR/script/validate_test_isolation.sh"
fi

echo 'Build and GitHub Release script safety ok'
