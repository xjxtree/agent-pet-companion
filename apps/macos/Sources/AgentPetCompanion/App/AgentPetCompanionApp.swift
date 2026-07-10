import AgentPetCompanionCore
import AppKit
import Darwin
import SwiftUI

private enum AppLaunchMode {
    static let runsUIValidation = CommandLine.arguments.contains("--run-ui-validation")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct AgentPetCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("Agent Pet Companion", id: "main") {
            if AppLaunchMode.runsUIValidation {
                EmptyView()
            } else {
                MainWindowContent(store: store)
            }
        }
        .defaultSize(width: 1120, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("显示/隐藏桌宠") {
                    store.toggleOverlay()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Agent Pet", systemImage: "pawprint.fill") {
            Button("打开主窗口") {
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
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AppStore

    var body: some View {
        ContentView()
            .environmentObject(store)
            .frame(minWidth: 760, minHeight: 520)
            .onAppear {
                store.setMainWindowPresenter {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .task {
                await store.bootstrapIfNeeded()
            }
    }
}
