#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo 'usage: prepare_interaction_attestation.sh --output ABSOLUTE_PATH [--proof-in ABSOLUTE_PATH] [--resume] [--swift-scope interaction|all]'
}

OUTPUT=""
PROOF_IN=""
RESUME=0
SWIFT_SCOPE="interaction"
while (($# > 0)); do
  case "$1" in
    --output)
      (($# >= 2)) || { usage >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --proof-in)
      (($# >= 2)) || { usage >&2; exit 2; }
      PROOF_IN="$2"
      shift 2
      ;;
    --resume)
      RESUME=1
      shift
      ;;
    --swift-scope)
      (($# >= 2)) || { usage >&2; exit 2; }
      SWIFT_SCOPE="$2"
      shift 2
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

case "$SWIFT_SCOPE" in
  interaction|all) ;;
  *) usage >&2; exit 2 ;;
esac

[[ "$OUTPUT" == /* ]] || {
  echo 'interaction attestation output must be an absolute path' >&2
  exit 2
}
if [[ -n "$PROOF_IN" && "$PROOF_IN" != /* ]]; then
  echo 'interaction proof input must be an absolute path' >&2
  exit 2
fi
if [[ "$RESUME" == "1" && -n "$PROOF_IN" ]]; then
  echo '--resume cannot be combined with --proof-in' >&2
  exit 2
fi

if [[ "$RESUME" == "1" && -z "$PROOF_IN" ]]; then
  validation_git_path="$(git -C "$ROOT_DIR" rev-parse --git-path apc-validation-cache-v1)"
  if [[ "$validation_git_path" == /* ]]; then
    validation_cache_dir="$validation_git_path"
  else
    validation_cache_dir="$ROOT_DIR/$validation_git_path"
  fi
  interaction_context="$({
    swift --version
    shasum -a 256 \
      "$ROOT_DIR/script/prepare_interaction_attestation.sh" \
      "$ROOT_DIR/script/validate_overlay_interaction.sh" \
      "$ROOT_DIR/script/validate_interaction_attestation.py"
    printf '%s\n' "$SWIFT_SCOPE"
  } | shasum -a 256 | awk '{print $1}')"
  interaction_fingerprint="$(
    "$ROOT_DIR/script/validation_fingerprint.py" \
      --root "$ROOT_DIR" \
      --scope interaction \
      --extra "$interaction_context"
  )"
  cached_proof="$validation_cache_dir/artifacts/interaction-$SWIFT_SCOPE-$interaction_fingerprint.json"
  if [[ -f "$cached_proof" ]] \
    && "$ROOT_DIR/script/validate_interaction_attestation.py" "$cached_proof" >/dev/null; then
    PROOF_IN="$cached_proof"
  fi
fi

SOURCE_VERSION="$(
  awk -F'"' '/^version = / {print $2; exit}' "$ROOT_DIR/crates/petcore/Cargo.toml"
)"
BUILD_ID="${APC_BUILD_ID:-$SOURCE_VERSION}"
[[ "$BUILD_ID" =~ ^[A-Za-z0-9._+-]{1,128}$ ]] || {
  echo 'interaction attestation build_id is invalid' >&2
  exit 2
}

(cd "$ROOT_DIR" && APC_BUILD_ID="$BUILD_ID" \
  cargo build --locked -p petcore -p petcore-cli >/dev/null)

read -r ACTUAL_BUILD_ID ACTUAL_DIGEST < <(
  "$ROOT_DIR/target/debug/petcore-cli" build-info | python3 -B -c '
import json
import sys
value = json.load(sys.stdin)
print(value.get("build_id", ""), value.get("interaction_contract_digest", ""))
'
)
[[ "$ACTUAL_BUILD_ID" == "$BUILD_ID" ]] || {
  printf 'compiled petcore-cli build_id %s does not match attestation build_id %s\n' \
    "${ACTUAL_BUILD_ID:-missing}" "$BUILD_ID" >&2
  exit 1
}
[[ "$ACTUAL_DIGEST" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'compiled petcore-cli interaction contract digest is invalid' >&2
  exit 1
}

INTERACTION_ARGS=(
  --attestation-out "$OUTPUT"
  --build-id "$BUILD_ID"
  --swift-scope "$SWIFT_SCOPE"
)
if [[ -n "$PROOF_IN" ]]; then
  INTERACTION_ARGS+=(--proof-in "$PROOF_IN")
fi
"$ROOT_DIR/script/validate_overlay_interaction.sh" "${INTERACTION_ARGS[@]}"

ATTESTATION_DIGEST="$(
  "$ROOT_DIR/script/validate_interaction_attestation.py" \
    "$OUTPUT" \
    --expected-build-id "$BUILD_ID" \
    --print-digest
)"
[[ "$ATTESTATION_DIGEST" == "$ACTUAL_DIGEST" ]] || {
  echo 'generated interaction attestation digest does not match compiled PetCore' >&2
  exit 1
}

if [[ "$RESUME" == "1" && -z "${cached_proof:-}" ]]; then
  echo 'internal error: resumable interaction proof path was not initialized' >&2
  exit 1
fi
if [[ "$RESUME" == "1" && "$PROOF_IN" != "${cached_proof:-}" ]]; then
  mkdir -p "$(dirname "$cached_proof")"
  temporary_proof="$cached_proof.$$"
  cp "$OUTPUT" "$temporary_proof"
  mv "$temporary_proof" "$cached_proof"
fi
