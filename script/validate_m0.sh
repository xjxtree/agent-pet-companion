#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'pkill -P $$ >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"
cargo build --workspace
(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready") &
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" health)"
grep -q '"ok": true' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" codex)"
grep -q '"initialized": true' <<<"$OUT"

APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack sample --output "$TMP_DIR/sample" --quality high --frames 2 >/dev/null
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/sample")"
grep -q '"ok": true' <<<"$OUT"

(cd "$ROOT_DIR/apps/macos" && swift build --product AgentPetCompanion >/dev/null)
OUT="$(cd "$ROOT_DIR/apps/macos" && swift run AgentPetCompanionCoreValidation)"
grep -q 'ok' <<<"$OUT"

echo "M0 validation ok"
