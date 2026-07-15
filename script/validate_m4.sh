#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-m4.XXXXXX")"
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
cargo build --workspace >/dev/null
(
  APC_HOME="$TMP_DIR/home" \
  APC_AGENT_CONFIG_HOME="$TMP_DIR/agent-home" \
  APC_CONNECTOR_CLI_PATH="$ROOT_DIR/target/debug/petcore-cli" \
  APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready"
) &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

for source in codex claude_code pi opencode; do
  OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id "evt_${source}_start" --source "$source" --event-type start --title 开始处理)"
  grep -q '"triggered": true' <<<"$OUT"
  OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections repair --source "$source")"
  grep -q '"items"' <<<"$OUT"
  OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" connections test --source "$source")"
  grep -q '"triggered": false' <<<"$OUT"
  grep -q '"diagnostic": true' <<<"$OUT"
done

OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id evt_duplicate --source codex --event-type tool --title 执行工具)"
grep -q '"inserted": true' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id evt_duplicate --source codex --event-type tool --title 执行工具)"
grep -q '"inserted": false' <<<"$OUT"

echo "M4 validation ok"
