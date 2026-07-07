import AgentPetCompanionCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    await store.bootstrap()
                }
        }
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
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(store.behavior.enabled ? "隐藏桌宠" : "显示桌宠") {
                store.toggleOverlay()
            }
            Divider()
            Button("检查连接") {
                store.selection = .connections
                Task { await store.refresh() }
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
