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
import re
import sys
import urllib.parse

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

ignored_parts = {".git", ".build", "dist", "target"}
markdown_link = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
broken_links = []
for path in sorted(root.rglob("*.md")):
    if ignored_parts.intersection(path.relative_to(root).parts):
        continue
    source = path.read_text(encoding="utf-8")
    for match in markdown_link.finditer(source):
        value = match.group(1).strip()
        if value.startswith("<") and ">" in value:
            value = value[1:value.index(">")]
        elif value:
            value = value.split(maxsplit=1)[0]
        if not value or value.startswith(("#", "http://", "https://", "mailto:", "app://")):
            continue
        local_path = urllib.parse.unquote(value.split("#", 1)[0])
        if not (path.parent / local_path).resolve().exists():
            line = source.count("\n", 0, match.start()) + 1
            broken_links.append(f"{path.relative_to(root)}:{line}: {value}")

if broken_links:
    raise SystemExit("broken local Markdown links:\n" + "\n".join(broken_links))
PY

echo 'Shell, Python, JSON and local Markdown link syntax ok'
