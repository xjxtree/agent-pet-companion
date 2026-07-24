#!/usr/bin/env bash
set -euo pipefail

TAG=""
COMMIT=""
REMOTE="origin"

usage() {
  cat <<'USAGE'
Usage: verify_remote_release_tag.sh --tag vX.Y.Z --commit FULL_COMMIT [--remote origin]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --commit)
      COMMIT="${2:-}"
      shift 2
      ;;
    --remote)
      REMOTE="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$TAG" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
  echo "release tag must match vX.Y.Z" >&2
  exit 2
}
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "release commit must be a full lowercase Git object ID" >&2
  exit 2
}
[[ -n "$REMOTE" && "$REMOTE" != *$'\n'* ]] || {
  echo "release remote must be a non-empty single-line name" >&2
  exit 2
}

tag_ref="refs/tags/$TAG"
peeled_ref="$tag_ref^{}"
remote_refs="$(
  git ls-remote --tags "$REMOTE" "$tag_ref" "$peeled_ref"
)"

resolved_commit="$(
  printf '%s\n' "$remote_refs" |
    awk -v direct="$tag_ref" -v peeled="$peeled_ref" '
      $2 == direct {
        direct_oid = $1
        direct_count += 1
      }
      $2 == peeled {
        peeled_oid = $1
        peeled_count += 1
      }
      END {
        if (direct_count != 1 || peeled_count > 1) {
          exit 1
        }
        if (peeled_count == 1) {
          print peeled_oid
        } else {
          print direct_oid
        }
      }
    '
)"

[[ "$resolved_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "remote release tag is missing or does not resolve to one commit" >&2
  exit 1
}
[[ "$resolved_commit" == "$COMMIT" ]] || {
  echo "remote release tag no longer targets the protected candidate commit" >&2
  exit 1
}

echo "Remote release tag matches protected candidate: $TAG"
