#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_ONLY=0
SKIP_SOURCE_SYNTAX=0

# GitHub runner images do not guarantee ripgrep. Keep this validator portable
# without adding package-manager setup to every Linux and macOS contract job.
if ! command -v rg >/dev/null 2>&1; then
  rg() {
    local mode="${1:-}"
    shift || true
    case "$mode" in
      -Fq)
        grep -Fq "$@"
        ;;
      -q)
        grep -Eq "$@"
        ;;
      -n)
        grep -En "$@"
        ;;
      -c)
        grep -Ec "$@"
        ;;
      *)
        printf 'unsupported portable search mode: %s\n' "$mode" >&2
        return 2
        ;;
    esac
  }
fi

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
  "$ROOT_DIR/script/validate_macos_build_contract.py"
  "$ROOT_DIR/script/validate_release_zip.py"
  "$ROOT_DIR/script/validate_release_identity.py"
  "$ROOT_DIR/script/validate_release_artifact_metadata.py"
  "$ROOT_DIR/script/validate_github_release_api.py"
  "$ROOT_DIR/script/validate_codex_plugin_version.py"
  "$ROOT_DIR/script/ci_proof_promotion.py"
  "$ROOT_DIR/script/release_source_proof.py"
  "$ROOT_DIR/script/resolve_release_source_proof.py"
  "$ROOT_DIR/script/validate_rust_test_shards.py"
  "$ROOT_DIR/script/configure_main_branch_ruleset.py"
  "$ROOT_DIR/script/development_flow.py"
  "$ROOT_DIR/script/development_domains.py"
  "$ROOT_DIR/script/engineering_metrics.py"
  "$ROOT_DIR/script/changelog_fragments.py"
  "$ROOT_DIR/script/swift_build_artifact.py"
  "$ROOT_DIR/script/validate_local_tests.py"
  "$ROOT_DIR/script/validate_overlay_interaction.sh"
  "$ROOT_DIR/script/prepare_interaction_attestation.sh"
  "$ROOT_DIR/script/verify_release_candidate_digests.sh"
  "$ROOT_DIR/script/validate_github_release_artifacts.sh"
)
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
AUTO_MERGE_WORKFLOW="$ROOT_DIR/.github/workflows/auto-merge.yml"
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

# Local pre-push and CI share only the path classifier. The local gate stays
# compile-only, while CI owns complete tests, source proof, and App assembly.
rg -Fq './script/validation_scope.py' "$CI_WORKFLOW"
rg -Fq './script/development_flow.py ci-context' "$CI_WORKFLOW"
rg -Fq './script/changelog_fragments.py policy' "$CI_WORKFLOW"
rg -Fq -- '--release-preparation "${{ needs.scope.outputs.release_preparation }}"' "$CI_WORKFLOW"
rg -Fq 'needs.scope.outputs.actionable' "$CI_WORKFLOW"
rg -Fq "needs.scope.outputs.full_candidate == '1'" "$CI_WORKFLOW"
rg -Fq "needs.scope.outputs.release_source == '1'" "$CI_WORKFLOW"
if rg -Fq './script/validate_pre_push.sh' "$CI_WORKFLOW"; then
  echo 'CI must not couple its authoritative gates to the local fast gate' >&2
  exit 1
fi
rg -Fq "needs.scope.outputs.bundle == '1'" "$CI_WORKFLOW"
rg -Fq "needs.scope.outputs.producer == '1'" "$CI_WORKFLOW"
rg -Fq 'Pillow==11.3.0' "$CI_WORKFLOW"
rg -Fq 'features.check("webp_anim")' "$CI_WORKFLOW"
rg -Fq 'pet_bytebudcodex|pet_pinklace|pet_xingwutuanzi' "$CI_WORKFLOW"
if rg -Fq "if: steps.validation_scope.outputs.docs_only != '1'" "$CI_WORKFLOW"; then
  echo 'script-only CI changes must not restore Rust/Swift build caches' >&2
  exit 1
fi
rg -Fq -- '--validation full' "$CI_WORKFLOW"
rg -Fq -- '--interaction-attestation' "$CI_WORKFLOW"
rg -Fq './script/validate_rust_test_shards.py' "$CI_WORKFLOW"
rg -Fq -- '--shard "${{ matrix.shard }}"' "$CI_WORKFLOW"
rg -Fq 'shard: [core, integration-a, integration-b, integration-c, integration-d]' "$CI_WORKFLOW"
rg -Fq 'name: Verify every Rust test shard' "$CI_WORKFLOW"
rg -Fq 'ci-rust-shard-proof-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.shard }}' "$CI_WORKFLOW"
rg -Fq 'validate_rust_test_shards.py --verify-completion-dir' "$CI_WORKFLOW"
rg -Fq 'RUST_TEST_PROOF_RESULT: ${{ needs.rust_test_proof.result }}' "$CI_WORKFLOW"
rg -Fq 'name: Required CI' "$CI_WORKFLOW"
rg -Fq 'release-source-proof-${{ github.sha }}' "$CI_WORKFLOW"
rg -Fq 'ci-candidate-proof-${{ github.sha }}' "$CI_WORKFLOW"
rg -Fq './script/ci_proof_promotion.py create-candidate' "$CI_WORKFLOW"
rg -Fq './script/ci_proof_promotion.py promote' "$CI_WORKFLOW"
rg -Fq "needs.promotion.outputs.promoted != '1'" "$CI_WORKFLOW"
rg -Fq './script/release_source_proof.py create' "$CI_WORKFLOW"
rg -Fq './script/validate_event_storm.sh' "$CI_WORKFLOW"
rg -Fq 'runs-on: macos-26' "$CI_WORKFLOW"
rg -Fq 'runs-on: ubuntu-24.04' "$CI_WORKFLOW"
rg -Fq './script/validate_macos_build_contract.py toolchain' "$CI_WORKFLOW"
rg -Fq 'cargo test -p petcore --test integration_c process_runner:: --locked' "$CI_WORKFLOW"
rg -Fq 'cargo test -p petcore-cli --test integration petpack_build_metadata:: --locked' "$CI_WORKFLOW"
rg -Fq 'cargo test -p petcore --test integration_d daemon_lifecycle:: --locked' "$CI_WORKFLOW"
rg -Fq 'ci-swift-debug-products-${{ github.sha }}' "$CI_WORKFLOW"
rg -Fq './script/swift_build_artifact.py restore' "$CI_WORKFLOW"
rg -Fq 'Restore or write the one strict Swift debug cache' "$CI_WORKFLOW"
rg -Fq 'swift-strict-debug-v2-' "$CI_WORKFLOW"
rg -Fq 'steps.swift_toolchain_identity.outputs.digest' "$CI_WORKFLOW"
rg -Fq 'SWIFT_STRICT_CACHE_HIT: ${{ needs.swift_interaction.outputs.cache_hit }}' "$CI_WORKFLOW"
rg -Fq -- '--cache-observation "swift-strict=' "$CI_WORKFLOW"
rg -Fq -- '--pull-request-json' "$CI_WORKFLOW"
rg -Fq 'pull-request-timeline.json' "$CI_WORKFLOW"
rg -Fq 'gh api --paginate --slurp' "$CI_WORKFLOW"
rg -Fq './script/engineering_metrics.py' "$CI_WORKFLOW"
rg -Fq 'Rebind source interaction proof to the development build identity' "$CI_WORKFLOW"
rg -Fq -- '--proof-in "$RUNNER_TEMP/interaction-proof/interaction-attestation.json"' "$CI_WORKFLOW"
rg -Fq 'APC_BUILD_ID: ${{ steps.development_identity.outputs.build_id }}' "$CI_WORKFLOW"
rg -Fq 'development-attestation.json' "$CI_WORKFLOW"
rg -Fq 'FULL_CANDIDATE: ${{ needs.scope.outputs.full_candidate }}' "$CI_WORKFLOW"
if [[ "$(rg -c 'exit 1 ;;' "$CI_WORKFLOW")" -lt 4 ]]; then
  echo 'CI result aggregation must fail explicitly instead of relying on shell loop status' >&2
  exit 1
fi
python3 - "$CI_WORKFLOW" "$WORKFLOW" <<'PY'
import pathlib
import re
import sys

ci = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
release = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

def job(source: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [a-zA-Z0-9_]+:\n|\Z)", source
    )
    if match is None:
        raise SystemExit(f"workflow job is missing: {name}")
    return match.group(1)

for portable in ("scope", "static", "portable_contracts", "cargo_source", "rust_lint", "rust_test_build", "rust_tests", "rust_test_proof", "stress", "required"):
    if "runs-on: ubuntu-24.04" not in job(ci, portable):
        raise SystemExit(f"portable job must run on Ubuntu: {portable}")
for native in ("macos_contracts", "macos_platform", "swift_interaction", "overlay", "bundle", "candidate_proof", "source_proof"):
    if "runs-on: macos-26" not in job(ci, native):
        raise SystemExit(f"platform/proof job must run on macOS 26: {native}")
bundle = job(ci, "bundle")
overlay = job(ci, "overlay")
swift = job(ci, "swift_interaction")
if "needs: [scope, promotion, swift_interaction]" not in bundle or "overlay" in bundle.split("if:", 1)[0]:
    raise SystemExit("bundle must consume Swift proof in parallel with overlay")
if "swift_build_artifact.py restore" not in bundle or "swift_build_artifact.py restore" not in overlay:
    raise SystemExit("both Swift consumers must restore the exact build artifact")
if "swift_build_artifact.py create" not in swift:
    raise SystemExit("Swift interaction must be the only exact artifact producer")
if ci.count("Restore or write the one strict Swift debug cache") != 1:
    raise SystemExit("strict Swift cache must have exactly one writer")
if "id: swift_strict_cache" not in swift or "path: apps/macos/.build" not in swift:
    raise SystemExit("strict Swift cache must be owned by the Swift proof producer")
if "restore-keys:" in ci or "restore-keys:" in release:
    raise SystemExit("CI/Release caches must not use cross-identity prefix fallbacks")
if "matrix.architecture" not in job(release, "build_archives"):
    raise SystemExit("Release build cache identity must include architecture")
PY
rg -Fq 'RULESET_NAME = "Protected default branch"' \
  "$ROOT_DIR/script/configure_main_branch_ruleset.py"
rg -Fq 'REQUIRED_CHECK = "Required CI"' \
  "$ROOT_DIR/script/configure_main_branch_ruleset.py"
rg -Fq 'TRAIN_RULESET_NAME = "Protected integration trains"' \
  "$ROOT_DIR/script/configure_main_branch_ruleset.py"
rg -Fq '"allow_auto_merge": True' \
  "$ROOT_DIR/script/configure_main_branch_ruleset.py"
rg -Fq '"allow_merge_commit": False' \
  "$ROOT_DIR/script/configure_main_branch_ruleset.py"
rg -Fq '"allow_rebase_merge": False' \
  "$ROOT_DIR/script/configure_main_branch_ruleset.py"
rg -Fq 'if not args.apply:' "$ROOT_DIR/script/configure_main_branch_ruleset.py"
rg -Fq 'workflow_run:' "$AUTO_MERGE_WORKFLOW"
rg -Fq 'github.event.workflow_run.head_repository.full_name == github.repository' \
  "$AUTO_MERGE_WORKFLOW"
rg -Fq "github.event.workflow_run.event == 'pull_request'" "$AUTO_MERGE_WORKFLOW"
rg -Fq "github.event.workflow_run.path == '.github/workflows/ci.yml'" \
  "$AUTO_MERGE_WORKFLOW"
rg -Fq 'repos/$GITHUB_REPOSITORY/rules/branches/$encoded_base' \
  "$AUTO_MERGE_WORKFLOW"
rg -Fq '.context == "Required CI"' "$AUTO_MERGE_WORKFLOW"
rg -Fq -- '--squash --match-head-commit "$HEAD_SHA"' "$AUTO_MERGE_WORKFLOW"
rg -Fq './script/ci_proof_promotion.py verify-merge-source' "$AUTO_MERGE_WORKFLOW"
rg -Fq './script/ci_proof_promotion.py delete-merged-head' "$AUTO_MERGE_WORKFLOW"
rg -Fq -- '--allow-delete "$ALLOW_DELETE"' "$AUTO_MERGE_WORKFLOW"
rg -Fq 'newly_merged=$newly_merged' "$AUTO_MERGE_WORKFLOW"
rg -Fq 'f"--force-with-lease={full_ref}:{args.head_commit}"' \
  "$ROOT_DIR/script/ci_proof_promotion.py"
rg -Fq 'ref: main' "$AUTO_MERGE_WORKFLOW"
rg -Fq 'persist-credentials: false' "$AUTO_MERGE_WORKFLOW"
rg -Fq 'gh workflow run ci.yml --ref main -f "expected_sha=$merge_commit"' \
  "$AUTO_MERGE_WORKFLOW"
rg -Fq './script/ci_proof_promotion.py create-merge-ticket' "$CI_WORKFLOW"
rg -Fq 'ci-merge-ticket-${{ github.run_id }}-${{ github.run_attempt }}' "$CI_WORKFLOW"
if rg -q 'ref:[[:space:]]*\$\{\{[[:space:]]*github\.event\.workflow_run\.(head_sha|head_branch)' \
  "$AUTO_MERGE_WORKFLOW"; then
  echo 'workflow-run merger must never check out pull-request code' >&2
  exit 1
fi
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
rg -Fq -- '-Xswiftc -strict-concurrency=complete' "$ROOT_DIR/script/validate_swift_tests.sh"
rg -Fq -- '-Xswiftc -warnings-as-errors' "$ROOT_DIR/script/validate_swift_tests.sh"
rg -Fq -- '--attestation-out' "$OVERLAY_INTERACTION_VALIDATOR"
rg -Fq 'interaction-contract-files.txt' "$OVERLAY_INTERACTION_VALIDATOR"
rg -Fq 'petpack verify-production-interaction' \
  "$ROOT_DIR/script/validate_app_bundle.sh"
if rg -Fq 'prepare_interaction_attestation.sh' \
  "$ROOT_DIR/script/validate_portable_pet_maker.sh"; then
  echo 'portable producer validation must not invoke the macOS Swift proof producer' >&2
  exit 1
fi
rg -Fq 'validate_interaction_attestation.py' \
  "$ROOT_DIR/script/validate_portable_pet_maker.sh"
rg -Fq 'interaction-attestation.json' "$ROOT_DIR/script/build_app_bundle.sh"
rg -Fq -- '--interaction-attestation "$APC_INTERACTION_ATTESTATION_PATH"' "$TEST_ALL"
rg -Fq 'validate_interaction_attestation.py' "$ROOT_DIR/script/build_app_bundle.sh"
rg -Fq 'validate_interaction_attestation.py' "$ROOT_DIR/script/validate_overlay_offline.sh"
rg -Fq 'validate_localizations.py' "$TEST_ALL"
rg -Fq 'validation_fingerprint.py' "$TEST_ALL"
rg -Fq -- '--resume' "$TEST_ALL"
if rg -q 'test_all[.]sh|cargo test|cargo clippy|validate_swift_tests|build_app_bundle|validate_portable_pet_maker|validate_connectors_runtime' \
  "$PRE_PUSH_VALIDATOR"; then
  echo 'local fast gate must not duplicate authoritative CI tests or App assembly' >&2
  exit 1
fi
if rg -Fq 'test_all.sh' "$WORKFLOW"; then
  echo 'GitHub Release must reuse the exact main source proof instead of repeating test_all' >&2
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
rg -Fq 'Reuse exact main source proof' "$WORKFLOW"
rg -Fq './script/resolve_release_source_proof.py run' "$WORKFLOW"
rg -Fq './script/release_source_proof.py validate' "$WORKFLOW"
rg -Fq 'github-token: ${{ github.token }}' "$WORKFLOW"
rg -Fq 'run-id: ${{ steps.source_proof_run.outputs.run_id }}' "$WORKFLOW"
rg -Fq "inputs.commit || 'main'" "$WORKFLOW"
rg -Fq 'if: env.TAG_EXISTS != '\''1'\''' "$WORKFLOW"
rg -Fq '"repos/$GITHUB_REPOSITORY/git/refs"' "$WORKFLOW"
rg -Fq 'needs: [prepare, ensure_tag]' "$WORKFLOW"

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
rg -Fq 'validate_macos_build_contract.py" artifact' \
  "$ROOT_DIR/script/validate_app_bundle.sh"
rg -Fq 'validate_macos_build_contract.py" toolchain' \
  "$ROOT_DIR/script/build_app_bundle.sh"
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

rg -q 'workflow_dispatch:' "$WORKFLOW"
if rg -q '^  push:' "$WORKFLOW"; then
  echo 'release workflow must require explicit dispatch after local Computer Use acceptance' >&2
  exit 1
fi
rg -q 'host_ui_tested_commit:' "$WORKFLOW"
rg -q 'host_ui_result:' "$WORKFLOW"
rg -Fq 'test "$HOST_UI_TESTED_COMMIT" = "$commit"' "$WORKFLOW"
rg -Fq 'test "$HOST_UI_RESULT" = "passed"' "$WORKFLOW"
if rg -q 'self-hosted' "$WORKFLOW"; then
  echo 'release workflow must use fresh GitHub-hosted native macOS runners' >&2
  exit 1
fi
rg -Fq 'architecture: [arm64, x86_64]' "$WORKFLOW"
rg -Fq '${{ matrix.architecture == '\''arm64'\'' && '\''aarch64-apple-darwin'\'' || '\''x86_64-apple-darwin'\'' }}-release-' "$WORKFLOW"
rg -Fq 'run: ./script/build_release.sh --github-release --source-gate-proven --arch "${{ matrix.architecture }}"' \
  "$WORKFLOW"
rg -q 'validate_github_release_artifacts.sh' "$WORKFLOW"
rg -q 'gh release download' "$WORKFLOW"
rg -q 'persist-credentials: false' "$WORKFLOW"
rg -q 'git merge-base --is-ancestor "\$commit" refs/remotes/origin/main' \
  "$WORKFLOW"
rg -q 'needs: \[prepare, assemble, validate_arm64, validate_x86_64, validate_macos26\]' "$WORKFLOW"
rg -q 'runs-on: macos-26$' "$WORKFLOW"
rg -q 'runs-on: macos-15$' "$WORKFLOW"
rg -q 'runs-on: macos-15-intel$' "$WORKFLOW"
rg -Fq './script/validate_macos_build_contract.py toolchain' "$WORKFLOW"
rg -q 'verify_release_candidate_digests.sh' "$WORKFLOW"
rg -q 'validate_github_release_api.py' "$WORKFLOW"
rg -q 'validate_codex_plugin_version.py' "$WORKFLOW"
rg -q 'actions: read' "$WORKFLOW"
rg -Fq 'APC_PREVIOUS_RELEASE_TAG: ${{ needs.prepare.outputs.previous_tag }}' \
  "$WORKFLOW"
rg -q 'VERSIONED_SKILLS' "$ROOT_DIR/script/validate_codex_plugin_version.py"
rg -q 'HOOKS_ALLOWED_TOP_LEVEL_FIELDS' "$ROOT_DIR/script/validate_codex_plugin_version.py"
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
ensure_tag_start = source.index("\n  ensure_tag:")
build_start = source.index("\n  build_archives:")
assemble_start = source.index("\n  assemble:")
arm_start = source.index("\n  validate_arm64:")
x86_start = source.index("\n  validate_x86_64:")
macos26_start = source.index("\n  validate_macos26:")
publish_start = source.index("\n  publish:")
prepare = source[:ensure_tag_start]
ensure_tag = source[ensure_tag_start:build_start]
build = source[build_start:assemble_start]
assemble = source[assemble_start:arm_start]
arm = source[arm_start:x86_start]
x86 = source[x86_start:macos26_start]
macos26 = source[macos26_start:publish_start]
publish = source[publish_start:]

if source.count("contents: write") != 2:
    raise SystemExit("only tag binding and publish may have contents: write")
if "contents: write" not in ensure_tag or "contents: write" not in publish:
    raise SystemExit("tag binding and publish need explicit contents write permission")
if any("contents: write" in job for job in (prepare, build, assemble, arm, x86, macos26)):
    raise SystemExit("build and validation jobs must remain read-only")
if source.count("ref: ${{ needs.prepare.outputs.commit }}") < 5:
    raise SystemExit("every downstream job must check out the proven commit")
if source.count("./script/verify_remote_release_tag.sh") < 3:
    raise SystemExit("remote tag identity must be rechecked before and after publication")

proof_resolve = prepare.index("Resolve successful trusted main CI run")
proof_download = prepare.index("Download exact-commit source proof", proof_resolve)
proof_validation = prepare.index("./script/release_source_proof.py validate", proof_download)
proof_upload = prepare.index("Upload release-bound interaction proof", proof_validation)
tag_create = ensure_tag.index("Create missing lightweight tag after source proof succeeds")
tag_verify = ensure_tag.index("./script/verify_remote_release_tag.sh", tag_create)
official_build = build.index(
    'run: ./script/build_release.sh --github-release --source-gate-proven --arch "${{ matrix.architecture }}"'
)
metadata = assemble.index("validate_release_artifact_metadata.py")
digest_emission = assemble.index("Emit trusted digest for every candidate file", metadata)
upload = assemble.index("Upload exact release candidate", digest_emission)
if not proof_resolve < proof_download < proof_validation < proof_upload or not tag_create < tag_verify or not metadata < digest_emission < upload:
    raise SystemExit("release source proof, assembly, digest, and upload order is unsafe")
if "architecture: [arm64, x86_64]" not in build or official_build < 0:
    raise SystemExit("official architectures must build as a parallel matrix")

if 'run: test "$(uname -m)" = "arm64"' not in arm:
    raise SystemExit("arm64 validation job does not prove its native architecture")
if 'run: test "$(uname -m)" = "x86_64"' not in x86:
    raise SystemExit("x86_64 validation job does not prove its native architecture")
if 'test "$(uname -m)" = "arm64"' not in macos26:
    raise SystemExit("macOS 26 validation job does not prove its native architecture")
if "sw_vers -productVersion" not in macos26:
    raise SystemExit("macOS 26 validation job does not prove its operating system")

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
if macos26.count("validate_github_release_artifacts.sh") != 1:
    raise SystemExit("macOS 26 job must run one native packaged validation")

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
"$ROOT_DIR/script/validate_macos_build_contract.py" --help >/dev/null
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
"$ROOT_DIR/script/ci_proof_promotion.py" --help >/dev/null
"$ROOT_DIR/script/release_source_proof.py" --help >/dev/null
"$ROOT_DIR/script/resolve_release_source_proof.py" --help >/dev/null
"$ROOT_DIR/script/validate_rust_test_shards.py" --help >/dev/null
"$ROOT_DIR/script/configure_main_branch_ruleset.py" --help >/dev/null
"$ROOT_DIR/script/development_flow.py" --help >/dev/null
"$ROOT_DIR/script/development_domains.py" --help >/dev/null
"$ROOT_DIR/script/engineering_metrics.py" --help >/dev/null
"$ROOT_DIR/script/changelog_fragments.py" --help >/dev/null
"$ROOT_DIR/script/swift_build_artifact.py" --help >/dev/null
"$ROOT_DIR/script/validate_local_tests.py" --help >/dev/null

PYTHONDONTWRITEBYTECODE=1 \
  python3 "$ROOT_DIR/script/tests/test_validation_tooling.py"
PYTHONDONTWRITEBYTECODE=1 \
  python3 "$ROOT_DIR/script/tests/test_ci_proof_promotion.py"
PYTHONDONTWRITEBYTECODE=1 \
  python3 "$ROOT_DIR/script/tests/test_macos_build_contract.py"

if [[ "$STATIC_ONLY" == "0" ]]; then
  PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT_DIR/script/tests/test_release_distribution_contracts.py"
  "$ROOT_DIR/script/tests/test_release_shell_contracts.sh"
  "$ROOT_DIR/script/validate_test_isolation.sh"
fi

echo 'Build and GitHub Release script safety ok'
