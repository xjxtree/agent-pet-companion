#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
app = (root / "apps/macos/Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift").read_text()
app_store = (root / "apps/macos/Sources/AgentPetCompanion/App/AppStore.swift").read_text()
presentation = (
    root
    / "apps/macos/Sources/AgentPetCompanion/App/ControlCenterPresentationCoordinator.swift"
).read_text()
appearance = (
    root
    / "apps/macos/Sources/AgentPetCompanion/App/InitialAppearanceWindowAppearance.swift"
).read_text()
app_runtime = (root / "apps/macos/Sources/AgentPetCompanion/App/AppRuntimeLifecycle.swift").read_text()
overlay = (root / "apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift").read_text()
overlay_controller = (
    root / "apps/macos/Sources/AgentPetCompanion/Overlay/PetOverlayController.swift"
).read_text()
main_window_validator = (root / "script/validate_main_window_ui.sh").read_text()
petcore = (root / "apps/macos/Sources/AgentPetCompanion/App/PetCoreProcessManager.swift").read_text()
zh_hans = "\n".join(
    path.read_text()
    for path in sorted(
        (root / "apps/macos/Sources/AgentPetCompanion/Resources/Localization").glob(
            "*/zh-Hans.lproj/*.strings"
        )
    )
)
run_script = (root / "script/build_and_run.sh").read_text()
build_script = (root / "script/build_app_bundle.sh").read_text()
package = (root / "apps/macos/Package.swift").read_text()
lifecycle_client = (
    root / "apps/macos/Sources/AgentPetCompanionLifecycleClient/main.swift"
).read_text()
environment = (root / ".codex/environments/environment.toml").read_text()

run_start = run_script.index("run_host_bundle() {")
run_end = run_script.index("\n}\n\ncase", run_start)
run_body = run_script[run_start:run_end]

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
    "primary cold launch is routed through the registered control center presenter": (
        re.search(
            r'applicationDidFinishLaunching.*?ControlCenterColdLaunchTiming\.schedule\s*\{\s*'
            r'AppSingleInstanceCoordinator\.shared\.activatePrimaryInstance\(\)',
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
    "ordinary control-center presentation yields to an installed build handoff": (
        re.search(
            r'func presentMainWindow\(\)\s*\{\s*'
            r'presentMainWindow\(checkRuntimeHandoff: true\)',
            app_store,
        )
        is not None
        and "controlCenterPresentationCoordinator.requestPresentation(" in app_store
        and "runtimeHandoffIfNeeded" in presentation
    ),
    "one coordinator owns control-center visibility activation and key state": (
        "final class ControlCenterPresentationCoordinator" in presentation
        and "private var wantsPresentation = false" in presentation
        and "window.alphaValue = 1" in presentation
        and "window.ignoresMouseEvents = false" in presentation
        and "activateApplication()" in presentation
        and "window.makeKeyAndOrderFront(nil)" in presentation
        and "ControlCenterPresentationCoordinator(" in app_store
        and re.search(
            r'setMainWindowPresenter\s*\{\s*openWindow\(id:\s*"main"\)\s*\}',
            app,
        )
        is not None
    ),
    "appearance hydration never hides or disables a window": (
        "InitialAppearanceWindowView" in appearance
        and "window.appearance = nextAppearance" in appearance
        and "alphaValue" not in appearance
        and "ignoresMouseEvents" not in appearance
        and "InitialAppearanceWindowGate" not in app
    ),
    "overlay panels are passive unless the bubble holds an explicit keyboard lease": (
        "bubblePanel.becomesKeyOnlyIfNeeded = true" in overlay_controller
        and "override var canBecomeKey: Bool { keyboardNavigationLeaseIsActive }"
        in overlay_controller
        and overlay_controller.count("override var canBecomeKey: Bool { false }") >= 2
        and "beginKeyboardNavigationLease()" in overlay_controller
    ),
    "cold-launch acceptance rebuilds the exact worktree App": (
        '"$ROOT_DIR/script/build_app_bundle.sh" >/dev/null'
        in main_window_validator
        and 'if [[ ! -x "$APP_BINARY"' not in main_window_validator
    ),
    "resident UI host has no periodic installed-build polling": (
        "AppInstalledBuildMonitor" not in app_runtime
        and "installedBuildMonitor" not in app
        and ".seconds(2)" not in app_runtime
    ),
    "repository Run quits, rebuilds, opens, and verifies one runtime build set": (
        'command = "./script/build_and_run.sh --run"' in environment
        and 'MODE="${1:---build-only}"' in run_script
        and re.search(
            r'--run\|run\).*?run_host_bundle',
            run_script,
            re.S,
        )
        is not None
        and "AgentPetCompanionLifecycleClient" in package
        and "NSRunningApplication" in lifecycle_client
        and "dev.agentpet.companion" in lifecycle_client
        and "application.terminate()" in lifecycle_client
        and re.search(r'application\.forceTerminate\s*\(', lifecycle_client) is None
        and "quitTimeout: TimeInterval = 10" in lifecycle_client
        and "app-instance.lock" in lifecycle_client
        and "primaryInstanceLockIsFree()" in lifecycle_client
        and all(
            token in run_body
            for token in (
                "quit_running_app",
                "build_bundle",
                '/usr/bin/open -n "$APP_BUNDLE"',
                "wait_for_runtime_sync",
            )
        )
        and run_body.index("quit_running_app") < run_body.index("build_bundle")
        < run_body.index('/usr/bin/open -n "$APP_BUNDLE"')
        < run_body.index("wait_for_runtime_sync")
        and '/usr/bin/open -n "$APP_BUNDLE"' in run_script
        and 'bundle_cli_build_ids' in run_script
        and '-u APC_HOME' in run_script
        and '-u APC_DISABLE_LAUNCH_AGENT' in run_script
        and 'wait_for_runtime_sync "$expected_build_id"' in run_script
    ),
    "explicit quit names and terminates the UI host": (
        re.search(
            r'Button\s*\(\s*APCLocalization\.text\(\.appActionQuit\)\s*\)\s*\{.*?'
            r'NSApplication\.shared\.terminate\(nil\)',
            app,
            re.S,
        )
        is not None
        and '"app.action.quit" = "退出 Agent Pet";' in zh_hans
        and "NSApp.setActivationPolicy(.regular)" in app
        and "func applicationShouldTerminate(" not in app
        and "CommandGroup(replacing: .appTermination)" not in app
        and "func applicationWillTerminate" in app
        and "<key>LSUIElement</key>" not in build_script
        and "<key>LSBackgroundOnly</key>" not in build_script
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
