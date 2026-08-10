#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESUME_VALIDATION="${APC_TEST_ALL_RESUME:-0}"
CLEAR_VALIDATION_CACHE=0
SOURCE_ONLY=0
INCLUDE_STRESS="${APC_TEST_ALL_INCLUDE_STRESS:-0}"

usage() {
  cat <<'EOF'
usage: test_all.sh [--resume] [--source-only] [--include-stress] [--clear-cache]

  --resume       Reuse successful local steps only when their scoped source
                 fingerprint and toolchain context are unchanged.
  --source-only  Prove source and integration contracts without assembling a
                 development App; intended for a Release that validates exact
                 packaged artifacts separately.
  --include-stress
                 Include bounded event-storm stress. This is mandatory for the
                 Release source gate and optional for ordinary local work.
  --clear-cache  Remove this worktree's local validation checkpoints and exit.

The default invocation never consumes checkpoints and remains the CI/Release
proof path.
EOF
}

while (($# > 0)); do
  case "$1" in
    --resume)
      RESUME_VALIDATION=1
      shift
      ;;
    --clear-cache)
      CLEAR_VALIDATION_CACHE=1
      shift
      ;;
    --source-only)
      SOURCE_ONLY=1
      shift
      ;;
    --include-stress)
      INCLUDE_STRESS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$RESUME_VALIDATION" in
  0|false|FALSE|no|NO) RESUME_VALIDATION=0 ;;
  1|true|TRUE|yes|YES) RESUME_VALIDATION=1 ;;
  *) echo 'APC_TEST_ALL_RESUME must be 0 or 1' >&2; exit 2 ;;
esac
case "$INCLUDE_STRESS" in
  0|false|FALSE|no|NO) INCLUDE_STRESS=0 ;;
  1|true|TRUE|yes|YES) INCLUDE_STRESS=1 ;;
  *) echo 'APC_TEST_ALL_INCLUDE_STRESS must be 0 or 1' >&2; exit 2 ;;
esac

VALIDATION_CACHE_DIR=""
if [[ "$RESUME_VALIDATION" == "1" || "$CLEAR_VALIDATION_CACHE" == "1" ]]; then
  validation_git_path="$(git -C "$ROOT_DIR" rev-parse --git-path apc-validation-cache-v1)"
  if [[ "$validation_git_path" == /* ]]; then
    VALIDATION_CACHE_DIR="$validation_git_path"
  else
    VALIDATION_CACHE_DIR="$ROOT_DIR/$validation_git_path"
  fi
fi
if [[ "$CLEAR_VALIDATION_CACHE" == "1" ]]; then
  [[ -n "$VALIDATION_CACHE_DIR" && "$VALIDATION_CACHE_DIR" != "/" ]] || {
    echo 'refusing to clear an invalid validation cache path' >&2
    exit 1
  }
  rm -rf -- "$VALIDATION_CACHE_DIR"
  echo "Cleared local validation checkpoints: $VALIDATION_CACHE_DIR"
  exit 0
fi

TEST_ALL_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-test-all.XXXXXX")"
trap 'rm -rf "$TEST_ALL_TEMP_DIR"' EXIT
CACHE_CONTEXT=""
if [[ "$RESUME_VALIDATION" == "1" ]]; then
  mkdir -p "$VALIDATION_CACHE_DIR/steps" "$VALIDATION_CACHE_DIR/artifacts"
  find "$VALIDATION_CACHE_DIR/steps" -type f -name '*.ok' -mtime +14 -delete
  CACHE_CONTEXT="$(
    {
      uname -a
      rustc -Vv
      swift --version
      python3 --version 2>&1
      node --version 2>/dev/null || true
      python3 -c 'import PIL; print(PIL.__version__)' 2>/dev/null || true
      env | LC_ALL=C sort | awk -F= '
        /^APC_/ && $1 != "APC_TEST_ALL_RESUME" && $1 != "APC_BUILD_ID" && $1 != "APC_INTERACTION_ATTESTATION_PATH" { print }
      '
      shasum -a 256 "$ROOT_DIR/script/test_all.sh" "$ROOT_DIR/script/validation_fingerprint.py"
    } | shasum -a 256 | awk '{print $1}'
  )"
fi

log_legend() {
  cat <<'EOF'
Validation profiles:
  [fast/core] deterministic local checks for Rust, PetCore, CLI, schemas, Swift core, and security boundaries.
  [simulated integration] temp-home integration, local Pet Studio fallback, generated connector templates, or fake sentinel inputs; not real end-to-end acceptance.
  [macos runtime] real macOS app bundle and overlay runtime checks; environment-gated.
  [real agent connectors] current user Codex/Claude/Pi/OpenCode connector files sending diagnostic events into the current app; environment-gated.
  [real app server] real Codex App Server stdio session; environment-gated.
  [perf/nightly] bounded stress and budget checks; enabled explicitly with --include-stress.
Default test_all covers deterministic, simulated, and security checks. Stress, host UI, and real-agent checks require explicit opt-in and otherwise print skip reasons.
EOF
}

run_step() {
  local profile="$1"
  local label="$2"
  shift 2
  local started_at=$SECONDS
  printf '\n== [%s] %s ==\n' "$profile" "$label"
  if "$@"; then
    printf 'Completed in %ss: %s\n' "$((SECONDS - started_at))" "$label"
    return 0
  else
    local status=$?
    printf 'Failed after %ss: %s\n' "$((SECONDS - started_at))" "$label" >&2
    return "$status"
  fi
}

run_cached_step() {
  local profile="$1"
  local step_id="$2"
  local scope="$3"
  local label="$4"
  shift 4
  if [[ "$RESUME_VALIDATION" != "1" ]]; then
    run_step "$profile" "$label" "$@"
    return
  fi

  local command_key command_source_digest fingerprint marker_dir marker temporary_marker
  printf -v command_key '%q ' "$@"
  command_source_digest=""
  if [[ "$1" == "$ROOT_DIR/"* && -f "$1" ]]; then
    command_source_digest="$(shasum -a 256 "$1" | awk '{print $1}')"
  fi
  fingerprint="$(
    "$ROOT_DIR/script/validation_fingerprint.py" \
      --root "$ROOT_DIR" \
      --scope "$scope" \
      --extra "$CACHE_CONTEXT|$command_source_digest|$step_id|$command_key|${APC_EVENT_STORM_COUNT:-180}"
  )"
  marker_dir="$VALIDATION_CACHE_DIR/steps/$step_id"
  marker="$marker_dir/$fingerprint.ok"
  if [[ -f "$marker" ]]; then
    printf '\n== [%s] %s ==\n' "$profile" "$label"
    printf 'Reused local checkpoint for unchanged %s inputs (%s)\n' "$scope" "${fingerprint:0:12}"
    return
  fi

  run_step "$profile" "$label" "$@"
  mkdir -p "$marker_dir"
  temporary_marker="$marker_dir/.${fingerprint}.$$"
  printf '%s\n' "$fingerprint" >"$temporary_marker"
  mv "$temporary_marker" "$marker"
}

log_skip() {
  local profile="$1"
  local label="$2"
  local reason="$3"
  printf '\n== [%s] %s ==\n' "$profile" "$label"
  printf 'Skipped: %s\n' "$reason"
}

host_ui_skip_reason() {
  local setting="${APC_VALIDATE_HOST_UI:-0}"
  case "$setting" in
    0|false|FALSE|no|NO)
      printf 'APC_VALIDATE_HOST_UI=%s keeps host UI validation out of default test_all' "$setting"
      return 0
      ;;
    1|true|TRUE|yes|YES)
      ;;
    *)
      printf 'APC_VALIDATE_HOST_UI=%s is not recognized; use 0 or 1' "$setting"
      return 0
      ;;
  esac

  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'host UI validation requires Darwin; current host is %s' "$(uname -s)"
    return 0
  fi

  return 1
}

real_app_server_skip_reason() {
  local setting="${APC_VALIDATE_REAL_APP_SERVER:-0}"
  case "$setting" in
    0|false|FALSE|no|NO)
      printf 'APC_VALIDATE_REAL_APP_SERVER=%s keeps real Codex App Server validation out of default test_all' "$setting"
      return 0
      ;;
    1|true|TRUE|yes|YES)
      ;;
    *)
      printf 'APC_VALIDATE_REAL_APP_SERVER=%s is not recognized; use 0 or 1' "$setting"
      return 0
      ;;
  esac

  if [[ -n "${CODEX_APP_SERVER_CMD:-}" ]]; then
    return 1
  fi

  if ! command -v codex >/dev/null 2>&1; then
    printf 'CODEX_APP_SERVER_CMD is unset and codex CLI was not found'
    return 0
  fi

  if ! codex app-server --help >/dev/null 2>&1; then
    printf 'CODEX_APP_SERVER_CMD is unset and codex CLI does not expose a working app-server command'
    return 0
  fi

  return 1
}

real_agent_connectors_skip_reason() {
  local setting="${APC_VALIDATE_REAL_AGENT_CONNECTORS:-0}"
  case "$setting" in
    0|false|FALSE|no|NO)
      printf 'APC_VALIDATE_REAL_AGENT_CONNECTORS=%s keeps real user connector validation out of default test_all' "$setting"
      return 0
      ;;
    1|true|TRUE|yes|YES)
      return 1
      ;;
  esac

  printf 'APC_VALIDATE_REAL_AGENT_CONNECTORS=%s is not recognized; use 0 or 1' "$setting"
  return 0
}

log_legend

run_cached_step "fast/core" "test-isolation" "scripts" "default test isolation and owned-process safety" "$ROOT_DIR/script/validate_test_isolation.sh"
run_cached_step "fast/core" "app-lifecycle-contract" "swift" "macOS UI-host and PetCore lifecycle contract" "$ROOT_DIR/script/validate_app_lifecycle_contract.sh"
run_cached_step "fast/core" "schema-fixtures" "schemas" "JSON Schema positive/negative fixtures" "$ROOT_DIR/script/validate_schema_fixtures.sh"
run_cached_step "fast/core" "petpack-schemas" "schemas" "published petpack producer-profile schemas" "$ROOT_DIR/script/validate_petpack_spec_schemas.sh"
run_cached_step "fast/core" "localization-parity" "localization" "String Catalog and shipped localization parity" "$ROOT_DIR/script/validate_localizations.py"

if [[ -z "${APC_BUILD_ID:-}" ]]; then
  export APC_BUILD_ID="validation.$(date -u +%Y%m%d%H%M%S).$$"
fi
if [[ -n "${APC_INTERACTION_ATTESTATION_OUTPUT:-}" ]]; then
  [[ "$APC_INTERACTION_ATTESTATION_OUTPUT" == /* ]] || {
    echo 'APC_INTERACTION_ATTESTATION_OUTPUT must be an absolute path' >&2
    exit 2
  }
  export APC_INTERACTION_ATTESTATION_PATH="$APC_INTERACTION_ATTESTATION_OUTPUT"
  mkdir -p "$(dirname "$APC_INTERACTION_ATTESTATION_PATH")"
else
  export APC_INTERACTION_ATTESTATION_PATH="$TEST_ALL_TEMP_DIR/interaction-attestation.json"
fi
INTERACTION_PROOF_IN=""
if [[ "$RESUME_VALIDATION" == "1" ]]; then
  interaction_fingerprint="$(
    "$ROOT_DIR/script/validation_fingerprint.py" --root "$ROOT_DIR" --scope interaction
  )"
  cached_interaction_proof="$VALIDATION_CACHE_DIR/artifacts/interaction-full-swift-$interaction_fingerprint-$CACHE_CONTEXT.json"
  if [[ -f "$cached_interaction_proof" ]] \
    && "$ROOT_DIR/script/validate_interaction_attestation.py" "$cached_interaction_proof" >/dev/null; then
    INTERACTION_PROOF_IN="$cached_interaction_proof"
  fi
fi
INTERACTION_PREPARE_ARGS=(
  --output "$APC_INTERACTION_ATTESTATION_PATH"
  --swift-scope all
)
if [[ -n "$INTERACTION_PROOF_IN" ]]; then
  INTERACTION_PREPARE_ARGS+=(--proof-in "$INTERACTION_PROOF_IN")
fi
run_step "fast/core" "complete Swift suite and Phase A/T-B4 interaction attestation bound to this PetCore build" \
  "$ROOT_DIR/script/prepare_interaction_attestation.sh" "${INTERACTION_PREPARE_ARGS[@]}"
if [[ "$RESUME_VALIDATION" == "1" && -z "$INTERACTION_PROOF_IN" ]]; then
  cp "$APC_INTERACTION_ATTESTATION_PATH" "$cached_interaction_proof"
fi

run_cached_step "simulated integration" "portable-pet-maker" "producer" "portable pet maker helper, create/modify, and isolated daemon roundtrip" "$ROOT_DIR/script/validate_portable_pet_maker.sh"
run_cached_step "fast/core" "pet-skills" "producer" "pet-making Skill structure and shared contracts" "$ROOT_DIR/script/validate_pet_skills.sh"
run_cached_step "fast/core" "build-script-safety" "scripts" "shell, Python, JSON and release-script syntax/safety" "$ROOT_DIR/script/validate_build_scripts_safety.sh" --static-only
run_cached_step "fast/core" "rust-format" "rust" "Rust formatting" cargo fmt --all --manifest-path "$ROOT_DIR/Cargo.toml" -- --check
run_cached_step "fast/core" "rust-clippy" "rust" "strict Rust linting" cargo clippy --manifest-path "$ROOT_DIR/Cargo.toml" --workspace --all-targets --all-features --locked -- -D warnings
run_cached_step "fast/core" "rust-tests" "rust" "Rust workspace unit and integration tests" cargo test --manifest-path "$ROOT_DIR/Cargo.toml" --workspace --locked
run_cached_step "simulated integration" "connector-runtime" "connectors" "generated connector hook/plugin runtime smoke; not real third-party agent acceptance" "$ROOT_DIR/script/validate_connectors_runtime.sh"
if [[ "$INCLUDE_STRESS" == "1" ]]; then
  run_cached_step "perf/nightly" "event-storm" "rust" "bounded event storm stress at APC_EVENT_STORM_COUNT=${APC_EVENT_STORM_COUNT:-180}" "$ROOT_DIR/script/validate_event_storm.sh"
else
  log_skip "perf/nightly" "bounded event storm stress" "use --include-stress for Release or explicit stress validation"
fi
run_step "fast/core" "offline overlay geometry, scheduler, accessibility, frame-pipeline and pointer contracts" \
  "$ROOT_DIR/script/validate_overlay_offline.sh" \
  --interaction-attestation "$APC_INTERACTION_ATTESTATION_PATH"
run_cached_step "fast/core" "security-boundaries" "security" "security boundary checks with fake sentinel secrets" "$ROOT_DIR/script/validate_security_boundaries.sh"
if [[ "$SOURCE_ONLY" == "1" ]]; then
  log_skip "simulated integration" "development app bundle assembly without launch" "--source-only defers bundle proof to exact Release artifacts"
else
  run_step "simulated integration" "development app bundle assembly without launch" \
    "$ROOT_DIR/script/build_app_bundle.sh" \
    --configuration debug \
    --interaction-attestation "$APC_INTERACTION_ATTESTATION_PATH"
fi

if host_ui_skip_reason_value="$(host_ui_skip_reason)"; then
  log_skip "macos runtime" "real app bundle, overlay layout, display-width persistence, renderer telemetry, and app recovery" "$host_ui_skip_reason_value"
else
  run_step "macos runtime" "real app bundle launch and overlay verification" env APC_VALIDATE_HOST_UI=1 "$ROOT_DIR/script/build_and_run.sh" --verify
  run_step "macos runtime" "real main window UI structure without mouse events" "$ROOT_DIR/script/validate_main_window_ui.sh"
  run_step "macos runtime" "real overlay multi-agent layout without mouse events" "$ROOT_DIR/script/validate_overlay_non_mouse.sh"
  run_step "macos runtime" "overlay display-width persistence in the packaged app" "$ROOT_DIR/script/validate_overlay_display_width_persistence.sh"
  run_step "macos runtime" "real renderer cache strategy and runtime budget telemetry" "$ROOT_DIR/script/validate_renderer_runtime_budget.sh"
  run_step "macos runtime" "app recovery after PetCore restart" "$ROOT_DIR/script/validate_app_recovery.sh"
fi

if real_agent_connectors_skip_reason="$(real_agent_connectors_skip_reason)"; then
  log_skip "real agent connectors" "current user Codex/Claude/Pi/OpenCode connector roundtrip" "$real_agent_connectors_skip_reason"
else
  run_step "real agent connectors" "current user Codex/Claude/Pi/OpenCode connector roundtrip" "$ROOT_DIR/script/validate_real_agent_connectors.sh"
fi

if real_app_server_skip_reason="$(real_app_server_skip_reason)"; then
  log_skip "real app server" "real Codex App Server stdio validation" "$real_app_server_skip_reason"
else
  run_step "real app server" "real Codex App Server stdio validation" "$ROOT_DIR/script/validate_real_app_server.sh"
fi

echo "All enabled Agent Pet Companion validations passed; any skipped gates remain unverified"
