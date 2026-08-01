#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/apps/macos"
ATTESTATION_OUT=""
BUILD_ID=""

usage() {
  echo 'usage: validate_overlay_interaction.sh [--attestation-out ABSOLUTE_PATH --build-id BUILD_ID]'
}

while (($# > 0)); do
  case "$1" in
    --attestation-out)
      (($# >= 2)) || { usage >&2; exit 2; }
      ATTESTATION_OUT="$2"
      shift 2
      ;;
    --build-id)
      (($# >= 2)) || { usage >&2; exit 2; }
      BUILD_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$ATTESTATION_OUT" || -n "$BUILD_ID" ]]; then
  [[ "$ATTESTATION_OUT" == /* ]] || {
    echo 'interaction attestation output must be an absolute path' >&2
    exit 2
  }
  [[ "$BUILD_ID" =~ ^[A-Za-z0-9._+-]{1,128}$ ]] || {
    echo 'interaction attestation build_id is invalid' >&2
    exit 2
  }
  mkdir -p "$(dirname "$ATTESTATION_OUT")"
fi

# Real pointer, Space, focus-loss, and multi-display acceptance is performed
# with Computer Use. This script deliberately contains no synthesized input or
# app-launch automation; it locks the same interaction invariants with
# deterministic tests that are safe to run unattended.
for suite in \
  OverlayPlacementAuthorityTests \
  AppStoreOverlaySnapshotTests \
  OverlayGeometryTests \
  OverlayDisplayWidthTests; do
  swift test \
    --package-path "$MACOS_DIR" \
    --filter "$suite" \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors
done

if [[ -n "$ATTESTATION_OUT" ]]; then
  python3 -B - \
    "$ROOT_DIR" \
    "$ROOT_DIR/script/interaction-contract-files.txt" \
    "$ATTESTATION_OUT" \
    "$BUILD_ID" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
list_path = pathlib.Path(sys.argv[2])
output = pathlib.Path(sys.argv[3])
build_id = sys.argv[4]
entries = [line for line in list_path.read_text(encoding="utf-8").splitlines() if line]
if not entries or entries != sorted(set(entries)):
    raise SystemExit("interaction contract file list must be sorted, unique, and non-empty")

digest = hashlib.sha256()
for entry in entries:
    relative = pathlib.PurePosixPath(entry)
    if relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
        raise SystemExit(f"unsafe interaction contract path: {entry}")
    path = root.joinpath(*relative.parts)
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise SystemExit(f"interaction contract entry is not a regular file: {entry}")
    digest.update(entry.encode("utf-8"))
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")

payload = {
    "schema_version": "apc.overlay-interaction-attestation.v1",
    "build_id": build_id,
    "interaction_contract_digest": digest.hexdigest(),
    "passed_suites": [
        "OverlayPlacementAuthorityTests",
        "AppStoreOverlaySnapshotTests",
        "OverlayGeometryTests",
        "OverlayDisplayWidthTests",
    ],
    "ok": True,
}
output.parent.mkdir(parents=True, exist_ok=True)
descriptor, temporary_name = tempfile.mkstemp(
    prefix=f".{output.name}.", dir=output.parent
)
try:
    os.fchmod(descriptor, 0o644)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_name, output)
finally:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
PY
fi

echo "Overlay interaction contract validation ok; live pointer acceptance remains a Computer Use gate"
