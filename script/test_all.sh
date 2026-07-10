#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log_legend() {
  cat <<'EOF'
Validation profiles:
  [fast/core] deterministic local checks for Rust, PetCore, CLI, schemas, Swift core, and security boundaries.
  [simulated integration] temp-home integration, local Pet Studio fallback, generated connector templates, or fake sentinel inputs; not real end-to-end acceptance.
  [macos runtime] real macOS app bundle and overlay runtime checks; environment-gated.
  [real agent connectors] current user Codex/Claude/Pi/OpenCode connector files sending diagnostic events into the current app; environment-gated.
  [real app server] real Codex App Server stdio session; environment-gated.
  [perf/nightly] bounded stress and budget checks; default scale is still part of test_all.
Default test_all covers deterministic, simulated, security, and bounded stress checks only. Host UI and real-agent checks require explicit opt-in and otherwise print skip reasons.
EOF
}

run_step() {
  local profile="$1"
  local label="$2"
  shift 2
  printf '\n== [%s] %s ==\n' "$profile" "$label"
  "$@"
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

overlay_interaction_skip_reason() {
  local setting="${APC_VALIDATE_OVERLAY_INTERACTION:-0}"
  case "$setting" in
    0|false|FALSE|no|NO)
      printf 'APC_VALIDATE_OVERLAY_INTERACTION=%s keeps real mouse-event overlay interaction validation disabled' "$setting"
      return 0
      ;;
    1|true|TRUE|yes|YES)
      return 1
      ;;
  esac

  printf 'APC_VALIDATE_OVERLAY_INTERACTION=%s is not recognized; use 0 or 1' "$setting"
  return 0
}

log_legend

run_step "fast/core" "default test isolation and owned-process safety" "$ROOT_DIR/script/validate_test_isolation.sh"
run_step "fast/core" "JSON Schema positive/negative fixtures" "$ROOT_DIR/script/validate_schema_fixtures.sh"
run_step "fast/core" "shell, Python, JSON and release-script syntax/safety" "$ROOT_DIR/script/validate_build_scripts_safety.sh" --static-only
run_step "fast/core" "M0 bootstrap smoke: Rust workspace, PetCore, CLI, Swift core validation" "$ROOT_DIR/script/validate_m0.sh"
run_step "fast/core" "M1 daemon, launch-agent plist, local HTTP token, and event API smoke" "$ROOT_DIR/script/validate_m1.sh"
run_step "fast/core" "M2 petpack schema/build validation and renderer budget calculations" "$ROOT_DIR/script/validate_m2.sh"
run_step "simulated integration" "M3 Pet Studio generation with local fallback; not a real App Server run" "$ROOT_DIR/script/validate_m3.sh"
run_step "simulated integration" "M4 connector repair/test in a temporary agent home" "$ROOT_DIR/script/validate_m4.sh"
run_step "simulated integration" "generated connector hook/plugin runtime smoke; not real third-party agent acceptance" "$ROOT_DIR/script/validate_connectors_runtime.sh"
run_step "perf/nightly" "bounded event storm stress at APC_EVENT_STORM_COUNT=${APC_EVENT_STORM_COUNT:-180}" "$ROOT_DIR/script/validate_event_storm.sh"
run_step "simulated integration" "M5 behavior, filtering, hook redaction, and library guardrails" "$ROOT_DIR/script/validate_m5.sh"
run_step "fast/core" "M6 workspace tests, token mode, renderer budget, and Swift core validation" "$ROOT_DIR/script/validate_m6.sh"
run_step "fast/core" "offline overlay geometry, scheduler, accessibility, frame-pipeline and pointer contracts" "$ROOT_DIR/script/validate_overlay_offline.sh"
run_step "simulated integration" "V1 acceptance scenario with local Pet Studio fallback; not real end-to-end App Server/overlay acceptance" "$ROOT_DIR/script/validate_v1.sh"
run_step "fast/core" "security boundary checks with fake sentinel secrets" "$ROOT_DIR/script/validate_security_boundaries.sh"
run_step "simulated integration" "development app bundle packaging without launch" "$ROOT_DIR/script/build_app_bundle.sh" --configuration debug

if host_ui_skip_reason_value="$(host_ui_skip_reason)"; then
  log_skip "macos runtime" "real app bundle, overlay layout, scale persistence, renderer telemetry, and app recovery" "$host_ui_skip_reason_value"
else
  run_step "macos runtime" "real app bundle launch and overlay verification" env APC_VALIDATE_HOST_UI=1 "$ROOT_DIR/script/build_and_run.sh" --verify
  run_step "macos runtime" "real main window UI structure without mouse events" "$ROOT_DIR/script/validate_main_window_ui.sh"
  run_step "macos runtime" "real overlay multi-agent layout without mouse events" "$ROOT_DIR/script/validate_overlay_non_mouse.sh"
  if overlay_interaction_skip_reason="$(overlay_interaction_skip_reason)"; then
    log_skip "macos runtime" "real overlay mouse drag, resize, and bubble controls" "$overlay_interaction_skip_reason"
  else
    run_step "macos runtime" "real overlay mouse drag, resize, and bubble controls" "$ROOT_DIR/script/validate_overlay_interaction.sh"
  fi
  run_step "macos runtime" "overlay scale persistence in the packaged app" "$ROOT_DIR/script/validate_overlay_scale_persistence.sh"
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

echo "All Agent Pet Companion validations passed"
