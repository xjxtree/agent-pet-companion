#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/script/validate_m0.sh"
"$ROOT_DIR/script/validate_m1.sh"
"$ROOT_DIR/script/validate_m2.sh"
"$ROOT_DIR/script/validate_m3.sh"
"$ROOT_DIR/script/validate_m4.sh"
"$ROOT_DIR/script/validate_m5.sh"
"$ROOT_DIR/script/validate_m6.sh"

echo "All Agent Pet Companion validations passed"
