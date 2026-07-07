#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"
cargo build --workspace >/dev/null
(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready") &
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" health)"
grep -q '"ok": true' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" behavior get)"
grep -q '"enabled": true' <<<"$OUT"

PORT="$(cat "$TMP_DIR/home/run/http-port")"
TOKEN="$(cat "$TMP_DIR/home/run/update-token")"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"start","title":"开始处理"}')"
[[ "$HTTP_CODE" == "401" ]]
OUT="$(curl -s -H "X-Agent-Pet-Token: $TOKEN" -X POST "http://127.0.0.1:$PORT/agent-events" -d '{"source":"codex","event_type":"start","title":"开始处理"}')"
grep -q '"triggered":true' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
grep -q '"events"' <<<"$OUT"

echo "M1 validation ok"
