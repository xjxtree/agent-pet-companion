import AgentPetCompanionCore
import AppKit
import Darwin
import SwiftUI

private enum AppLaunchMode {
    static let runsUIValidation = CommandLine.arguments.contains("--run-ui-validation")
    static let manualInstallationRequest = runsUIValidation
        ? nil
        : AppInstallationPolicy.primaryLaunchRequest()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !AppLaunchMode.runsUIValidation else { return }
        APCBrandAssets.applyApplicationIcon()
        switch AppSingleInstanceCoordinator.shared.claimPrimaryInstance() {
        case .primary:
            AppDiagnostics.shared.log(
                .notice,
                category: "lifecycle",
                event: "primary_instance_claimed"
            )
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
        AppDiagnostics.shared.log(.notice, category: "lifecycle", event: "app_did_finish_launching")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AppLaunchMode.runsUIValidation,
              AppLaunchMode.manualInstallationRequest == nil,
              AppSingleInstanceCoordinator.shared.claim == .primary
        else { return }
        AppDiagnostics.shared.log(.debug, category: "lifecycle", event: "app_became_active")
        _ = AppUpdateHandoffCoordinator.shared.restartIfInstalledBuildChanged()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppLaunchMode.runsUIValidation,
              AppSingleInstanceCoordinator.shared.claim == .primary
        else { return false }
        AppDiagnostics.shared.log(.info, category: "lifecycle", event: "app_reopen_requested")
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

    func applicationWillTerminate(_ notification: Notification) {
        guard !AppLaunchMode.runsUIValidation,
              AppSingleInstanceCoordinator.shared.claim == .primary
        else { return }
        AppDiagnostics.shared.log(.notice, category: "lifecycle", event: "app_will_terminate")
    }
}

@main
struct AgentPetCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore

    init() {
        let claim = AppLaunchMode.runsUIValidation
            ? AppInstanceClaim.primary
            : AppSingleInstanceCoordinator.shared.claimPrimaryInstance()
        let diagnostics: AppDiagnostics
        if !AppLaunchMode.runsUIValidation, claim == .primary {
            AppDiagnostics.shared.startSession()
            diagnostics = .shared
        } else {
            diagnostics = .disabled
        }
        let store = AppStore(diagnostics: diagnostics)
        _store = StateObject(wrappedValue: store)
        let isPrimary = AppLaunchMode.runsUIValidation || claim == .primary
        if !AppLaunchMode.runsUIValidation, isPrimary {
            AppUpdateHandoffCoordinator.shared.configureSafety(
                canRestart: { [weak store] in
                    store?.isSafeForAppUpdateHandoff ?? true
                },
                onDeferred: { [weak store] in
                    store?.presentDeferredAppUpdateHandoff()
                },
                onFailure: { [weak store] request in
                    store?.presentFailedAppUpdateHandoff(request)
                }
            )
            AppSingleInstanceCoordinator.shared.setActivationHandler { [weak store] request in
                switch AppUpdateHandoffCoordinator.shared.handleRequestedBuild(request) {
                case .restartScheduled:
                    return
                case .restartDeferred:
                    return
                case let .manualInstallation(installationRequest):
                    store?.presentManualAppInstallation(installationRequest)
                    return
                case .ignored:
                    break
                }
                guard !AppUpdateHandoffCoordinator.shared.restartIfInstalledBuildChanged() else {
                    return
                }
                store?.presentMainWindow()
            }
            if AppLaunchMode.manualInstallationRequest == nil {
                Task { @MainActor in
                    await store.bootstrapIfNeeded()
                }
            }
        }
    }

    var body: some Scene {
        // The product has one control-center surface. `WindowGroup` creates a
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
        .windowToolbarStyle(.unified)
        .commands {
            AboutWindowCommands(
                store: store,
                installationOnly: AppLaunchMode.manualInstallationRequest != nil
            )
            ControlCenterCommands(
                store: store,
                installationOnly: AppLaunchMode.manualInstallationRequest != nil
            )
        }

        Window(APCLocalization.text(.appActionAbout), id: "about") {
            if AppLaunchMode.runsUIValidation {
                EmptyView()
            } else {
                AboutView(
                    store: store,
                    showsUpdateControls: AppLaunchMode.manualInstallationRequest == nil
                )
                    .apcAppearanceTheme(store.behavior.appearanceTheme)
                    .background {
                        if AppLaunchMode.manualInstallationRequest == nil {
                            InitialAppearanceWindowGateView(
                                readiness: store.initialAppearanceReadiness,
                                theme: store.behavior.appearanceTheme
                            )
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                        }
                    }
            }
        }
        .defaultSize(width: 440, height: 360)
        .windowResizability(.contentSize)

        MenuBarExtra {
            if let request = AppLaunchMode.manualInstallationRequest {
                AppInstallationStatusMenuContent(store: store, request: request)
            } else {
                AppStatusMenuContent(store: store)
            }
        } label: {
            AppStatusItemLabel(store: store)
        }
    }
}

/// The status-menu content is a standalone view so the production menu stays
/// reusable and testable without a second menu-only implementation.
struct AppStatusMenuContent: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Group {
            AppUpdateMenuSection(
                updater: store.appUpdater,
                presentUpdate: store.presentAvailableAppUpdate
            )
            Text(APCLocalization.format(
                .appMenuCurrentPet,
                MenuBarSummary.short(
                    store.activePet?.name ?? APCLocalization.text(.appStateNoPet)
                )
            ))
                .accessibilityIdentifier("menubar.summary.pet")
            Text(APCLocalization.format(
                .appMenuRecentAgent,
                MenuBarSummary.short(MenuBarLocalizedSummary.recentEvent(store.recentEvents.first))
            ))
                .accessibilityIdentifier("menubar.summary.agent")
            Divider()
            Button(APCLocalization.text(.appActionOpenControlCenter)) {
                store.presentMainWindow()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .accessibilityIdentifier("menubar.open-control-center")
            Button(APCLocalization.text(
                store.behavior.enabled ? .appActionHidePet : .appActionShowPet
            )) {
                store.toggleOverlay()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .accessibilityIdentifier("menubar.toggle-pet")
            Button(APCLocalization.text(.appActionFocusPetSessions)) {
                store.focusOverlayBubbleForKeyboardNavigation()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!store.canFocusOverlayBubbleForKeyboardNavigation)
            .accessibilityIdentifier("menubar.focus-pet-sessions")
            Button(APCLocalization.text(.appActionFocusPetResize)) {
                store.focusOverlayResizeForKeyboardNavigation()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!store.canFocusOverlayResizeForKeyboardNavigation)
            .accessibilityIdentifier("menubar.focus-pet-resize")
            Divider()
            Button(APCLocalization.text(.appActionCheckConnections)) {
                store.selection = .connections
                store.checkAllConnections()
                store.presentMainWindow()
            }
            .disabled(!store.canStartConnectionOperation)
            .accessibilityIdentifier("menubar.check-connections")
            Button(APCLocalization.text(.appUpdateCheckAction)) {
                store.checkForAppUpdatesManually()
            }
            .disabled(store.appUpdater.isChecking)
            .accessibilityIdentifier("menubar.check-for-updates")
            Divider()
            Button(APCLocalization.text(.appActionQuit)) {
                if AppSingleInstanceCoordinator.shared.claim == .primary {
                    AppDiagnostics.shared.log(
                        .notice,
                        category: "lifecycle",
                        event: "quit_requested"
                    )
                }
                NSApplication.shared.terminate(nil)
            }
            .accessibilityIdentifier("menubar.quit")
        }
    }
}

private struct AboutWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let store: AppStore
    let installationOnly: Bool

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(APCLocalization.text(.appActionAbout)) {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }
            if !installationOnly {
                Divider()
                Button(APCLocalization.text(.appUpdateCheckAction)) {
                    store.checkForAppUpdatesManually()
                }
                .disabled(store.appUpdater.isChecking)
            }
        }
    }
}

private struct ControlCenterCommands: Commands {
    let store: AppStore
    let installationOnly: Bool

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(APCLocalization.text(.appActionOpenControlCenter)) {
                store.presentMainWindow()
            }
            .keyboardShortcut("0", modifiers: [.command])

            if !installationOnly {
                Button(APCLocalization.text(.appActionTogglePet)) {
                    store.toggleOverlay()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button(APCLocalization.text(.appActionFocusPetSessions)) {
                    store.focusOverlayBubbleForKeyboardNavigation()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!store.canFocusOverlayBubbleForKeyboardNavigation)

                Button(APCLocalization.text(.appActionFocusPetResize)) {
                    store.focusOverlayResizeForKeyboardNavigation()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!store.canFocusOverlayResizeForKeyboardNavigation)

                Divider()

                Button(APCLocalization.text(.navigationDiagnostics)) {
                    store.selection = .diagnostics
                    store.presentMainWindow()
                }

                Button(APCLocalization.text(.appActionCheckConnections)) {
                    store.selection = .connections
                    store.checkAllConnections()
                    store.presentMainWindow()
                }
                .disabled(!store.canStartConnectionOperation)
            }
        }
    }
}

private enum MenuBarSummary {
    static func short(_ value: String, maximumCharacters: Int = 18) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }
}

private enum MenuBarLocalizedSummary {
    static func recentEvent(_ event: AgentEvent?) -> String {
        guard let event else { return APCLocalization.text(.appStateNoRecentActivity) }
        return "\(event.source.shortTitle) · \(APCLocalizedPresentation.eventTitle(event.eventType))"
    }
}

private struct AppStatusItemLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AppStore

    var body: some View {
        APCBrandMark(size: 18)
            .overlay(alignment: .topTrailing) {
                AppUpdateStatusDot(updater: store.appUpdater)
                    .offset(x: 2, y: -2)
            }
            .onAppear {
                store.setMainWindowPresenter {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

private struct AppInstallationStatusMenuContent: View {
    @ObservedObject var store: AppStore
    let request: AppManualInstallationRequest

    var body: some View {
        Text(APCLocalization.text(.appUpdateInstallRequired))
        Divider()
        Button(APCLocalization.text(.appUpdateShowInstallGuide)) {
            store.presentMainWindow()
        }
        Button(APCLocalization.text(
            request.origin == .invalidReleaseBundle
                ? .appUpdateRedownloadAction
                : .appUpdateRevealNewApp
        )) {
            if request.origin == .invalidReleaseBundle {
                AppManualInstallationActions.openLatestRelease()
            } else {
                AppManualInstallationActions.revealCandidate(request)
            }
        }
        if request.origin != .invalidReleaseBundle {
            Button(APCLocalization.text(.appUpdateOpenApplications)) {
                AppManualInstallationActions.openApplications()
            }
        }
        Divider()
        Button(APCLocalization.text(.appActionQuit)) {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct MainWindowContent: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var updater: AppUpdateController

    init(store: AppStore) {
        self.store = store
        _updater = ObservedObject(wrappedValue: store.appUpdater)
    }

    var body: some View {
        Group {
            if let request = AppLaunchMode.manualInstallationRequest {
                AppManualInstallationGuideView(
                    request: request,
                    allowsDismissal: false
                )
            } else {
                ContentView()
                    .environmentObject(store)
                    .sheet(isPresented: appModalSheetIsPresented) {
                        if let request = store.manualAppInstallationRequest {
                            AppManualInstallationGuideView(request: request) {
                                store.dismissManualAppInstallation()
                            }
                        } else {
                            AppUpdateSheetView(updater: updater) { release in
                                store.beginManualAppUpdateDownload(release)
                            }
                        }
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSApplication.didBecomeActiveNotification
                        )
                    ) { _ in
                        store.appUpdater.checkAutomaticallyIfDue()
                    }
            }
        }
            .frame(
                minWidth: ControlCenterShellPolicy.supportedMinimumWindowWidth,
                minHeight: ControlCenterShellPolicy.supportedMinimumWindowHeight
            )
            .apcAppearanceTheme(store.behavior.appearanceTheme)
            .background {
                ZStack {
                    if AppLaunchMode.manualInstallationRequest == nil {
                        InitialAppearanceWindowGateView(
                            readiness: store.initialAppearanceReadiness,
                            theme: store.behavior.appearanceTheme
                        )
                    }
                    ControlCenterWindowRegistrationView(store: store)
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
    }

    private var appModalSheetIsPresented: Binding<Bool> {
        Binding(
            get: {
                store.manualAppInstallationRequest != nil
                    || updater.isSheetPresented
            },
            set: { isPresented in
                if !isPresented {
                    store.dismissManualAppInstallation()
                    updater.dismissSheet()
                }
            }
        )
    }
}

private struct ControlCenterWindowRegistrationView: NSViewRepresentable {
    let store: AppStore

    func makeNSView(context: Context) -> ControlCenterWindowRegistrationHostView {
        ControlCenterWindowRegistrationHostView(store: store)
    }

    func updateNSView(
        _ nsView: ControlCenterWindowRegistrationHostView,
        context: Context
    ) {
        nsView.store = store
        nsView.registerWindowIfAvailable()
    }
}

@MainActor
private final class ControlCenterWindowRegistrationHostView: NSView {
    weak var store: AppStore?

    init(store: AppStore) {
        self.store = store
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindowIfAvailable()
    }

    func registerWindowIfAvailable() {
        guard let window else { return }
        store?.registerControlCenterWindow(window)
    }
}
