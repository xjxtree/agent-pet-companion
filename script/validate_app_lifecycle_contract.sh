#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
app = (root / "apps/macos/Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift").read_text()
overlay = (root / "apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift").read_text()
petcore = (root / "apps/macos/Sources/AgentPetCompanion/App/PetCoreProcessManager.swift").read_text()
zh_hans = (root / "apps/macos/Sources/AgentPetCompanion/Resources/zh-Hans.lproj/Localizable.strings").read_text()

checks = {
    "control center is a singleton Window scene": (
        re.search(r'Window\s*\(\s*"Agent Pet Companion"\s*,\s*id:\s*"main"\s*\)', app)
        is not None
        and re.search(r"WindowGroup\s*\(", app) is None
    ),
    "closing the last control center window keeps the UI host alive": (
        re.search(
            r'applicationShouldTerminateAfterLastWindowClosed.*?->\s*Bool\s*\{.*?false\s*\}',
            app,
            re.S,
        )
        is not None
    ),
    "Dock reopen is routed once through the primary activation handler": (
        re.search(
            r'applicationShouldHandleReopen.*?activatePrimaryInstance\(\).*?return false',
            app,
            re.S,
        )
        is not None
    ),
    "menu bar reopens through the shared presenter": (
        re.search(
            r'MenuBarExtra\s*\{.*?Button\s*\(\s*'
            r'APCLocalization\.text\(\.appActionOpenControlCenter\)\s*\)\s*\{\s*'
            r'store\.presentMainWindow\(\)',
            app,
            re.S,
        )
        is not None
    ),
    "desktop pet reopens through the shared presenter": (
        "onOpenMainWindow: { store.presentMainWindow() }" in overlay
        and re.search(
            r'\.contextMenu\s*\{.*?store\.presentMainWindow\(\).*?'
            r'Label\s*\(\s*APCLocalization\.text\(\.appActionOpenControlCenter\)',
            overlay,
            re.S,
        )
        is not None
        and '"app.action.open_control_center" = "打开控制中心";' in zh_hans
    ),
    "explicit quit names and terminates the UI host": (
        re.search(
            r'Button\s*\(\s*APCLocalization\.text\(\.appActionQuit\)\s*\)\s*\{\s*'
            r'NSApplication\.shared\.terminate\(nil\)',
            app,
        )
        is not None
        and '"app.action.quit" = "退出 Agent Pet";' in zh_hans
    ),
    "UI-host quit does not request PetCore shutdown": "petcore.shutdown" not in app,
    "PetCore remains independently launchd-owned": (
        '"RunAtLoad": true' in petcore
        and '"KeepAlive": true' in petcore
        and re.search(r'ProgramArguments.*?executable.*?"serve"', petcore, re.S) is not None
    ),
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit(
        "app lifecycle contract validation failed: " + "; ".join(failed)
    )

print(f"App lifecycle contract validation ok: {len(checks)}/{len(checks)} checks passed")
PY
