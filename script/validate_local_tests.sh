#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="origin/main"
ARGS=()

while (($#)); do
  case "$1" in
    --base-ref)
      [[ $# -ge 2 ]] || { echo '--base-ref requires a value' >&2; exit 2; }
      BASE_REF="$2"
      shift 2
      ;;
    --domain|--paths-file)
      [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
      ARGS+=("$1" "$2")
      shift 2
      ;;
    --plan-only)
      ARGS+=("$1")
      shift
      ;;
    -h|--help)
      exec "$ROOT_DIR/script/validate_local_tests.py" --help
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ " ${ARGS[*]} " == *" --paths-file "* ]]; then
  exec "$ROOT_DIR/script/validate_local_tests.py" --root "$ROOT_DIR" "${ARGS[@]}"
fi

exec "$ROOT_DIR/script/validate_local_tests.py" \
  --root "$ROOT_DIR" \
  --base-ref "$BASE_REF" \
  "${ARGS[@]}"
