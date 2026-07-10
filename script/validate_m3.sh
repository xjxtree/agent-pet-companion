#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-m3.XXXXXX")"
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
(APC_HOME="$TMP_DIR/home" APC_DISABLE_CODEX_APP_SERVER_AUTO=1 APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK=1 "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready") &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

FORM='{"description":"安静陪伴的东方幻想角色","style":"半写实","quality":"high","reference_images":[]}'
JOB_JSON="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation start --form-json "$FORM")"
JOB_ID="$(printf '%s\n' "$JOB_JSON" | sed -n 's/.*"job_id": "\(.*\)".*/\1/p')"
[[ -n "$JOB_ID" ]]

for _ in {1..300}; do
  MESSAGES="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation messages --job-id "$JOB_ID")"
  printf '%s\n' "$MESSAGES" | grep -q '完成，可在宠物库启用' && break
  sleep 0.1
done
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" generation messages --job-id "$JOB_ID")"
grep -q '完成，可在宠物库启用' <<<"$OUT"
OUT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
grep -q '"pets"' <<<"$OUT"
PETPACK_PATH="$(SNAPSHOT="$OUT" python3 - <<'PY'
import json, os
data = json.loads(os.environ["SNAPSHOT"])
print(data["pets"][0]["petpack_path"])
PY
)"
PET_ID="$(SNAPSHOT="$OUT" python3 - <<'PY'
import json, os
data = json.loads(os.environ["SNAPSHOT"])
print(data["pets"][0]["id"])
PY
)"
[[ -f "$(dirname "$PETPACK_PATH")/$PET_ID-frames/tool/0023.png" ]]

echo "M3 validation ok"
