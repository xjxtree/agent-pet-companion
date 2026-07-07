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

FORM='{"description":"安静陪伴的东方幻想角色","style":"半写实","quality":"high","reference_images":[],"note":null}'
JOB_JSON="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation start --form-json "$FORM")"
JOB_ID="$(printf '%s\n' "$JOB_JSON" | sed -n 's/.*"job_id": "\(.*\)".*/\1/p')"
[[ -n "$JOB_ID" ]]

for _ in {1..80}; do
  MESSAGES="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation messages --job-id "$JOB_ID")"
  printf '%s\n' "$MESSAGES" | grep -q '完成，可在宠物库启用' && break
  sleep 0.1
done
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation messages --job-id "$JOB_ID")"
grep -q '完成，可在宠物库启用' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
grep -q '"pets"' <<<"$OUT"

echo "M3 validation ok"
