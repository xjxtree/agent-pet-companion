#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-m6.XXXXXX")"
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
cargo test --workspace >/dev/null
(APC_HOME="$TMP_DIR/home" APC_DISABLE_CODEX_APP_SERVER_AUTO=1 "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready") &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

TOKEN_MODE="$(stat -f '%Lp' "$TMP_DIR/home/run/update-token")"
[[ "$TOKEN_MODE" == "600" ]]
PORT="$(cat "$TMP_DIR/home/run/http-port")"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"failed","title":"失败"}')"
[[ "$HTTP_CODE" == "401" ]]

OUT="$("$ROOT_DIR/target/debug/petcore-cli" renderer budget --quality original --fps 20)"
grep -q '"renderer_budget_mb": 420' <<<"$OUT"
(cd "$ROOT_DIR/apps/macos" && swift build --product AgentPetCompanion >/dev/null)
OUT="$(cd "$ROOT_DIR/apps/macos" && swift run AgentPetCompanionCoreValidation)"
grep -q 'ok' <<<"$OUT"

echo "M6 validation ok"
