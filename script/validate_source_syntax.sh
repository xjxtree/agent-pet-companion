#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r -d '' path; do
  bash -n "$path"
done < <(find "$ROOT_DIR/script" "$ROOT_DIR/skills" -type f -name '*.sh' -print0)

python3 - "$ROOT_DIR" <<'PY'
import ast
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for base in (root / "script", root / "skills"):
    for path in sorted(base.rglob("*.py")):
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))

for base in (root / "schemas", root / "fixtures", root / "plugins"):
    if not base.exists():
        continue
    for path in sorted(base.rglob("*.json")):
        with path.open(encoding="utf-8") as file:
            json.load(file)

for path in sorted((root / "apps").rglob("*.xcstrings")):
    with path.open(encoding="utf-8") as file:
        json.load(file)
PY

echo 'Shell, Python and JSON source syntax ok'
