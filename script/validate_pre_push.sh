#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF=""
PLAN_ONLY=0
FULL=0
CI_MODE=0

usage() {
  cat <<'EOF'
usage: validate_pre_push.sh [--base REF] [--plan-only] [--full] [--ci]

Runs source-safe, change-scoped checks for an ordinary commit. --full delegates
to test_all.sh --resume; CI and Release continue to use uncached test_all.sh.
--ci uses the same path classifier but runs complete script/release contract
tests when those files changed. It never enables host UI or Computer Use.
EOF
}

while (($# > 0)); do
  case "$1" in
    --base)
      (($# >= 2)) || { usage >&2; exit 2; }
      BASE_REF="$2"
      shift 2
      ;;
    --plan-only)
      PLAN_ONLY=1
      shift
      ;;
    --full)
      FULL=1
      shift
      ;;
    --ci)
      CI_MODE=1
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

if [[ "$FULL" == "1" ]]; then
  if [[ "$PLAN_ONLY" == "1" ]]; then
    echo './script/test_all.sh --resume'
    exit 0
  fi
  exec "$ROOT_DIR/script/test_all.sh" --resume
fi

if [[ -z "$BASE_REF" ]]; then
  if upstream="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    BASE_REF="$(git -C "$ROOT_DIR" merge-base HEAD "$upstream")"
  else
    BASE_REF="HEAD"
  fi
fi
git -C "$ROOT_DIR" rev-parse --verify "$BASE_REF^{commit}" >/dev/null

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-pre-push.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
CHANGED_PATHS="$TMP_DIR/changed-paths"
UNTRACKED_PATHS="$TMP_DIR/untracked-paths"
git -C "$ROOT_DIR" diff --name-only -z "$BASE_REF" -- >"$CHANGED_PATHS"
git -C "$ROOT_DIR" ls-files --others --exclude-standard -z >"$UNTRACKED_PATHS"
cat "$UNTRACKED_PATHS" >>"$CHANGED_PATHS"

eval "$(
  "$ROOT_DIR/script/validation_scope.py" \
    --root "$ROOT_DIR" \
    --paths-file "$CHANGED_PATHS" \
    --format shell
)"

PLAN=("git diff --check against $BASE_REF" "source syntax and local Markdown links")
if [[ "$APC_CHANGED_LOCALIZATION" == "1" ]]; then
  PLAN+=("String Catalog/.strings parity")
fi
if [[ "$APC_CHANGED_SCRIPTS" == "1" ]]; then
  PLAN+=("static build and release-script safety")
fi
if [[ "$APC_CHANGED_PRODUCER" == "1" ]]; then
  PLAN+=("pet Skill contracts and portable maker roundtrip")
fi
if [[ "$APC_CHANGED_CONNECTORS" == "1" ]]; then
  PLAN+=("generated connector runtime smoke")
fi
case "$APC_RUST_MODE" in
  workspace) PLAN+=("Rust fmt plus workspace Clippy/tests") ;;
  petcore) PLAN+=("Rust fmt plus petcore/petcore-cli Clippy/tests") ;;
  cli) PLAN+=("Rust fmt plus petcore-cli Clippy/tests") ;;
esac
case "$APC_SWIFT_MODE" in
  overlay) PLAN+=("focused overlay, frame-pipeline, and interaction Swift tests") ;;
  full) PLAN+=("complete Swift unit and UI-model tests") ;;
esac
if [[ "$APC_CHANGED_PLUGIN_VERSION" == "1" ]]; then
  PLAN+=("Codex plugin and bundled Skill version discipline")
fi
if [[ "$APC_BUILD_BUNDLE" == "1" && "$CI_MODE" == "1" ]]; then
  PLAN+=("CI packaged development App proof")
fi
if [[ "$APC_COMPUTER_USE" == "recommended" ]]; then
  PLAN+=("Computer Use recommended after automated checks; never run automatically")
else
  PLAN+=("Computer Use not required for this change scope")
fi

echo "Pre-push plan for $APC_CHANGED_COUNT changed path(s):"
printf '  - %s\n' "${PLAN[@]}"
if [[ "$PLAN_ONLY" == "1" ]]; then
  exit 0
fi

run() {
  local label="$1"
  shift
  printf '\n== %s ==\n' "$label"
  "$@"
}

run "Whitespace and conflict-marker check" git -C "$ROOT_DIR" diff --check "$BASE_REF" --
while IFS= read -r -d '' untracked_path; do
  untracked_check=""
  untracked_status=0
  if untracked_check="$(
    git -C "$ROOT_DIR" diff --no-index --check -- /dev/null "$ROOT_DIR/$untracked_path" 2>&1
  )"; then
    untracked_status=0
  else
    untracked_status=$?
  fi
  if ((untracked_status > 1)) || [[ -n "$untracked_check" ]]; then
    printf '%s\n' "$untracked_check" >&2
    echo "untracked file failed whitespace validation: $untracked_path" >&2
    exit 1
  fi
done <"$UNTRACKED_PATHS"
run "Source syntax" "$ROOT_DIR/script/validate_source_syntax.sh"
if [[ "$APC_CHANGED_LOCALIZATION" == "1" ]]; then
  run "Localization parity" "$ROOT_DIR/script/validate_localizations.py"
fi
if [[ "$APC_CHANGED_SCRIPTS" == "1" ]]; then
  SCRIPT_SAFETY_ARGS=(--skip-source-syntax)
  if [[ "$CI_MODE" != "1" ]]; then
    SCRIPT_SAFETY_ARGS+=(--static-only)
  fi
  run "Build and release-script safety" \
    "$ROOT_DIR/script/validate_build_scripts_safety.sh" \
    "${SCRIPT_SAFETY_ARGS[@]}"
fi
if [[ "$APC_CHANGED_PLUGIN_VERSION" == "1" ]]; then
  run "Codex plugin and Skill version discipline" \
    "$ROOT_DIR/script/validate_codex_plugin_version.py" \
    --base-ref "$BASE_REF"
fi
if [[ "$APC_CHANGED_PRODUCER" == "1" ]]; then
  run "Pet Skill contracts" "$ROOT_DIR/script/validate_pet_skills.sh"
  run "Portable pet maker" "$ROOT_DIR/script/validate_portable_pet_maker.sh"
fi
if [[ "$APC_CHANGED_CONNECTORS" == "1" ]]; then
  run "Connector runtime" "$ROOT_DIR/script/validate_connectors_runtime.sh"
fi

RUST_PACKAGE_ARGS=()
case "$APC_RUST_MODE" in
  workspace) RUST_PACKAGE_ARGS=(--workspace) ;;
  petcore) RUST_PACKAGE_ARGS=(-p petcore -p petcore-cli) ;;
  cli) RUST_PACKAGE_ARGS=(-p petcore-cli) ;;
esac
if ((${#RUST_PACKAGE_ARGS[@]} > 0)); then
  run "Rust formatting" cargo fmt --all --manifest-path "$ROOT_DIR/Cargo.toml" -- --check
  run "Scoped Rust linting" cargo clippy \
    --manifest-path "$ROOT_DIR/Cargo.toml" \
    "${RUST_PACKAGE_ARGS[@]}" \
    --all-targets --all-features --locked -- -D warnings
  run "Scoped Rust tests" cargo test \
    --manifest-path "$ROOT_DIR/Cargo.toml" \
    "${RUST_PACKAGE_ARGS[@]}" \
    --locked
fi
case "$APC_SWIFT_MODE" in
  overlay)
    run "Focused overlay Swift tests" \
      "$ROOT_DIR/script/validate_swift_tests.sh" --scope overlay
    ;;
  full)
    run "Swift tests" "$ROOT_DIR/script/validate_swift_tests.sh"
    ;;
esac

echo 'Change-scoped pre-push validation passed. Use --full for the complete local gate.'
