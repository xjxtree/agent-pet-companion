#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s "$ROOT_DIR/skills/agent-pet-studio/tests" \
  -p 'test_*.py'

echo 'In-app Pet Studio timing source helper tests passed'
