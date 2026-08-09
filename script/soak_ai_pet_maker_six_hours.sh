#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${APC_RUN_SIX_HOUR_MAKER_SOAK:-0}" in
  1|true|TRUE|yes|YES) ;;
  *)
    printf '%s\n' \
      'Skipped six-hour AI Pet Maker soak; set APC_RUN_SIX_HOUR_MAKER_SOAK=1 to opt in.'
    exit 0
    ;;
esac

# Keep one real task in its durable waiting-for-user state for just over six
# hours, then let the normal real-AppServer validator reply, finish the task,
# exercise restart/resume, and strictly cancel a second task. The validator
# asserts the backend-authoritative started/ended interval includes this wait.
export APC_VALIDATE_REAL_APP_SERVER=1
export APC_REAL_APP_SERVER_INPUT_WAIT_SECONDS="${APC_REAL_APP_SERVER_INPUT_WAIT_SECONDS:-21660}"
export APC_REAL_APP_SERVER_POLL_SECONDS="${APC_REAL_APP_SERVER_POLL_SECONDS:-0.5}"
export APC_REAL_APP_SERVER_POLL_COUNT="${APC_REAL_APP_SERVER_POLL_COUNT:-57600}"

exec "$ROOT_DIR/script/validate_real_app_server.sh"
