#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo 'usage: prepare_interaction_attestation.sh --output ABSOLUTE_PATH [--proof-in ABSOLUTE_PATH]'
}

OUTPUT=""
PROOF_IN=""
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

[[ "$OUTPUT" == /* ]] || {
  echo 'interaction attestation output must be an absolute path' >&2
  exit 2
}
if [[ -n "$PROOF_IN" && "$PROOF_IN" != /* ]]; then
  echo 'interaction proof input must be an absolute path' >&2
  exit 2
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
