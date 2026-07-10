#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_require_host_ui_opt_in "renderer runtime validation"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-renderer-runtime.XXXXXX")"
apc_use_isolated_home "$TMP_DIR"
APP_NAME="AgentPetCompanion"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
PETCORE_BINARY="$APP_BUNDLE/Contents/Resources/bin/petcore"
PETCORE_CLI="$APP_BUNDLE/Contents/Resources/bin/petcore-cli"
TELEMETRY_PATH="$TMP_DIR/renderer-telemetry.json"
APP_LOG="$TMP_DIR/app.log"
OWNED_PROTOCOL="$APC_HOME/run/validation-owned-runtime.json"
FRAMES="${APC_RENDERER_RUNTIME_FRAMES:-9}"
METRIC_SAMPLES="${APC_RENDERER_METRIC_SAMPLES:-61}"
METRIC_INTERVAL_SECONDS="${APC_RENDERER_METRIC_INTERVAL_SECONDS:-0.5}"
export LC_ALL=C

if [[ ! "$METRIC_SAMPLES" =~ ^[0-9]+$ ]] || ((METRIC_SAMPLES < 3)); then
  echo "renderer runtime validation failed: APC_RENDERER_METRIC_SAMPLES must be an integer >= 3" >&2
  exit 2
fi
python3 - "$METRIC_INTERVAL_SECONDS" "$METRIC_SAMPLES" <<'PY'
import sys

try:
    interval = float(sys.argv[1])
except ValueError as error:
    raise SystemExit("renderer runtime validation failed: metric interval must be numeric") from error
if interval <= 0:
    raise SystemExit("renderer runtime validation failed: metric interval must be positive")
sample_count = int(sys.argv[2])
if (sample_count - 1) * interval < 30:
    raise SystemExit("renderer runtime validation failed: metric samples must span at least 30 seconds")
PY

cleanup() {
  apc_stop_owned_runtime "$PETCORE_CLI" "$PETCORE_BINARY" "$OWNED_PROTOCOL"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

json_expr() {
  local json="$1"
  local expr="$2"
  JSON="$json" python3 - "$expr" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON"])
expr = sys.argv[1]
if not eval(expr, {"__builtins__": {}, "abs": abs, "len": len}, {"data": data}):
    raise SystemExit(f"assertion failed: {expr}\n{json.dumps(data, ensure_ascii=False, indent=2)}")
PY
}

read_json_file() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as file:
    print(json.dumps(json.load(file), ensure_ascii=False))
PY
}

wait_for_telemetry() {
  local quality="$1"
  local source_kind="$2"
  local fps_profile="$3"
  local expected_fps="$4"
  local extra_expr="$5"
  for _ in {1..120}; do
    if [[ -s "$TELEMETRY_PATH" ]]; then
      local telemetry
      telemetry="$(read_json_file "$TELEMETRY_PATH")"
      if JSON="$telemetry" QUALITY="$quality" SOURCE_KIND="$source_kind" FPS_PROFILE="$fps_profile" EXPECTED_FPS="$expected_fps" EXTRA_EXPR="$extra_expr" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON"])
quality = os.environ["QUALITY"]
source_kind = os.environ["SOURCE_KIND"]
fps_profile = os.environ["FPS_PROFILE"]
expected_fps = int(os.environ["EXPECTED_FPS"])
extra_expr = os.environ["EXTRA_EXPR"]
ok = (
    data.get("quality") == quality
    and data.get("source_kind") == source_kind
    and data.get("fps") == expected_fps
    and data.get("fps_profile") == fps_profile
    and bool(data.get("active")) is True
    and data.get("decode_pipeline") == "actor"
    and data.get("draw_reads_disk") is False
    and int(data.get("actual_draw_count", 0)) > 0
    and float(data.get("measurement_seconds", 0)) >= 0.75
    and float(data.get("observed_fps", 0)) > 0
    and int(data.get("ready_decoded_bytes", 0)) > 0
    and int(data.get("ready_decoded_frame_count", 0)) > 0
    and int(data.get("pipeline_cache_bytes", 0)) > 0
    and int(data.get("pipeline_cache_frame_count", 0)) > 0
    and int(data.get("peak_drawable_texture_allocated_bytes", 0)) > 0
    and int(data.get("peak_metal_device_allocated_bytes", 0)) > 0
    and eval(extra_expr, {"__builtins__": {}, "abs": abs, "len": len}, {"data": data})
)
sys.exit(0 if ok else 1)
PY
      then
        printf '%s\n' "$telemetry"
        return 0
      fi
    fi
    sleep 0.25
  done

  echo "renderer runtime validation failed: telemetry did not match quality=$quality source=$source_kind fps_profile=$fps_profile" >&2
  [[ -s "$TELEMETRY_PATH" ]] && cat "$TELEMETRY_PATH" >&2
  return 1
}

sample_process_metrics() {
  local label="$1"
  local samples_path="$TMP_DIR/$label-process-metrics.tsv"
  : >"$samples_path"
  for ((index = 0; index < METRIC_SAMPLES; index += 1)); do
    ps -o %cpu= -o rss= -o time= -p "$APC_OWNED_APP_PID" \
      | awk 'NF >= 3 { print $1, $2, $3; found=1; exit } END { if (!found) exit 1 }' \
      >>"$samples_path" || {
        echo "renderer runtime validation failed: could not sample app CPU/RSS" >&2
        return 1
      }
    if ((index + 1 < METRIC_SAMPLES)); then
      sleep "$METRIC_INTERVAL_SECONDS"
    fi
  done
  python3 - "$samples_path" "$METRIC_INTERVAL_SECONDS" <<'PY'
import json
import statistics
import sys

samples = []
with open(sys.argv[1], encoding="utf-8") as file:
    for line in file:
        cpu, rss_kb, cpu_time = line.split()
        samples.append((float(cpu), int(rss_kb) / 1024.0, cpu_time))
if not samples:
    raise SystemExit("renderer runtime validation failed: process metric sample is empty")
cpu = [sample[0] for sample in samples]
rss = [sample[1] for sample in samples]
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
        raise SystemExit(f"renderer runtime validation failed: unrecognized ps CPU time {value!r}")
    return days * 86400 + hours * 3600 + minutes * 60 + seconds
sample_interval = float(sys.argv[2])
sample_span = max(0, len(samples) - 1) * sample_interval
cpu_time_delta = max(0.0, cpu_seconds(samples[-1][2]) - cpu_seconds(samples[0][2]))
window_cpu_average = cpu_time_delta / sample_span * 100 if sample_span else 0.0
print(json.dumps({
    "sample_count": len(samples),
    "sample_interval_seconds": sample_interval,
    "sample_span_seconds": sample_span,
    "cpu_average_percent": window_cpu_average,
    "cpu_peak_percent": max(cpu),
    "ps_sample_average_percent": sum(cpu) / len(cpu),
    "cpu_time_delta_seconds": cpu_time_delta,
    "rss_median_mib": statistics.median(rss),
    "rss_peak_mib": max(rss),
}, sort_keys=True))
PY
}

assert_hidden_baseline() {
  local metrics="$1"
  METRICS="$metrics" python3 - <<'PY'
import json
import os

metrics = json.loads(os.environ["METRICS"])
if metrics["sample_count"] < 3:
    raise SystemExit("renderer runtime validation failed: too few hidden baseline samples")
if metrics["cpu_average_percent"] >= 1.0:
    raise SystemExit(
        "renderer runtime validation failed: hidden overlay CPU average "
        f"{metrics['cpu_average_percent']:.2f}% is not below 1%"
    )
PY
}

attach_process_metrics() {
  local telemetry="$1"
  local baseline_metrics="$2"
  local active_metrics="$3"
  local cpu_budget="$4"
  local renderer_memory_budget="$5"
  local minimum_observed_fps="$6"
  TELEMETRY="$telemetry" \
  BASELINE_METRICS="$baseline_metrics" \
  ACTIVE_METRICS="$active_metrics" \
  CPU_BUDGET="$cpu_budget" \
  RENDERER_MEMORY_BUDGET="$renderer_memory_budget" \
  MINIMUM_OBSERVED_FPS="$minimum_observed_fps" \
  python3 - <<'PY'
import json
import os

data = json.loads(os.environ["TELEMETRY"])
baseline = json.loads(os.environ["BASELINE_METRICS"])
active = json.loads(os.environ["ACTIVE_METRICS"])
cpu_budget = float(os.environ["CPU_BUDGET"])
renderer_memory_budget = float(os.environ["RENDERER_MEMORY_BUDGET"])
minimum_observed_fps = float(os.environ["MINIMUM_OBSERVED_FPS"])
renderer_rss_delta = max(0.0, active["rss_peak_mib"] - baseline["rss_median_mib"])

if active["cpu_average_percent"] > cpu_budget:
    raise SystemExit(
        "renderer runtime validation failed: active CPU average "
        f"{active['cpu_average_percent']:.2f}% exceeds {cpu_budget:.2f}%"
    )
if renderer_rss_delta > renderer_memory_budget:
    raise SystemExit(
        "renderer runtime validation failed: active RSS peak delta "
        f"{renderer_rss_delta:.2f} MiB exceeds Renderer budget "
        f"{renderer_memory_budget:.2f} MiB"
    )
if float(data.get("observed_fps", 0)) < minimum_observed_fps:
    raise SystemExit(
        "renderer runtime validation failed: playback observed FPS "
        f"{float(data.get('observed_fps', 0)):.2f} is below the "
        f"{minimum_observed_fps:.2f} FPS tolerance"
    )

data["process_metrics"] = {
    "method": "30-second cumulative process CPU-time delta plus repeated ps RSS samples and tracked decoded/Metal allocations; Renderer memory is active RSS peak minus hidden-overlay RSS median",
    "hidden_baseline": baseline,
    "active": active,
    "renderer_rss_delta_peak_mib": renderer_rss_delta,
    "cpu_average_budget_percent": cpu_budget,
    "renderer_memory_budget_mib": renderer_memory_budget,
    "minimum_observed_fps": minimum_observed_fps,
}
print(json.dumps(data, ensure_ascii=False, sort_keys=True))
PY
}

"$ROOT_DIR/script/build_app_bundle.sh" >/dev/null

HIGH_SOURCE="$TMP_DIR/high-source"
ULTRA_SOURCE="$TMP_DIR/ultra-source"
ORIGINAL_SOURCE="$TMP_DIR/original-source"
"$PETCORE_CLI" petpack sample --output "$HIGH_SOURCE" --quality high --frames "$FRAMES" >/dev/null
"$PETCORE_CLI" petpack sample --output "$ULTRA_SOURCE" --quality ultra --frames "$FRAMES" >/dev/null
"$PETCORE_CLI" petpack sample --output "$ORIGINAL_SOURCE" --quality original --frames "$FRAMES" >/dev/null
mkdir -p "$TMP_DIR/home"

HIGH_BUDGET="$("$PETCORE_CLI" renderer budget --quality high --fps-profile standard)"
json_expr "$HIGH_BUDGET" 'data["fps"] == 12 and data["renderer_budget_mb"] == 180 and data["uses_ring_cache"] is False'
ULTRA_BUDGET="$("$PETCORE_CLI" renderer budget --quality ultra --fps-profile smooth)"
json_expr "$ULTRA_BUDGET" 'data["fps"] == 20 and data["renderer_budget_mb"] == 260 and data["uses_ring_cache"] is False'
ORIGINAL_BUDGET="$("$PETCORE_CLI" renderer budget --quality original --fps-profile smooth)"
json_expr "$ORIGINAL_BUDGET" 'data["fps"] == 20 and data["renderer_budget_mb"] == 420 and data["uses_ring_cache"] is True and data["runtime_cache_frame_limit"] == 9'

HIGH_PET="$(APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" petpack import --offline "$HIGH_SOURCE")"
ULTRA_PET="$(APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" petpack import --offline "$ULTRA_SOURCE")"
ORIGINAL_PET="$(APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" petpack import --offline "$ORIGINAL_SOURCE")"
HIGH_ID="$(JSON="$HIGH_PET" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["JSON"])["id"])
PY
)"
ULTRA_ID="$(JSON="$ULTRA_PET" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["JSON"])["id"])
PY
)"
ORIGINAL_ID="$(JSON="$ORIGINAL_PET" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["JSON"])["id"])
PY
)"

# Import fixtures before the daemon starts so large original-quality packs are
# not constrained by the interactive RPC deadline. The app and PetCore then
# share the already-populated isolated APC_HOME.
export APC_RENDERER_TELEMETRY_PATH="$TELEMETRY_PATH"
apc_start_owned_runtime \
  "$APP_BINARY" \
  "$PETCORE_CLI" \
  "$PETCORE_BINARY" \
  "$APP_LOG" \
  "$OWNED_PROTOCOL"
kill -0 "$APC_OWNED_APP_PID" >/dev/null

STANDARD_BEHAVIOR='{"enabled":true,"status_bubble":true,"click_menu":true,"mouse_passthrough":true,"auto_hide":false,"fps_profile":"standard","sources":{"codex":true,"claude_code":true,"pi":true,"opencode":true},"events":{"start":true,"tool":true,"waiting":true,"review":true,"done":true,"failed":true}}'
SMOOTH_BEHAVIOR='{"enabled":true,"status_bubble":true,"click_menu":true,"mouse_passthrough":true,"auto_hide":false,"fps_profile":"smooth","sources":{"codex":true,"claude_code":true,"pi":true,"opencode":true},"events":{"start":true,"tool":true,"waiting":true,"review":true,"done":true,"failed":true}}'
HIDDEN_BEHAVIOR='{"enabled":false,"status_bubble":true,"click_menu":true,"mouse_passthrough":true,"auto_hide":false,"fps_profile":"smooth","sources":{"codex":true,"claude_code":true,"pi":true,"opencode":true},"events":{"start":true,"tool":true,"waiting":true,"review":true,"done":true,"failed":true}}'
APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" behavior set-json --value-json "$HIDDEN_BEHAVIOR" >/dev/null
sleep 3
BASELINE_METRICS="$(sample_process_metrics hidden)"
assert_hidden_baseline "$BASELINE_METRICS"

APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" behavior set-json --value-json "$STANDARD_BEHAVIOR" >/dev/null
APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" pet activate --id "$HIGH_ID" >/dev/null

HIGH_TELEMETRY="$(wait_for_telemetry high eager standard 12 'data["frame_count"] >= 1 and data["runtime_cache_frame_limit"] == data["frame_count"] and data["estimated_runtime_cache_mb"] <= 180 and data["pipeline_cache_bytes"] <= 180 * 1024 * 1024 and abs(data["canvas_width"] - 384) < 1 and abs(data["canvas_height"] - 416) < 1')"
HIGH_METRICS="$(sample_process_metrics high)"
HIGH_TELEMETRY="$(wait_for_telemetry high eager standard 12 'data["measurement_seconds"] >= 30')"
HIGH_TELEMETRY="$(attach_process_metrics "$HIGH_TELEMETRY" "$BASELINE_METRICS" "$HIGH_METRICS" 4 180 10.8)"

APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" behavior set-json --value-json "$SMOOTH_BEHAVIOR" >/dev/null
APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" pet activate --id "$ULTRA_ID" >/dev/null

ULTRA_TELEMETRY="$(wait_for_telemetry ultra eager smooth 20 'data["frame_count"] >= 1 and data["runtime_cache_frame_limit"] == data["frame_count"] and data["estimated_runtime_cache_mb"] <= 260 and data["pipeline_cache_bytes"] <= 260 * 1024 * 1024 and abs(data["canvas_width"] - 768) < 1 and abs(data["canvas_height"] - 832) < 1')"
ULTRA_METRICS="$(sample_process_metrics ultra)"
ULTRA_TELEMETRY="$(wait_for_telemetry ultra eager smooth 20 'data["measurement_seconds"] >= 30')"
ULTRA_TELEMETRY="$(attach_process_metrics "$ULTRA_TELEMETRY" "$BASELINE_METRICS" "$ULTRA_METRICS" 7 260 18)"

APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" pet activate --id "$ORIGINAL_ID" >/dev/null
ORIGINAL_TELEMETRY="$(wait_for_telemetry original ring smooth 20 'data["frame_count"] >= 9 and data["runtime_cache_frame_limit"] == 9 and data["estimated_runtime_cache_mb"] <= 420 and data["pipeline_cache_bytes"] <= 420 * 1024 * 1024 and abs(data["canvas_width"] - 1536) < 1 and abs(data["canvas_height"] - 1664) < 1')"
ORIGINAL_METRICS="$(sample_process_metrics original)"
ORIGINAL_TELEMETRY="$(wait_for_telemetry original ring smooth 20 'data["measurement_seconds"] >= 30')"
ORIGINAL_TELEMETRY="$(attach_process_metrics "$ORIGINAL_TELEMETRY" "$BASELINE_METRICS" "$ORIGINAL_METRICS" 9 420 18)"

printf 'Renderer runtime validation ok: high=%s ultra=%s original=%s\n' "$HIGH_TELEMETRY" "$ULTRA_TELEMETRY" "$ORIGINAL_TELEMETRY"
