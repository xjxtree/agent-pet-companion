#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-event-storm.XXXXXX")"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"
EVENT_COUNT="${APC_EVENT_STORM_COUNT:-180}"
PETCORE_PID=""

cleanup() {
  if [[ -n "$PETCORE_PID" ]]; then
    kill "$PETCORE_PID" >/dev/null 2>&1 || true
    wait "$PETCORE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_json() {
  local json="$1"
  local expr="$2"
  JSON="$json" python3 - "$expr" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON"])
expr = sys.argv[1]
allowed = {"__builtins__": {}, "data": data, "any": any, "all": all, "len": len, "set": set}
if not eval(expr, allowed, {}):
    raise SystemExit(f"assertion failed: {expr}\n{json.dumps(data, ensure_ascii=False, indent=2)}")
PY
}

cd "$ROOT_DIR"
cargo build --workspace >/dev/null

(
  APC_HOME="$TMP_DIR/home" \
  APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  "$ROOT_DIR/target/debug/petcore" serve --ready-file "$TMP_DIR/ready"
) &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

INITIAL_SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
INITIAL_REVISION="$(JSON="$INITIAL_SNAPSHOT" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["JSON"])["revision"])
PY
)"

sources=(codex claude_code pi opencode)
events=(start tool waiting review done failed)
start_seconds="$SECONDS"
for ((index = 0; index < EVENT_COUNT; index++)); do
  source="${sources[$((index % ${#sources[@]}))]}"
  event_type="${events[$((index % ${#events[@]}))]}"
  APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" agent ingest \
    --id "evt_storm_$index" \
    --source "$source" \
    --event-type "$event_type" \
    --title "风暴事件 $index" \
    --session-id "storm-session-$((index % 17))" \
    --project-path "/tmp/apc-storm/$((index % 9))" >/dev/null
done
duration="$((SECONDS - start_seconds))"
if (( duration > 30 )); then
  echo "event storm validation failed: ingesting $EVENT_COUNT events took ${duration}s" >&2
  exit 1
fi

SNAPSHOT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" snapshot)"
assert_json "$SNAPSHOT" 'len(data["events"]) <= 8'
assert_json "$SNAPSHOT" 'data["revision"] != "'"$INITIAL_REVISION"'"'
assert_json "$SNAPSHOT" 'all(event["id"].startswith("evt_storm_") for event in data["events"])'

RECENT="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" events recent --limit "$EVENT_COUNT")"
EVENT_COUNT="$EVENT_COUNT" JSON="$RECENT" python3 - <<'PY'
import json
import os

events = json.loads(os.environ["JSON"])
expected = int(os.environ["EVENT_COUNT"])
ids = {event["id"] for event in events}
assert len(events) == expected, len(events)
assert len(ids) == expected, len(ids)
assert "evt_storm_0" in ids, ids
assert f"evt_storm_{expected - 1}" in ids, ids
PY

WAITED="$(APC_HOME="$TMP_DIR/home" "$ROOT_DIR/target/debug/petcore-cli" state wait --after-revision "$INITIAL_REVISION" --timeout-ms 1000)"
assert_json "$WAITED" 'data["changed"] is True and data["revision"] != "'"$INITIAL_REVISION"'"'
assert_json "$WAITED" 'len(data["events"]) <= 8'

echo "Event storm validation ok"
