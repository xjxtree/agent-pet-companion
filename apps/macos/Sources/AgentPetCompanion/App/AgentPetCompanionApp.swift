import AgentPetCompanionCore
import AppKit
import Darwin
import SwiftUI

private enum AppLaunchMode {
    static let runsUIValidation = CommandLine.arguments.contains("--run-ui-validation")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !AppLaunchMode.runsUIValidation else { return }
        switch AppSingleInstanceCoordinator.shared.claimPrimaryInstance() {
        case .primary:
            break
        case .secondary:
            NSApp.setActivationPolicy(.prohibited)
            AppSingleInstanceCoordinator.shared.requestPrimaryActivation()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        case let .failed(reason):
            fputs("AgentPetCompanion single-instance lock failed: \(reason)\n", stderr)
            NSApp.setActivationPolicy(.prohibited)
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppLaunchMode.runsUIValidation {
            NSApp.setActivationPolicy(.prohibited)
            Task {
                do {
                    let results = try await AgentPetCompanionUIValidationContract.run()
                    for result in results {
                        print("PASS \(result)")
                    }
                    print("AgentPetCompanionUIValidation ok: \(results.count)/\(results.count) checks passed")
                    fflush(stdout)
                    exit(0)
                } catch {
                    fputs("AgentPetCompanionUIValidation failed: \(error.localizedDescription)\n", stderr)
                    fflush(stderr)
                    exit(1)
                }
            }
            return
        }
        guard AppSingleInstanceCoordinator.shared.claim == .primary else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AppLaunchMode.runsUIValidation,
              AppSingleInstanceCoordinator.shared.claim == .primary
        else { return }
        _ = AppUpdateHandoffCoordinator.shared.restartIfInstalledBuildChanged()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppLaunchMode.runsUIValidation,
              AppSingleInstanceCoordinator.shared.claim == .primary
        else { return false }
        AppSingleInstanceCoordinator.shared.activatePrimaryInstance()
        // The activation handler owns the single openWindow(id:) request. Do
        // not let AppKit issue a second implicit reopen for the same scene.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The control center is only one surface of the resident UI host. The
        // menu bar item, pet panels, and PetCore subscription remain available
        // after its last regular window closes. Explicit Quit still terminates
        // the complete UI host through AppKit's normal application lifecycle.
        false
    }
}

@main
struct AgentPetCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        let isPrimary = AppLaunchMode.runsUIValidation
            || AppSingleInstanceCoordinator.shared.claimPrimaryInstance() == .primary
        if !AppLaunchMode.runsUIValidation, isPrimary {
            AppSingleInstanceCoordinator.shared.setActivationHandler { [weak store] request in
                guard !AppUpdateHandoffCoordinator.shared.restartForRequestedBuildIfNeeded(request)
                else { return }
                guard !AppUpdateHandoffCoordinator.shared.restartIfInstalledBuildChanged() else {
                    return
                }
                store?.presentMainWindow()
            }
            Task { @MainActor in
                await store.bootstrapIfNeeded()
            }
        }
    }

    var body: some Scene {
        // The product has one settings/studio surface. `WindowGroup` creates a
        // new NSWindow for every openWindow/reopen request, while `Window`
        // reuses the scene's single system-managed window.
        Window("Agent Pet Companion", id: "main") {
            if AppLaunchMode.runsUIValidation {
                EmptyView()
            } else {
                MainWindowContent(store: store)
            }
        }
        .defaultSize(width: 1120, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(APCLocalization.text(.appActionOpenControlCenter)) {
                    store.presentMainWindow()
                }
                Divider()
                Button(APCLocalization.text(.appActionTogglePet)) {
                    store.toggleOverlay()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            Button(APCLocalization.text(.appActionOpenControlCenter)) {
                store.presentMainWindow()
            }
            Button(store.behavior.enabled ? "隐藏桌宠" : "显示桌宠") {
                store.toggleOverlay()
            }
            Divider()
            Button("检查连接") {
                store.selection = .connections
                store.checkAllConnections()
                store.presentMainWindow()
            }
            Divider()
            Button(APCLocalization.text(.appActionQuit)) {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            AppStatusItemLabel(store: store)
        }
    }
}

private struct AppStatusItemLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AppStore

    var body: some View {
        Label("Agent Pet", systemImage: "pawprint.fill")
            .onAppear {
                store.setMainWindowPresenter {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

private struct MainWindowContent: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ContentView()
            .environmentObject(store)
            .frame(minWidth: 760, minHeight: 520)
    }
}
