#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "renderer runtime validation"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-renderer-runtime.XXXXXX")"
apc_use_isolated_home "$TMP_DIR"
APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AgentPetCompanion"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="$APP_BUNDLE/Contents/Resources/bin/petcore-cli"
TELEMETRY_PATH="$TMP_DIR/renderer-telemetry.json"
APP_LOG="$TMP_DIR/app.log"
OWNED_PROTOCOL="$APC_HOME/run/validation-owned-runtime.json"
METRIC_SAMPLES="${APC_RENDERER_METRIC_SAMPLES:-61}"
METRIC_INTERVAL_SECONDS="${APC_RENDERER_METRIC_INTERVAL_SECONDS:-0.5}"
export LC_ALL=C

if [[ ! "$METRIC_SAMPLES" =~ ^[0-9]+$ ]] || ((METRIC_SAMPLES < 3)); then
  echo "renderer runtime validation failed: APC_RENDERER_METRIC_SAMPLES must be an integer >= 3" >&2
  exit 2
fi
python3 - "$METRIC_INTERVAL_SECONDS" "$METRIC_SAMPLES" <<'PY'
import sys

interval = float(sys.argv[1])
samples = int(sys.argv[2])
if interval <= 0 or (samples - 1) * interval < 30:
    raise SystemExit(
        "renderer runtime validation failed: metric samples must span at least 30 seconds"
    )
PY

cleanup() {
  local status="$?"
  if ((status != 0)); then
    [[ -s "$TELEMETRY_PATH" ]] && cat "$TELEMETRY_PATH" >&2
    [[ -s "$APP_LOG" ]] && tail -n 80 "$APP_LOG" >&2
  fi
  apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
  rm -rf "$TMP_DIR"
  return "$status"
}
trap cleanup EXIT

assert_json() {
  local json="$1"
  local expression="$2"
  JSON="$json" EXPRESSION="$expression" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON"])
expression = os.environ["EXPRESSION"]
if not eval(
    expression,
    {"__builtins__": {}, "abs": abs, "len": len, "set": set},
    {"data": data},
):
    raise SystemExit(
        f"renderer assertion failed: {expression}\n"
        f"{json.dumps(data, ensure_ascii=False, indent=2)}"
    )
PY
}

wait_for_telemetry() {
  local quality="$1"
  local minimum_seconds="$2"
  local expected_width="$3"
  local expected_height="$4"
  for _ in {1..160}; do
    if [[ -s "$TELEMETRY_PATH" ]] && \
      QUALITY="$quality" \
      MINIMUM_SECONDS="$minimum_seconds" \
      EXPECTED_WIDTH="$expected_width" \
      EXPECTED_HEIGHT="$expected_height" \
      TELEMETRY_PATH="$TELEMETRY_PATH" \
      python3 - <<'PY'
import json
import os
import sys

try:
    with open(os.environ["TELEMETRY_PATH"], encoding="utf-8") as file:
        data = json.load(file)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

durations = [150, 150, 150, 150, 170, 230]
legacy = {
    "fps_profile",
    "native_fps",
    "fps",
    "duration_ms",
    "sampled_frame_count",
    "observed_fps",
}
ok = (
    data.get("quality") == os.environ["QUALITY"]
    and data.get("state") == "waiting"
    and data.get("source_kind") == "eager"
    and data.get("frame_durations_ms") == durations
    and data.get("total_duration_ms") == sum(durations)
    and data.get("playback_mode") == "burst_then_settle"
    and data.get("entry_repeat_count") == 2
    and data.get("settle_frame_index") == 5
    and data.get("reduced_motion_frame_index") == 4
    and data.get("source_frame_count") == len(durations)
    and data.get("frame_count") == len(durations)
    and bool(data.get("active")) is True
    and int(data.get("canvas_width", 0)) == int(os.environ["EXPECTED_WIDTH"])
    and int(data.get("canvas_height", 0)) == int(os.environ["EXPECTED_HEIGHT"])
    and int(data.get("ready_decoded_frame_count", 0)) == len(durations)
    and int(data.get("pipeline_cache_frame_count", 0)) >= len(durations)
    and int(data.get("pipeline_cache_bytes", 0)) > 0
    and data.get("decode_pipeline") == "actor"
    and data.get("draw_reads_disk") is False
    and float(data.get("measurement_seconds", 0)) >= float(os.environ["MINIMUM_SECONDS"])
    and not legacy.intersection(data)
)
sys.exit(0 if ok else 1)
PY
    then
      python3 - "$TELEMETRY_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    print(json.dumps(json.load(file), ensure_ascii=False, sort_keys=True))
PY
      return 0
    fi
    sleep 0.25
  done
  echo "renderer runtime validation failed: V3 telemetry did not settle for $quality" >&2
  return 1
}

sample_process_metrics() {
  local label="$1"
  local path="$TMP_DIR/$label-process-metrics.tsv"
  : >"$path"
  for ((index = 0; index < METRIC_SAMPLES; index += 1)); do
    ps -o %cpu= -o rss= -o time= -p "$APC_OWNED_APP_PID" \
      | awk 'NF >= 3 { print $1, $2, $3; found=1; exit } END { if (!found) exit 1 }' \
      >>"$path"
    if ((index + 1 < METRIC_SAMPLES)); then
      sleep "$METRIC_INTERVAL_SECONDS"
    fi
  done
  python3 - "$path" "$METRIC_INTERVAL_SECONDS" <<'PY'
import json
import statistics
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as file:
    for line in file:
        cpu, rss_kb, cpu_time = line.split()
        rows.append((float(cpu), int(rss_kb) / 1024.0, cpu_time))

def cpu_seconds(value):
    days = 0
    if "-" in value:
        day, value = value.split("-", 1)
        days = int(day)
    parts = [float(part) for part in value.split(":")]
    if len(parts) == 2:
        hours, minutes, seconds = 0, parts[0], parts[1]
    elif len(parts) == 3:
        hours, minutes, seconds = parts
    else:
        raise SystemExit(f"unrecognized ps CPU time: {value}")
    return days * 86400 + hours * 3600 + minutes * 60 + seconds

span = max(0, len(rows) - 1) * float(sys.argv[2])
delta = max(0.0, cpu_seconds(rows[-1][2]) - cpu_seconds(rows[0][2]))
print(json.dumps({
    "sample_count": len(rows),
    "sample_span_seconds": span,
    "cpu_average_percent": delta / span * 100 if span else 0.0,
    "rss_median_mib": statistics.median(row[1] for row in rows),
    "rss_peak_mib": max(row[1] for row in rows),
}, sort_keys=True))
PY
}

assert_hidden_baseline() {
  METRICS="$1" python3 - <<'PY'
import json
import os

metrics = json.loads(os.environ["METRICS"])
if metrics["cpu_average_percent"] >= 1.0:
    raise SystemExit(
        "renderer runtime validation failed: hidden overlay CPU average "
        f"{metrics['cpu_average_percent']:.2f}% is not below 1%"
    )
PY
}

"$ROOT_DIR/script/build_app_bundle.sh" >/dev/null

LOW_BUDGET="$("$PETCORE_CLI" renderer budget --quality low --frame-count 2)"
STANDARD_BUDGET="$("$PETCORE_CLI" renderer budget --quality standard --frame-count 8)"
STANDARD_MAX_BUDGET="$("$PETCORE_CLI" renderer budget --quality standard --frame-count 40)"
HIGH_BUDGET="$("$PETCORE_CLI" renderer budget --quality high --frame-count 8)"
HIGH_MAX_BUDGET="$("$PETCORE_CLI" renderer budget --quality high --frame-count 40)"
assert_json "$LOW_BUDGET" 'data["quality"] == "low" and data["frame_count"] == 2 and data["runtime_cache_frame_limit"] == 2 and data["uses_ring_cache"] is False'
assert_json "$STANDARD_BUDGET" 'data["quality"] == "standard" and data["frame_count"] == 8 and data["runtime_cache_frame_limit"] == 8 and data["uses_ring_cache"] is False'
assert_json "$STANDARD_MAX_BUDGET" 'data["quality"] == "standard" and data["frame_count"] == 40 and data["runtime_cache_frame_limit"] == 40 and data["uses_ring_cache"] is False'
assert_json "$HIGH_BUDGET" 'data["quality"] == "high" and data["frame_count"] == 8 and data["runtime_cache_frame_limit"] == 8 and data["uses_ring_cache"] is False'
assert_json "$HIGH_MAX_BUDGET" 'data["quality"] == "high" and data["frame_count"] == 40 and data["runtime_cache_frame_limit"] == 40 and data["uses_ring_cache"] is False'

declare -a PET_IDS=()
for quality in low standard high; do
  source_dir="$TMP_DIR/$quality-source"
  "$PETCORE_CLI" petpack sample --output "$source_dir" --quality "$quality" >/dev/null
  imported="$(APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" petpack import --offline "$source_dir")"
  assert_json "$imported" 'data["quality"] in {"low", "standard", "high"} and len(data["states"]) == 9 and len(data["states"][3]["frame_durations_ms"]) == 6'
  PET_IDS+=("$(JSON="$imported" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["JSON"])["id"])
PY
)")
done

export APC_RENDERER_TELEMETRY_PATH="$TELEMETRY_PATH"
apc_start_owned_runtime \
  "$APP_BINARY" \
  "$PETCORE_CLI" \
  "$PETCORE_BINARY" \
  "$APP_LOG" \
  "$OWNED_PROTOCOL"

APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" behavior set-json --value-json '{"enabled":false}' >/dev/null
sleep 2
BASELINE_METRICS="$(sample_process_metrics hidden)"
assert_hidden_baseline "$BASELINE_METRICS"
APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" behavior set-json --value-json '{"enabled":true}' >/dev/null

activate_waiting_state() {
  local quality="$1"
  local pet_id="$2"
  rm -f "$TELEMETRY_PATH"
  APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" pet activate --id "$pet_id" >/dev/null
  APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" agent ingest \
    --source codex \
    --event-type waiting \
    --id "renderer-v3-${quality}-$$" \
    --session-id "renderer-v3-${quality}" \
    --title "Renderer V3 timing" \
    --payload-json '{"schema_version":"apc.agent-event.v1","diagnostic":false,"session_active":true,"session_open":true,"interaction_kind":"input_required"}' \
    >/dev/null
}

activate_waiting_state low "${PET_IDS[0]}"
LOW_TELEMETRY="$(wait_for_telemetry low 1 192 208)"
activate_waiting_state standard "${PET_IDS[1]}"
STANDARD_TELEMETRY="$(wait_for_telemetry standard 10 384 416)"
activate_waiting_state high "${PET_IDS[2]}"
HIGH_TELEMETRY="$(wait_for_telemetry high 10 576 624)"
ACTIVE_METRICS="$(sample_process_metrics high)"

TELEMETRY="$HIGH_TELEMETRY" \
BASELINE="$BASELINE_METRICS" \
ACTIVE="$ACTIVE_METRICS" \
python3 - <<'PY'
import json
import os

telemetry = json.loads(os.environ["TELEMETRY"])
baseline = json.loads(os.environ["BASELINE"])
active = json.loads(os.environ["ACTIVE"])
if telemetry["actual_draw_count"] > telemetry["frame_count"] + 2:
    raise SystemExit(
        "renderer runtime validation failed: burst_then_settle kept drawing after settling"
    )
if telemetry["observed_draws_per_second"] >= 1:
    raise SystemExit(
        "renderer runtime validation failed: settled renderer still draws continuously"
    )
if active["cpu_average_percent"] > 4:
    raise SystemExit(
        "renderer runtime validation failed: settled renderer CPU average exceeds 4%"
    )
if max(0, active["rss_peak_mib"] - baseline["rss_median_mib"]) > 165:
    raise SystemExit(
        "renderer runtime validation failed: high-tier renderer exceeds memory budget"
    )
PY

printf 'Renderer V3 runtime validation ok: low=%s standard=%s high=%s\n' \
  "$LOW_TELEMETRY" "$STANDARD_TELEMETRY" "$HIGH_TELEMETRY"
