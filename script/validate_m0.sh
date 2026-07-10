#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-m0.XXXXXX")"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"
PETCORE_PID=""

cleanup() {
  if [[ -n "$PETCORE_PID" ]]; then
    kill "$PETCORE_PID" >/dev/null 2>&1 || true
    wait "$PETCORE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
cargo build --workspace
(APC_HOME="$TMP_DIR/home" APC_DISABLE_CODEX_APP_SERVER_AUTO=1 "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready") &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" health)"
grep -q '"ok": true' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" codex)"
python3 - "$OUT" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert isinstance(data.get("initialized"), bool), data
if not data["initialized"]:
    assert data.get("detail") or data.get("action") or data.get("skip_reason"), data
PY

APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack sample --output "$TMP_DIR/sample" --quality high --frames 2 >/dev/null
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/sample")"
grep -q '"ok": true' <<<"$OUT"

(cd "$ROOT_DIR/apps/macos" && swift build --product AgentPetCompanion >/dev/null)
OUT="$(cd "$ROOT_DIR/apps/macos" && swift run AgentPetCompanionCoreValidation)"
grep -q 'ok' <<<"$OUT"

echo "M0 validation ok"
