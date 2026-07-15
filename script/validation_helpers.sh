#!/usr/bin/env bash

apc_use_isolated_home() {
  local root="$1"
  local original_home="${HOME:-}"

  if [[ -z "${CARGO_HOME:-}" && -n "$original_home" ]]; then
    export CARGO_HOME="$original_home/.cargo"
  fi
  if [[ -z "${RUSTUP_HOME:-}" && -n "$original_home" ]]; then
    export RUSTUP_HOME="$original_home/.rustup"
  fi

  export HOME="$root/user-home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export APC_AGENT_CONFIG_HOME="$root/agent-home"
  export APC_HOME="$root/home"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$APC_AGENT_CONFIG_HOME" "$APC_HOME"
}

apc_require_host_ui_opt_in() {
  local label="${1:-host UI validation}"

  case "${APC_VALIDATE_HOST_UI:-0}" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    *)
      printf '%s is disabled; rerun with APC_VALIDATE_HOST_UI=1\n' "$label" >&2
      return 2
      ;;
  esac
}

APC_OWNED_APP_PID=""
APC_OWNED_PETCORE_PID=""
APC_OWNED_PROCESS_START=""
APC_OWNED_INSTANCE_ID=""
APC_OWNED_APP_BINARY=""

apc_read_runtime_identity() {
  local petcore_cli="$1"
  local petcore_binary="$2"
  local marker="$APC_HOME/run/runtime.json"
  local health

  health="$("$petcore_cli" health 2>/dev/null)" || return 1
  local identity
  identity="$(HEALTH="$health" python3 - "$marker" "$APC_HOME" <<'PY'
import json
import os
import pathlib
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as file:
        marker = json.load(file)
    health = json.loads(os.environ["HEALTH"])
except (FileNotFoundError, OSError, json.JSONDecodeError, KeyError):
    raise SystemExit(1)

pid = marker.get("pid")
process_start = marker.get("process_start")
instance_id = marker.get("instance_id")
if marker.get("schema_version") != "apc.runtime.v1":
    raise SystemExit(1)
if not isinstance(pid, int) or pid <= 1:
    raise SystemExit(1)
if not isinstance(process_start, str) or not process_start.strip():
    raise SystemExit(1)
if not isinstance(instance_id, str) or not instance_id.strip():
    raise SystemExit(1)
if health.get("ok") is not True or health.get("instance_id") != instance_id:
    raise SystemExit(1)
if pathlib.Path(str(health.get("home", ""))).resolve() != pathlib.Path(sys.argv[2]).resolve():
    raise SystemExit(1)

print(pid, process_start, instance_id, sep="\t")
PY
)" || return 1

  local pid process_start instance_id command managed_runtime_prefix
  IFS=$'\t' read -r pid process_start instance_id <<<"$identity"
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  managed_runtime_prefix="$(python3 - "$APC_HOME" <<'PY'
import os
import sys
print(os.path.normpath(os.path.join(sys.argv[1], "runtime", "versions")))
PY
)"
  [[ -n "$command" ]] || return 1
  [[ "$command" == *"$petcore_binary"* \
    || ("$command" == *"$managed_runtime_prefix"* && "$command" == *"/petcore"*) ]] \
    || return 1
  printf '%s\t%s\t%s\n' "$pid" "$process_start" "$instance_id"
}

apc_write_owned_runtime_protocol() {
  local protocol_path="$1"
  local petcore_binary="$2"

  mkdir -p "$(dirname "$protocol_path")"
  python3 - \
    "$protocol_path" \
    "$APC_OWNED_APP_PID" \
    "$APC_OWNED_PETCORE_PID" \
    "$APC_OWNED_PROCESS_START" \
    "$APC_OWNED_INSTANCE_ID" \
    "$APC_OWNED_APP_BINARY" \
    "$petcore_binary" \
    "$APC_HOME" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
data = {
    "protocol_version": "apc.validation-owned.v1",
    "app_pid": int(sys.argv[2]),
    "petcore_pid": int(sys.argv[3]),
    "schema_version": "apc.runtime.v1",
    "process_start": sys.argv[4],
    "instance_id": sys.argv[5],
    "app_binary": sys.argv[6],
    "petcore_binary": sys.argv[7],
    "apc_home": sys.argv[8],
}
temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
os.replace(temporary, path)
PY
}

apc_start_owned_runtime() {
  local app_binary="$1"
  local petcore_cli="$2"
  local petcore_binary="$3"
  local app_log="$4"
  local protocol_path="$5"

  APC_OWNED_APP_PID=""
  APC_OWNED_PETCORE_PID=""
  APC_OWNED_PROCESS_START=""
  APC_OWNED_INSTANCE_ID=""
  APC_OWNED_APP_BINARY="$app_binary"

  mkdir -p "$(dirname "$app_log")"
  APC_DISABLE_LAUNCH_AGENT=1 "$app_binary" >"$app_log" 2>&1 &
  APC_OWNED_APP_PID="$!"

  local identity pid process_start instance_id parent_pid app_command
  for _ in {1..120}; do
    if ! kill -0 "$APC_OWNED_APP_PID" >/dev/null 2>&1; then
      printf 'owned app exited before its PetCore became healthy: %s\n' "$app_log" >&2
      # The Process-launched PetCore may already have been reparented to
      # launchd. Keep the recorded App identity long enough for the bounded
      # managed-runtime scan in cleanup to claim and stop it.
      apc_stop_owned_runtime "$petcore_cli" "$petcore_binary" "$protocol_path"
      return 1
    fi
    if identity="$(apc_read_runtime_identity "$petcore_cli" "$petcore_binary")"; then
      IFS=$'\t' read -r pid process_start instance_id <<<"$identity"
      parent_pid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ' || true)"
      app_command="$(ps -p "$APC_OWNED_APP_PID" -o command= 2>/dev/null || true)"
      if [[ "$parent_pid" == "$APC_OWNED_APP_PID" \
        && -n "$app_command" \
        && "$app_command" == *"$app_binary"* ]]; then
        APC_OWNED_PETCORE_PID="$pid"
        APC_OWNED_PROCESS_START="$process_start"
        APC_OWNED_INSTANCE_ID="$instance_id"
        apc_write_owned_runtime_protocol "$protocol_path" "$petcore_binary"
        return 0
      fi
    fi
    sleep 0.1
  done

  printf 'owned app PetCore identity did not become verifiable: %s\n' "$app_log" >&2
  apc_stop_owned_runtime "$petcore_cli" "$petcore_binary" "$protocol_path"
  return 1
}

apc_claim_owned_runtime() {
  local petcore_cli="$1"
  local petcore_binary="$2"
  local protocol_path="$3"
  local values

  values="$(python3 - "$protocol_path" "$APC_HOME" "$petcore_binary" <<'PY'
import json
import pathlib
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (FileNotFoundError, OSError, json.JSONDecodeError):
    raise SystemExit(1)
if data.get("protocol_version") != "apc.validation-owned.v1":
    raise SystemExit(1)
if data.get("schema_version") != "apc.runtime.v1":
    raise SystemExit(1)
if pathlib.Path(str(data.get("apc_home", ""))).resolve() != pathlib.Path(sys.argv[2]).resolve():
    raise SystemExit(1)
if pathlib.Path(str(data.get("petcore_binary", ""))).resolve() != pathlib.Path(sys.argv[3]).resolve():
    raise SystemExit(1)
for key in ("app_pid", "petcore_pid"):
    if not isinstance(data.get(key), int) or data[key] <= 1:
        raise SystemExit(1)
for key in ("process_start", "instance_id", "app_binary", "petcore_binary"):
    if not isinstance(data.get(key), str) or not data[key]:
        raise SystemExit(1)
print(
    data["app_pid"], data["petcore_pid"], data["process_start"],
    data["instance_id"], data["app_binary"], sep="\t"
)
PY
)" || return 1
  local claimed_app_pid claimed_petcore_pid claimed_process_start claimed_instance_id claimed_app_binary
  IFS=$'\t' read -r \
    claimed_app_pid \
    claimed_petcore_pid \
    claimed_process_start \
    claimed_instance_id \
    claimed_app_binary <<<"$values"

  kill -0 "$claimed_app_pid" >/dev/null 2>&1 || return 1
  local app_command
  app_command="$(ps -p "$claimed_app_pid" -o command= 2>/dev/null || true)"
  [[ -n "$app_command" && "$app_command" == *"$claimed_app_binary"* ]] || return 1
  local identity pid process_start instance_id
  identity="$(apc_read_runtime_identity "$petcore_cli" "$petcore_binary")" || return 1
  IFS=$'\t' read -r pid process_start instance_id <<<"$identity"
  [[ "$pid" == "$claimed_petcore_pid" \
    && "$process_start" == "$claimed_process_start" \
    && "$instance_id" == "$claimed_instance_id" ]] || return 1

  APC_OWNED_APP_PID="$claimed_app_pid"
  APC_OWNED_PETCORE_PID="$claimed_petcore_pid"
  APC_OWNED_PROCESS_START="$claimed_process_start"
  APC_OWNED_INSTANCE_ID="$claimed_instance_id"
  APC_OWNED_APP_BINARY="$claimed_app_binary"
}

apc_stop_owned_runtime() {
  local petcore_cli="$1"
  local petcore_binary="$2"
  local protocol_path="$3"
  local may_stop_petcore=0
  local owned_child_pid=""

  if [[ -z "$APC_OWNED_APP_PID" && -f "$protocol_path" ]]; then
    apc_claim_owned_runtime "$petcore_cli" "$petcore_binary" "$protocol_path" || true
  fi

  if [[ -n "$APC_OWNED_PETCORE_PID" ]]; then
    local identity pid process_start instance_id
    if identity="$(apc_read_runtime_identity "$petcore_cli" "$petcore_binary")"; then
      IFS=$'\t' read -r pid process_start instance_id <<<"$identity"
      if [[ "$pid" == "$APC_OWNED_PETCORE_PID" \
        && "$process_start" == "$APC_OWNED_PROCESS_START" \
        && "$instance_id" == "$APC_OWNED_INSTANCE_ID" ]]; then
        may_stop_petcore=1
      fi
    fi
  fi

  local app_command=""
  if [[ -n "$APC_OWNED_APP_PID" ]]; then
    app_command="$(ps -p "$APC_OWNED_APP_PID" -o command= 2>/dev/null || true)"
  fi

  # AppKit/Process children are reparented when the UI host exits. Search all
  # processes only for a PetCore executable inside this validation's isolated
  # APC_HOME/runtime/versions tree; this cannot match the user's global
  # Application Support runtime or an unrelated PetCore.
  local candidate_pid candidate_command managed_runtime_prefix
  managed_runtime_prefix="$(python3 - "$APC_HOME" <<'PY'
import os
import sys
print(os.path.normpath(os.path.join(sys.argv[1], "runtime", "versions")))
PY
)"
  while read -r candidate_pid candidate_command; do
    [[ "$candidate_pid" =~ ^[0-9]+$ ]] || continue
    while [[ "$candidate_command" == *"//"* ]]; do
      candidate_command="${candidate_command//\/\//\/}"
    done
    if [[ "$candidate_command" == *"$managed_runtime_prefix"/*"/petcore serve "* ]]; then
      owned_child_pid="$candidate_pid"
      break
    fi
  done < <(ps -axo pid=,command= 2>/dev/null || true)

  if [[ -z "$owned_child_pid" && -n "$APC_OWNED_APP_PID" ]]; then
    # Retain the parent-scoped fallback for test fixtures that use a synthetic
    # PetCore command outside the staged runtime tree.
    managed_runtime_prefix="$(python3 - "$APC_HOME" <<'PY'
import os
import sys
print(os.path.normpath(os.path.join(sys.argv[1], "runtime", "versions")))
PY
)"
    while IFS= read -r candidate_pid; do
      [[ "$candidate_pid" =~ ^[0-9]+$ ]] || continue
      candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
      if [[ "$candidate_command" == "$managed_runtime_prefix"/*"/petcore serve "* ]]; then
        owned_child_pid="$candidate_pid"
        break
      fi
    done < <(pgrep -P "$APC_OWNED_APP_PID" 2>/dev/null || true)
  fi
  if [[ -n "$APC_OWNED_APP_PID" \
    && -n "$APC_OWNED_APP_BINARY" \
    && "$app_command" == *"$APC_OWNED_APP_BINARY"* ]]; then
    kill "$APC_OWNED_APP_PID" >/dev/null 2>&1 || true
    wait "$APC_OWNED_APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$may_stop_petcore" == "1" ]]; then
    kill "$APC_OWNED_PETCORE_PID" >/dev/null 2>&1 || true
    for _ in {1..50}; do
      kill -0 "$APC_OWNED_PETCORE_PID" >/dev/null 2>&1 || break
      sleep 0.02
    done
    if kill -0 "$APC_OWNED_PETCORE_PID" >/dev/null 2>&1; then
      kill -KILL "$APC_OWNED_PETCORE_PID" >/dev/null 2>&1 || true
    fi
  elif [[ -n "$owned_child_pid" ]]; then
    kill "$owned_child_pid" >/dev/null 2>&1 || true
    for _ in {1..50}; do
      kill -0 "$owned_child_pid" >/dev/null 2>&1 || break
      sleep 0.02
    done
    if kill -0 "$owned_child_pid" >/dev/null 2>&1; then
      kill -KILL "$owned_child_pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$protocol_path"

  APC_OWNED_APP_PID=""
  APC_OWNED_PETCORE_PID=""
  APC_OWNED_PROCESS_START=""
  APC_OWNED_INSTANCE_ID=""
  APC_OWNED_APP_BINARY=""
}
