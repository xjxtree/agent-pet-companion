#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF=""
PLAN_ONLY=0
FULL=0

usage() {
  cat <<'EOF'
usage: validate_pre_push.sh [--base REF] [--plan-only] [--full]

Runs source-safe, change-scoped checks for an ordinary commit. --full delegates
to test_all.sh --resume; CI and Release continue to use uncached test_all.sh.
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

eval "$(python3 -B - "$CHANGED_PATHS" <<'PY'
import pathlib
import shlex
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
paths = sorted({item.decode("utf-8", errors="surrogateescape") for item in raw.split(b"\0") if item})

def matches(prefixes):
    return any(path == prefix or path.startswith(prefix.rstrip("/") + "/") for path in paths for prefix in prefixes)

root_rust = any(path in {"Cargo.toml", "Cargo.lock", "rust-toolchain.toml"} for path in paths)
petcore_types = matches(("crates/petcore-types",))
petcore = matches(("crates/petcore",))
petcore_cli = matches(("crates/petcore-cli",))
schema_inputs = matches(("schemas", "fixtures"))
swift = matches(("apps/macos",))
localization = matches(("apps/macos/Sources/AgentPetCompanion/Resources",))
scripts = matches(("script", ".github"))
producer = (
    matches(("skills/agent-pet-maker", "skills/agent-pet-studio"))
    or any(path.startswith(("schemas/petpack", "fixtures/petpack")) for path in paths)
)
connectors = matches(("plugins", "docs/integrations/agent-connectors.md"))

if root_rust or petcore_types or schema_inputs:
    rust_mode = "workspace"
elif petcore:
    rust_mode = "petcore"
elif petcore_cli:
    rust_mode = "cli"
else:
    rust_mode = "none"

values = {
    "APC_CHANGED_COUNT": str(len(paths)),
    "APC_CHANGED_SWIFT": "1" if swift else "0",
    "APC_CHANGED_LOCALIZATION": "1" if localization else "0",
    "APC_CHANGED_SCRIPTS": "1" if scripts else "0",
    "APC_CHANGED_PRODUCER": "1" if producer else "0",
    "APC_CHANGED_CONNECTORS": "1" if connectors else "0",
    "APC_RUST_MODE": rust_mode,
}
for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
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
if [[ "$APC_CHANGED_SWIFT" == "1" ]]; then
  PLAN+=("complete Swift unit and UI-model tests")
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
  run "Static build-script safety" "$ROOT_DIR/script/validate_build_scripts_safety.sh" --static-only
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
if [[ "$APC_CHANGED_SWIFT" == "1" ]]; then
  run "Swift tests" "$ROOT_DIR/script/validate_swift_tests.sh"
fi

echo 'Change-scoped pre-push validation passed. Use --full for the complete local gate.'
