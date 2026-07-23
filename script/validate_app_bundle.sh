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
BUNDLED_PORTABLE_SKILL="$APP_RESOURCES/skills/agent-pet-maker"
SOURCE_PORTABLE_SKILL="$ROOT_DIR/skills/agent-pet-maker"
LOCALIZATION_BUNDLE="$APP_RESOURCES/AgentPetCompanion_AgentPetCompanion.bundle"
BUNDLE_ICON="$APP_RESOURCES/AgentPetCompanion.icns"
SOURCE_ICON="$ROOT_DIR/logo/macos/AgentPetCompanionTransparent.icns"
BUNDLED_BRAND_MARK="$LOCALIZATION_BUNDLE/AgentPetCompanionMark.png"
SOURCE_BRAND_MARK="$ROOT_DIR/logo/transparent/agent-pet-mark-transparent-1024.png"
BUNDLED_PETS_DIR="$LOCALIZATION_BUNDLE/BuiltInPets"
SOURCE_PETS_DIR="$ROOT_DIR/apps/macos/Sources/AgentPetCompanion/Resources/BuiltInPets"
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
[[ -f "$BUNDLED_PORTABLE_SKILL/SKILL.md" ]] || {
  echo "app bundle validation failed: missing bundled agent-pet-maker skill" >&2
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
[[ -f "$BUNDLE_ICON" ]] || {
  echo "app bundle validation failed: missing app icon" >&2
  exit 1
}
[[ -f "$BUNDLED_BRAND_MARK" ]] || {
  echo "app bundle validation failed: missing bundled brand mark" >&2
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
if find "$BUNDLED_PORTABLE_SKILL" \
  \( -type d -name '__pycache__' -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
  -print -quit | grep -q .; then
  echo "app bundle validation failed: bundled agent-pet-maker contains Python bytecode" >&2
  exit 1
fi
diff -qr -x '__pycache__' -x '*.pyc' -x '*.pyo' \
  "$SOURCE_PORTABLE_SKILL" "$BUNDLED_PORTABLE_SKILL" >/dev/null || {
  echo "app bundle validation failed: bundled agent-pet-maker skill differs from source" >&2
  exit 1
}
cmp -s "$SOURCE_ICON" "$BUNDLE_ICON" || {
  echo "app bundle validation failed: bundled app icon differs from approved transparent icon" >&2
  exit 1
}
cmp -s "$SOURCE_BRAND_MARK" "$BUNDLED_BRAND_MARK" || {
  echo "app bundle validation failed: bundled brand mark differs from approved transparent mark" >&2
  exit 1
}
for petpack_name in pet_xingwutuanzi.petpack pet_bytebudcodex.petpack; do
  [[ -f "$BUNDLED_PETS_DIR/$petpack_name" && ! -L "$BUNDLED_PETS_DIR/$petpack_name" ]] || {
    echo "app bundle validation failed: missing bundled pet $petpack_name" >&2
    exit 1
  }
  cmp -s "$SOURCE_PETS_DIR/$petpack_name" "$BUNDLED_PETS_DIR/$petpack_name" || {
    echo "app bundle validation failed: bundled pet differs from audited source: $petpack_name" >&2
    exit 1
  }
  "$PETCORE_CLI" petpack validate "$BUNDLED_PETS_DIR/$petpack_name" >/dev/null
done
if [[ "$(find "$BUNDLED_PETS_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" != "2" ]]; then
  echo "app bundle validation failed: bundled pet inventory must contain exactly the two approved entries" >&2
  exit 1
fi
python3 - "$BUNDLED_PETS_DIR" <<'PY'
import hashlib
import json
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
expected = {
    "pet_xingwutuanzi.petpack": (
        "pet_xingwutuanzi",
        "9a67254a1ee3f1a2afd599f376fd0cc0ee9935e137426924a99c20a24bdb49c2",
    ),
    "pet_bytebudcodex.petpack": (
        "pet_bytebudcodex",
        "a0b64b46054ed5a73abeefc7c0f734cfaa2d92878f5c097ca85bdcb06d547d6f",
    ),
}
for name, (pet_id, digest) in expected.items():
    path = root / name
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"app bundle validation failed: bundled pet digest mismatch: {name}")
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read("manifest.json"))
    if manifest.get("id") != pet_id:
        raise SystemExit(f"app bundle validation failed: bundled pet ID mismatch: {name}")
PY

python3 - "$APP_CONTENTS/Info.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as file:
    info = plistlib.load(file)

expected = {
    "CFBundleExecutable": "AgentPetCompanion",
    "CFBundleIdentifier": "dev.agentpet.companion",
    "CFBundleIconFile": "AgentPetCompanion.icns",
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
mime = petpack.get("UTTypeTagSpecification", {}).get("public.mime-type")
if mime != "application/vnd.agentpet.petpack+zip":
    raise SystemExit(
        "app bundle validation failed: dev.agentpet.petpack MIME type is invalid"
    )
PY

grep -q '^name: agent-pet-studio$' "$BUNDLED_SKILL"
grep -q 'APC_PETCORE_CLI' "$BUNDLED_SKILL"
grep -q 'Do not read agent auth' "$BUNDLED_SKILL"
grep -q '^name: agent-pet-maker$' "$BUNDLED_PORTABLE_SKILL/SKILL.md"
grep -q 'capability-missing' "$BUNDLED_PORTABLE_SKILL/SKILL.md"
[[ -x "$BUNDLED_PORTABLE_SKILL/scripts/petpack_workspace.py" ]]

# Run the exact packaged Swift/AppKit executable through its prohibited-
# activation validation mode. This exercises packaged optimization, resources,
# overlay geometry, keyboard accessibility, and frame-pipeline wiring without
# opening windows or taking user input.
UI_VALIDATION_OUTPUT="$(
  APC_HOME="$TMP_DIR/ui-validation-home" \
  APC_DISABLE_LAUNCH_AGENT=1 \
  APC_DISABLE_CODEX_APP_SERVER_AUTO=1 \
  "$APP_BINARY" --run-ui-validation
)"
grep -q '^AgentPetCompanionUIValidation ok: [0-9][0-9]*/[0-9][0-9]* checks passed$' \
  <<<"$UI_VALIDATION_OUTPUT" || {
  echo 'app bundle validation failed: packaged UI validation did not complete' >&2
  printf '%s\n' "$UI_VALIDATION_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$UI_VALIDATION_OUTPUT"

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
assert data["fps"] == 10, data
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

# Exercise the packaged daemon, CLI and exact packaged resource directory as
# one clean-home seed path. Static digest checks above prove provenance; this
# closes the release gate by proving the installed summaries, active choice and
# rollback-compatible database schema that the App's first snapshot consumes.
BUNDLED_SEED="$(
  APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" petpack seed-bundled \
    --inventory-root "$BUNDLED_PETS_DIR"
)"
BUNDLED_PETS="$(APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" pet list)"
BUNDLED_SEED="$BUNDLED_SEED" \
BUNDLED_PETS="$BUNDLED_PETS" \
BUNDLED_HOME="$TMP_DIR/home" \
BUNDLED_DB="$TMP_DIR/home/agent-pet.sqlite" \
python3 - <<'PY'
import json
import os
import pathlib
import sqlite3

seed = json.loads(os.environ["BUNDLED_SEED"])
pets = json.loads(os.environ["BUNDLED_PETS"])
expected_ids = ["pet_xingwutuanzi", "pet_bytebudcodex"]
outcomes = seed.get("outcomes")
if seed.get("inventory") != "apc.bundled-pets.v1":
    raise SystemExit("app bundle validation failed: bundled seed inventory mismatch")
if not isinstance(outcomes, list) or [item.get("pet_id") for item in outcomes] != expected_ids:
    raise SystemExit("app bundle validation failed: bundled seed outcomes mismatch")
if any(item.get("status") != "installed" for item in outcomes):
    raise SystemExit("app bundle validation failed: clean-home bundled seed did not install both pets")

by_id = {pet.get("id"): pet for pet in pets if isinstance(pet, dict)}
if len(pets) != 2 or set(by_id) != set(expected_ids):
    raise SystemExit("app bundle validation failed: clean-home library does not contain exactly both bundled pets")
managed_pets_root = pathlib.Path(os.environ["BUNDLED_HOME"]).resolve() / "pets"
for pet_id in expected_ids:
    pet = by_id[pet_id]
    if pet.get("origin") != "verified_skill_source":
        raise SystemExit(f"app bundle validation failed: bundled origin mismatch: {pet_id}")
    if pet.get("generator") != "agent-pet-companion.release-inventory":
        raise SystemExit(f"app bundle validation failed: bundled generator mismatch: {pet_id}")
    if pet.get("provenance") != "apc.bundled-pets.v1":
        raise SystemExit(f"app bundle validation failed: bundled provenance mismatch: {pet_id}")
    package_path = pathlib.Path(pet.get("petpack_path", ""))
    if not package_path.is_file() or managed_pets_root not in package_path.resolve().parents:
        raise SystemExit(f"app bundle validation failed: installed bundled package is unavailable: {pet_id}")
if by_id["pet_xingwutuanzi"].get("active") is not True:
    raise SystemExit("app bundle validation failed: first clean-home bundled pet is not active")
if by_id["pet_bytebudcodex"].get("active") is not False:
    raise SystemExit("app bundle validation failed: second clean-home bundled pet unexpectedly became active")

with sqlite3.connect(os.environ["BUNDLED_DB"]) as database:
    schema_version = database.execute("PRAGMA user_version").fetchone()[0]
if schema_version != 5:
    raise SystemExit(
        f"app bundle validation failed: bundled seed changed database schema to {schema_version}, expected 5"
    )
PY

for source in codex claude_code pi opencode; do
  APC_HOME="$TMP_DIR/home" "$PETCORE_CLI" connections repair --source "$source" >/dev/null
done

grep -qF "$PETCORE_CLI" \
  "$TMP_DIR/agent-home/.agents/plugins/plugins/agent-pet-companion/hooks/hooks.json"
CLAUDE_HELPER="$TMP_DIR/home/connectors/claude-code/agent-pet-companion-hook.sh"
grep -qF "$CLAUDE_HELPER" "$TMP_DIR/agent-home/.claude/settings.json"
grep -qF "$PETCORE_CLI" "$CLAUDE_HELPER"
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
  SIGNATURE_PRESENT=0
  # The linker may ad-hoc sign an individual Mach-O even for an intentionally
  # unsigned app bundle. The outer bundle is signed only when it has a resource
  # envelope; a partial outer signature directory is invalid as well.
  if [[ -e "$APP_CONTENTS/_CodeSignature" ]]; then
    SIGNATURE_PRESENT=1
  fi

  if [[ "$SIGNATURE_PRESENT" == "1" ]]; then
    command -v codesign >/dev/null 2>&1 || {
      echo 'development app bundle validation failed: a signature is present but codesign is unavailable' >&2
      exit 1
    }
    if ! codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"; then
      echo 'development app bundle validation failed: a signature is present but strict verification failed' >&2
      exit 1
    fi
    echo 'Development app bundle validation ok (signature present and strictly valid; notarization not required by this mode)'
  else
    echo 'Development app bundle validation ok (no signature present; not distributable)'
  fi
fi
