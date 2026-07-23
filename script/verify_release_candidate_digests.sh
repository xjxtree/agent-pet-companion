#!/usr/bin/env bash
set -euo pipefail

DIRECTORY=""
VERSION=""
ARM64_ZIP_SHA256=""
X86_64_ZIP_SHA256=""
ARM64_EVIDENCE_SHA256=""
X86_64_EVIDENCE_SHA256=""
CHECKSUM_SHA256=""

usage() {
  cat <<'EOF'
usage: verify_release_candidate_digests.sh \
  --directory PATH --version X.Y.Z \
  --arm64-zip-sha256 DIGEST \
  --x86_64-zip-sha256 DIGEST \
  --arm64-evidence-sha256 DIGEST \
  --x86_64-evidence-sha256 DIGEST \
  --checksum-sha256 DIGEST

Compares every downloaded candidate file with digests emitted by the trusted
signing job. It performs no archive extraction.
EOF
}

while (($# > 0)); do
  case "$1" in
    --directory) DIRECTORY="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --arm64-zip-sha256) ARM64_ZIP_SHA256="${2:-}"; shift 2 ;;
    --x86_64-zip-sha256) X86_64_ZIP_SHA256="${2:-}"; shift 2 ;;
    --arm64-evidence-sha256) ARM64_EVIDENCE_SHA256="${2:-}"; shift 2 ;;
    --x86_64-evidence-sha256) X86_64_EVIDENCE_SHA256="${2:-}"; shift 2 ;;
    --checksum-sha256) CHECKSUM_SHA256="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$DIRECTORY" && ! -L "$DIRECTORY" ]] || {
  echo '--directory must be a regular directory' >&2
  exit 2
}
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){2}$ ]] || {
  echo '--version must be a three-component semantic version' >&2
  exit 2
}
for digest in \
  "$ARM64_ZIP_SHA256" \
  "$X86_64_ZIP_SHA256" \
  "$ARM64_EVIDENCE_SHA256" \
  "$X86_64_EVIDENCE_SHA256" \
  "$CHECKSUM_SHA256"; do
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'every trusted candidate digest must be a lowercase SHA-256 value' >&2
    exit 2
  }
done

names=(
  "AgentPetCompanion-$VERSION-macos-arm64.zip"
  "AgentPetCompanion-$VERSION-macos-x86_64.zip"
  "AgentPetCompanion-$VERSION-macos-arm64-distribution.json"
  "AgentPetCompanion-$VERSION-macos-x86_64-distribution.json"
  "AgentPetCompanion-$VERSION-SHA256SUMS.txt"
)
expected=(
  "$ARM64_ZIP_SHA256"
  "$X86_64_ZIP_SHA256"
  "$ARM64_EVIDENCE_SHA256"
  "$X86_64_EVIDENCE_SHA256"
  "$CHECKSUM_SHA256"
)

for index in "${!names[@]}"; do
  path="$DIRECTORY/${names[$index]}"
  [[ -f "$path" && ! -L "$path" ]] || {
    printf 'downloaded release candidate is missing regular file %s\n' "${names[$index]}" >&2
    exit 1
  }
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$actual" == "${expected[$index]}" ]] || {
    printf 'downloaded release candidate digest mismatch: %s\n' "${names[$index]}" >&2
    exit 1
  }
done
echo 'Downloaded release candidate matches all five trusted build-job digests'
