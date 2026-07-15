#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="development"
APP_BUNDLE="$ROOT_DIR/dist/AgentPetCompanion.app"

usage() {
  echo 'usage: validate_app_bundle.sh [--development|--distribution] [APP_BUNDLE]'
}

while (($# > 0)); do
  case "$1" in
    --development)
      MODE="development"
      shift
      ;;
    --distribution)
      MODE="distribution"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -* )
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      APP_BUNDLE="$1"
      shift
      (($# == 0)) || { usage >&2; exit 2; }
      ;;
  esac
done
APP_NAME="AgentPetCompanion"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
APP_RESOURCES="$APP_CONTENTS/Resources"
PETCORE="$APP_RESOURCES/bin/petcore"
PETCORE_CLI="$APP_RESOURCES/bin/petcore-cli"
RUNTIME_MANIFEST="$APP_RESOURCES/runtime-manifest.json"
BUNDLED_SKILL="$APP_RESOURCES/skills/agent-pet-studio/SKILL.md"
SOURCE_SKILL="$ROOT_DIR/skills/agent-pet-studio/SKILL.md"
LOCALIZATION_BUNDLE="$APP_RESOURCES/AgentPetCompanion_AgentPetCompanion.bundle"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-bundle-validation.XXXXXX")"
. "$ROOT_DIR/script/validation_helpers.sh"
apc_use_isolated_home "$TMP_DIR"
PETCORE_PID=""

cleanup() {
  if [[ -n "$PETCORE_PID" ]]; then
    kill "$PETCORE_PID" >/dev/null 2>&1 || true
    wait "$PETCORE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[[ -d "$APP_BUNDLE" ]] || {
  echo "app bundle validation failed: missing bundle $APP_BUNDLE" >&2
  exit 1
}
[[ -x "$APP_BINARY" ]] || {
  echo "app bundle validation failed: missing executable $APP_BINARY" >&2
  exit 1
}
[[ -x "$PETCORE" ]] || {
  echo "app bundle validation failed: missing bundled petcore $PETCORE" >&2
  exit 1
}
[[ -x "$PETCORE_CLI" ]] || {
  echo "app bundle validation failed: missing bundled petcore-cli $PETCORE_CLI" >&2
  exit 1
}
[[ -f "$RUNTIME_MANIFEST" ]] || {
  echo "app bundle validation failed: missing runtime manifest $RUNTIME_MANIFEST" >&2
  exit 1
}
[[ -f "$BUNDLED_SKILL" ]] || {
  echo "app bundle validation failed: missing bundled agent-pet-studio skill" >&2
  exit 1
}
[[ -f "$LOCALIZATION_BUNDLE/Localizable.xcstrings" ]] || {
  echo "app bundle validation failed: missing bundled String Catalog" >&2
  exit 1
}
[[ -f "$LOCALIZATION_BUNDLE/en.lproj/Localizable.strings" ]] || {
  echo "app bundle validation failed: missing bundled English localization" >&2
  exit 1
}
if ! find "$LOCALIZATION_BUNDLE" -maxdepth 2 -type f \
  -ipath '*/zh-hans.lproj/Localizable.strings' -print -quit | grep -q .; then
  echo "app bundle validation failed: missing bundled Simplified Chinese localization" >&2
  exit 1
fi
cmp -s "$SOURCE_SKILL" "$BUNDLED_SKILL" || {
  echo "app bundle validation failed: bundled agent-pet-studio skill differs from source" >&2
  exit 1
}

python3 - "$APP_CONTENTS/Info.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as file:
    info = plistlib.load(file)

expected = {
    "CFBundleExecutable": "AgentPetCompanion",
    "CFBundleIdentifier": "dev.agentpet.companion",
    "CFBundleName": "AgentPetCompanion",
    "CFBundlePackageType": "APPL",
    "NSPrincipalClass": "NSApplication",
}
for key, value in expected.items():
    actual = info.get(key)
    if actual != value:
        raise SystemExit(f"app bundle validation failed: {key}={actual!r}, expected {value!r}")

minimum = info.get("LSMinimumSystemVersion")
if minimum != "14.0":
    raise SystemExit(
        f"app bundle validation failed: LSMinimumSystemVersion={minimum!r}, expected '14.0'"
    )

version = info.get("CFBundleShortVersionString")
build = info.get("CFBundleVersion")
build_id = info.get("APCBuildID")
release_channel = info.get("APCReleaseChannel")
runtime_manifest_schema = info.get("APCRuntimeManifestSchemaVersion")
if not isinstance(version, str) or not version.strip():
    raise SystemExit("app bundle validation failed: missing CFBundleShortVersionString")
if not isinstance(build, str) or not build.strip():
    raise SystemExit("app bundle validation failed: missing CFBundleVersion")
if not isinstance(build_id, str) or not build_id.strip():
    raise SystemExit("app bundle validation failed: missing APCBuildID")
if release_channel not in {"develop", "release"}:
    raise SystemExit("app bundle validation failed: invalid APCReleaseChannel")
if runtime_manifest_schema != "apc.runtime-manifest.v1":
    raise SystemExit("app bundle validation failed: invalid APCRuntimeManifestSchemaVersion")

exported_types = info.get("UTExportedTypeDeclarations")
if not isinstance(exported_types, list):
    raise SystemExit("app bundle validation failed: missing UTExportedTypeDeclarations")
petpack = next(
    (
        declaration
        for declaration in exported_types
        if declaration.get("UTTypeIdentifier") == "dev.agentpet.petpack"
    ),
    None,
)
if petpack is None:
    raise SystemExit("app bundle validation failed: missing dev.agentpet.petpack UTI")
if "public.data" not in petpack.get("UTTypeConformsTo", []):
    raise SystemExit("app bundle validation failed: dev.agentpet.petpack must conform to public.data")
extensions = petpack.get("UTTypeTagSpecification", {}).get("public.filename-extension", [])
if extensions != ["petpack"]:
    raise SystemExit(
        "app bundle validation failed: dev.agentpet.petpack filename extension must be petpack"
    )
PY

grep -q '^name: agent-pet-studio$' "$BUNDLED_SKILL"
grep -q 'APC_PETCORE_CLI' "$BUNDLED_SKILL"
grep -q 'Do not read agent auth' "$BUNDLED_SKILL"

APC_HOME="$TMP_DIR/home" "$PETCORE" preflight \
  --home "$TMP_DIR/home" \
  --manifest "$RUNTIME_MANIFEST" >/dev/null

APC_HOME="$TMP_DIR/home" "$PETCORE" init

BUNDLE_BUILD_ID="$(python3 - "$APP_CONTENTS/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as file:
    print(plistlib.load(file)["APCBuildID"])
PY
)"

BUDGET="$("$PETCORE_CLI" renderer budget --quality high --fps-profile standard)"
JSON="$BUDGET" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON"])
assert data["quality"] == "high", data
assert data["fps"] == 12, data
assert data["renderer_budget_mb"] == 180, data
PY

(
  APC_HOME="$TMP_DIR/home" \
  APC_AGENT_CONFIG_HOME="$TMP_DIR/agent-home" \
  APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  APC_EXPECTED_BUILD_ID="$BUNDLE_BUILD_ID" \
  APC_EXPECTED_RUNTIME_MANIFEST="$RUNTIME_MANIFEST" \
  "$PETCORE" serve --ready-file "$TMP_DIR/ready"
) &
PETCORE_PID="$!"
for _ in {1..100}; do
  [[ -f "$TMP_DIR/ready" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/ready" ]]

HEALTH="$(APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" health)"
HEALTH="$HEALTH" BUNDLE_BUILD_ID="$BUNDLE_BUILD_ID" RUNTIME_MANIFEST="$RUNTIME_MANIFEST" python3 - <<'PY'
import json
import os

health = json.loads(os.environ["HEALTH"])
expected = os.environ["BUNDLE_BUILD_ID"]
with open(os.environ["RUNTIME_MANIFEST"], "r", encoding="utf-8") as file:
    manifest = json.load(file)
if health.get("build_id") != expected:
    raise SystemExit(
        f"app bundle validation failed: PetCore build_id={health.get('build_id')!r}, expected {expected!r}"
    )
if health.get("runtime_manifest") != manifest:
    raise SystemExit("app bundle validation failed: PetCore runtime manifest mismatch")
PY

for source in codex claude_code pi opencode; do
  APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" connections repair --source "$source" >/dev/null
done

grep -qF "$PETCORE_CLI" \
  "$TMP_DIR/agent-home/.agents/plugins/plugins/agent-pet-companion/hooks/hooks.json"
grep -qF "$PETCORE_CLI" "$TMP_DIR/agent-home/.claude/settings.json"
grep -qF "$PETCORE_CLI" "$TMP_DIR/home/connectors/claude-code/agent-pet-companion-hook.sh"
grep -qF "$PETCORE_CLI" "$TMP_DIR/agent-home/.pi/agent/extensions/agent-pet-companion.ts"
grep -qF "$PETCORE_CLI" "$TMP_DIR/agent-home/.config/opencode/plugins/agent-pet-companion.js"

if [[ "$MODE" == "distribution" ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || {
    echo 'distribution validation requires Darwin' >&2
    exit 1
  }
  for dependency in codesign lipo spctl xcrun; do
    command -v "$dependency" >/dev/null 2>&1 || {
      printf 'distribution validation requires %s\n' "$dependency" >&2
      exit 1
    }
  done
  for binary in "$APP_BINARY" "$PETCORE" "$PETCORE_CLI"; do
    architectures="$(lipo -archs "$binary")"
    [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]] || {
      printf 'distribution validation failed: %s is not universal (%s)\n' "$binary" "$architectures" >&2
      exit 1
    }
  done
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  codesign -d --verbose=4 "$APP_BUNDLE" 2>&1 | grep -q 'Runtime Version'
  xcrun stapler validate "$APP_BUNDLE"
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
  echo 'Distribution app bundle validation ok: universal, signed, hardened, notarized and stapled'
else
  if codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
    echo 'Development app bundle validation ok (signature present; notarization not required by this mode)'
  else
    echo 'Development app bundle validation ok (unsigned development build; not distributable)'
  fi
fi
