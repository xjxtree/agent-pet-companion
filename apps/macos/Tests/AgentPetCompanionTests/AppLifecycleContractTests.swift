import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite
struct AppLifecycleContractTests {
    @MainActor
    @Test
    func closingTheLastControlCenterWindowDoesNotRequestHostTermination() {
        let delegate = AppDelegate()

        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @MainActor
    @Test
    func reopenBeforeSceneRegistrationIsReplayedExactlyOnce() {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        var presentations = 0

        store.presentMainWindow()
        store.presentMainWindow()
        store.setMainWindowPresenter {
            presentations += 1
        }
        #expect(presentations == 1)

        store.setMainWindowPresenter {
            presentations += 1
        }
        #expect(presentations == 1)
    }

    @Test
    func controlCenterUsesOneSystemManagedWindowAndAllReopenSurfacesShareItsPresenter() throws {
        let appSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
        )
        let overlaySource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"
        )

        #expect(LifecycleSource.matches(
            #"Window\s*\(\s*"Agent Pet Companion"\s*,\s*id:\s*"main"\s*\)"#,
            in: appSource
        ))
        #expect(!LifecycleSource.matches(#"WindowGroup\s*\("#, in: appSource))
        #expect(LifecycleSource.matches(
            #"applicationShouldHandleReopen[\s\S]*?activatePrimaryInstance\(\)[\s\S]*?return false"#,
            in: appSource
        ))
        #expect(LifecycleSource.matches(
            #"MenuBarExtra\s*\{[\s\S]*?Button\s*\(\s*APCLocalization\.text\(\.appActionOpenControlCenter\)\s*\)\s*\{\s*store\.presentMainWindow\(\)"#,
            in: appSource
        ))
        #expect(LifecycleSource.matches(
            #"\.contextMenu\s*\{[\s\S]*?store\.presentMainWindow\(\)[\s\S]*?Label\s*\(\s*APCLocalization\.text\(\.appActionOpenControlCenter\)"#,
            in: overlaySource
        ))
        #expect(overlaySource.contains("onOpenMainWindow: { store.presentMainWindow() }"))
        #expect(APCLocalization.text(.appActionOpenControlCenter) == "打开控制中心")
    }

    @Test
    func explicitQuitTerminatesOnlyTheUIHostWhilePetCoreRemainsLaunchdOwned() throws {
        let appSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
        )
        let processManagerSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/PetCoreProcessManager.swift"
        )

        #expect(LifecycleSource.matches(
            #"Button\s*\(\s*APCLocalization\.text\(\.appActionQuit\)\s*\)\s*\{\s*NSApplication\.shared\.terminate\(nil\)"#,
            in: appSource
        ))
        #expect(APCLocalization.text(.appActionQuit) == "退出 Agent Pet")
        #expect(!appSource.contains("petcore.shutdown"))
        #expect(processManagerSource.contains(#""RunAtLoad": true"#))
        #expect(processManagerSource.contains(#""KeepAlive": true"#))
        #expect(LifecycleSource.matches(
            #"ProgramArguments[\s\S]*?executable[\s\S]*?"serve""#,
            in: processManagerSource
        ))
    }
}

private enum LifecycleSource {
    static func read(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    static func matches(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }
}
