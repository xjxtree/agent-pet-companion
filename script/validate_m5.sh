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

"$ROOT_DIR/target/debug/petcore-cli" petpack sample --output "$TMP_DIR/pet" --quality high --frames 1 >/dev/null
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack import "$TMP_DIR/pet")"
grep -q '"active": true' <<<"$OUT"

BEHAVIOR='{"enabled":false,"status_bubble":true,"click_menu":true,"mouse_passthrough":false,"auto_hide":false,"fps_profile":"smooth","sources":{"codex":false,"claude_code":true,"pi":true,"opencode":true},"events":{"start":true,"tool":false,"waiting":true,"review":true,"done":true,"failed":true}}'
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" behavior set-json --value-json "$BEHAVIOR")"
grep -q '"enabled": false' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest --id evt_filtered_source --source codex --event-type start --title 开始处理)"
grep -q '"triggered": false' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" behavior get)"
grep -q '"fps_profile": "smooth"' <<<"$OUT"

echo "M5 validation ok"
