import AgentPetCompanionCore
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct AppStoreBootstrapHooks {
    typealias EnsureRunning = @Sendable () async -> ServiceStartResult
    typealias Recover = @Sendable () async -> ServiceStartResult
    typealias FetchInitialBehavior = @MainActor (AppStore) async throws -> Any
    typealias RefreshSnapshot = @MainActor (AppStore) async throws -> Void
    typealias OnReady = @MainActor (AppStore) async -> Void

    let ensureRunning: EnsureRunning
    let recover: Recover
    let fetchInitialBehavior: FetchInitialBehavior?
    let refreshSnapshot: RefreshSnapshot
    let onReady: OnReady

    init(
        ensureRunning: @escaping EnsureRunning,
        recover: @escaping Recover,
        fetchInitialBehavior: FetchInitialBehavior? = nil,
        refreshSnapshot: @escaping RefreshSnapshot,
        onReady: @escaping OnReady
    ) {
        self.ensureRunning = ensureRunning
        self.recover = recover
        self.fetchInitialBehavior = fetchInitialBehavior
        self.refreshSnapshot = refreshSnapshot
        self.onReady = onReady
    }
}

private struct OverlayPetFrameHitTestProjection {
    var hitTest: OverlayPetFrameHitTest?
    var petID: String
    var stateEntryID: String
}

enum PetCoreRuntimePhase: Equatable {
    case checking
    case running
    case failed
}

struct PetCoreRuntimeInfo: Equatable {
    var phase: PetCoreRuntimePhase
    var version: String?
    var appBuild: String?
    var buildID: String?
    var rpcProtocol: String?
    var releaseChannel: String?
    var databaseSchemaRange: String?
    var instanceID: String?
    var errorMessage: String?

    static func initial(manifest: RuntimeReleaseManifest?) -> Self {
        Self(
            phase: .checking,
            version: manifest?.appVersion,
            appBuild: manifest?.appBuild,
            buildID: manifest?.buildID,
            rpcProtocol: manifest?.petCoreRPCProtocol,
            releaseChannel: manifest?.releaseChannel,
            databaseSchemaRange: manifest.map {
                $0.minimumDatabaseSchemaVersion == $0.maximumDatabaseSchemaVersion
                    ? String($0.minimumDatabaseSchemaVersion)
                    : "\($0.minimumDatabaseSchemaVersion)–\($0.maximumDatabaseSchemaVersion)"
            },
            instanceID: nil,
            errorMessage: nil
        )
    }

    static func running(
        healthValue: Any,
        expectedManifest: RuntimeReleaseManifest? = PetCoreRuntimeContract.requiredManifest
    ) -> Self? {
        guard PetCoreRuntimeContract.acceptsHealth(
            healthValue,
            expectedBuildID: expectedManifest?.buildID ?? PetCoreRuntimeContract.requiredBuildID,
            expectedManifest: expectedManifest
        ), let health = healthValue as? [String: Any]
        else { return nil }

        let manifest = RuntimeReleaseManifest.decodeHealthValue(health["runtime_manifest"])
            ?? expectedManifest
        var info = initial(manifest: manifest)
        info.phase = .running
        info.version = health["version"] as? String ?? info.version
        info.buildID = health["build_id"] as? String ?? info.buildID
        info.rpcProtocol = health["rpc_protocol"] as? String ?? info.rpcProtocol
        info.instanceID = health["instance_id"] as? String
        return info
    }

    mutating func markChecking() {
        phase = .checking
    }

    mutating func markRunning() {
        phase = .running
        errorMessage = nil
    }

    mutating func markFailed(_ reason: String) {
        phase = .failed
        errorMessage = reason
    }
}

enum AgentSessionDeepLink {
    static func url(source: AgentSource?, sessionID: String?) -> URL? {
        guard source == .codex else { return nil }
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              sessionID.count == 36,
              let uuid = UUID(uuidString: sessionID)
        else {
            return nil
        }
        let canonical = uuid.uuidString.lowercased()
        guard canonical.caseInsensitiveCompare(sessionID) == .orderedSame else {
            return nil
        }
        return URL(string: "codex://threads/\(canonical)")
    }
}

enum AgentSessionOpenRoute: Equatable {
    case url(URL)
    case application(bundleIdentifiers: [String], paths: [String])
}

enum AgentSessionRouter {
    private static let chatGPTBundleIdentifiers = ["com.openai.codex"]
    private static let chatGPTPaths = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
    private static let terminalTargets: [String: ([String], [String])] = [
        "warp": (["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"], ["/Applications/Warp.app", "/Applications/WarpPreview.app"]),
        "terminal": (["com.apple.Terminal"], ["/System/Applications/Utilities/Terminal.app"]),
        "iterm2": (["com.googlecode.iterm2"], ["/Applications/iTerm.app"]),
        "ghostty": (["com.mitchellh.ghostty"], ["/Applications/Ghostty.app"])
    ]

    static func route(
        source: AgentSource?,
        sessionID: String?,
        navigation: AgentSessionNavigation
    ) -> AgentSessionOpenRoute? {
        guard !navigation.explicitlyClosed else { return nil }

        if let openURL = validatedSessionOpenURL(navigation.openURL) {
            return .url(openURL)
        }

        if navigation.surface == "cli_terminal"
            || navigation.terminalApp != nil
            || (source != nil && source != .codex)
        {
            if let terminalApp = navigation.terminalApp,
               let target = terminalTargets[terminalApp]
            {
                return .application(bundleIdentifiers: target.0, paths: target.1)
            }
            let allTargets = ["warp", "terminal", "iterm2", "ghostty"]
                .compactMap { terminalTargets[$0] }
            return .application(
                bundleIdentifiers: allTargets.flatMap { $0.0 },
                paths: allTargets.flatMap { $0.1 }
            )
        }

        if source == .codex,
           navigation.surface == "chatgpt_app",
           navigation.sessionOpen == true,
           let deepLink = AgentSessionDeepLink.url(
               source: source,
               // Only PetCore's dedicated, strictly validated routing field
               // may cross back into a Codex task URL. Never reinterpret the
               // generic projected session identity as a routable raw ID.
               sessionID: navigation.routableSessionID
           )
        {
            return .url(deepLink)
        }

        if source == .codex {
            return .application(
                bundleIdentifiers: chatGPTBundleIdentifiers,
                paths: chatGPTPaths
            )
        }
        return nil
    }

    static func validatedSessionOpenURL(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              ["warp", "warppreview"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "session",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return nil
        }
        let identifier = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard identifier.range(
            of: "^[0-9A-Fa-f]{32}$",
            options: .regularExpression
        ) != nil
        else {
            return nil
        }
        return url
    }
}

extension AgentEvent {
    /// App Server lease renewal advances `created_at` even when every visible
    /// field is unchanged. Treat that timestamp as transport metadata so the
    /// overlay does not redraw once per poll while still publishing real
    /// state, message, navigation, or activity changes.
    func hasSamePresentation(as other: AgentEvent) -> Bool {
        id == other.id
            && source == other.source
            && sessionID == other.sessionID
            && eventType == other.eventType
            && title == other.title
            && detail == other.detail
            && payloadJSON == other.payloadJSON
    }

}

extension ActiveAgentState {
    func hasSamePresentation(as other: ActiveAgentState) -> Bool {
        let current = OverlaySessionContent(state: self)
        let next = OverlaySessionContent(state: other)
        return state == other.state
            && officialStatus == other.officialStatus
            && sessionActive == other.sessionActive
            && leaseSeconds == other.leaseSeconds
            // `expiresAt`, persisted sequence, event identity, and connector
            // lifecycle aliases are transport/audit metadata. Compare the
            // values the bubble actually renders plus the pet's semantic
            // state-entry identity so equivalent terminal edges cannot cause
            // a second redraw or animation restart.
            && current.id == next.id
            && current.source == next.source
            && current.sessionID == next.sessionID
            && current.eventType == next.eventType
            && current.sessionTitle == next.sessionTitle
            && current.messageText == next.messageText
            && current.statusText == next.statusText
            && current.actionLabel == next.actionLabel
            && current.navigation == next.navigation
            && OverlayPetAnimationIdentity.stateEntryID(for: self)
                == OverlayPetAnimationIdentity.stateEntryID(for: other)
    }
}

private func optionalEventHasSamePresentation(_ lhs: AgentEvent?, _ rhs: AgentEvent?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (.some(lhs), .some(rhs)):
        lhs.hasSamePresentation(as: rhs)
    default:
        false
    }
}

private func activeStatesHaveSamePresentation(
    _ lhs: [ActiveAgentState],
    _ rhs: [ActiveAgentState]
) -> Bool {
    lhs.count == rhs.count
        && zip(lhs, rhs).allSatisfy { $0.hasSamePresentation(as: $1) }
}

private func eventsHaveSamePresentation(_ lhs: [AgentEvent], _ rhs: [AgentEvent]) -> Bool {
    lhs.count == rhs.count
        && zip(lhs, rhs).allSatisfy { $0.hasSamePresentation(as: $1) }
}

struct OverlayBubbleLayoutSignature: Equatable {
    struct Group: Equatable {
        let id: String
        let visibleSessionCount: Int
        let isStacked: Bool
    }

    let bubbleDismissed: Bool
    let groups: [Group]

    init(contents: [OverlayBubbleContent], bubbleDismissed: Bool) {
        self.bubbleDismissed = bubbleDismissed
        groups = contents.map { content in
            Group(
                id: content.id,
                visibleSessionCount: content.visibleSessions.count,
                isStacked: content.isStacked
            )
        }
    }
}

enum PetCoreServiceFailureCode: String, Codable, Equatable, Sendable {
    case none
    case petCoreBinaryMissing = "petcore_binary_missing"
    case cliMissing = "cli_missing"
    case launchAgentDisabled = "launch_agent_disabled"
    case runtimePathsFailed = "runtime_paths_failed"
    case launchctlFailed = "launchctl_failed"
    case candidateHealthFailed = "candidate_health_failed"
    case directLaunchFailed = "direct_launch_failed"
    case updateRollbackFailed = "update_rollback_failed"
    case unknown
}

enum PetCoreServiceFailureClassifier {
    static func classify(_ reason: String) -> PetCoreServiceFailureCode {
        if reason.contains("PetCore 更新失败且回滚未完成")
            || reason.contains("PetCore 更新失败，已恢复")
        {
            return .updateRollbackFailed
        }
        if reason.contains("未找到 petcore-cli 可执行文件") {
            return .cliMissing
        }
        if reason.contains("未找到 petcore 可执行文件") {
            return .petCoreBinaryMissing
        }
        if reason.contains("LaunchAgent 已由 APC_DISABLE_LAUNCH_AGENT 禁用") {
            return .launchAgentDisabled
        }
        if reason.contains("准备 petcore 运行目录失败") {
            return .runtimePathsFailed
        }
        if reason.contains("PetCore LaunchAgent 命令失败") {
            return .launchctlFailed
        }
        if reason.contains("候选 PetCore 启动后未通过版本与健康检查")
            || reason.contains("候选 PetCore 预检失败")
            || reason.contains("LaunchAgent 已启动，但 PetCore 未在限定时间内就绪")
        {
            return .candidateHealthFailed
        }
        if reason.contains("启动 petcore 失败")
            || reason.contains("PetCore 直接启动后未在限定时间内就绪")
        {
            return .directLaunchFailed
        }
        return .unknown
    }
}

private enum PetAssetDiagnosticCategory: String {
    case assetsInvalid = "assets_invalid"
    case unknown

    static func classify(_ warning: PetAssetWarning) -> Self {
        warning.code == "pet_assets_invalid" ? .assetsInvalid : .unknown
    }
}

enum OverlayKeyboardFocusAction: CaseIterable, Hashable {
    case bubbleSessions
    case resizeHandle

    func isAvailable(overlayEnabled: Bool, bubbleSessionCount: Int) -> Bool {
        guard overlayEnabled else { return false }
        switch self {
        case .bubbleSessions:
            return bubbleSessionCount > 0
        case .resizeHandle:
            return true
        }
    }

    static func availableActions(
        overlayEnabled: Bool,
        bubbleSessionCount: Int
    ) -> Set<Self> {
        Set(allCases.filter {
            $0.isAvailable(
                overlayEnabled: overlayEnabled,
                bubbleSessionCount: bubbleSessionCount
            )
        })
    }
}

private enum LatestGenerationRestoreAttemptState: Equatable {
    case notAttempted
    case inFlight
    case resolved
}

private struct ActiveGenerationRecoveryProjectionIdentity: Equatable {
    var jobID: String
    var form: GenerationForm
    var referenceReselectionCount: Int
}

private struct SanitizedGenerationRecoveryProjection {
    var identity: ActiveGenerationRecoveryProjectionIdentity
    var form: GenerationForm?
    var referenceReselectionCount: Int
}

@MainActor
final class AppStore: ObservableObject {
    typealias BundledPetSeeder = @MainActor () async -> Bool
    typealias BundledPetSeedSleeper = @Sendable (Duration) async throws -> Void
    typealias InitialAppearanceFallbackSleeper = @Sendable (Duration) async throws -> Void
    typealias RuntimeHandoffCheck = @MainActor () -> Bool
    typealias ApplicationAppearanceApplier = @MainActor (AppearanceTheme) -> Void
    typealias OverlayPresenter = @MainActor (PetOverlayController, AppStore) -> Void
    typealias OverlayKeyboardFocusHandler = @MainActor (
        _ controller: PetOverlayController,
        _ action: OverlayKeyboardFocusAction
    ) -> Void
    typealias PetCoreRequestOverride = @MainActor (
        _ method: String,
        _ params: Any,
        _ timeout: Duration?
    ) async throws -> Any

    @Published var selection: NavigationSection = .library
    @Published private(set) var descriptionText = AIPetMakerDefaults.descriptionText
    @Published private(set) var selectedStyle: StylePreset = .semiRealistic
    @Published private(set) var selectedQuality: QualityLevel = .high
    @Published private(set) var referenceImages: [String] = []
    @Published private(set) var referenceImageIssue: MakerReferenceImageIssue?
    @Published private(set) var referenceReselectionCount = 0
    @Published var behavior = BehaviorSettings()
    @Published private(set) var activeAgentState: ActiveAgentState?
    @Published private(set) var activeAgentSessions: [ActiveAgentState] = []
    @Published private(set) var activeAgentSessionsOmittedCount = 0
    @Published private(set) var overlayVisibility = OverlayVisibility()
    @Published var pets: [PetSummary] = []
    @Published private(set) var hasLoadedStateSnapshot = false
    @Published private(set) var initialAppearanceReadiness = InitialAppearanceReadiness.pending
    @Published private(set) var petAssetWarningIndex = PetAssetWarningIndex()
    @Published var events: [AgentEvent] = []
    @Published var recentEvents: [AgentEvent] = []
    @Published var connections: [AgentConnectionStatus] = []
    @Published private(set) var generationSession = GenerationSession()
    #if DEBUG
    private var uiNextFixturePetHistories: [String: PetHistorySnapshot] = [:]
    #endif
    @Published var generationReplyText = ""
    @Published var statusText = "正在初始化"
    @Published var serviceStatusText = "正在初始化"
    @Published private(set) var petCoreOperationalState = PetCoreOperationalState.checking
    @Published private(set) var petCoreRuntimeInfo = PetCoreRuntimeInfo.initial(
        manifest: PetCoreRuntimeContract.requiredManifest
    )
    @Published private(set) var lastServiceFailureCode = PetCoreServiceFailureCode.none
    @Published var overlayScale = OverlayGeometry.defaultScale
    @Published var overlayVisible = true
    @Published var overlayScreenFrame = CGRect(x: 780, y: 140, width: 704, height: 640)
    @Published var overlayScreenVisibleFrame = NSScreen.main?.visibleFrame ?? .zero
    @Published var overlayPetScreenCenter = CGPoint.zero
    private(set) var overlayPetVisualEnvelope: OverlayPetVisualEnvelope?
    private var overlayPetFrameHitTestProjection: OverlayPetFrameHitTestProjection?
    var overlayPetFrameHitTest: OverlayPetFrameHitTest? {
        guard let projection = overlayPetFrameHitTestProjection,
              activePet?.id == projection.petID,
              OverlayPetAnimationIdentity.stateEntryID(for: presentedActiveAgentState)
                == projection.stateEntryID else {
            return nil
        }
        return projection.hitTest
    }
    @Published var overlayBubbleDismissed = false
    @Published var overlayDismissedBubbleEventIDs: Set<String> = []
    @Published private(set) var overlayAgentGroupExpansionOverrides: [AgentSource: Bool] = [:]
    @Published var overlayPointerNearPet = false
    @Published var overlayPetDragInProgress = false
    @Published var overlayResizeInProgress = false
    @Published var petOperationIDs: Set<String> = []
    @Published var isImportingPetpack = false
    @Published private(set) var petLibraryNotice: PetLibraryNotice?
    @Published private(set) var diagnosticsExportState = DiagnosticsExportState.idle
    @Published private(set) var connectionOperationState = AgentConnectionOperationState.idle
    @Published private(set) var connectionCheckCWD: String?

    private let client: PetCoreClient
    private let overlayController: PetOverlayController
    private let bootstrapHooks: AppStoreBootstrapHooks
    private let diagnostics: AppDiagnostics
    private let bundledPetSeederOverride: BundledPetSeeder?
    private let bundledPetSeedSleeper: BundledPetSeedSleeper
    private let initialAppearanceFallbackSleeper: InitialAppearanceFallbackSleeper
    private let runtimeHandoffIfNeeded: RuntimeHandoffCheck
    private let applicationAppearanceApplier: ApplicationAppearanceApplier
    private let overlayPresenter: OverlayPresenter
    private let overlayKeyboardFocusHandler: OverlayKeyboardFocusHandler
    private let petCoreRequestOverride: PetCoreRequestOverride?
    private var refreshTask: Task<Void, Never>?
    private var petpackImportTask: Task<Void, Never>?
    private var overlayPetPositionInitialized = false
    private var overlayPlacementLoaded = false
    private var isApplyingOverlayPlacement = false
    private var overlayPlacementSaveTask: Task<Void, Never>?
    private var stateRevision = ""
    private(set) var behaviorRevision = "0"
    private var overlayKnownReopenIDs: Set<String> = []
    private var overlayAwaitingVisibilityRestore = false
    private var behaviorMutationTask: Task<Void, Never>?
    private var mainWindowPresenter: (() -> Void)?
    private weak var controlCenterWindow: NSWindow?
    private var pendingMainWindowPresentation = false
    private var generationMessagesTask: Task<Void, Never>?
    private var latestGenerationRestoreAttemptState = LatestGenerationRestoreAttemptState.notAttempted
    private var latestGenerationRestoreAttemptSequence: UInt64 = 0
    private var latestGenerationRestoreInFlight: (id: UInt64, task: Task<Void, Never>)?
    private var makerUserMutationRevision: UInt64 = 0
    private var automaticLatestGenerationRestoreInvalidated = false
    private var reselectedReferenceImagePaths: Set<String> = []
    private var activeGenerationRecoveryProjection: SanitizedGenerationRecoveryProjection?
    private var runtimeBootstrapCompleted = false
    private var runtimeBootstrapRequiresFullRecovery = false
    private var runtimeBootstrapSequence: UInt64 = 0
    private var runtimeBootstrap: (id: UInt64, task: Task<Bool, Never>)?
    private var runtimeBootstrapRetryTask: Task<Void, Never>?
    private var runtimeBootstrapRetryDelaySeconds: UInt64 = 2
    private var bundledPetSeedRetryTask: Task<Void, Never>?
    private var initialAppearanceFallbackTask: Task<Void, Never>?
    private var recoverySequence: UInt64 = 0
    private var serviceRecovery: (id: UInt64, task: Task<Bool, Never>)?
    private var connectionOperationGate = AgentConnectionOperationGate()
    private var hasPresentedOverlay = false

    static let bundledPetSeedRetryDelays: [Duration] = [
        .seconds(2),
        .seconds(4),
        .seconds(8)
    ]
    static let initialAppearanceFallbackDelay: Duration = .milliseconds(500)
    static let controlCenterWindowIdentifier = NSUserInterfaceItemIdentifier(
        "dev.agentpet.companion.control-center"
    )
    private static let defaultOverlayKeyboardFocusHandler: OverlayKeyboardFocusHandler = { controller, action in
        switch action {
        case .bubbleSessions:
            controller.focusBubbleForKeyboardNavigation()
        case .resizeHandle:
            controller.focusResizeForKeyboardNavigation()
        }
    }

    init(diagnostics: AppDiagnostics = .shared) {
        let processManager = PetCoreProcessManager()
        let bootstrapCoordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await processManager.ensureRunning() }
        )
        client = PetCoreClient()
        overlayController = PetOverlayController()
        self.diagnostics = diagnostics
        bundledPetSeederOverride = nil
        bundledPetSeedSleeper = { duration in
            try await Task.sleep(for: duration)
        }
        initialAppearanceFallbackSleeper = { duration in
            try await Task.sleep(for: duration)
        }
        runtimeHandoffIfNeeded = {
            AppUpdateHandoffCoordinator.shared.restartIfInstalledBuildChanged()
        }
        applicationAppearanceApplier = { theme in
            APCApplicationAppearance.apply(theme)
        }
        overlayPresenter = { controller, store in
            controller.show(store: store)
        }
        overlayKeyboardFocusHandler = Self.defaultOverlayKeyboardFocusHandler
        petCoreRequestOverride = nil
        bootstrapHooks = AppStoreBootstrapHooks(
            ensureRunning: { await bootstrapCoordinator.ensureRunning() },
            recover: { await bootstrapCoordinator.recover() },
            fetchInitialBehavior: { store in
                try await store.requestPetCore(method: "behavior.get")
            },
            refreshSnapshot: { store in try await store.refreshSnapshot() },
            onReady: { store in await store.completeRuntimeBootstrap() }
        )
    }

    init(
        client: PetCoreClient = PetCoreClient(),
        bootstrapHooks: AppStoreBootstrapHooks,
        diagnostics: AppDiagnostics = .disabled,
        bundledPetSeeder: BundledPetSeeder? = nil,
        bundledPetSeedSleeper: @escaping BundledPetSeedSleeper = { duration in
            try await Task.sleep(for: duration)
        },
        initialAppearanceFallbackSleeper: @escaping InitialAppearanceFallbackSleeper = { duration in
            try await Task.sleep(for: duration)
        },
        runtimeHandoffIfNeeded: @escaping RuntimeHandoffCheck = { false },
        applicationAppearanceApplier: @escaping ApplicationAppearanceApplier = { theme in
            APCApplicationAppearance.apply(theme)
        },
        overlayPresenter: @escaping OverlayPresenter = { controller, store in
            controller.show(store: store)
        },
        overlayKeyboardFocusHandler: OverlayKeyboardFocusHandler? = nil,
        petCoreRequestOverride: PetCoreRequestOverride? = nil
    ) {
        self.client = client
        overlayController = PetOverlayController()
        self.bootstrapHooks = bootstrapHooks
        self.diagnostics = diagnostics
        bundledPetSeederOverride = bundledPetSeeder
        self.bundledPetSeedSleeper = bundledPetSeedSleeper
        self.initialAppearanceFallbackSleeper = initialAppearanceFallbackSleeper
        self.runtimeHandoffIfNeeded = runtimeHandoffIfNeeded
        self.applicationAppearanceApplier = applicationAppearanceApplier
        self.overlayPresenter = overlayPresenter
        self.overlayKeyboardFocusHandler = overlayKeyboardFocusHandler
            ?? Self.defaultOverlayKeyboardFocusHandler
        self.petCoreRequestOverride = petCoreRequestOverride
    }

    var activePet: PetSummary? {
        pets.first(where: \.active)
    }

    /// Compatibility projection for older callers. The typed operation state
    /// remains the single source of truth for serialization and failure UI.
    var connectionOperationSources: Set<AgentSource> {
        Set(connectionOperationState.runningOperation?.sources ?? [])
    }

    var activeOverlayEvent: AgentEvent? {
        presentedActiveAgentState?.event
    }

    var presentedActiveAgentState: ActiveAgentState? {
        OverlayPresentedAgentState.resolve(
            canonicalState: activeAgentState,
            activeSessions: activeAgentSessions,
            dismissedSessionIDs: overlayDismissedBubbleEventIDs
        )
    }

    var activeAgentEventText: String {
        activeOverlayEvent.map { "\($0.source.title) · \($0.title)" } ?? "暂无活跃 Agent 事件"
    }

    var overlayBubbleEvents: [AgentEvent] {
        activeAgentSessions
            .map(\.event)
            .filter {
                !overlayDismissedBubbleEventIDs.contains(OverlaySessionContent.stableID(
                    source: $0.source,
                    sessionID: $0.sessionID,
                    fallbackEventID: $0.id
                ))
            }
    }

    var overlayAvailableBubbleContents: [OverlayBubbleContent] {
        guard overlayVisibility.statusBubbleVisible else { return [] }
        let visibleStates = activeAgentSessions.filter {
            !overlayDismissedBubbleEventIDs.contains(OverlaySessionContent.stableID(
                source: $0.source,
                sessionID: $0.sessionID ?? $0.event.sessionID,
                fallbackEventID: $0.event.id
            ))
        }
        var grouped = AgentSource.allCases.compactMap { source -> OverlayBubbleContent? in
            let states = visibleStates.filter { $0.source == source }
            return states.isEmpty ? nil : OverlayBubbleContent(
                source: source,
                states: states,
                isExpanded: overlayAgentGroupIsExpanded(source)
            )
        }
        if activeAgentSessionsOmittedCount > 0 {
            grouped.append(.omittedSummary(count: activeAgentSessionsOmittedCount))
        }
        if !grouped.isEmpty {
            return grouped
        }
        return activeAgentState == nil && activeAgentSessions.isEmpty ? [.idle] : []
    }

    var overlayBubbleContents: [OverlayBubbleContent] {
        guard !overlayBubbleDismissed else { return [] }
        return overlayAvailableBubbleContents
    }

    var hasAvailableOverlayBubbleContent: Bool {
        !overlayAvailableBubbleContents.isEmpty
    }

    var overlayBubbleSessionCount: Int {
        overlayAvailableBubbleContents
            .reduce(0) { $0 + $1.representedSessionCount }
    }

    var canFocusOverlayBubbleForKeyboardNavigation: Bool {
        overlayKeyboardFocusActions.contains(.bubbleSessions)
    }

    var canFocusOverlayResizeForKeyboardNavigation: Bool {
        overlayKeyboardFocusActions.contains(.resizeHandle)
    }

    private var overlayKeyboardFocusActions: Set<OverlayKeyboardFocusAction> {
        OverlayKeyboardFocusAction.availableActions(
            overlayEnabled: behavior.enabled,
            bubbleSessionCount: overlayBubbleSessionCount
        )
    }

    var overlayBubbleStatusTone: OverlaySessionGroupTone {
        OverlaySessionGroupTone.aggregate(
            overlayAvailableBubbleContents.flatMap(\.sessions)
        )
    }

    var overlayBubbleIsCollapsed: Bool {
        overlayBubbleDismissed || overlayBubbleContents.isEmpty
    }

    func overlayAgentGroupIsExpanded(_ source: AgentSource) -> Bool {
        overlayAgentGroupExpansionOverrides[source]
            ?? (behavior.sessionGroupDisplay == .expanded)
    }

    var canStartGeneration: Bool {
        !generationSession.isActive
            && GenerationPromptPolicy.isValid(descriptionText)
    }

    var isWaitingForGenerationInput: Bool {
        generationSession.state == .waitingForInput
    }

    var canSendGenerationReply: Bool {
        generationSession.canSendReply
    }

    var canRetryGeneration: Bool {
        generationSession.canRetry
            && referenceReselectionCount == 0
            && (generationSession.operation == .modify
                || !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var generationStateTitle: String {
        if generationSession.operation == .modify {
            return switch generationSession.state {
            case .idle: "尚未开始"
            case .starting: "正在启动修改"
            case .running: "正在修改"
            case .waitingForInput: "修改等待补充信息"
            case .cancelling: "正在取消修改"
            case .succeeded: "修改完成"
            case .failed: "修改失败"
            case .cancelled: "修改已取消"
            }
        }
        return switch generationSession.state {
        case .idle: "尚未开始"
        case .starting: "正在启动"
        case .running: "正在生成"
        case .waitingForInput: "等待补充信息"
        case .cancelling: "正在取消"
        case .succeeded: "生成完成"
        case .failed: "生成失败"
        case .cancelled: "已取消"
        }
    }

    func setMainWindowPresenter(_ presenter: @escaping () -> Void) {
        mainWindowPresenter = presenter
        guard pendingMainWindowPresentation else { return }
        pendingMainWindowPresentation = false
        guard !runtimeHandoffIfNeeded() else { return }
        presenter()
        NSApp?.activate(ignoringOtherApps: true)
    }

    func registerControlCenterWindow(_ window: NSWindow) {
        window.identifier = Self.controlCenterWindowIdentifier
        controlCenterWindow = window
    }

    func presentMainWindow() {
        guard !runtimeHandoffIfNeeded() else { return }
        if frontExistingMainWindow() {
            pendingMainWindowPresentation = false
            NSApp?.activate(ignoringOtherApps: true)
            return
        }

        if let mainWindowPresenter {
            pendingMainWindowPresentation = false
            mainWindowPresenter()
        } else {
            // A secondary launch or Dock reopen can arrive before either scene
            // has installed its openWindow presenter. Replay exactly once when
            // the first presenter becomes available.
            pendingMainWindowPresentation = true
        }
        NSApp?.activate(ignoringOtherApps: true)
    }

    func presentAgentSession(
        source: AgentSource?,
        sessionID: String? = nil,
        navigation: AgentSessionNavigation = AgentSessionNavigation()
    ) {
        guard source != nil else {
            presentMainWindow()
            return
        }
        guard let route = AgentSessionRouter.route(
            source: source,
            sessionID: sessionID,
            navigation: navigation
        ) else { return }
        let workspace = NSWorkspace.shared
        switch route {
        case let .url(url):
            if workspace.open(url) { return }
            let fallback = AgentSessionRouter.route(
                source: source,
                sessionID: nil,
                navigation: AgentSessionNavigation(
                    sessionOpen: navigation.sessionOpen,
                    surface: navigation.surface,
                    terminalApp: navigation.terminalApp
                )
            )
            guard case let .application(bundleIdentifiers, paths) = fallback else {
                presentMainWindow()
                return
            }
            openAgentApplication(bundleIdentifiers: bundleIdentifiers, paths: paths)
        case let .application(bundleIdentifiers, paths):
            openAgentApplication(bundleIdentifiers: bundleIdentifiers, paths: paths)
        }
    }

    func activateOverlaySession(_ session: OverlaySessionContent) {
        if session.canOpen {
            presentAgentSession(
                source: session.source,
                sessionID: session.sessionID,
                navigation: session.navigation
            )
        } else if session.source == nil {
            presentMainWindow()
        }

        if session.dismissesAfterActivation {
            dismissOverlayBubble(eventID: session.id)
        }
    }

    private func openAgentApplication(bundleIdentifiers: [String], paths: [String]) {
        let workspace = NSWorkspace.shared
        if let running = workspace.runningApplications
            .filter({ application in
                application.bundleIdentifier.map(bundleIdentifiers.contains) == true
                    && !application.isTerminated
            })
            .sorted(by: { ($0.isActive ? 1 : 0) > ($1.isActive ? 1 : 0) })
            .first,
           running.activate(options: [])
        {
            return
        }
        let applicationURL = bundleIdentifiers.lazy
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            .first
            ?? paths
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        guard let applicationURL else {
            presentMainWindow()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
    }

    private func frontExistingMainWindow() -> Bool {
        guard let application = NSApp else {
            return false
        }
        let window = if let controlCenterWindow,
                        Self.isMainWindowCandidate(controlCenterWindow) {
            controlCenterWindow
        } else {
            application.windows.first(where: Self.isMainWindowCandidate)
        }
        guard let window else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        window.identifier == controlCenterWindowIdentifier
            && !(window is NSPanel)
            && window.level == .normal
            && window.styleMask.contains(.titled)
    }

    private enum RuntimeBootstrapStartMode {
        case ensureRunning
        case recover
    }

    func bootstrapIfNeeded() async {
        _ = await runRuntimeBootstrapIfNeeded(startMode: .ensureRunning)
    }

    private func runRuntimeBootstrapIfNeeded(
        startMode: RuntimeBootstrapStartMode
    ) async -> Bool {
        if runtimeBootstrapCompleted { return true }
        if let runtimeBootstrap {
            return await runtimeBootstrap.task.value
        }

        runtimeBootstrapSequence &+= 1
        let id = runtimeBootstrapSequence
        let task = Task { @MainActor [weak self] in
            await self?.performRuntimeBootstrap(startMode: startMode) ?? false
        }
        runtimeBootstrap = (id, task)
        let succeeded = await task.value
        if runtimeBootstrap?.id == id {
            runtimeBootstrap = nil
        }
        return succeeded
    }

    private func performRuntimeBootstrap(
        startMode: RuntimeBootstrapStartMode
    ) async -> Bool {
        diagnostics.log(.info, category: "service", event: "petcore_bootstrap_started")
        setServiceChecking()
        // Bound the invisible window gate from bootstrap start. Runtime
        // replacement and rollback can take much longer than appearance
        // hydration, and must not make the App look dead while it is checking.
        scheduleInitialAppearanceFallback()
        let startResult = switch startMode {
        case .ensureRunning:
            await bootstrapHooks.ensureRunning()
        case .recover:
            await bootstrapHooks.recover()
        }
        switch startResult {
        case .alreadyHealthy, .started:
            diagnostics.log(.notice, category: "service", event: "petcore_bootstrap_ready")
            setServiceOnline()
            runtimeBootstrapRetryTask?.cancel()
            runtimeBootstrapRetryTask = nil
            runtimeBootstrapRetryDelaySeconds = 2
            await prepareInitialAppearance()
            await bootstrapHooks.onReady(self)
            // Prefer the first authoritative snapshot when behavior.get could
            // not provide a theme, but never hold the window beyond the
            // bounded appearance fallback scheduled above.
            if initialAppearanceReadiness == .pending {
                resolveInitialAppearanceAsUnavailable()
            }
            runtimeBootstrapCompleted = true
            runtimeBootstrapRequiresFullRecovery = false
            presentOverlayAfterFirstSnapshotIfNeeded()
            return true
        case let .failed(reason):
            let failureCode = PetCoreServiceFailureClassifier.classify(reason)
            diagnostics.log(
                .error,
                category: "service",
                event: "petcore_bootstrap_failed",
                metadata: ["failure_code": .string(failureCode.rawValue)],
                throttleKey: "petcore_bootstrap_failed",
                minimumInterval: 30
            )
            setServiceFailure(reason, failureCode: failureCode)
            runtimeBootstrapRequiresFullRecovery = true
            resolveInitialAppearanceAsUnavailable()
            scheduleRuntimeBootstrapRetry()
            return false
        }
    }

    private func scheduleInitialAppearanceFallback() {
        guard initialAppearanceReadiness == .pending,
              initialAppearanceFallbackTask == nil
        else { return }
        let sleeper = initialAppearanceFallbackSleeper
        initialAppearanceFallbackTask = Task { @MainActor [weak self] in
            do {
                try await sleeper(Self.initialAppearanceFallbackDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.initialAppearanceReadiness == .pending
            else { return }
            self.initialAppearanceFallbackTask = nil
            self.initialAppearanceReadiness = .unavailable
        }
    }

    private func resolveInitialAppearanceAsUnavailable() {
        initialAppearanceFallbackTask?.cancel()
        initialAppearanceFallbackTask = nil
        if initialAppearanceReadiness == .pending {
            initialAppearanceReadiness = .unavailable
        }
    }

    private func resolveInitialAppearanceAsAuthoritative() {
        initialAppearanceFallbackTask?.cancel()
        initialAppearanceFallbackTask = nil
        initialAppearanceReadiness = .authoritative
    }

    private func prepareInitialAppearance() async {
        guard initialAppearanceReadiness != .authoritative else { return }
        guard let fetchInitialBehavior = bootstrapHooks.fetchInitialBehavior else {
            return
        }

        do {
            let result = try await fetchInitialBehavior(self)
            let data = try JSONSerialization.data(withJSONObject: result)
            let versioned = try JSONDecoder().decode(
                VersionedBehaviorSettings.self,
                from: data
            )
            // A full snapshot may arrive through an explicit refresh while the
            // focused behavior request is suspended. Once that snapshot is
            // authoritative, never publish this older focused result.
            guard initialAppearanceReadiness != .authoritative else { return }
            // The publication order is deliberate: every window gate observing
            // readiness must see behavior, revision, and AppKit appearance as
            // one fully prepared initial presentation state.
            behavior = versioned.behavior
            behaviorRevision = versioned.revision
            applyCurrentAppearance()
            resolveInitialAppearanceAsAuthoritative()
        } catch {
            diagnostics.logFailure(
                error,
                category: "service",
                event: "initial_appearance_unavailable",
                throttleKey: "initial_appearance_unavailable",
                minimumInterval: 30
            )
        }
    }

    func retryPetCoreStartup() {
        guard petCoreRuntimeInfo.phase != .running else { return }
        diagnostics.log(.notice, category: "service", event: "petcore_retry_requested")
        runtimeBootstrapRetryTask?.cancel()
        runtimeBootstrapRetryTask = nil
        setServiceChecking()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.recoverServiceConnection()
        }
    }

    private func scheduleRuntimeBootstrapRetry() {
        guard !runtimeBootstrapCompleted, runtimeBootstrapRetryTask == nil else { return }
        let delay = runtimeBootstrapRetryDelaySeconds
        diagnostics.log(
            .info,
            category: "service",
            event: "petcore_retry_scheduled",
            metadata: ["delay_seconds": .integer(Int64(delay))],
            throttleKey: "petcore_retry_scheduled",
            minimumInterval: 5
        )
        runtimeBootstrapRetryDelaySeconds = min(delay * 2, 30)
        runtimeBootstrapRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.runtimeBootstrapRetryTask = nil
            await self.bootstrapIfNeeded()
        }
    }

    private func completeRuntimeBootstrap() async {
        await refreshPetCoreRuntimeInfo()
        diagnostics.log(
            .notice,
            category: "service",
            event: "petcore_runtime_connected",
            metadata: [
                "version": .string(petCoreRuntimeInfo.version ?? "unknown"),
                "build_id": .string(petCoreRuntimeInfo.buildID ?? "unknown"),
                "rpc_protocol": .string(petCoreRuntimeInfo.rpcProtocol ?? "unknown")
            ]
        )
        let bundledPetsReady = await performBundledPetSeed()
        let bundledPetFailureStatus = bundledPetsReady ? nil : statusText
        let snapshotReady = await refreshDuringRuntimeBootstrap()
        if let bundledPetFailureStatus, snapshotReady {
            // A healthy state snapshot must not hide a failed inventory seed.
            // Keep the actionable library error visible while bounded retries
            // continue independently of PetCore runtime rollback.
            statusText = bundledPetFailureStatus
        }
        if !bundledPetsReady {
            scheduleBundledPetSeedRetry()
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.waitForStateChange()
            }
        }
    }

    /// Seeds the closed, content-pinned App inventory before the first state
    /// snapshot is presented. PetCore resolves conflicts by stable manifest ID:
    /// matching IDs are preserved, while equal display names with distinct IDs
    /// coexist in the library.
    private func seedBundledPets() async -> Bool {
        guard BundledPetInventory.hasCompleteResources() else {
            diagnostics.log(
                .error,
                category: "library",
                event: "bundled_pet_seed_failed",
                metadata: ["failure_code": .string("resource_missing")]
            )
            statusText = "App 内置宠物资源不完整"
            return false
        }

        do {
            let result = try await requestPetCore(
                method: "petpack.seed_bundled",
                params: BundledPetInventory.rpcParameters
            )
            let outcomes = (result as? [String: Any])?["outcomes"] as? [[String: Any]] ?? []
            let installedCount = outcomes.lazy.filter {
                $0["status"] as? String == "installed"
            }.count
            diagnostics.log(
                .info,
                category: "library",
                event: "bundled_pet_seed_completed",
                metadata: [
                    "inventory_count": .integer(Int64(BundledPetInventory.fileNames.count)),
                    "installed_count": .integer(Int64(installedCount))
                ]
            )
            return true
        } catch {
            diagnostics.logFailure(
                error,
                category: "library",
                event: "bundled_pet_seed_failed",
                throttleKey: "bundled_pet_seed_failed",
                minimumInterval: 30
            )
            statusText = "App 内置宠物加载失败：\(error.localizedDescription)"
            return false
        }
    }

    private func performBundledPetSeed() async -> Bool {
        if let bundledPetSeederOverride {
            return await bundledPetSeederOverride()
        }
        return await seedBundledPets()
    }

    private func scheduleBundledPetSeedRetry() {
        guard bundledPetSeedRetryTask == nil else { return }
        bundledPetSeedRetryTask = Task { @MainActor [weak self] in
            guard let store = self else { return }
            defer { store.bundledPetSeedRetryTask = nil }
            _ = await store.retryBundledPetSeedAfterBootstrapFailure()
        }
    }

    /// Retries only the App inventory ensure operation. This intentionally
    /// does not call the runtime launcher or last-known-good rollback path.
    /// The injected seeder and sleeper keep the bounded behavior testable
    /// without launching the App UI or taking over user input.
    func retryBundledPetSeedAfterBootstrapFailure() async -> Bool {
        for delay in Self.bundledPetSeedRetryDelays {
            do {
                try await bundledPetSeedSleeper(delay)
            } catch {
                return false
            }
            guard !Task.isCancelled else { return false }
            if await performBundledPetSeed() {
                let snapshotReady = await refresh()
                if snapshotReady, Self.isBundledPetSeedFailureStatus(statusText) {
                    statusText = "App 内置宠物已加载"
                }
                return snapshotReady
            }
        }
        return false
    }

    private static func isBundledPetSeedFailureStatus(_ value: String) -> Bool {
        value == "App 内置宠物资源不完整"
            || value.hasPrefix("App 内置宠物加载失败")
    }

    @discardableResult
    func refresh() async -> Bool {
        await refresh(recoveryMode: .coordinated)
    }

    private enum SnapshotRecoveryMode {
        case coordinated
        case runtimeBootstrap
    }

    private func refreshDuringRuntimeBootstrap() async -> Bool {
        await refresh(recoveryMode: .runtimeBootstrap)
    }

    private func refresh(recoveryMode: SnapshotRecoveryMode) async -> Bool {
        do {
            try await bootstrapHooks.refreshSnapshot(self)
            setServiceOnline()
            return true
        } catch {
            diagnostics.logFailure(
                error,
                category: "service",
                event: "petcore_snapshot_failed",
                throttleKey: "petcore_snapshot_failed",
                minimumInterval: 30
            )
            setServiceFailure(
                "本地服务连接失败：\(error.localizedDescription)",
                status: "PetCore 连接失败",
                operationalState: .offline
            )
            switch recoveryMode {
            case .coordinated:
                return await recoverServiceConnection()
            case .runtimeBootstrap:
                return await runServiceRecovery()
            }
        }
    }

    func recoverServiceConnection() async -> Bool {
        if let runtimeBootstrap {
            runtimeBootstrapRetryTask?.cancel()
            runtimeBootstrapRetryTask = nil
            return await runtimeBootstrap.task.value
        }
        if runtimeBootstrapRequiresFullRecovery {
            runtimeBootstrapRetryTask?.cancel()
            runtimeBootstrapRetryTask = nil
            return await runRuntimeBootstrapIfNeeded(startMode: .recover)
        }
        if let serviceRecovery {
            return await serviceRecovery.task.value
        }

        recoverySequence &+= 1
        let id = recoverySequence
        let task = Task { @MainActor [weak self] in
            await self?.runServiceRecovery() ?? false
        }
        serviceRecovery = (id, task)
        let recovered = await task.value
        if serviceRecovery?.id == id {
            serviceRecovery = nil
        }
        return recovered
    }

    private func runServiceRecovery() async -> Bool {
        setServiceRecovering()
        diagnostics.log(.info, category: "service", event: "petcore_recovery_started")
        switch await bootstrapHooks.recover() {
        case .alreadyHealthy, .started:
            do {
                try await bootstrapHooks.refreshSnapshot(self)
                diagnostics.log(.notice, category: "service", event: "petcore_recovery_succeeded")
                setServiceOnline()
                return true
            } catch {
                diagnostics.logFailure(
                    error,
                    category: "service",
                    event: "petcore_recovery_snapshot_failed",
                    throttleKey: "petcore_recovery_snapshot_failed",
                    minimumInterval: 30
                )
                setServiceFailure(
                    "本地服务连接失败：\(error.localizedDescription)",
                    status: "PetCore 连接失败",
                    operationalState: .offline
                )
                return false
            }
        case let .failed(reason):
            let failureCode = PetCoreServiceFailureClassifier.classify(reason)
            diagnostics.log(
                .error,
                category: "service",
                event: "petcore_recovery_failed",
                metadata: ["failure_code": .string(failureCode.rawValue)],
                throttleKey: "petcore_recovery_failed",
                minimumInterval: 30
            )
            setServiceFailure(reason, failureCode: failureCode)
            return false
        }
    }

    private func refreshSnapshot() async throws {
        let result = try await requestPetCore(method: "state.snapshot")
        try applyStateSnapshot(result)
        if latestGenerationRestoreAttemptState != .resolved {
            await restoreLatestGenerationSessionIfNeeded()
        }
        setServiceOnline()
    }

    private func waitForStateChange() async {
        // With no time-limited active state, the daemon revision wakes this
        // request immediately. A longer idle wait avoids decoding and
        // republishing an unchanged full snapshot every three seconds while
        // still keeping generation and event-expiry paths responsive.
        let timeoutMs = if generationSession.isActive {
            1_000
        } else if activeAgentState != nil {
            3_000
        } else {
            30_000
        }
        do {
            let result = try await requestPetCore(
                method: "state.wait",
                params: [
                    "after_revision": stateRevision,
                    "timeout_ms": timeoutMs
                ],
                timeout: .seconds(35)
            )
            try applyStateSnapshot(result)
            setServiceOnline()
        } catch {
            diagnostics.logFailure(
                error,
                category: "service",
                event: "petcore_state_wait_failed",
                throttleKey: "petcore_state_wait_failed",
                minimumInterval: 30
            )
            setServiceFailure(
                "本地服务连接失败：\(error.localizedDescription)",
                status: "PetCore 连接失败",
                operationalState: .offline
            )
            if !(await recoverServiceConnection()) {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshPetCoreRuntimeInfo() async {
        guard let result = try? await requestPetCore(
            method: "petcore.health",
            timeout: .seconds(1)
        ), let info = PetCoreRuntimeInfo.running(healthValue: result)
        else { return }
        petCoreRuntimeInfo = info
    }

    private func setServiceChecking() {
        petCoreOperationalState = .checking
        var nextRuntimeInfo = petCoreRuntimeInfo
        nextRuntimeInfo.markChecking()
        if petCoreRuntimeInfo != nextRuntimeInfo {
            petCoreRuntimeInfo = nextRuntimeInfo
        }
        setServiceStatusText("正在检查本地服务版本与兼容性")
    }

    private func setServiceRecovering() {
        petCoreOperationalState = .recovering
        setServiceStatusText("正在恢复本地服务")
    }

    private func setServiceFailure(
        _ reason: String,
        status: String = "PetCore 启动失败",
        failureCode: PetCoreServiceFailureCode? = nil,
        operationalState: PetCoreOperationalState? = nil
    ) {
        let resolvedFailureCode = failureCode ?? PetCoreServiceFailureClassifier.classify(reason)
        lastServiceFailureCode = resolvedFailureCode
        petCoreOperationalState = operationalState ?? .failure(for: resolvedFailureCode)
        var nextRuntimeInfo = petCoreRuntimeInfo
        nextRuntimeInfo.markFailed(reason)
        if petCoreRuntimeInfo != nextRuntimeInfo {
            petCoreRuntimeInfo = nextRuntimeInfo
        }
        setServiceStatusText(status)
    }

    private func setServiceOnline() {
        lastServiceFailureCode = .none
        petCoreOperationalState = .online
        var nextRuntimeInfo = petCoreRuntimeInfo
        nextRuntimeInfo.markRunning()
        if petCoreRuntimeInfo != nextRuntimeInfo {
            petCoreRuntimeInfo = nextRuntimeInfo
        }
        setServiceStatusText("本地服务运行中")
    }

    private func setServiceStatusText(_ value: String) {
        let shouldMirrorToStatus = statusText == serviceStatusText
            || statusText == "正在初始化"
            || statusText.hasPrefix("本地服务")
            || statusText.hasPrefix("PetCore")
        if serviceStatusText != value {
            serviceStatusText = value
        }
        if shouldMirrorToStatus, statusText != value {
            statusText = value
        }
    }

    func applyStateSnapshot(_ result: Any) throws {
        let previousOverlayBubbleLayout = OverlayBubbleLayoutSignature(
            contents: overlayBubbleContents,
            bubbleDismissed: overlayBubbleDismissed
        )
        let data = try JSONSerialization.data(withJSONObject: result)
        let snapshot = try JSONDecoder().decode(StateSnapshot.self, from: data)
        if let activeGeneration = snapshot.activeGeneration {
            reconcileActiveGeneration(activeGeneration)
        }
        let previousSessionGroupDisplay = behavior.sessionGroupDisplay
        let previousAppearanceTheme = behavior.appearanceTheme
        let behaviorChanged = behavior != snapshot.behavior
        if behaviorChanged {
            behavior = snapshot.behavior
            if behavior.sessionGroupDisplay != previousSessionGroupDisplay {
                overlayAgentGroupExpansionOverrides.removeAll()
            }
        }
        behaviorRevision = snapshot.behaviorRevision ?? behaviorRevision
        if behavior.appearanceTheme != previousAppearanceTheme
            || initialAppearanceReadiness != .authoritative
        {
            applyCurrentAppearance()
        }
        let activeStateChanged = switch (activeAgentState, snapshot.activeAgentState) {
        case (nil, nil):
            false
        case let (.some(current), .some(next)):
            !current.hasSamePresentation(as: next)
        default:
            true
        }
        if activeStateChanged {
            activeAgentState = snapshot.activeAgentState
        }
        let nextActiveAgentSessions = snapshot.activeAgentSessions
            ?? snapshot.activeAgentState.map { [$0] }
            ?? []
        let nextActiveAgentSessionsOmittedCount = max(
            0,
            snapshot.activeAgentSessionsOmittedCount ?? 0
        )
        let activeSessionsChanged = !activeStatesHaveSamePresentation(
            activeAgentSessions,
            nextActiveAgentSessions
        )
        if activeSessionsChanged {
            activeAgentSessions = nextActiveAgentSessions
        }
        if activeAgentSessionsOmittedCount != nextActiveAgentSessionsOmittedCount {
            activeAgentSessionsOmittedCount = nextActiveAgentSessionsOmittedCount
        }
        let nextOverlayVisibility = snapshot.overlayVisibility ?? OverlayVisibility(
            petVisible: snapshot.behavior.enabled,
            statusBubbleVisible: snapshot.behavior.enabled
                && snapshot.behavior.statusBubble
                && (!nextActiveAgentSessions.isEmpty
                    || (!snapshot.behavior.autoHide && snapshot.activeAgentState == nil))
        )
        let overlayVisibilityChanged = overlayVisibility != nextOverlayVisibility
        if overlayVisibilityChanged {
            overlayVisibility = nextOverlayVisibility
        }
        if pets != snapshot.pets {
            pets = snapshot.pets
        }
        let assetWarnings = snapshot.petAssetWarnings ?? []
        let nextPetAssetWarningIndex = PetAssetWarningIndex(assetWarnings)
        if petAssetWarningIndex != nextPetAssetWarningIndex {
            petAssetWarningIndex = nextPetAssetWarningIndex
            if !assetWarnings.isEmpty {
                let categories = Set(assetWarnings.map(PetAssetDiagnosticCategory.classify))
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ",")
                diagnostics.log(
                    .warning,
                    category: "render",
                    event: "pet_asset_warnings_changed",
                    metadata: [
                        "warning_count": .integer(Int64(assetWarnings.count)),
                        "warning_categories": .string(categories)
                    ],
                    throttleKey: "pet_asset_warnings_changed",
                    minimumInterval: 30
                )
            }
        }
        if !eventsHaveSamePresentation(events, snapshot.events) {
            events = snapshot.events
        }
        let restoringOverlayVisibility = overlayAwaitingVisibilityRestore
        let nextDismissalIDs = Set(nextActiveAgentSessions.map {
            OverlaySessionContent.stableID(
                source: $0.source,
                sessionID: $0.sessionID ?? $0.event.sessionID,
                fallbackEventID: $0.event.id
            )
        })
        let nextReopenIDs = Set(nextActiveAgentSessions.map(OverlaySessionContent.reopenID(for:)))
        let newlyActivatedDismissalIDs = OverlayPresentedAgentState.newlyActivatedDismissalIDs(
            activeSessions: nextActiveAgentSessions,
            knownReopenIDs: overlayKnownReopenIDs
        )
        let hasNewOverlayActivation = !newlyActivatedDismissalIDs.isEmpty
        if !snapshot.behavior.enabled {
            overlayAwaitingVisibilityRestore = true
            overlayKnownReopenIDs.formUnion(nextReopenIDs)
        } else if restoringOverlayVisibility, nextReopenIDs.isEmpty {
            // PetCore can publish enabled=true before active session arbitration catches up.
            // Preserve manual dismissal state until the restored session set arrives.
        } else {
            var nextDismissedBubbleEventIDs = overlayDismissedBubbleEventIDs
            nextDismissedBubbleEventIDs.formIntersection(nextDismissalIDs)
            nextDismissedBubbleEventIDs.subtract(newlyActivatedDismissalIDs)
            if overlayDismissedBubbleEventIDs != nextDismissedBubbleEventIDs {
                overlayDismissedBubbleEventIDs = nextDismissedBubbleEventIDs
            }
            overlayKnownReopenIDs = nextReopenIDs
            overlayAwaitingVisibilityRestore = false
        }
        if hasNewOverlayActivation, overlayBubbleDismissed {
            overlayBubbleDismissed = false
        }
        let nextRecentEvents = snapshot.recentEvents ?? snapshot.events
        if !eventsHaveSamePresentation(recentEvents, nextRecentEvents) {
            recentEvents = nextRecentEvents
        }
        applyAuthoritativeConnectionSnapshot(snapshot.connections)
        stateRevision = snapshot.revision ?? stateRevision
        let snapshotPlacement = snapshot.overlayPlacement ?? OverlayPlacement()
        if !overlayPlacementLoaded {
            applyOverlayPlacement(snapshotPlacement)
        } else if shouldApplyRemoteOverlayPlacement(snapshotPlacement) {
            applyOverlayPlacement(snapshotPlacement)
        }
        syncOverlayVisibilityForBehavior()
        let overlayBubbleLayoutChanged = previousOverlayBubbleLayout
            != OverlayBubbleLayoutSignature(
                contents: overlayBubbleContents,
                bubbleDismissed: overlayBubbleDismissed
            )
        if overlayBubbleLayoutChanged
            || overlayVisibilityChanged
            || behavior.sessionGroupDisplay != previousSessionGroupDisplay
        {
            overlayController.updateLayout()
        }
        if initialAppearanceReadiness != .authoritative {
            resolveInitialAppearanceAsAuthoritative()
        }
        if !hasLoadedStateSnapshot {
            hasLoadedStateSnapshot = true
        }
        presentOverlayAfterFirstSnapshotIfNeeded()
    }

    private func presentOverlayAfterFirstSnapshotIfNeeded() {
        guard runtimeBootstrapCompleted,
              hasLoadedStateSnapshot,
              !hasPresentedOverlay
        else { return }
        hasPresentedOverlay = true
        overlayPresenter(overlayController, self)
    }

    #if DEBUG
    /// Deterministic preview-only state injection. It intentionally bypasses
    /// bootstrap, persistence, and the real overlay presenter while using the
    /// same observable properties consumed by production views.
    func configureForUINextVisualFixture(
        pets: [PetSummary],
        connections: [AgentConnectionStatus],
        events: [AgentEvent],
        operationalState: PetCoreOperationalState,
        connectionOperationState: AgentConnectionOperationState = .idle,
        connectionCheckCWD: String? = nil,
        petHistories: [String: PetHistorySnapshot] = [:],
        generationRestore: GenerationSessionRestore? = nil
    ) {
        self.pets = pets
        self.connections = connections
        self.events = events
        recentEvents = events
        self.connectionOperationState = connectionOperationState
        self.connectionCheckCWD = connectionCheckCWD
        uiNextFixturePetHistories = petHistories
        if let generationRestore {
            let restore = sanitizedGenerationRestore(generationRestore)
            _ = reduceGeneration(.restore(restore))
            applyRestoredGenerationForm(
                restore.submittedForm,
                referenceReselectionCount: restore.referenceReselectionCount
            )
        }
        petCoreOperationalState = operationalState
        switch operationalState {
        case .online:
            petCoreRuntimeInfo.markRunning()
        case .checking, .recovering:
            petCoreRuntimeInfo.markChecking()
        case .offline, .runtimeMismatch, .error:
            petCoreRuntimeInfo.markFailed("UI Next fixture: \(operationalState.rawValue)")
        }
        // Keep About, diagnostics, MenuBarExtra, and connection-inspector
        // fixtures representative of a packaged runtime rather than showing
        // development placeholders that never appear in a validated bundle.
        petCoreRuntimeInfo.version = "0.1.0"
        petCoreRuntimeInfo.appBuild = "20260721.1"
        petCoreRuntimeInfo.buildID = "apc-ui-next-fixture-v1"
        petCoreRuntimeInfo.rpcProtocol = "v2"
        petCoreRuntimeInfo.releaseChannel = "develop"
        petCoreRuntimeInfo.databaseSchemaRange = "0–5"
        petCoreRuntimeInfo.instanceID = "fixture-instance"
        hasLoadedStateSnapshot = true
        initialAppearanceReadiness = .authoritative
    }
    #endif

    private func reconcileActiveGeneration(_ snapshot: ActiveGenerationSnapshot) {
        let previousJobID = generationSession.jobID
        var restore = GenerationSessionRestore(snapshot: snapshot)
        let projectionIdentity = ActiveGenerationRecoveryProjectionIdentity(
            jobID: snapshot.jobID,
            form: snapshot.form,
            referenceReselectionCount: snapshot.referenceReselectionCount
        )
        let projectionChanged = activeGenerationRecoveryProjection?.identity != projectionIdentity
        if projectionChanged {
            restore = sanitizedGenerationRestore(restore)
            activeGenerationRecoveryProjection = SanitizedGenerationRecoveryProjection(
                identity: projectionIdentity,
                form: restore.submittedForm,
                referenceReselectionCount: restore.referenceReselectionCount
            )
        } else if let projection = activeGenerationRecoveryProjection {
            restore.submittedForm = projection.form
            restore.referenceReselectionCount = projection.referenceReselectionCount
        }
        _ = reduceGeneration(.restore(restore))
        if projectionChanged {
            applyRestoredGenerationForm(
                restore.submittedForm,
                referenceReselectionCount: restore.referenceReselectionCount
            )
        }
        latestGenerationRestoreAttemptState = .resolved
        if previousJobID != snapshot.jobID {
            generationReplyText = ""
        }
    }

    /// Coalesces concurrent recovery callers. A failed or malformed local RPC
    /// remains retryable on the next successful state refresh; only an empty
    /// valid response or an applied valid session resolves the launch restore.
    func restoreLatestGenerationSessionIfNeeded() async {
        guard !automaticLatestGenerationRestoreInvalidated,
              generationDraftIsPristineForAutomaticRestore
        else { return }

        switch latestGenerationRestoreAttemptState {
        case .resolved:
            return
        case .inFlight:
            if let task = latestGenerationRestoreInFlight?.task {
                await task.value
            }
            return
        case .notAttempted:
            break
        }

        latestGenerationRestoreAttemptSequence &+= 1
        let attemptID = latestGenerationRestoreAttemptSequence
        let mutationRevision = makerUserMutationRevision
        latestGenerationRestoreAttemptState = .inFlight
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLatestGenerationRestore(
                attemptID: attemptID,
                makerMutationRevision: mutationRevision
            )
        }
        latestGenerationRestoreInFlight = (attemptID, task)
        await task.value
    }

    private func performLatestGenerationRestore(
        attemptID: UInt64,
        makerMutationRevision: UInt64
    ) async {
        do {
            let result = try await requestPetCore(method: "generation.latest")
            let data = try JSONSerialization.data(withJSONObject: result)
            let snapshot = try JSONDecoder().decode(
                LatestGenerationSessionSnapshot.self,
                from: data
            )
            if !snapshot.found {
                finishLatestGenerationRestoreWithoutSession(attemptID: attemptID)
                return
            }
            guard let decodedRestore = GenerationSessionRestore(snapshot: snapshot) else {
                throw PetCoreClientError.invalidResponse
            }
            finishLatestGenerationRestore(
                sanitizedGenerationRestore(decodedRestore),
                attemptID: attemptID,
                makerMutationRevision: makerMutationRevision
            )
        } catch {
            diagnostics.logFailure(
                error,
                category: "generation",
                event: "latest_generation_restore_failed",
                throttleKey: "latest_generation_restore_failed",
                minimumInterval: 30
            )
            finishRetryableLatestGenerationRestore(attemptID: attemptID)
        }
    }

    private func finishLatestGenerationRestoreWithoutSession(attemptID: UInt64) {
        guard latestGenerationRestoreInFlight?.id == attemptID else { return }
        latestGenerationRestoreInFlight = nil
        guard latestGenerationRestoreAttemptState == .inFlight else { return }
        latestGenerationRestoreAttemptState = .resolved
    }

    private func finishRetryableLatestGenerationRestore(attemptID: UInt64) {
        guard latestGenerationRestoreInFlight?.id == attemptID else { return }
        latestGenerationRestoreInFlight = nil
        guard latestGenerationRestoreAttemptState == .inFlight else { return }
        latestGenerationRestoreAttemptState = .notAttempted
    }

    private func finishLatestGenerationRestore(
        _ restore: GenerationSessionRestore,
        attemptID: UInt64,
        makerMutationRevision: UInt64
    ) {
        guard latestGenerationRestoreInFlight?.id == attemptID else { return }
        latestGenerationRestoreInFlight = nil
        guard latestGenerationRestoreAttemptState == .inFlight else { return }
        guard !automaticLatestGenerationRestoreInvalidated,
              self.makerUserMutationRevision == makerMutationRevision,
              generationDraftIsPristineForAutomaticRestore
        else {
            latestGenerationRestoreAttemptState = .notAttempted
            return
        }
        _ = reduceGeneration(.restore(restore))
        applyRestoredGenerationForm(
            restore.submittedForm,
            referenceReselectionCount: restore.referenceReselectionCount
        )
        generationReplyText = ""
        latestGenerationRestoreAttemptState = .resolved
    }

    private var generationDraftIsPristineForAutomaticRestore: Bool {
        generationSession == GenerationSession()
            && descriptionText == AIPetMakerDefaults.descriptionText
            && selectedStyle == .semiRealistic
            && selectedQuality == .high
            && referenceImages.isEmpty
            && referenceImageIssue == nil
    }

    private func sanitizedGenerationRestore(
        _ restore: GenerationSessionRestore
    ) -> GenerationSessionRestore {
        guard let form = restore.submittedForm else { return restore }
        let projectedPaths = form.referenceImages
        let validatedPaths = projectedPaths.enumerated().compactMap { index, path in
            MakerReferenceImagePolicy.validatedRecoveryProjectionPath(
                path,
                jobID: restore.jobID,
                index: index
            )
        }
        var sanitized = restore
        let safePaths: [String]
        if validatedPaths.count == projectedPaths.count {
            safePaths = validatedPaths
        } else {
            // Projection is all-or-nothing: if even one supposedly safe copy
            // disappeared or fails local validation, retain no projected path.
            safePaths = []
            sanitized.referenceReselectionCount = min(
                MakerReferenceImagePolicy.maximumCount,
                restore.referenceReselectionCount + projectedPaths.count
            )
        }
        sanitized.submittedForm = GenerationForm(
            description: form.description,
            style: form.style,
            quality: form.quality,
            referenceImages: safePaths
        )
        return sanitized
    }

    private func applyRestoredGenerationForm(
        _ form: GenerationForm?,
        referenceReselectionCount: Int
    ) {
        guard let form else { return }
        descriptionText = form.description
        if let style = StylePreset(rawValue: form.style) {
            selectedStyle = style
        }
        selectedQuality = form.quality
        referenceImages = form.referenceImages
        self.referenceReselectionCount = referenceReselectionCount
        reselectedReferenceImagePaths.removeAll()
        referenceImageIssue = referenceReselectionCount > 0
            ? .reselectionRequired(referenceReselectionCount)
            : nil
    }

    private func recordMakerUserMutation() {
        makerUserMutationRevision &+= 1
        automaticLatestGenerationRestoreInvalidated = true
    }

    private func refreshReferenceImageIssue(
        fallback: MakerReferenceImageIssue? = nil
    ) {
        if referenceReselectionCount > 0 {
            referenceImageIssue = .reselectionRequired(referenceReselectionCount)
        } else {
            referenceImageIssue = fallback ?? MakerReferenceImagePolicy.issue(for: referenceImages)
        }
    }

    func updateGenerationDescription(_ value: String) {
        guard !generationSession.isActive else { return }
        recordMakerUserMutation()
        descriptionText = GenerationPromptPolicy.truncate(value)
    }

    func selectGenerationStyle(_ style: StylePreset) {
        guard !generationSession.isActive else { return }
        recordMakerUserMutation()
        selectedStyle = style
    }

    func selectGenerationQuality(_ quality: QualityLevel) {
        guard !generationSession.isActive else { return }
        recordMakerUserMutation()
        selectedQuality = quality
    }

    func startGeneration() {
        guard canStartGeneration else {
            statusText = generationSession.isActive ? generationStateTitle : "请先填写宠物描述"
            return
        }
        if let issue = MakerReferenceImagePolicy.issue(for: referenceImages) {
            referenceImageIssue = issue
            return
        }
        referenceImageIssue = nil
        let description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let form = GenerationForm(
            description: description,
            style: selectedStyle.rawValue,
            quality: selectedQuality,
            referenceImages: referenceImages
        )
        beginGeneration(
            with: form,
            initialMessage: APCLocalization.format(
                .studioMessageCreateRequestedFormat,
                APCLocalizedPresentation.styleTitle(selectedStyle)
            )
        )
    }

    func startPetEdit(
        _ pet: PetSummary,
        baselineRevisionID: String? = nil,
        instruction: String
    ) {
        guard !pet.isBundled else {
            statusText = "App 内置宠物不可原地修改；请导出并使用新的宠物 ID 创建副本"
            return
        }
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            statusText = "请先填写希望如何修改宠物"
            return
        }
        guard GenerationPromptPolicy.scalarCount(instruction)
            <= AIPetMakerDefaults.maximumDescriptionCharacters
        else {
            statusText = "宠物修改要求不能超过 8000 个字符"
            return
        }
        guard !generationSession.isActive else {
            statusText = "请先完成或取消当前 AI 制作任务"
            return
        }
        recordMakerUserMutation()
        referenceReselectionCount = 0
        reselectedReferenceImagePaths.removeAll()
        referenceImageIssue = nil

        let form = GenerationForm(
            description: instruction,
            style: pet.style,
            quality: pet.quality,
            referenceImages: []
        )
        let initialUserMessage = GenerationMessage(
            role: "user",
            content: instruction,
            progress: 0.01,
            createdAt: ""
        )
        _ = reduceGeneration(.editRequested(
            form: form,
            initialMessage: initialUserMessage,
            petID: pet.id,
            baselineRevisionID: baselineRevisionID
        ))
        generationReplyText = ""
        selection = .maker
        statusText = "正在建立 \(pet.name) 的修改会话"

        Task {
            do {
                var parameters: [String: Any] = [
                    "pet_id": pet.id,
                    "instruction": instruction,
                ]
                if let baselineRevisionID {
                    parameters["baseline_revision_id"] = baselineRevisionID
                }
                let result = try await requestPetCore(
                    method: "generation.edit",
                    params: parameters
                )
                guard let dict = result as? [String: Any],
                      let jobID = dict["job_id"] as? String,
                      !jobID.isEmpty
                else {
                    throw PetCoreClientError.invalidResponse
                }
                let acceptedBaselineRevisionID = dict["baseline_revision_id"] as? String
                    ?? baselineRevisionID
                _ = reduceGeneration(.startAccepted(
                    jobID: jobID,
                    baselineRevisionID: acceptedBaselineRevisionID
                ))
                statusText = "正在修改 \(pet.name)"
            } catch {
                let failure = GenerationMessage(
                    role: "assistant",
                    content: APCLocalization.text(.studioMessageStartModifyFailed),
                    progress: 1,
                    createdAt: "",
                    kind: "generation_failed"
                )
                _ = reduceGeneration(.startFailed(message: failure))
                statusText = "修改启动失败：\(error.localizedDescription)"
            }
        }
    }

    func preparePetCustomizationCopy(_ pet: PetSummary) {
        guard pet.isBundled else {
            statusText = APCLocalization.text(.libraryCopyBundledOnly)
            return
        }
        guard !generationSession.isActive else {
            statusText = APCLocalization.text(.libraryCopyActiveTask)
            return
        }
        recordMakerUserMutation()

        let draft = PetLibraryCopyDraft.make(
            for: pet,
            existingPetIDs: Set(pets.map(\.id))
        )
        let referencePath = PetAssetLocator.coverURL(for: pet)
            .flatMap(Self.safeMakerReferenceImagePath)

        _ = reduceGeneration(.reset)
        descriptionText = draft.brief
        selectedStyle = draft.style
        selectedQuality = draft.quality
        referenceImages = referencePath.map { [$0] } ?? []
        referenceReselectionCount = 0
        reselectedReferenceImagePaths.removeAll()
        referenceImageIssue = nil
        generationReplyText = ""
        selection = .maker
        statusText = APCLocalization.format(.libraryCopyPreparedFormat, pet.name)
    }

    func clearStudioForm() {
        guard !generationSession.isActive else {
            statusText = "活动任务使用已提交表单，完成或取消后才能清空草稿"
            return
        }
        recordMakerUserMutation()
        descriptionText = AIPetMakerDefaults.descriptionText
        referenceImages.removeAll()
        referenceReselectionCount = 0
        reselectedReferenceImagePaths.removeAll()
        referenceImageIssue = nil
        generationReplyText = ""
        statusText = "已清空新建表单"
    }

    func showNewPetDraft() {
        guard !generationSession.isActive else {
            statusText = "请先完成或取消当前 AI 制作任务"
            return
        }
        recordMakerUserMutation()
        _ = reduceGeneration(.reset)
        referenceReselectionCount = 0
        reselectedReferenceImagePaths.removeAll()
        referenceImageIssue = MakerReferenceImagePolicy.issue(for: referenceImages)
        generationReplyText = ""
        selection = .maker
        statusText = "可以开始制作新宠物"
    }

    func retryGeneration() {
        guard generationSession.submittedForm != nil else {
            startGeneration()
            return
        }
        guard generationSession.canRetry else {
            statusText = generationSession.isActive ? generationStateTitle : "当前会话不可重试"
            return
        }
        guard referenceReselectionCount == 0 else {
            refreshReferenceImageIssue()
            statusText = APCLocalizedPresentation.referenceImageIssue(
                .reselectionRequired(referenceReselectionCount)
            )
            return
        }
        let modifying = generationSession.operation == .modify
        if !modifying, let issue = MakerReferenceImagePolicy.issue(for: referenceImages) {
            referenceImageIssue = issue
            return
        }
        referenceImageIssue = nil
        guard let form = PetStudioDraftPolicy.retryForm(
            session: generationSession,
            descriptionText: descriptionText,
            style: selectedStyle,
            quality: selectedQuality,
            referenceImages: referenceImages
        ) else { return }
        if modifying, generationSession.resultPetID == nil {
            statusText = "修改会话缺少宠物 ID，无法安全重试"
            return
        }
        if modifying, generationSession.jobID == nil {
            guard let petID = generationSession.resultPetID,
                  let pet = pets.first(where: { $0.id == petID }),
                  let instruction = generationSession.messages.first(where: { $0.role == "user" })?
                    .content
            else {
                statusText = "修改会话缺少可重试的宠物基线"
                return
            }
            startPetEdit(
                pet,
                baselineRevisionID: generationSession.baselineRevisionID,
                instruction: instruction
            )
            return
        }
        beginGeneration(
            with: form,
            initialMessage: modifying
                ? APCLocalization.text(.studioMessageRetryModify)
                : APCLocalization.format(
                    .studioMessageRetryCreateFormat,
                    APCLocalizedPresentation.styleTitle(selectedStyle)
                ),
            retryOfJobID: generationSession.jobID,
            operation: generationSession.operation,
            resultPetID: generationSession.resultPetID
        )
        statusText = modifying ? "正在重试宠物修改" : "正在重试 AI 辅助会话"
    }

    private func beginGeneration(
        with form: GenerationForm,
        initialMessage: String,
        retryOfJobID: String? = nil,
        operation: GenerationOperation = .create,
        resultPetID: String? = nil,
        baselineRevisionID: String? = nil
    ) {
        let initialUserMessage = GenerationMessage(
            role: "user",
            content: initialMessage,
            progress: 0.05,
            createdAt: ""
        )
        if retryOfJobID != nil {
            _ = reduceGeneration(.retryRequested(
                form: form,
                initialMessage: initialUserMessage
            ))
        } else if operation == .modify, let resultPetID {
            _ = reduceGeneration(.editRequested(
                form: form,
                initialMessage: initialUserMessage,
                petID: resultPetID,
                baselineRevisionID: baselineRevisionID
            ))
        } else {
            _ = reduceGeneration(.startRequested(form: form, initialMessage: initialUserMessage))
        }
        generationReplyText = ""

        Task {
            do {
                let formData = try JSONEncoder().encode(form)
                let formObject = try JSONSerialization.jsonObject(with: formData)
                let result: Any
                if let retryOfJobID {
                    var parameters: [String: Any] = ["job_id": retryOfJobID]
                    if GenerationRetryRequestPolicy.includesForm(for: operation) {
                        parameters["form"] = formObject
                    }
                    result = try await requestPetCore(
                        method: "generation.retry",
                        params: parameters
                    )
                } else {
                    result = try await requestPetCore(method: "generation.start", params: formObject)
                }
                guard let dict = result as? [String: Any],
                      let jobID = dict["job_id"] as? String,
                      !jobID.isEmpty
                else {
                    throw PetCoreClientError.invalidResponse
                }
                _ = reduceGeneration(.startAccepted(
                    jobID: jobID,
                    baselineRevisionID: dict["baseline_revision_id"] as? String
                ))
            } catch {
                let failure = GenerationMessage(
                    role: "assistant",
                    content: APCLocalization.text(
                        operation == .modify
                            ? .studioMessageStartModifyFailed
                            : .studioMessageStartCreateFailed
                    ),
                    progress: 1,
                    createdAt: "",
                    kind: "generation_failed"
                )
                _ = reduceGeneration(.startFailed(message: failure))
            }
        }
    }

    func refreshGenerationMessages() async {
        guard let generationJobID = generationSession.jobID else { return }
        do {
            let result = try await requestPetCore(method: "generation.messages", params: ["job_id": generationJobID])
            let data = try JSONSerialization.data(withJSONObject: result)
            let messages = try JSONDecoder().decode([GenerationMessage].self, from: data)
            await applyGenerationMessages(messages)
        } catch {
            statusText = "生成消息暂不可用"
        }
    }

    private func startGenerationMessageStream(jobID: String) {
        generationMessagesTask?.cancel()
        generationMessagesTask = Task { [weak self] in
            while !Task.isCancelled {
                let shouldContinue = await self?.waitForGenerationMessages(jobID: jobID) ?? false
                if !shouldContinue {
                    break
                }
            }
        }
    }

    private func waitForGenerationMessages(jobID: String) async -> Bool {
        guard generationSession.jobID == jobID else { return false }
        do {
            let result = try await requestPetCore(
                method: "generation.messages.wait",
                params: [
                    "job_id": jobID,
                    "after_revision": generationSession.messageRevision,
                    "timeout_ms": 30_000
                ],
                timeout: .seconds(35)
            )
            let data = try JSONSerialization.data(withJSONObject: result)
            let snapshot = try JSONDecoder().decode(GenerationMessagesSnapshot.self, from: data)
            await applyGenerationMessages(
                snapshot.messages,
                revision: snapshot.revision,
                resultMetadata: snapshot.resultMetadata
            )
            return generationSession.isActive && generationSession.jobID == jobID
        } catch {
            statusText = "生成消息暂不可用"
            try? await Task.sleep(for: .seconds(1))
            return generationSession.isActive && generationSession.jobID == jobID
        }
    }

    private func applyGenerationMessages(
        _ messages: [GenerationMessage],
        revision: String? = nil,
        resultMetadata: GenerationResultMetadata? = nil
    ) async {
        if let resultMetadata, !resultMetadata.isEmpty {
            _ = reduceGeneration(.resultMetadataReceived(resultMetadata))
        }
        let effects = reduceGeneration(.messagesReceived(messages, revision: revision))
        if effects.contains(.refreshSnapshot) {
            await refresh()
        }
    }

    func sendGenerationReply() {
        let content = generationReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard generationSession.canSendReply else {
            statusText = "请先等待 AI 追问或生成成功"
            return
        }
        guard let generationJobID = generationSession.jobID else {
            statusText = "请先发起 AI 辅助会话"
            return
        }
        let previousState = generationSession.state
        _ = reduceGeneration(.replySubmitted)
        generationReplyText = ""

        Task {
            do {
                let result = try await requestPetCore(
                    method: "generation.reply",
                    params: ["job_id": generationJobID, "content": content]
                )
                let data = try JSONSerialization.data(withJSONObject: result)
                let messages = try JSONDecoder().decode([GenerationMessage].self, from: data)
                await applyGenerationMessages(messages)
                if generationSession.isActive {
                    _ = reduceGeneration(.resetMessageRevision)
                    startGenerationMessageStream(jobID: generationJobID)
                }
            } catch {
                _ = reduceGeneration(.replyFailed(restoring: previousState))
                statusText = "发送失败：\(error.localizedDescription)"
                generationReplyText = content
            }
        }
    }

    func cancelGeneration() {
        guard generationSession.canCancel,
              let generationJobID = generationSession.jobID
        else {
            return
        }
        _ = reduceGeneration(.cancelRequested)
        statusText = "正在取消生成"
        Task {
            do {
                let result = try await requestPetCore(method: "generation.cancel", params: ["job_id": generationJobID])
                let data = try JSONSerialization.data(withJSONObject: result)
                let messages = try JSONDecoder().decode([GenerationMessage].self, from: data)
                if !messages.isEmpty {
                    await applyGenerationMessages(messages)
                } else {
                    let effects = reduceGeneration(.cancelConfirmed)
                    if effects.contains(.refreshSnapshot) {
                        await refresh()
                    }
                }
                statusText = generationSession.operation == .modify ? "已取消修改" : "已取消生成"
            } catch {
                _ = reduceGeneration(.cancelFailed)
                let action = generationSession.operation == .modify ? "修改" : "生成"
                statusText = "取消\(action)失败：\(error.localizedDescription)"
            }
        }
    }

    func fetchGenerationHistory(for pet: PetSummary) async throws -> GenerationHistory {
        let result = try await requestPetCore(
            method: "generation.for_pet",
            params: ["pet_id": pet.id]
        )
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(GenerationHistory.self, from: data)
    }

    func fetchPetHistory(
        for pet: PetSummary,
        limit: Int = 16
    ) async throws -> PetHistorySnapshot {
        let boundedLimit = min(max(limit, 1), 32)
        #if DEBUG
        if var fixtureHistory = uiNextFixturePetHistories[pet.id] {
            fixtureHistory.revisions = Array(fixtureHistory.revisions.prefix(boundedLimit))
            fixtureHistory.jobs = Array(fixtureHistory.jobs.prefix(boundedLimit))
            return fixtureHistory
        }
        #endif
        let result = try await requestPetCore(
            method: "pet.history",
            params: ["pet_id": pet.id, "limit": boundedLimit]
        )
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(PetHistorySnapshot.self, from: data)
    }

    func openGenerationHistory(for pet: PetSummary) {
        guard !generationSession.isActive else {
            statusText = "请先完成或取消当前 AI 制作任务，再查看其他制作记录"
            return
        }
        recordMakerUserMutation()
        statusText = "正在打开 \(pet.name) 的生成会话"
        Task {
            do {
                let history = try await fetchGenerationHistory(for: pet)
                guard history.found, let jobID = history.jobId else {
                    statusText = "\(pet.name) 没有关联的 App 内制作记录"
                    return
                }
                guard !generationSession.isActive else {
                    statusText = "当前 AI 制作任务已开始，未打开其他制作记录"
                    return
                }

                let restoredState = restoredGenerationState(
                    status: history.status,
                    messages: history.messages
                )
                let restore = GenerationSessionRestore(
                    state: restoredState,
                    jobID: jobID,
                    submittedForm: history.form,
                    messages: history.messages,
                    progress: history.messages.last?.progress ?? (restoredState.isTerminal ? 1 : 0),
                    messageRevision: "",
                    operation: history.operation ?? .create,
                    resultPetID: history.resultPetId,
                    baselineRevisionID: history.baselineRevisionID,
                    resultRevisionID: history.revisionId,
                    validationSummary: history.validationSummary,
                    referenceReselectionCount: history.referenceReselectionCount
                )
                let sanitizedRestore = sanitizedGenerationRestore(restore)
                _ = reduceGeneration(.restore(sanitizedRestore))
                applyRestoredGenerationForm(
                    sanitizedRestore.submittedForm,
                    referenceReselectionCount: sanitizedRestore.referenceReselectionCount
                )
                generationReplyText = ""
                selection = .maker
                statusText = "已打开 \(pet.name) 的生成会话"
            } catch {
                statusText = "打开生成会话失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func reduceGeneration(
        _ action: GenerationSessionAction
    ) -> GenerationSessionEffects {
        var next = generationSession
        let effects = next.reduce(action)
        if generationSession != next {
            generationSession = next
        }
        if effects.contains(.stopMessageStream) {
            generationMessagesTask?.cancel()
        }
        if effects.contains(.startMessageStream), let jobID = generationSession.jobID {
            startGenerationMessageStream(jobID: jobID)
        }
        return effects
    }

    private func restoredGenerationState(
        status: GenerationJobHistoryStatus?,
        messages: [GenerationMessage]
    ) -> GenerationSessionState {
        if let status {
            return switch status {
            case .pending: .starting
            case .running: .running
            case .waitingForUser: .waitingForInput
            case .completed: .succeeded
            case .failed: .failed
            case .canceled: .cancelled
            }
        }
        if GenerationConversation.needsUserInput(messages) {
            return .waitingForInput
        }
        if GenerationConversation.succeeded(messages) {
            return .succeeded
        }
        if GenerationConversation.cancelled(messages) {
            return .cancelled
        }
        if GenerationConversation.failed(messages) {
            return .failed
        }
        return .idle
    }

    func updateBehavior(_ next: BehaviorSettings) {
        let patch = BehaviorSettingsPatch(from: behavior, to: next)
        guard !patch.isEmpty else { return }
        let appearanceChanged = behavior.appearanceTheme != next.appearanceTheme
        let sessionGroupDisplayChanged = behavior.sessionGroupDisplay != next.sessionGroupDisplay
        behavior = next
        if appearanceChanged {
            applyCurrentAppearance()
        }
        if sessionGroupDisplayChanged {
            overlayAgentGroupExpansionOverrides.removeAll()
            overlayController.updateLayout()
        }
        syncOverlayVisibilityForBehavior()
        enqueueBehaviorPatch(patch, optimisticBehavior: next)
    }

    func previewBubbleTransparency(_ value: Double) {
        var next = behavior
        next.bubbleTransparency = BehaviorSettings.clampedBubbleTransparency(value)
        behavior = next
    }

    func commitBubbleTransparency(from previousValue: Double) {
        var previous = behavior
        previous.bubbleTransparency = BehaviorSettings.clampedBubbleTransparency(previousValue)
        let patch = BehaviorSettingsPatch(from: previous, to: behavior)
        guard !patch.isEmpty else { return }
        enqueueBehaviorPatch(patch, optimisticBehavior: behavior)
    }

    func waitForBehaviorPersistence() async {
        _ = await behaviorMutationTask?.value
    }

    private func enqueueBehaviorPatch(
        _ patch: BehaviorSettingsPatch,
        optimisticBehavior: BehaviorSettings
    ) {
        let predecessor = behaviorMutationTask
        behaviorMutationTask = Task { [weak self] in
            _ = await predecessor?.value
            guard let self else { return }
            await persistBehaviorPatch(patch, optimisticBehavior: optimisticBehavior)
        }
    }

    private func persistBehaviorPatch(
        _ patch: BehaviorSettingsPatch,
        optimisticBehavior: BehaviorSettings
    ) async {
        for attempt in 0..<2 {
            do {
                let data = try JSONEncoder().encode(patch)
                let changes = try JSONSerialization.jsonObject(with: data)
                let result = try await requestPetCore(
                    method: "behavior.patch",
                    params: [
                        "expected_revision": behaviorRevision,
                        "changes": changes
                    ]
                )
                let resultData = try JSONSerialization.data(withJSONObject: result)
                let updated = try JSONDecoder().decode(
                    VersionedBehaviorSettings.self,
                    from: resultData
                )
                behaviorRevision = updated.revision
                if behavior == optimisticBehavior {
                    let appearanceChanged = behavior.appearanceTheme != updated.behavior.appearanceTheme
                    behavior = updated.behavior
                    if appearanceChanged {
                        applyCurrentAppearance()
                    }
                    syncOverlayVisibilityForBehavior()
                }
                statusText = "设置已保存"
                return
            } catch let PetCoreClientError.rpcError(message)
                where attempt == 0 && message.contains("behavior revision conflict") {
                do {
                    try await refreshSnapshot()
                } catch {
                    statusText = "设置冲突且刷新失败：\(error.localizedDescription)"
                    return
                }
            } catch {
                statusText = "设置保存失败：\(error.localizedDescription)"
                try? await refreshSnapshot()
                return
            }
        }
    }

    private func syncOverlayVisibilityForBehavior() {
        let nextVisibility = OverlayVisibility(
            petVisible: behavior.enabled,
            statusBubbleVisible: behavior.enabled
                && behavior.statusBubble
                && (!activeAgentSessions.isEmpty || (!behavior.autoHide && activeAgentState == nil))
        )
        let visibilityChanged = overlayVisibility != nextVisibility
        if visibilityChanged {
            overlayVisibility = nextVisibility
        }
        let petVisibilityChanged = overlayVisible != nextVisibility.petVisible
        if petVisibilityChanged {
            overlayVisible = nextVisibility.petVisible
            overlayController.setVisible(nextVisibility.petVisible)
        } else if visibilityChanged {
            overlayController.updateLayout()
        }
    }

    private func applyCurrentAppearance() {
        applicationAppearanceApplier(behavior.appearanceTheme)
        overlayController.updateAppearance(behavior.appearanceTheme)
    }

    func setSource(_ source: AgentSource, enabled: Bool) {
        var next = behavior
        next.sources[source] = enabled
        updateBehavior(next)
    }

    func setEvent(_ event: AgentEventKind, enabled: Bool) {
        var next = behavior
        next.events[event] = enabled
        updateBehavior(next)
    }

    func activatePet(_ pet: PetSummary) {
        guard !pet.active else { return }
        petOperationIDs.insert(pet.id)
        statusText = "正在启用 \(pet.name)"
        Task {
            defer { petOperationIDs.remove(pet.id) }
            await finishPetActivation(
                pet,
                activate: {
                    _ = try await self.requestPetCore(
                        method: "pet.activate",
                        params: ["id": pet.id]
                    )
                },
                refreshSnapshot: { try await self.refreshSnapshot() },
                recoverSnapshot: { await self.refresh() }
            )
        }
    }

    func finishPetActivation(
        _ pet: PetSummary,
        activate: @MainActor () async throws -> Void,
        refreshSnapshot: @MainActor () async throws -> Void,
        recoverSnapshot: @MainActor () async -> Void
    ) async {
        do {
            try await activate()
        } catch {
            statusText = "启用失败：\(error.localizedDescription)"
            await recoverSnapshot()
            return
        }

        do {
            try await refreshSnapshot()
            statusText = "已启用 \(pet.name)"
        } catch {
            statusText = "已启用 \(pet.name)，但状态刷新失败：\(error.localizedDescription)"
            await recoverSnapshot()
        }
    }

    func deletePet(_ pet: PetSummary) {
        petOperationIDs.insert(pet.id)
        statusText = "正在删除 \(pet.name)"
        Task {
            defer { petOperationIDs.remove(pet.id) }
            do {
                let result = try await requestPetCore(method: "pet.delete", params: ["id": pet.id])
                try await refreshSnapshot()
                let deletedAssets = (result as? [String: Any])?["deleted_assets"] as? Bool ?? true
                statusText = deletedAssets
                    ? "已删除 \(pet.name)"
                    : "已删除 \(pet.name)，部分本地资源待下次清理"
            } catch {
                statusText = "删除失败：\(error.localizedDescription)"
                await refresh()
            }
        }
    }

    func importPetpacks() {
        let panel = NSOpenPanel()
        panel.title = APCLocalization.text(.libraryImportTitle)
        panel.prompt = APCLocalization.text(.libraryImportAction)
        panel.message = APCLocalization.text(.libraryImportMessage)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [PetpackImportPolicy.contentType]

        guard panel.runModal() == .OK else { return }
        importPetpacks(urls: panel.urls)
    }

    func importPetpacks(urls: [URL]) {
        guard petpackImportTask == nil else { return }

        let urls = urls.filter { PetpackImportPolicy.acceptsFileName($0.lastPathComponent) }
        guard !urls.isEmpty else {
            let notice = setPetLibraryImportFailure(
                importedCount: 0,
                failures: [.invalidSelection]
            )
            statusText = notice.message.replacingOccurrences(of: "\n", with: " ")
            return
        }

        petLibraryNotice = nil
        isImportingPetpack = true
        statusText = urls.count == 1 ? "正在导入本 App .petpack" : "正在导入 \(urls.count) 个本 App .petpack"
        petpackImportTask = Task {
            defer {
                isImportingPetpack = false
                petpackImportTask = nil
            }
            var importedCount = 0
            var failures: [PetLibraryImportFailure] = []

            for (fileIndex, url) in urls.enumerated() {
                do {
                    _ = try await requestPetCore(
                        method: "petpack.import",
                        params: ["path": url.standardizedFileURL.path]
                    )
                    importedCount += 1
                } catch {
                    diagnostics.logFailure(
                        error,
                        category: "library",
                        event: "petpack_import_failed",
                        metadata: ["file_index": .integer(Int64(fileIndex))]
                    )
                    failures.append(.file(at: url))
                }
            }

            if importedCount > 0 {
                do {
                    try await refreshSnapshot()
                    selection = .library
                } catch {
                    await refresh()
                }
            }

            if failures.isEmpty {
                petLibraryNotice = nil
                statusText = importedCount == 1 ? "已导入本 App .petpack" : "已导入 \(importedCount) 个本 App .petpack"
            } else if importedCount > 0 {
                let notice = setPetLibraryImportFailure(
                    importedCount: importedCount,
                    failures: failures
                )
                statusText = notice.message.replacingOccurrences(of: "\n", with: " ")
            } else {
                let notice = setPetLibraryImportFailure(importedCount: 0, failures: failures)
                statusText = notice.message.replacingOccurrences(of: "\n", with: " ")
            }
        }
    }

    func waitForPetpackImport() async {
        _ = await petpackImportTask?.value
    }

    func dismissPetLibraryNotice() {
        petLibraryNotice = nil
    }

    @discardableResult
    func setPetLibraryImportFailure(
        importedCount: Int,
        failures: [PetLibraryImportFailure]
    ) -> PetLibraryNotice {
        let notice = PetLibraryNotice.importFailure(
            importedCount: importedCount,
            failures: failures
        )
        petLibraryNotice = notice
        return notice
    }

    func exportPet(_ pet: PetSummary) {
        let panel = NSSavePanel()
        panel.title = APCLocalization.text(.libraryExportAction)
        panel.prompt = APCLocalization.text(.libraryExportAction)
        panel.nameFieldStringValue = "\(safeExportName(pet.name)).petpack"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [PetpackImportPolicy.contentType]

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        petOperationIDs.insert(pet.id)
        statusText = "正在校验并导出 \(pet.name)"
        Task {
            defer { petOperationIDs.remove(pet.id) }
            do {
                _ = try await requestPetCore(
                    method: "petpack.export",
                    params: [
                        "id": pet.id,
                        "path": destinationURL.standardizedFileURL.path
                    ]
                )
                statusText = "已导出 \(destinationURL.lastPathComponent)"
            } catch {
                statusText = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    func prepareDiagnosticsExport() {
        guard diagnosticsExportState.primaryAction == .prepare else { return }

        let environment = AppDiagnosticEnvironment.capture(store: self)
        diagnosticsExportState = .exporting
        statusText = "正在打包诊断日志"
        diagnostics.log(.notice, category: "diagnostics", event: "diagnostics_export_started")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDiagnosticsArchivePreparation(environment: environment)
        }
    }

    func savePreparedDiagnosticsArchive() {
        guard diagnosticsExportState.primaryAction == .save,
              let archive = diagnosticsExportState.preparedArchive
        else { return }

        let panel = NSSavePanel()
        panel.title = APCLocalization.text(.diagnosticsPackageTitle)
        panel.prompt = APCLocalization.text(.diagnosticsLogDownload)
        panel.message = APCLocalization.text(.diagnosticsPrivacy)
        panel.nameFieldStringValue = archive.suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            diagnostics.log(
                .debug,
                category: "diagnostics",
                event: "diagnostics_archive_save_cancelled"
            )
            return
        }

        guard destinationURL.standardizedFileURL != archive.stagedURL.standardizedFileURL else {
            let message = "日志保存位置无效，请选择其他位置"
            diagnosticsExportState = .saveFailed(archive, message)
            statusText = message
            return
        }

        diagnosticsExportState = .saving(archive)
        statusText = "正在保存诊断日志"
        diagnostics.log(
            .notice,
            category: "diagnostics",
            event: "diagnostics_archive_save_started"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDiagnosticsArchiveSave(archive, to: destinationURL)
        }
    }

    static func defaultDiagnosticsArchiveName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "AgentPetCompanion-Diagnostics-\(formatter.string(from: date)).zip"
    }

    static func diagnosticsExportParameters(
        environment: AppDiagnosticEnvironment
    ) throws -> [String: Any] {
        ["app_environment": try environment.jsonObject()]
    }

    static func validatedDiagnosticArchiveURL(
        from result: Any,
        homeURL: URL
    ) throws -> URL {
        let decoded = try AppDiagnosticRPCExportResult.decode(result)
        guard (1 ... 128).contains(decoded.fileCount),
              decoded.archiveBytes > 0,
              !decoded.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AppDiagnosticArchiveError.invalidArchive
        }
        return try AppDiagnosticArchiveSecurity.validateTemporaryArchive(
            URL(fileURLWithPath: decoded.path),
            homeURL: homeURL,
            expectedFileName: decoded.fileName,
            expectedBytes: decoded.archiveBytes
        )
    }

    private func performDiagnosticsArchivePreparation(
        environment: AppDiagnosticEnvironment
    ) async {
        let homeURL = diagnostics.homeURL ?? AppDiagnosticPaths.defaultHomeURL()
        let stagedArchive: URL
        do {
            let result = try await requestPetCore(
                method: "diagnostics.export",
                params: Self.diagnosticsExportParameters(environment: environment)
            )
            stagedArchive = try Self.validatedDiagnosticArchiveURL(
                from: result,
                homeURL: homeURL
            )
            diagnostics.log(
                .info,
                category: "diagnostics",
                event: "diagnostics_archive_received"
            )
        } catch {
            diagnostics.logFailure(
                error,
                category: "diagnostics",
                event: "diagnostics_rpc_export_unavailable",
                throttleKey: "diagnostics_rpc_export_unavailable",
                minimumInterval: 5
            )
            do {
                stagedArchive = try await AppDiagnosticOfflineExporter.makeArchive(
                    environment: environment,
                    homeURL: homeURL
                )
                diagnostics.log(
                    .notice,
                    category: "diagnostics",
                    event: "diagnostics_offline_archive_created"
                )
            } catch {
                diagnostics.logFailure(
                    error,
                    category: "diagnostics",
                    event: "diagnostics_offline_export_failed"
                )
                let message = "日志导出失败，请稍后重试"
                diagnosticsExportState = .failed(message)
                statusText = message
                return
            }
        }

        let archive = PreparedDiagnosticsArchive(
            stagedURL: stagedArchive,
            suggestedFileName: Self.defaultDiagnosticsArchiveName()
        )
        diagnosticsExportState = .ready(archive)
        statusText = "诊断日志包已就绪"
        diagnostics.log(
            .notice,
            category: "diagnostics",
            event: "diagnostics_archive_ready"
        )
    }

    private func performDiagnosticsArchiveSave(
        _ archive: PreparedDiagnosticsArchive,
        to destinationURL: URL
    ) async {
        do {
            try await AppDiagnosticArchiveSecurity.install(archive.stagedURL, at: destinationURL)
            try? FileManager.default.removeItem(at: archive.stagedURL)
            let message = "已导出 \(destinationURL.lastPathComponent)"
            diagnosticsExportState = .succeeded(message)
            statusText = message
            diagnostics.log(
                .notice,
                category: "diagnostics",
                event: "diagnostics_export_succeeded"
            )
        } catch {
            diagnostics.logFailure(
                error,
                category: "diagnostics",
                event: "diagnostics_archive_install_failed"
            )
            let message = "日志导出失败，请检查目标位置后重试"
            diagnosticsExportState = .saveFailed(archive, message)
            statusText = message
        }
    }

    func repairConnection(_ source: AgentSource) {
        launchConnectionOperation(.init(kind: .repair, sources: [source]))
    }

    func repairConnections(_ sources: [AgentSource]) {
        launchConnectionOperation(.init(kind: .repair, sources: sources))
    }

    func uninstallConnection(_ source: AgentSource) {
        launchConnectionOperation(.init(kind: .uninstall, sources: [source]))
    }

    func uninstallConnections(_ sources: [AgentSource]) {
        launchConnectionOperation(.init(kind: .uninstall, sources: sources))
    }

    func checkConnection(_ source: AgentSource) {
        launchConnectionOperation(.init(kind: .check, sources: [source]))
    }

    func checkAllConnections() {
        launchConnectionOperation(.init(kind: .check, sources: AgentSource.allCases))
    }

    func chooseConnectionCheckDirectory() {
        let panel = NSOpenPanel()
        panel.title = APCLocalization.text(.connectionsDirectoryPanelTitle)
        panel.prompt = APCLocalization.text(.connectionsDirectoryPanelPrompt)
        panel.message = APCLocalization.text(.connectionsDirectoryPanelMessage)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setConnectionCheckDirectory(url.standardizedFileURL.path)
        checkAllConnections()
    }

    func resetConnectionCheckDirectory() {
        setConnectionCheckDirectory(nil)
        checkAllConnections()
    }

    func setConnectionCheckDirectory(_ path: String?) {
        guard let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else {
            connectionCheckCWD = nil
            return
        }
        connectionCheckCWD = URL(
            fileURLWithPath: normalized,
            isDirectory: true
        ).standardizedFileURL.path
    }

    static func connectionOperationParameters(
        source: AgentSource? = nil,
        cwd: String?
    ) -> [String: String] {
        var params: [String: String] = [:]
        if let source {
            params["source"] = source.rawValue
        }
        if let cwd, !cwd.isEmpty {
            params["cwd"] = cwd
        }
        return params
    }

    func sendConnectionTestEvent(_ source: AgentSource) {
        launchConnectionOperation(.init(kind: .test, sources: [source]))
    }

    func retryConnectionOperation() {
        guard let failure = connectionOperationState.failedOperation else { return }
        launchConnectionOperation(failure.operation)
    }

    func dismissConnectionOperationNotice() {
        guard !connectionOperationState.isRunning else { return }
        connectionOperationState = .idle
    }

    private func launchConnectionOperation(_ operation: AgentConnectionOperation) {
        guard let permit = connectionOperationGate.begin(operation) else { return }
        connectionOperationState = .running(operation)
        statusText = connectionOperationStartedStatus(operation)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let completion = try await self.performConnectionOperation(operation)
                self.connectionOperationGate.finish(permit)
                self.connectionOperationState = .succeeded(operation)
                self.statusText = completion
            } catch {
                self.connectionOperationGate.finish(permit)
                let reason = Self.connectionOperationFailureReason(for: error)
                self.diagnostics.log(
                    .error,
                    category: "connections",
                    event: "connection_operation_failed",
                    metadata: [
                        "operation": .string(operation.kind.rawValue),
                        "reason": .string(reason.rawValue),
                        "source_count": .integer(Int64(operation.sources.count))
                    ]
                )
                self.connectionOperationState = .failed(.init(
                    operation: operation,
                    reason: reason
                ))
                self.statusText = self.connectionOperationFailurePrefix(operation)
                if operation.kind == .repair || operation.kind == .uninstall {
                    _ = await self.refresh()
                }
            }
        }
    }

    private func performConnectionOperation(
        _ operation: AgentConnectionOperation
    ) async throws -> String {
        switch operation.kind {
        case .check:
            return try await performConnectionCheck(operation.sources)
        case .test:
            guard let source = operation.sources.first else {
                throw AgentConnectionOperationExecutionError(.invalidRequest)
            }
            let result = try await requestPetCore(
                method: "connections.test",
                params: ["source": source.rawValue]
            )
            guard (result as? [String: Any])?["ok"] as? Bool == true else {
                throw AgentConnectionOperationExecutionError(.rejected)
            }
            _ = await refresh()
            return "\(source.title) PetCore 通道自检通过（诊断事件不触发桌宠）"
        case .repair:
            return try await performConnectionRepair(operation.sources)
        case .uninstall:
            return try await performConnectionUninstall(operation.sources)
        }
    }

    private func performConnectionCheck(_ sources: [AgentSource]) async throws -> String {
        if sources == AgentSource.allCases {
            let result = try await requestPetCore(
                method: "connections.check",
                params: Self.connectionOperationParameters(cwd: connectionCheckCWD)
            )
            let data = try JSONSerialization.data(withJSONObject: result)
            connections = try JSONDecoder().decode([AgentConnectionStatus].self, from: data)
            sortConnections()
            return "连接检查完成"
        }

        for source in sources {
            let result = try await requestPetCore(
                method: "connections.check",
                params: Self.connectionOperationParameters(
                    source: source,
                    cwd: connectionCheckCWD
                )
            )
            try updateConnectionStatus(from: result)
        }
        return sources.count == 1
            ? "\(sources[0].title) 检查完成"
            : "\(sources.count) 个 Agent 连接检查完成"
    }

    private func performConnectionRepair(_ sources: [AgentSource]) async throws -> String {
        var repaired: [String] = []
        var pending: [String] = []
        var failed: [String] = []
        for source in sources {
            do {
                let result = try await requestPetCore(
                    method: "connections.repair",
                    params: Self.connectionOperationParameters(
                        source: source,
                        cwd: connectionCheckCWD
                    )
                )
                let status = try updateConnectionStatus(from: result)
                if unresolvedConnectionItemCount(status) == 0 {
                    repaired.append(source.shortTitle)
                } else {
                    pending.append(source.shortTitle)
                }
            } catch {
                failed.append(source.shortTitle)
            }
        }
        sortConnections()
        if !failed.isEmpty {
            throw AgentConnectionOperationExecutionError(.partialFailure)
        }
        return pending.isEmpty
            ? "连接修复完成：\(repaired.joined(separator: "、"))"
            : "修复已执行，仍需处理：\(pending.joined(separator: "、"))"
    }

    private func performConnectionUninstall(_ sources: [AgentSource]) async throws -> String {
        var uninstalled: [String] = []
        var pending: [String] = []
        var failed: [String] = []
        for source in sources {
            do {
                let result = try await requestPetCore(
                    method: "connections.uninstall",
                    params: ["source": source.rawValue]
                )
                let status = try updateConnectionStatus(from: result)
                if status.hasInstalledConnectorArtifacts {
                    pending.append(source.shortTitle)
                } else {
                    uninstalled.append(source.shortTitle)
                }
            } catch {
                failed.append(source.shortTitle)
            }
        }
        sortConnections()
        if !failed.isEmpty {
            throw AgentConnectionOperationExecutionError(.partialFailure)
        }
        return pending.isEmpty
            ? "连接卸载完成：\(uninstalled.joined(separator: "、"))"
            : "卸载已执行，仍需处理：\(pending.joined(separator: "、"))"
    }

    private func connectionOperationStartedStatus(
        _ operation: AgentConnectionOperation
    ) -> String {
        let names = operation.sources.map(\.shortTitle).joined(separator: "、")
        return switch operation.kind {
        case .check: "正在检查 \(names)"
        case .test: "正在测试 \(names) 的 PetCore 通道"
        case .repair: "正在修复 \(names)"
        case .uninstall: "正在卸载 \(names)"
        }
    }

    private func connectionOperationFailurePrefix(
        _ operation: AgentConnectionOperation
    ) -> String {
        switch operation.kind {
        case .check: "连接检查失败"
        case .test: "通道自检失败"
        case .repair: "连接修复失败"
        case .uninstall: "连接卸载失败"
        }
    }

    static func connectionOperationFailureReason(
        for error: Error
    ) -> AgentConnectionOperationFailureReason {
        if let error = error as? AgentConnectionOperationExecutionError {
            return error.reason
        }
        if let error = error as? PetCoreClientError {
            return switch error {
            case .socketPathTooLong, .connectFailed, .writeFailed:
                .transportUnavailable
            case .invalidResponse:
                .invalidResponse
            case .rpcError:
                .rejected
            }
        }
        return .unknown
    }

    func toggleOverlay() {
        var next = behavior
        next.enabled.toggle()
        diagnostics.log(
            .info,
            category: "overlay",
            event: "overlay_enabled_changed",
            metadata: ["enabled": .bool(next.enabled)]
        )
        updateBehavior(next)
    }

    func resizeOverlay(delta: CGSize) {
        let change = (delta.width + delta.height) / 420
        setOverlayScale(overlayScale + change)
    }

    func updateOverlayPlacement(frame: CGRect, visibleFrame: CGRect?) {
        recordOverlayPanelFrame(frame, visibleFrame: visibleFrame)
        ensureOverlayPetPosition(in: overlayScreenVisibleFrame)
    }

    func recordOverlayPanelFrame(_ frame: CGRect, visibleFrame: CGRect?) {
        let nextVisibleFrame = visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        if !rect(overlayScreenFrame, nearlyEquals: frame) {
            overlayScreenFrame = frame
        }
        if !rect(overlayScreenVisibleFrame, nearlyEquals: nextVisibleFrame) {
            overlayScreenVisibleFrame = nextVisibleFrame
        }
    }

    func moveOverlayPet(to proposedCenter: CGPoint, visibleFrame: CGRect?, commit: Bool = true) {
        let targetScreen = screen(containing: proposedCenter)
            ?? screen(matchingVisibleFrame: visibleFrame)
            ?? screen(containing: overlayPetScreenCenter)
            ?? NSScreen.main
        let targetVisibleFrame = targetScreen?.visibleFrame ?? visibleFrame ?? overlayScreenVisibleFrame
        guard !targetVisibleFrame.isEmpty else {
            overlayPetScreenCenter = proposedCenter
            overlayPetPositionInitialized = true
            return
        }
        let movementFrame = OverlayGeometry.petMovementFrame(
            screenFrame: targetScreen?.frame ?? targetVisibleFrame,
            visibleFrame: targetVisibleFrame
        )
        overlayScreenVisibleFrame = targetVisibleFrame
        overlayPetScreenCenter = OverlayGeometry.clampedPetScreenCenter(
            proposedCenter,
            scale: overlayScale,
            visibleFrame: movementFrame,
            clickMenuEnabled: behavior.clickMenu,
            petVisualEnvelope: overlayPetVisualEnvelope
        )
        overlayPetPositionInitialized = true
        if commit {
            diagnostics.log(
                .info,
                category: "overlay",
                event: "overlay_position_committed",
                metadata: ["committed": .bool(true)]
            )
            overlayController.updateLayout()
            scheduleOverlayPlacementSave()
        } else {
            overlayController.updateLayoutDuringInteraction()
        }
    }

    func ensureOverlayPetPosition(in visibleFrame: CGRect) {
        guard !visibleFrame.isEmpty else { return }
        if overlayPetPositionInitialized {
            let targetScreen = screen(matchingVisibleFrame: visibleFrame)
                ?? screen(containing: overlayPetScreenCenter)
            let movementFrame = OverlayGeometry.petMovementFrame(
                screenFrame: targetScreen?.frame ?? visibleFrame,
                visibleFrame: targetScreen?.visibleFrame ?? visibleFrame
            )
            overlayPetScreenCenter = OverlayGeometry.clampedPetScreenCenter(
                overlayPetScreenCenter,
                scale: overlayScale,
                visibleFrame: movementFrame,
                clickMenuEnabled: behavior.clickMenu,
                petVisualEnvelope: overlayPetVisualEnvelope
            )
        } else {
            overlayPetScreenCenter = OverlayGeometry.defaultPetScreenCenter(
                in: visibleFrame,
                scale: overlayScale
            )
            overlayPetPositionInitialized = true
        }
    }

    func resizeOverlay(from initialScale: CGFloat, translation: CGSize, commit: Bool = true) {
        let change = (translation.width + translation.height) / 520
        setOverlayScale(initialScale + change, commit: commit)
    }

    func resizeOverlay(from initialScale: CGFloat, screenTranslation: CGSize, commit: Bool = true) {
        let change = (screenTranslation.width + screenTranslation.height) / 520
        setOverlayScale(initialScale + change, commit: commit)
    }

    func setOverlayScale(_ scale: CGFloat, commit: Bool = true) {
        overlayScale = OverlayGeometry.clampedScale(scale)
        if commit {
            diagnostics.log(
                .info,
                category: "overlay",
                event: "overlay_scale_committed",
                metadata: ["scale": .double(Double(overlayScale))]
            )
            let visibleFrame = screen(containing: overlayPetScreenCenter)?.visibleFrame ?? overlayScreenVisibleFrame
            ensureOverlayPetPosition(in: visibleFrame)
            overlayController.updateScale(overlayScale)
            scheduleOverlayPlacementSave()
        } else {
            overlayController.updateScaleDuringInteraction(overlayScale)
        }
    }

    func adjustOverlayScale(by step: CGFloat) {
        setOverlayScale(overlayScale + step)
    }

    func updateOverlayLayout() {
        overlayController.updateLayout()
    }

    func updateOverlayPetVisualEnvelope(
        _ envelope: OverlayPetVisualEnvelope?,
        petID: String,
        stateEntryID: String
    ) {
        guard activePet?.id == petID else { return }
        guard OverlayPetAnimationIdentity.stateEntryID(for: presentedActiveAgentState)
            == stateEntryID
        else {
            return
        }
        guard overlayPetVisualEnvelope != envelope else { return }
        overlayPetVisualEnvelope = envelope
        let visibleFrame = screen(containing: overlayPetScreenCenter)?.visibleFrame
            ?? overlayScreenVisibleFrame
        ensureOverlayPetPosition(in: visibleFrame)
        overlayController.updateLayoutDuringInteraction()
    }

    func updateOverlayPetFrameHitTest(
        _ hitTest: OverlayPetFrameHitTest?,
        petID: String,
        stateEntryID: String
    ) {
        guard activePet?.id == petID else { return }
        guard OverlayPetAnimationIdentity.stateEntryID(for: presentedActiveAgentState)
            == stateEntryID else {
            return
        }
        if let projection = overlayPetFrameHitTestProjection,
           projection.petID == petID,
           projection.stateEntryID == stateEntryID,
           projection.hitTest == hitTest {
            return
        }
        overlayPetFrameHitTestProjection = OverlayPetFrameHitTestProjection(
            hitTest: hitTest,
            petID: petID,
            stateEntryID: stateEntryID
        )
        // A frame can change under a stationary pointer. Re-evaluate the panel
        // immediately so a newly transparent pixel never retains the window's
        // mouse ownership until the next physical pointer event.
        overlayController.refreshPointerPassthrough()
    }

    func toggleOverlayBubble() {
        let wasDismissed = overlayBubbleDismissed
        if overlayBubbleDismissed {
            overlayBubbleDismissed = false
        } else if !overlayAvailableBubbleContents.isEmpty {
            overlayBubbleDismissed = true
        }
        if overlayBubbleDismissed != wasDismissed {
            diagnostics.log(
                .info,
                category: "overlay",
                event: "overlay_bubble_toggled",
                metadata: ["collapsed": .bool(overlayBubbleDismissed)]
            )
        }
        overlayController.updateLayout(
            animateBubble: overlayBubbleDismissed != wasDismissed
        )
    }

    /// Idempotently reveal the bubble without turning an already-visible
    /// bubble into a collapsed one. Pet activation uses this safe fallback
    /// when its current Agent session cannot be opened directly.
    func revealOverlayBubble() {
        guard overlayBubbleDismissed, !overlayAvailableBubbleContents.isEmpty else {
            overlayController.updateLayout()
            return
        }
        overlayBubbleDismissed = false
        diagnostics.log(
            .info,
            category: "overlay",
            event: "overlay_bubble_revealed",
            metadata: ["collapsed": .bool(false)]
        )
        overlayController.updateLayout(animateBubble: true)
    }

    func focusOverlayBubbleForKeyboardNavigation() {
        guard canFocusOverlayBubbleForKeyboardNavigation else { return }
        revealOverlayBubble()
        overlayKeyboardFocusHandler(overlayController, .bubbleSessions)
    }

    func focusOverlayResizeForKeyboardNavigation() {
        guard canFocusOverlayResizeForKeyboardNavigation else { return }
        overlayKeyboardFocusHandler(overlayController, .resizeHandle)
    }

    func toggleOverlayAgentGroup(_ source: AgentSource) {
        overlayAgentGroupExpansionOverrides[source] = !overlayAgentGroupIsExpanded(source)
        overlayController.updateLayout(animateBubble: true)
    }

    func dismissOverlayBubble(eventID: String) {
        if eventID == OverlayBubbleContent.idle.id {
            overlayBubbleDismissed = true
        } else {
            overlayDismissedBubbleEventIDs.insert(eventID)
        }
        overlayController.updateLayout(animateBubble: true)
    }

    func dismissOverlayBubble(eventIDs: [String]) {
        if eventIDs == OverlayBubbleContent.idle.dismissalIDs {
            overlayBubbleDismissed = true
        } else {
            overlayDismissedBubbleEventIDs.formUnion(eventIDs)
        }
        overlayController.updateLayout(animateBubble: true)
    }

    func dismissAllOverlayBubbles() {
        overlayBubbleDismissed = true
        overlayController.updateLayout(animateBubble: true)
    }

    func setOverlayPointerNearPet(_ value: Bool) {
        if overlayPointerNearPet != value {
            overlayPointerNearPet = value
            overlayController.refreshPointerDrivenControlVisibility()
        }
    }

    func refreshOverlayPointerState() {
        overlayController.refreshPointerPassthrough()
    }

    func reconcileOverlayPointerInteractions(pressedMouseButtons: Int) {
        guard pressedMouseButtons == 0 else { return }
        cancelOverlayPointerInteractions()
    }

    func cancelOverlayPointerInteractions() {
        guard overlayPetDragInProgress || overlayResizeInProgress else { return }
        overlayPetDragInProgress = false
        overlayResizeInProgress = false
        overlayController.updateLayoutDuringInteraction()
    }

    func setOverlayPetDragInProgress(_ value: Bool) {
        if overlayPetDragInProgress != value {
            overlayPetDragInProgress = value
            overlayController.updateLayoutDuringInteraction()
            overlayController.refreshPointerPassthrough()
        }
    }

    func setOverlayResizeInProgress(_ value: Bool) {
        if overlayResizeInProgress != value {
            overlayResizeInProgress = value
            overlayController.updateLayoutDuringInteraction()
            overlayController.refreshPointerPassthrough()
        }
    }

    private func rect(_ lhs: CGRect, nearlyEquals rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    func chooseReferenceImages() {
        guard !generationSession.isActive else {
            statusText = "活动任务的参考图已冻结"
            return
        }
        let panel = NSOpenPanel()
        panel.title = APCLocalization.text(.studioReferencesPanelTitle)
        panel.prompt = APCLocalization.text(.commonChoose)
        panel.message = APCLocalization.text(.studioReferencesPanelMessage)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .webP]

        guard panel.runModal() == .OK else { return }
        addReferenceImageURLs(panel.urls)
    }

    func addReferenceImageURLs(_ urls: [URL]) {
        guard !generationSession.isActive else {
            statusText = "活动任务的参考图已冻结"
            return
        }
        recordMakerUserMutation()
        let admission = MakerReferenceImagePolicy.admit(
            existingPaths: referenceImages,
            urls: urls
        )
        referenceImages.append(contentsOf: admission.acceptedPaths)
        let reselectionFillCount = min(
            referenceReselectionCount,
            admission.acceptedPaths.count
        )
        if reselectionFillCount > 0 {
            reselectedReferenceImagePaths.formUnion(
                admission.acceptedPaths.prefix(reselectionFillCount)
            )
            referenceReselectionCount -= reselectionFillCount
        }
        refreshReferenceImageIssue(fallback: admission.issue)

        if urls.isEmpty || admission.acceptedPaths.isEmpty && admission.issue != nil {
            statusText = "请选择图片文件"
        } else if admission.acceptedPaths.isEmpty {
            statusText = "参考图已在列表中"
        } else {
            statusText = "已添加 \(admission.acceptedPaths.count) 张参考图"
        }
    }

    func removeReferenceImage(_ path: String) {
        guard !generationSession.isActive else {
            statusText = "活动任务的参考图已冻结"
            return
        }
        recordMakerUserMutation()
        let removedReselection = reselectedReferenceImagePaths.remove(path) != nil
        referenceImages.removeAll { $0 == path }
        if removedReselection {
            referenceReselectionCount = min(
                MakerReferenceImagePolicy.maximumCount,
                referenceReselectionCount + 1
            )
        }
        refreshReferenceImageIssue()
        statusText = "已移除参考图"
    }

    private static func safeMakerReferenceImagePath(_ url: URL) -> String? {
        MakerReferenceImagePolicy.validatedPath(for: url)
    }

    private func safeExportName(_ name: String) -> String {
        let illegalCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name
            .components(separatedBy: illegalCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "AgentPet" : cleaned
    }

    private func applyOverlayPlacement(_ placement: OverlayPlacement) {
        isApplyingOverlayPlacement = true
        defer {
            isApplyingOverlayPlacement = false
            overlayPlacementLoaded = true
        }

        let persistedCenter = CGPoint(x: placement.x, y: placement.y)
        let screen = screen(matchingDisplayID: placement.displayId)
            ?? screen(containing: persistedCenter)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame
            ?? (overlayScreenVisibleFrame.isEmpty ? .zero : overlayScreenVisibleFrame)
        guard !visibleFrame.isEmpty else { return }

        let persistedScale = CGFloat(placement.scale)
        let targetScale = OverlayGeometry.resolvedInitialScale(
            persistedScale: persistedScale,
            hasPersistedPosition: persistedCenter != .zero
        )
        overlayScale = targetScale

        if persistedCenter == .zero {
            overlayPetScreenCenter = OverlayGeometry.defaultPetScreenCenter(
                in: visibleFrame,
                scale: targetScale
            )
        } else {
            let movementFrame = OverlayGeometry.petMovementFrame(
                screenFrame: screen?.frame ?? visibleFrame,
                visibleFrame: visibleFrame
            )
            overlayPetScreenCenter = OverlayGeometry.clampedPetScreenCenter(
                persistedCenter,
                scale: targetScale,
                visibleFrame: movementFrame,
                clickMenuEnabled: behavior.clickMenu,
                petVisualEnvelope: overlayPetVisualEnvelope
            )
        }
        overlayPetPositionInitialized = true
        overlayController.updateScale(targetScale)

        let normalizedPlacement = currentOverlayPlacement()
        Task { [weak self] in
            await self?.saveOverlayPlacement(normalizedPlacement)
        }
    }

    private func shouldApplyRemoteOverlayPlacement(_ placement: OverlayPlacement) -> Bool {
        guard overlayPlacementLoaded, !isApplyingOverlayPlacement else { return false }
        guard !overlayPetDragInProgress, !overlayResizeInProgress else { return false }

        let current = currentOverlayPlacement()
        let positionChanged = abs(current.x - placement.x) > 0.5
            || abs(current.y - placement.y) > 0.5
        let scaleChanged = abs(current.scale - placement.scale) > 0.0001
        return positionChanged || scaleChanged || current.displayId != placement.displayId
    }

    private func scheduleOverlayPlacementSave() {
        guard overlayPlacementLoaded && !isApplyingOverlayPlacement else { return }
        let placement = currentOverlayPlacement()
        overlayPlacementSaveTask?.cancel()
        overlayPlacementSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            await self?.saveOverlayPlacement(placement)
        }
    }

    private func saveOverlayPlacement(_ placement: OverlayPlacement) async {
        do {
            let data = try JSONEncoder().encode(placement)
            let object = try JSONSerialization.jsonObject(with: data)
            _ = try await requestPetCore(method: "overlay.placement.update", params: object)
        } catch {
            statusText = "桌宠位置保存失败"
        }
    }

    @discardableResult
    private func updateConnectionStatus(from result: Any) throws -> AgentConnectionStatus {
        let data = try JSONSerialization.data(withJSONObject: result)
        let status = try JSONDecoder().decode(AgentConnectionStatus.self, from: data)
        connections.removeAll { $0.source == status.source }
        connections.append(status)
        sortConnections()
        return status
    }

    private func unresolvedConnectionItemCount(_ status: AgentConnectionStatus) -> Int {
        status.blockingItems.count
    }

    private func sortConnections() {
        connections.sort {
            let lhs = AgentSource.allCases.firstIndex(of: $0.source) ?? 0
            let rhs = AgentSource.allCases.firstIndex(of: $1.source) ?? 0
            return lhs < rhs
        }
    }

    func applyAuthoritativeConnectionSnapshot(_ snapshotConnections: [AgentConnectionStatus]) {
        let sorted = snapshotConnections.sorted {
            let lhs = AgentSource.allCases.firstIndex(of: $0.source) ?? 0
            let rhs = AgentSource.allCases.firstIndex(of: $1.source) ?? 0
            return lhs < rhs
        }
        if connections != sorted {
            connections = sorted
        }
    }

    private func currentOverlayPlacement() -> OverlayPlacement {
        OverlayPlacement(
            x: Double(overlayPetScreenCenter.x),
            y: Double(overlayPetScreenCenter.y),
            scale: Double(overlayScale),
            displayId: currentDisplayID(for: overlayPetScreenCenter)
        )
    }

    private func currentDisplayID(for point: CGPoint) -> String {
        let screen = screen(containing: point) ?? NSScreen.main
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? "main"
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func screen(matchingDisplayID displayID: String) -> NSScreen? {
        if displayID == "main" {
            return NSScreen.main
        }
        return NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.stringValue == displayID
        }
    }

    private func screen(matchingVisibleFrame visibleFrame: CGRect?) -> NSScreen? {
        guard let visibleFrame, !visibleFrame.isEmpty else { return nil }
        return NSScreen.screens.first { screen in
            screen.visibleFrame == visibleFrame || screen.visibleFrame.intersects(visibleFrame)
        }
    }

    private func requestPetCore(
        method: String,
        params: Any = [:],
        timeout: Duration? = nil
    ) async throws -> Any {
        if let petCoreRequestOverride {
            return try await petCoreRequestOverride(method, params, timeout)
        }
        let startedAt = Date()
        do {
            let paramsData = try JSONSerialization.data(withJSONObject: params)
            let responseData = try await client.requestData(
                method: method,
                paramsJSONData: paramsData,
                timeout: timeout
            )
            guard
                let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            else {
                throw PetCoreClientError.invalidResponse
            }
            if let error = object["error"] as? [String: Any] {
                throw PetCoreClientError.rpcError(
                    String(describing: error["message"] ?? "Unknown PetCore error")
                )
            }
            if !Self.isPollingRPC(method) {
                diagnostics.log(
                    Self.isUserMutationRPC(method) ? .info : .debug,
                    category: "rpc",
                    event: "rpc_succeeded",
                    metadata: [
                        "method": .string(method),
                        "duration_ms": .integer(Self.elapsedMilliseconds(since: startedAt))
                    ]
                )
            }
            return object["result"] ?? NSNull()
        } catch {
            diagnostics.logFailure(
                error,
                category: "rpc",
                event: "rpc_failed",
                metadata: [
                    "method": .string(method),
                    "duration_ms": .integer(Self.elapsedMilliseconds(since: startedAt))
                ],
                throttleKey: "rpc_failed.\(method)",
                minimumInterval: Self.isPollingRPC(method) ? 30 : 5
            )
            throw error
        }
    }

    private static func elapsedMilliseconds(since date: Date) -> Int64 {
        Int64(max(0, Date().timeIntervalSince(date) * 1_000).rounded())
    }

    private static func isUserMutationRPC(_ method: String) -> Bool {
        method.hasPrefix("generation.")
            || method.hasPrefix("pet.")
            || method.hasPrefix("petpack.")
            || method.hasPrefix("connections.")
            || method == "behavior.patch"
            || method == "overlay.placement.update"
            || method == "diagnostics.export"
    }

    private static func isPollingRPC(_ method: String) -> Bool {
        method == "state.wait" || method == "generation.messages.wait"
    }
}

private struct StateSnapshot: Codable {
    var revision: String?
    var changed: Bool?
    var behavior: BehaviorSettings
    var behaviorRevision: String?
    var overlayPlacement: OverlayPlacement?
    var pets: [PetSummary]
    var petAssetWarnings: [PetAssetWarning]?
    var activeGeneration: ActiveGenerationSnapshot?
    var activeAgentState: ActiveAgentState?
    var activeAgentSessions: [ActiveAgentState]?
    var activeAgentSessionsOmittedCount: Int?
    var overlayVisibility: OverlayVisibility?
    var events: [AgentEvent]
    var recentEvents: [AgentEvent]?
    var connections: [AgentConnectionStatus]

    enum CodingKeys: String, CodingKey {
        case revision
        case changed
        case behavior
        case behaviorRevision = "behavior_revision"
        case overlayPlacement = "overlay_placement"
        case pets
        case petAssetWarnings = "pet_asset_warnings"
        case activeGeneration = "active_generation"
        case activeAgentState = "active_agent_state"
        case activeAgentSessions = "active_agent_sessions"
        case activeAgentSessionsOmittedCount = "active_agent_sessions_omitted_count"
        case overlayVisibility = "overlay_visibility"
        case events
        case recentEvents = "recent_events"
        case connections
    }
}

private struct GenerationMessagesSnapshot: Codable {
    var revision: String?
    var changed: Bool?
    var messages: [GenerationMessage]
    var resultPetID: String?
    var revisionID: String?
    var validationSummary: GenerationValidationSummary?

    var resultMetadata: GenerationResultMetadata {
        GenerationResultMetadata(
            resultPetID: resultPetID,
            revisionID: revisionID,
            validationSummary: validationSummary
        )
    }

    enum CodingKeys: String, CodingKey {
        case revision
        case changed
        case messages
        case resultPetID = "result_pet_id"
        case revisionID = "revision_id"
        case validationSummary = "validation_summary"
    }
}
