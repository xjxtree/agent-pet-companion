#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"
cargo build --workspace >/dev/null

for quality in standard high ultra original; do
  "$ROOT_DIR/target/debug/petcore-cli" petpack sample --output "$TMP_DIR/$quality" --quality "$quality" --frames 1 >/dev/null
  OUT="$("$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/$quality")"
  grep -q '"ok": true' <<<"$OUT"
  OUT="$("$ROOT_DIR/target/debug/petcore-cli" petpack build --input "$TMP_DIR/$quality" --output "$TMP_DIR/$quality.petpack")"
  grep -q '"ok": true' <<<"$OUT"
done

rm -rf "$TMP_DIR/high/assets/frames/tool"
if "$ROOT_DIR/target/debug/petcore-cli" petpack validate "$TMP_DIR/high" >/dev/null 2>&1; then
  echo "expected missing state validation to fail" >&2
  exit 1
fi

OUT="$("$ROOT_DIR/target/debug/petcore-cli" renderer budget --quality high --fps 12)"
grep -q '"renderer_budget_mb": 180' <<<"$OUT"
OUT="$("$ROOT_DIR/target/debug/petcore-cli" renderer budget --quality original --fps 20)"
grep -q '"uses_ring_cache": true' <<<"$OUT"

echo "M2 validation ok"
