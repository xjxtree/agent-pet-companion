#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
  echo 'usage: validate_overlay_performance_summary.sh SUMMARY_JSON REFRESH_HZ' >&2
  exit 2
fi

SUMMARY_PATH="$1"
REFRESH_HZ="$2"

[[ "$SUMMARY_PATH" == /* && -f "$SUMMARY_PATH" && ! -L "$SUMMARY_PATH" ]] || {
  echo 'overlay performance summary must be an absolute regular non-symlink file' >&2
  exit 2
}

python3 -B - "$SUMMARY_PATH" "$REFRESH_HZ" <<'PY'
import json
import math
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
refresh_hz = float(sys.argv[2])
if not math.isfinite(refresh_hz) or refresh_hz <= 0 or refresh_hz > 1_000:
    raise SystemExit("refresh rate must be finite and in (0, 1000]")
if path.stat().st_size <= 0 or path.stat().st_size > 64 * 1024:
    raise SystemExit("overlay performance summary must contain 1..65536 bytes")

data = json.loads(path.read_text(encoding="utf-8"))
expected_keys = {
    "schema_version",
    "presentation_sample_count",
    "completed_interaction_count",
    "event_to_window_apply_ms",
    "handler_cpu_ms",
    "missed_display_link_ratio",
    "release_to_stable_ms",
    "commit_to_convergence_ms",
    "attempt_count",
}
if set(data) != expected_keys:
    raise SystemExit("overlay performance summary fields are not closed")
if data["schema_version"] != "apc.overlay-performance-summary.v1":
    raise SystemExit("overlay performance summary schema mismatch")
if not isinstance(data["presentation_sample_count"], int) or data["presentation_sample_count"] <= 0:
    raise SystemExit("overlay performance summary has no presentation samples")
if not isinstance(data["completed_interaction_count"], int) or data["completed_interaction_count"] <= 0:
    raise SystemExit("overlay performance summary has no completed interactions")

def percentiles(name):
    value = data.get(name)
    if not isinstance(value, dict) or set(value) != {"p50", "p95", "p99"}:
        raise SystemExit(f"{name} percentiles are missing or not closed")
    result = tuple(value[key] for key in ("p50", "p95", "p99"))
    if any(isinstance(item, bool) or not isinstance(item, (int, float)) for item in result):
        raise SystemExit(f"{name} contains a non-numeric percentile")
    result = tuple(float(item) for item in result)
    if any(not math.isfinite(item) or item < 0 for item in result):
        raise SystemExit(f"{name} contains an invalid percentile")
    if not result[0] <= result[1] <= result[2]:
        raise SystemExit(f"{name} percentiles are not monotonic")
    return result

event_latency = percentiles("event_to_window_apply_ms")
handler_cpu = percentiles("handler_cpu_ms")
release_stable = percentiles("release_to_stable_ms")
convergence = percentiles("commit_to_convergence_ms")
attempts = percentiles("attempt_count")
missed_ratio = data["missed_display_link_ratio"]
if isinstance(missed_ratio, bool) or not isinstance(missed_ratio, (int, float)):
    raise SystemExit("missed_display_link_ratio must be numeric")
missed_ratio = float(missed_ratio)
if not math.isfinite(missed_ratio) or not 0 <= missed_ratio <= 1:
    raise SystemExit("missed_display_link_ratio must be in [0, 1]")

refresh_interval_ms = 1_000 / refresh_hz
failures = []
if event_latency[1] > refresh_interval_ms:
    failures.append("event-to-window p95 exceeds one refresh interval")
if event_latency[2] > 2 * refresh_interval_ms:
    failures.append("event-to-window p99 exceeds two refresh intervals")
if handler_cpu[1] > 4:
    failures.append("handler CPU p95 exceeds 4 ms")
if handler_cpu[2] > 8:
    failures.append("handler CPU p99 exceeds 8 ms")
if missed_ratio >= 0.01:
    failures.append("missed display-link ratio is not below 1%")
if attempts[2] > 5:
    failures.append("placement attempt count exceeds five")
if failures:
    raise SystemExit("overlay performance validation failed: " + "; ".join(failures))

print(json.dumps({
    "refresh_hz": refresh_hz,
    "event_to_window_apply_ms": data["event_to_window_apply_ms"],
    "handler_cpu_ms": data["handler_cpu_ms"],
    "missed_display_link_ratio": missed_ratio,
    "release_to_stable_ms": data["release_to_stable_ms"],
    "commit_to_convergence_ms": data["commit_to_convergence_ms"],
    "attempt_count": data["attempt_count"],
    "ok": True,
}, sort_keys=True, separators=(",", ":")))
PY
