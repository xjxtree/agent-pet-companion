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

    @MainActor
    @Test
    func aboutWindowFirstDoesNotInterceptAControlCenterReopen() {
        let aboutWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aboutWindow.identifier = NSUserInterfaceItemIdentifier("about")
        let controlCenterWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controlCenterWindow.identifier = AppStore.controlCenterWindowIdentifier

        let resolved = [aboutWindow, controlCenterWindow]
            .first(where: AppStore.isMainWindowCandidate)

        #expect(resolved === controlCenterWindow)
    }

    @MainActor
    @Test
    func mainWindowPresentationYieldsToAnInstalledBuildHandoff() {
        var handoffChecks = 0
        var presentations = 0
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            runtimeHandoffIfNeeded: {
                handoffChecks += 1
                return true
            }
        )
        store.setMainWindowPresenter {
            presentations += 1
        }

        store.presentMainWindow()

        #expect(handoffChecks == 1)
        #expect(presentations == 0)
    }

    @Test
    func controlCenterUsesOneSystemManagedWindowAndAllReopenSurfacesShareItsPresenter() throws {
        let appSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
        )
        let appStoreSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AppStore.swift"
        )
        let runtimeSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AppRuntimeLifecycle.swift"
        )
        let overlaySource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"
        )

        #expect(LifecycleSource.matches(
            #"Window\s*\(\s*"Agent Pet Companion"\s*,\s*id:\s*"main"\s*\)"#,
            in: appSource
        ))
        #expect(!LifecycleSource.matches(#"WindowGroup\s*\("#, in: appSource))
        #expect(appSource.contains(".defaultSize(width: 1120, height: 720)"))
        #expect(appSource.contains(".frame(minWidth: 760, minHeight: 520)"))
        #expect(appSource.contains(".windowToolbarStyle(.unified)"))
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
        #expect(LifecycleSource.matches(
            #"func presentMainWindow\(\) \{\s*guard !runtimeHandoffIfNeeded\(\) else \{ return \}"#,
            in: appStoreSource
        ))
        #expect(!runtimeSource.contains("AppInstalledBuildMonitor"))
        #expect(!appSource.contains("installedBuildMonitor"))
        #expect(APCLocalization.text(.appActionOpenControlCenter) == "打开控制中心")
    }

    @Test
    func aboutUsesASmallSingletonWindowAndTheStandardAppInfoCommand() throws {
        let appSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
        )
        let aboutSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/Views/AboutView.swift"
        )

        #expect(LifecycleSource.matches(
            #"Window\s*\(\s*APCLocalization\.text\(\.appActionAbout\)\s*,\s*id:\s*\"about\"\s*\)"#,
            in: appSource
        ))
        #expect(appSource.contains("CommandGroup(replacing: .appInfo)"))
        #expect(appSource.contains("openWindow(id: \"about\")"))
        #expect(appSource.contains(".windowResizability(.contentSize)"))
        #expect(aboutSource.contains("APCBrandMark(size: 72)"))
        #expect(aboutSource.contains("CFBundleShortVersionString"))
        #expect(aboutSource.contains("CFBundleVersion"))
        #expect(aboutSource.contains("about.window"))
    }

    @Test
    func controlCenterTitleAndToolbarActionsHaveNativeMenuContracts() throws {
        let appSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
        )
        let contentSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/Views/ContentView.swift"
        )
        let shellSource = try LifecycleSource.read(
            "Sources/AgentPetCompanion/Views/ControlCenterShell.swift"
        )

        #expect(contentSource.contains("ControlCenterWindowTitleUpdater"))
        #expect(contentSource.contains("store.selection.localizedTitle"))
        #expect(shellSource.contains("window?.title = title"))
        #expect(!contentSource.contains(".navigationTitle("))

        let commands = try #require(appSource.range(of: "private struct ControlCenterCommands"))
        let summaries = try #require(appSource.range(of: "private enum MenuBarSummary"))
        let commandSource = appSource[commands.lowerBound ..< summaries.lowerBound]
        for key in [
            ".appActionOpenControlCenter",
            ".appActionTogglePet",
            ".navigationDiagnostics",
            ".appActionCheckConnections",
        ] {
            #expect(commandSource.contains(key))
        }
        #expect(commandSource.contains("store.presentMainWindow()"))
        #expect(commandSource.contains("store.toggleOverlay()"))
        #expect(commandSource.contains("store.selection = .diagnostics"))
        #expect(commandSource.contains("store.checkAllConnections()"))
    }

    @Test
    func repositoryRunNormallyQuitsTheOldAppBeforeReplacingAndOpeningTheBundle() throws {
        let clientSource = try LifecycleSource.read(
            "Sources/AgentPetCompanionLifecycleClient/main.swift"
        )
        let packageSource = try LifecycleSource.read("Package.swift")
        let runScript = try LifecycleSource.readFromRepository("script/build_and_run.sh")
        let runBody = try #require(LifecycleSource.functionBody("run_host_bundle", in: runScript))

        #expect(packageSource.contains("AgentPetCompanionLifecycleClient"))
        #expect(clientSource.contains("NSRunningApplication"))
        #expect(clientSource.contains("dev.agentpet.companion"))
        #expect(clientSource.contains("application.terminate()"))
        #expect(!LifecycleSource.matches(#"application\.forceTerminate\s*\("#, in: clientSource))
        #expect(clientSource.contains("quitTimeout: TimeInterval = 10"))
        #expect(clientSource.contains("app-instance.lock"))
        #expect(clientSource.contains("primaryInstanceLockIsFree()"))

        let quit = try #require(runBody.range(of: "quit_running_app"))
        let build = try #require(runBody.range(of: "build_bundle"))
        let open = try #require(runBody.range(of: #"/usr/bin/open -n "$APP_BUNDLE""#))
        let synchronize = try #require(runBody.range(of: "wait_for_runtime_sync"))
        #expect(quit.lowerBound < build.lowerBound)
        #expect(build.lowerBound < open.lowerBound)
        #expect(open.lowerBound < synchronize.lowerBound)
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
            #"Button\s*\(\s*APCLocalization\.text\(\.appActionQuit\)\s*\)\s*\{[\s\S]*?NSApplication\.shared\.terminate\(nil\)"#,
            in: appSource
        ))
        #expect(APCLocalization.text(.appActionQuit) == "退出 Agent Pet")
        #expect(appSource.contains("NSApp.setActivationPolicy(.regular)"))
        #expect(!appSource.contains("func applicationShouldTerminate("))
        #expect(!appSource.contains("CommandGroup(replacing: .appTermination)"))
        #expect(appSource.contains("func applicationWillTerminate"))
        #expect(!appSource.contains("petcore.shutdown"))
        #expect(processManagerSource.contains(#""RunAtLoad": true"#))
        #expect(processManagerSource.contains(#""KeepAlive": true"#))
        #expect(LifecycleSource.matches(
            #"ProgramArguments[\s\S]*?executable[\s\S]*?"serve""#,
            in: processManagerSource
        ))
    }

    @Test
    func persistentDiagnosticsStartsOnlyAfterThePrimaryInstanceClaim() throws {
        let source = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
        )
        #expect(LifecycleSource.matches(
            #"let claim =[\s\S]*?claimPrimaryInstance\(\)[\s\S]*?claim == \.primary[\s\S]*?AppDiagnostics\.shared\.startSession\(\)[\s\S]*?diagnostics = \.shared[\s\S]*?else \{\s*diagnostics = \.disabled[\s\S]*?AppStore\(diagnostics: diagnostics\)"#,
            in: source
        ))
        let secondaryStart = try #require(source.range(of: "case .secondary:"))
        let failedStart = try #require(source.range(of: "case let .failed", range: secondaryStart.upperBound ..< source.endIndex))
        let secondaryBranch = source[secondaryStart.lowerBound ..< failedStart.lowerBound]
        #expect(!secondaryBranch.contains("AppDiagnostics.shared"))
    }

    @Test
    func bundledPetsAndAuthoritativeSnapshotPrecedeFirstOverlayPresentation() throws {
        let source = try LifecycleSource.read(
            "Sources/AgentPetCompanion/App/AppStore.swift"
        )
        #expect(LifecycleSource.matches(
            #"private func completeRuntimeBootstrap\(\) async \{[\s\S]*?await performBundledPetSeed\(\)[\s\S]*?let snapshotReady = await refreshDuringRuntimeBootstrap\(\)"#,
            in: source
        ))
        #expect(LifecycleSource.matches(
            #"func applyStateSnapshot\(_ result: Any\) throws \{[\s\S]*?resolveInitialAppearanceAsAuthoritative\(\)[\s\S]*?hasLoadedStateSnapshot = true[\s\S]*?presentOverlayAfterFirstSnapshotIfNeeded\(\)"#,
            in: source
        ))
        #expect(LifecycleSource.matches(
            #"private func presentOverlayAfterFirstSnapshotIfNeeded\(\) \{[\s\S]*?guard runtimeBootstrapCompleted,[\s\S]*?hasLoadedStateSnapshot,[\s\S]*?!hasPresentedOverlay[\s\S]*?overlayPresenter\(overlayController, self\)"#,
            in: source
        ))
    }

    @MainActor
    @Test
    func failedBundledPetSeedRetriesWithBackoffAndRefreshesAfterSuccess() async {
        let probe = BundledPetSeedRetryProbe(results: [false, true])
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in await probe.recordRefresh() },
                onReady: { _ in }
            ),
            bundledPetSeeder: { await probe.nextSeedResult() },
            bundledPetSeedSleeper: { delay in await probe.recordDelay(delay) }
        )
        store.statusText = "App 内置宠物加载失败：transient"

        let succeeded = await store.retryBundledPetSeedAfterBootstrapFailure()
        let snapshot = await probe.snapshot()

        #expect(succeeded)
        #expect(snapshot.seedAttempts == 2)
        #expect(snapshot.delays == Array(AppStore.bundledPetSeedRetryDelays.prefix(2)))
        #expect(snapshot.refreshes == 1)
        #expect(store.statusText == "App 内置宠物已加载")
    }

    @MainActor
    @Test
    func bundledPetSeedRetryStopsAfterTheBoundedSchedule() async {
        let probe = BundledPetSeedRetryProbe(results: [false, false, false, true])
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in await probe.recordRefresh() },
                onReady: { _ in }
            ),
            bundledPetSeeder: { await probe.nextSeedResult() },
            bundledPetSeedSleeper: { delay in await probe.recordDelay(delay) }
        )

        let succeeded = await store.retryBundledPetSeedAfterBootstrapFailure()
        let snapshot = await probe.snapshot()

        #expect(!succeeded)
        #expect(snapshot.seedAttempts == AppStore.bundledPetSeedRetryDelays.count)
        #expect(snapshot.delays == AppStore.bundledPetSeedRetryDelays)
        #expect(snapshot.refreshes == 0)
    }

    @MainActor
    @Test
    func successfulBundledPetRetryDoesNotOverwriteAUserOperationStatus() async {
        let probe = BundledPetSeedRetryProbe(results: [true])
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in await probe.recordRefresh() },
                onReady: { _ in }
            ),
            bundledPetSeeder: { await probe.nextSeedResult() },
            bundledPetSeedSleeper: { delay in await probe.recordDelay(delay) }
        )
        store.statusText = "正在导入用户宠物"

        let succeeded = await store.retryBundledPetSeedAfterBootstrapFailure()

        #expect(succeeded)
        #expect(store.statusText == "正在导入用户宠物")
    }
}

private actor BundledPetSeedRetryProbe {
    struct Snapshot: Sendable {
        let seedAttempts: Int
        let delays: [Duration]
        let refreshes: Int
    }

    private var results: [Bool]
    private var seedAttempts = 0
    private var delays: [Duration] = []
    private var refreshes = 0

    init(results: [Bool]) {
        self.results = results
    }

    func nextSeedResult() -> Bool {
        seedAttempts += 1
        return results.isEmpty ? false : results.removeFirst()
    }

    func recordDelay(_ delay: Duration) {
        delays.append(delay)
    }

    func recordRefresh() {
        refreshes += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(seedAttempts: seedAttempts, delays: delays, refreshes: refreshes)
    }
}

private enum LifecycleSource {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func read(_ relativePath: String) throws -> String {
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    static func readFromRepository(_ relativePath: String) throws -> String {
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    static func functionBody(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "\(name)() {") else { return nil }
        guard let end = source.range(
            of: "\n}\n",
            range: start.upperBound ..< source.endIndex
        ) else { return nil }
        return String(source[start.lowerBound ..< end.upperBound])
    }

    static func matches(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }
}
