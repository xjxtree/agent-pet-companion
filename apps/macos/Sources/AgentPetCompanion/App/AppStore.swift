import AgentPetCompanionCore
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum OverlayBubbleDisclosureDirection: Equatable {
    case expanding
    case collapsing
}

enum OverlayBubbleDisclosureAction: Equatable {
    case revealBubble
    case revealCollapsedStandaloneStack
    case expandStandaloneStack
    case collapseStandaloneStack
    case dismissBubble

    static func resolve(
        groupSessionsByAgent: Bool,
        sessionCount: Int,
        bubbleDismissed: Bool,
        standaloneStackExpanded: Bool,
        standaloneStackDirection: OverlayBubbleDisclosureDirection
    ) -> Self? {
        guard sessionCount > 0 else { return nil }
        guard !groupSessionsByAgent, sessionCount > 1 else {
            return bubbleDismissed ? .revealBubble : .dismissBubble
        }
        if bubbleDismissed {
            return .revealCollapsedStandaloneStack
        }
        if standaloneStackExpanded {
            return .collapseStandaloneStack
        }
        return standaloneStackDirection == .expanding
            ? .expandStandaloneStack
            : .dismissBubble
    }

    var revealsMoreContent: Bool {
        switch self {
        case .revealBubble, .revealCollapsedStandaloneStack, .expandStandaloneStack:
            true
        case .collapseStandaloneStack, .dismissBubble:
            false
        }
    }
}

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
    let requiresAuthoritativeSnapshotOnReady: Bool

    init(
        ensureRunning: @escaping EnsureRunning,
        recover: @escaping Recover,
        fetchInitialBehavior: FetchInitialBehavior? = nil,
        refreshSnapshot: @escaping RefreshSnapshot,
        onReady: @escaping OnReady,
        requiresAuthoritativeSnapshotOnReady: Bool = false
    ) {
        self.ensureRunning = ensureRunning
        self.recover = recover
        self.fetchInitialBehavior = fetchInitialBehavior
        self.refreshSnapshot = refreshSnapshot
        self.onReady = onReady
        self.requiresAuthoritativeSnapshotOnReady =
            requiresAuthoritativeSnapshotOnReady
    }
}

private struct OverlayPetFrameHitTestProjection {
    var hitTest: OverlayPetFrameHitTest?
    var petID: String
    var semanticOwnerEntryID: String
}

enum PetCoreRuntimePhase: Equatable {
    case checking
    case running
    case failed
}

enum PetStudioCodexAvailability: Equatable, Sendable {
    case checking
    case available
    case missing
    case unavailable

    var permitsGeneration: Bool {
        self == .available
    }
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
        guard let source else { return nil }
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
        switch source {
        case .codex:
            return URL(string: "codex://threads/\(canonical)")
        // Claude Desktop's `claude://resume` imports a CLI transcript as a new
        // Desktop session rather than locating the existing one, so there is no
        // truthful exact-session link to build for Claude Code.
        // dsh V1 has no App surface and no session deep link, like Pi.
        case .claudeCode, .pi, .opencode, .dsh:
            return nil
        }
    }
}

enum AgentSessionOpenRoute: Equatable {
    case url(URL)
    case application(bundleIdentifiers: [String], paths: [String])
}

enum AgentSessionOpenFailure: Equatable, Sendable {
    case urlOpenRejected
    case applicationUnavailable
    case applicationLaunchFailed
}

enum AgentSessionOpenOutcome: Equatable, Sendable {
    case openedExactSession
    case openedAgentHost
    case failed(AgentSessionOpenFailure)

    var didOpen: Bool {
        switch self {
        case .openedExactSession, .openedAgentHost: true
        case .failed: false
        }
    }
}

private struct OverlaySessionNavigationNoticeRecord: Equatable {
    let identity: OverlaySessionProjectionIdentity
    let notice: OverlaySessionNavigationNotice
}

private struct OverlaySessionProjectionIdentity: Equatable, Sendable {
    let eventID: String
    let acknowledgementID: String?
}

enum AgentSessionRouter {
    private static let chatGPTBundleIdentifiers = ["com.openai.codex"]
    private static let chatGPTPaths = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
    private static let claudeBundleIdentifiers = ["com.anthropic.claudefordesktop"]
    private static let claudePaths = ["/Applications/Claude.app"]
    private static let openCodeBundleIdentifiers = [
        "ai.opencode.desktop",
        "ai.opencode.desktop.beta",
        "ai.opencode.desktop.dev"
    ]
    private static let openCodePaths = [
        "/Applications/OpenCode.app",
        "/Applications/OpenCode Beta.app",
        "/Applications/OpenCode Dev.app"
    ]
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

        switch navigation.capability {
        case .exactSession:
            return exactSessionRoute(source: source, navigation: navigation)
        case .agentHost:
            return agentHostRoute(source: source, navigation: navigation)
        case .unavailable:
            return nil
        }
    }

    static func validatedCapability(
        source: AgentSource?,
        sessionID: String?,
        navigation: AgentSessionNavigation
    ) -> NavigationCapability {
        route(source: source, sessionID: sessionID, navigation: navigation) == nil
            ? .unavailable
            : navigation.capability
    }

    static func hostFallbackRoute(
        source: AgentSource?,
        navigation: AgentSessionNavigation
    ) -> AgentSessionOpenRoute? {
        guard navigation.capability == .exactSession,
              !navigation.explicitlyClosed else { return nil }
        return agentHostRoute(source: source, navigation: navigation)
    }

    private static func exactSessionRoute(
        source: AgentSource?,
        navigation: AgentSessionNavigation
    ) -> AgentSessionOpenRoute? {
        if navigation.surface == "cli_terminal",
           navigation.terminalApp == "warp",
           let openURL = validatedSessionOpenURL(navigation.openURL) {
            return .url(openURL)
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
        return nil
    }

    private static func agentHostRoute(
        source: AgentSource?,
        navigation: AgentSessionNavigation
    ) -> AgentSessionOpenRoute? {
        guard let source else { return nil }
        if navigation.surface == "cli_terminal" {
            guard let terminalApp = navigation.terminalApp,
                  let target = terminalTargets[terminalApp]
            else {
                return nil
            }
            return .application(bundleIdentifiers: target.0, paths: target.1)
        }

        if source == .codex, navigation.surface == "chatgpt_app" {
            return .application(
                bundleIdentifiers: chatGPTBundleIdentifiers,
                paths: chatGPTPaths
            )
        }
        if source == .claudeCode, navigation.surface == "claude_app" {
            return .application(
                bundleIdentifiers: claudeBundleIdentifiers,
                paths: claudePaths
            )
        }
        if source == .opencode, navigation.surface == "opencode_app" {
            return .application(
                bundleIdentifiers: openCodeBundleIdentifiers,
                paths: openCodePaths
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
            && current.activityText == next.activityText
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

    func isAvailable(overlayEnabled: Bool, bubbleSessionCount: Int) -> Bool {
        guard overlayEnabled else { return false }
        return bubbleSessionCount > 0
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

enum OnboardingOperationFailure: Equatable {
    case serviceUnavailable
    case petActivation
    case revisionConflict
    case requestRejected
}

enum IncludedCompanionRestoreState: Equatable {
    case idle
    case restoring
    case restored
    case failed
}

enum PetAssetRepairState: Equatable {
    case idle
    case repairing
    case repaired
    case failed
}

enum AppUpdateConvergenceAttention: Equatable {
    case bundledPets
    case connectors([ProductConnectorConvergenceIssue])
    case service

    var sources: [AgentSource] {
        if case let .connectors(issues) = self {
            issues.map(\.source)
        } else {
            []
        }
    }
}

enum AppUpdateConvergenceState: Equatable {
    case idle
    case waitingForActiveWork
    case updating
    case completed(version: String)
    case needsAttention(AppUpdateConvergenceAttention)
}

enum AppStartupConnectionCheckState: Equatable {
    case idle
    case waiting
    case checking
    case completed
    case failed(AgentConnectionOperationFailureReason)
}

@MainActor
final class AppStore: ObservableObject {
    typealias BundledPetSeeder = @MainActor () async -> Bool
    typealias BundledPetSeedSleeper = @Sendable (Duration) async throws -> Void
    typealias InitialAppearanceFallbackSleeper = @Sendable (Duration) async throws -> Void
    typealias OverlayPlacementRetrySleeper = @Sendable (Duration) async throws -> Void
    typealias AgentSessionRouteOpener = @MainActor (
        AgentSessionOpenRoute
    ) async -> AgentSessionOpenOutcome
    typealias ProductConvergenceSleeper = @Sendable (Duration) async throws -> Void
    typealias ProductConvergenceUpgradeEvidence = @MainActor (
        RuntimeReleaseManifest
    ) -> Bool
    typealias RuntimeHandoffCheck = @MainActor () -> Bool
    typealias ApplicationAppearanceApplier = @MainActor (AppearanceTheme) -> Void
    typealias ApplicationLanguageApplier = @MainActor (InterfaceLanguage) -> Void
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
    @Published private(set) var selectedStyle = AIPetMakerDefaults.style
    @Published private(set) var selectedQuality = AIPetMakerDefaults.quality
    @Published private(set) var referenceImages: [String] = []
    @Published private(set) var referenceImageIssue: MakerReferenceImageIssue?
    @Published private(set) var referenceReselectionCount = 0
    @Published private(set) var petStudioCodexAvailability =
        PetStudioCodexAvailability.checking
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
    @Published private(set) var onboarding: VersionedOnboardingProgress?
    @Published private(set) var onboardingMutationInFlight = false
    @Published private(set) var onboardingDismissedForCurrentLaunch = false
    @Published private(set) var onboardingOperationFailure: OnboardingOperationFailure?
    @Published private(set) var includedCompanionRestoreState =
        IncludedCompanionRestoreState.idle
    @Published private(set) var petAssetRepairStates: [String: PetAssetRepairState] = [:]
    @Published private(set) var generationSession = GenerationSession()
    @Published private(set) var generationHistorySnapshot =
        GenerationStudioHistorySnapshot()
    @Published private(set) var selectedGenerationHistoryJobID: String?
    @Published private(set) var generationHistoryDetail: GenerationStudioHistoryDetail?
    @Published private(set) var generationHistoryMessages: [GenerationMessage] = []
    @Published private(set) var generationHistoryMessagesHasMore = false
    @Published private(set) var generationHistoryMessagesIsLoading = false
    @Published private(set) var makerDraftIsActive = false
    @Published private(set) var generationHistoryIsLoading = false
    @Published private(set) var generationHistoryHasLoaded = false
    @Published private(set) var generationHistoryDetailIsLoading = false
    @Published private(set) var generationHistoryLoadFailed = false
    @Published private(set) var generationHistoryDeleteInFlightJobID: String?
    @Published private(set) var generationHistoryMutationError: String?
    @Published var generationReplyText = ""
    @Published var statusText = "正在初始化"
    @Published var serviceStatusText = "正在初始化"
    @Published private(set) var petCoreOperationalState = PetCoreOperationalState.checking
    @Published private(set) var petCoreRuntimeInfo = PetCoreRuntimeInfo.initial(
        manifest: PetCoreRuntimeContract.requiredManifest
    )
    @Published private(set) var lastServiceFailureCode = PetCoreServiceFailureCode.none
    @Published private(set) var overlayDisplayWidthPt =
        OverlayGeometry.defaultDisplayWidthPt
    @Published var overlayVisible = true
    @Published var overlayScreenFrame = CGRect(x: 780, y: 140, width: 704, height: 640)
    @Published var overlayScreenVisibleFrame = NSScreen.main?.visibleFrame ?? .zero
    @Published var overlayPetScreenCenter = CGPoint.zero
    @Published private(set) var overlayPlacementSaveNeedsAttention = false
    var overlayPresentedPetScreenCenter: CGPoint {
        overlayPetDragPresentationCenter ?? overlayPetScreenCenter
    }
    private(set) var overlayPetVisualEnvelope: OverlayPetVisualEnvelope?
    private var overlayPetFrameHitTestProjection: OverlayPetFrameHitTestProjection?
    var overlayPetFrameHitTest: OverlayPetFrameHitTest? {
        guard let projection = overlayPetFrameHitTestProjection,
              activePet?.id == projection.petID,
              OverlayPetAnimationIdentity.stateEntryID(for: presentedActiveAgentState)
                == projection.semanticOwnerEntryID else {
            return nil
        }
        return projection.hitTest
    }
    var overlayPetPointerMaskState: OverlayPointerMaskState {
        guard let projection = overlayPetFrameHitTestProjection else {
            return .missing
        }
        guard activePet?.id == projection.petID,
              OverlayPetAnimationIdentity.stateEntryID(
                  for: presentedActiveAgentState
              ) == projection.semanticOwnerEntryID else {
            return .stale
        }
        return projection.hitTest == nil ? .missing : .valid
    }
    var overlayActivePointerInteractionID: UUID? {
        overlayDragInteractionID
    }
    @Published var overlayBubbleDismissed = false
    /// Presentation-only side of the pet used to keep flat session cards and
    /// the disclosure chevron ordered toward the pet. It changes only when a
    /// placement edge actually flips, never for ordinary drag samples.
    @Published private(set) var overlayBubbleAnchorDirection: OverlayBubbleAnchorDirection = .above
    @Published var overlayDismissedBubbleEventIDs: Set<String> = []
    @Published private var overlaySessionNavigationNotices:
        [String: OverlaySessionNavigationNoticeRecord] = [:]
    private var overlaySessionProjectionIdentities:
        [String: OverlaySessionProjectionIdentity] = [:]
    @Published private(set) var overlayAgentGroupExpansionOverrides: [AgentSource: Bool] = [:]
    /// Oldest-to-newest stable slots for the non-grouped tray. Status churn
    /// within one activation epoch never mutates this order.
    private var overlayStandaloneSessionOrder: [String] = []
    private var overlayStandaloneSessionActivationIDs: [String: String] = [:]
    @Published private(set) var overlayStandaloneStackExpansionOverride: Bool?
    private var overlayStandaloneStackDisclosureDirection:
        OverlayBubbleDisclosureDirection = .expanding
    @Published var overlayPointerNearPet = false
    @Published var overlayPetDragInProgress = false
    @Published var petOperationIDs: Set<String> = []
    @Published var isImportingPetpack = false
    @Published private(set) var petpackImportProgress: PetLibraryImportProgress?
    @Published private(set) var petLibraryNotice: PetLibraryNotice?
    @Published private(set) var diagnosticsExportState = DiagnosticsExportState.idle
    @Published private(set) var portableMakerSkillStatus: PortableMakerSkillStatus?
    @Published private(set) var portableMakerSkillOperation = PortableMakerSkillOperation.idle
    @Published private(set) var portableMakerSkillFailure: PortableMakerSkillFailure?
    @Published private(set) var manualAppInstallationRequest: AppManualInstallationRequest?
    @Published private(set) var startupConnectionCheckState =
        AppStartupConnectionCheckState.idle
    @Published private(set) var appUpdateConvergenceState = AppUpdateConvergenceState.idle {
        didSet {
            if case let .needsAttention(attention) = appUpdateConvergenceState {
                connectionsModel.applyUpdateAttention(attention)
            } else {
                connectionsModel.applyUpdateAttention(nil)
            }
        }
    }

    private let client: PetCoreClient
    private let overlayController: PetOverlayController
    private let bootstrapHooks: AppStoreBootstrapHooks
    private let diagnostics: AppDiagnostics
    private let bundledPetSeederOverride: BundledPetSeeder?
    private let bundledPetSeedSleeper: BundledPetSeedSleeper
    private let initialAppearanceFallbackSleeper: InitialAppearanceFallbackSleeper
    private let overlayPlacementRetrySleeper: OverlayPlacementRetrySleeper
    private let overlayPlacementJournalStore: OverlayPlacementJournalStore
    private let agentSessionRouteOpener: AgentSessionRouteOpener
    private let runtimeHandoffIfNeeded: RuntimeHandoffCheck
    private let controlCenterWindowProvider:
        ControlCenterPresentationCoordinator.WindowProvider
    private let controlCenterApplicationActivator:
        ControlCenterPresentationCoordinator.ApplicationActivator
    private let applicationAppearanceApplier: ApplicationAppearanceApplier
    private let applicationLanguageApplier: ApplicationLanguageApplier
    private let overlayPresenter: OverlayPresenter
    private let overlayKeyboardFocusHandler: OverlayKeyboardFocusHandler
    private let petCoreRequestOverride: PetCoreRequestOverride?
    let connectionsModel = ConnectionsModel()
    let appUpdater: AppUpdateController
    private let productConvergenceSleeper: ProductConvergenceSleeper
    private let productConvergenceNoticePreferences: ProductConvergenceNoticePreferences
    private let productConvergenceManifest: RuntimeReleaseManifest?
    private let productConvergenceUpgradeEvidence: ProductConvergenceUpgradeEvidence
    private var refreshTask: Task<Void, Never>?
    private var petpackImportTask: Task<Void, Never>?
    private var overlayPetPositionInitialized = false
    private var overlayPlacementAuthority = OverlayPlacementAuthority()
    private var overlayPlacementSaveTask: Task<Void, Never>?
    private var overlayPlacementExhaustedGeneration: UInt64?
    private var overlayPlacementJournalDidLoad = false
    private let overlayPlacementPreviewDriver =
        OverlayDisplayLinkCoalescer<CGFloat>()
    private var overlayDisplayWidthCommitTask: Task<Void, Never>?
    private var overlayDisplayWidthCommitDeadline: TimeInterval?
    private var overlayPetDragPresentationCenter: CGPoint?
    private var overlayBubbleProjectionCache: (
        inputs: OverlayBubbleProjectionInputs,
        contents: [OverlayBubbleContent]
    )?
    private var overlayDragInteractionID: UUID?
    private var overlayLostMouseUpFallbackTask: Task<Void, Never>?
    private var pendingDisplayWidthPt: CGFloat?
    private var stateRevision = ""
    private(set) var behaviorRevision = "0"
    private var authoritativeBehavior = BehaviorSettings()
    private var overlayLastReopenIDBySession: [String: String] = [:]
    private var behaviorMutationTask: Task<Void, Never>?
    private var behaviorMutationSequence: UInt64 = 0
    private var pendingBehaviorMutationCount = 0
    private var connectionsModelObservation: AnyCancellable?
    private lazy var controlCenterPresentationCoordinator =
        ControlCenterPresentationCoordinator(
            identifier: Self.controlCenterWindowIdentifier,
            windowProvider: controlCenterWindowProvider,
            activateApplication: controlCenterApplicationActivator,
            runtimeHandoffIfNeeded: { [weak self] in
                self?.runtimeHandoffIfNeeded() ?? false
            },
            onWindowOpened: { [weak self] _ in
                guard let self else { return }
                self.overlayController.controlCenterDidOpen()
                self.diagnostics.log(
                    .debug,
                    category: "lifecycle",
                    event: "control_center_opened"
                )
            },
            onWindowClosed: { [weak self] in
                guard let self else { return }
                self.overlayController.controlCenterDidClose()
                self.diagnostics.log(
                    .debug,
                    category: "lifecycle",
                    event: "control_center_closed"
                )
            }
        )
    private var generationMessagesTask: Task<Void, Never>?
    private var latestGenerationRestoreAttemptState = LatestGenerationRestoreAttemptState.notAttempted
    private var latestGenerationRestoreAttemptSequence: UInt64 = 0
    private var latestGenerationRestoreInFlight: (id: UInt64, task: Task<Void, Never>)?
    private var makerUserMutationRevision: UInt64 = 0
    private var automaticLatestGenerationRestoreInvalidated = false
    private var generationHistoryListSequence: UInt64 = 0
    private var generationHistoryDetailSequence: UInt64 = 0
    private var generationHistoryMessagesSequence: UInt64 = 0
    /// A job ID returned by a successful start/edit/retry RPC is authoritative
    /// before it appears in an eventually refreshed history list. Keep that
    /// selection stable until a list snapshot catches up.
    private var generationHistorySelectionIntentJobID: String?
    private var reselectedReferenceImagePaths: Set<String> = []
    private var activeGenerationRecoveryProjection: SanitizedGenerationRecoveryProjection?
    private var runtimeBootstrapCompleted = false
    private var runtimeBootstrapRequiresFullRecovery = false
    private let runtimeBootstrapSlot = SequencedTaskSlot<Bool>()
    private var runtimeBootstrapRetryTask: Task<Void, Never>?
    private var runtimeBootstrapRetryDelaySeconds: UInt64 = 2
    private var startupConnectionCheckTask: Task<Void, Never>?
    private var bundledPetSeedRetryTask: Task<Void, Never>?
    private var initialAppearanceFallbackTask: Task<Void, Never>?
    private let serviceRecoverySlot = SequencedTaskSlot<Bool>()
    private var hasPresentedOverlay = false
    private var productConvergenceTask: Task<Void, Never>?
    private var productConvergenceVisibilityTask: Task<Void, Never>?
    private var inFlightProtectedMutationCount = 0

    static let bundledPetSeedRetryDelays: [Duration] = [
        .seconds(2),
        .seconds(4),
        .seconds(8)
    ]
    static let initialAppearanceFallbackDelay: Duration = .milliseconds(500)
    static func stateWaitTimeoutMilliseconds(
        generationIsActive: Bool,
        hasActiveAgentState: Bool
    ) -> Int {
        if generationIsActive || hasActiveAgentState {
            return 1_000
        }
        return 30_000
    }

    static let controlCenterWindowIdentifier = NSUserInterfaceItemIdentifier(
        "dev.agentpet.companion.control-center"
    )

    var controlCenterIsOpen: Bool {
        controlCenterPresentationCoordinator.isOpen
    }

    var controlCenterPresentationPhase: ControlCenterPresentationCoordinator.Phase {
        controlCenterPresentationCoordinator.phase
    }
    private static let defaultOverlayKeyboardFocusHandler: OverlayKeyboardFocusHandler = { controller, action in
        switch action {
        case .bubbleSessions:
            controller.focusBubbleForKeyboardNavigation()
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
        overlayPlacementRetrySleeper = { duration in
            try await Task.sleep(for: duration)
        }
        overlayPlacementJournalStore = .fileBacked()
        agentSessionRouteOpener = Self.openAgentSessionRoute
        runtimeHandoffIfNeeded = {
            AppUpdateHandoffCoordinator.shared.restartIfInstalledBuildChanged()
        }
        controlCenterWindowProvider = { NSApp?.windows ?? [] }
        controlCenterApplicationActivator = {
            NSApp?.activate(ignoringOtherApps: true)
        }
        applicationAppearanceApplier = { theme in
            APCApplicationAppearance.apply(theme)
        }
        applicationLanguageApplier = { language in
            APCLocalization.applyInterfaceLanguage(language)
        }
        overlayPresenter = { controller, store in
            controller.show(store: store)
        }
        overlayKeyboardFocusHandler = Self.defaultOverlayKeyboardFocusHandler
        petCoreRequestOverride = nil
        appUpdater = AppUpdateController(diagnostics: diagnostics)
        productConvergenceSleeper = { duration in
            try await Task.sleep(for: duration)
        }
        productConvergenceNoticePreferences = ProductConvergenceNoticePreferences()
        productConvergenceManifest = PetCoreRuntimeContract.requiredManifest
        productConvergenceUpgradeEvidence = { manifest in
            PetCoreRuntimeUpgradeEvidence.hasManagedUpdateContext(
                currentBuildID: manifest.buildID
            )
        }
        bootstrapHooks = AppStoreBootstrapHooks(
            ensureRunning: { await bootstrapCoordinator.ensureRunning() },
            recover: { await bootstrapCoordinator.recover() },
            fetchInitialBehavior: { store in
                try await store.requestPetCore(method: "behavior.get")
            },
            refreshSnapshot: { store in try await store.refreshSnapshot() },
            onReady: { store in await store.completeRuntimeBootstrap() },
            requiresAuthoritativeSnapshotOnReady: true
        )
        configureConnectionsModel()
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
        overlayPlacementRetrySleeper: @escaping OverlayPlacementRetrySleeper = { duration in
            try await Task.sleep(for: duration)
        },
        overlayPlacementJournalStore: OverlayPlacementJournalStore = .disabled(),
        agentSessionRouteOpener: @escaping AgentSessionRouteOpener = { _ in
            .failed(.applicationUnavailable)
        },
        runtimeHandoffIfNeeded: @escaping RuntimeHandoffCheck = { false },
        controlCenterWindowProvider: @escaping
            ControlCenterPresentationCoordinator.WindowProvider = { [] },
        controlCenterApplicationActivator: @escaping
            ControlCenterPresentationCoordinator.ApplicationActivator = {},
        applicationAppearanceApplier: @escaping ApplicationAppearanceApplier = { theme in
            APCApplicationAppearance.apply(theme)
        },
        applicationLanguageApplier: @escaping ApplicationLanguageApplier = { language in
            APCLocalization.applyInterfaceLanguage(language)
        },
        overlayPresenter: @escaping OverlayPresenter = { controller, store in
            controller.show(store: store)
        },
        overlayKeyboardFocusHandler: OverlayKeyboardFocusHandler? = nil,
        petCoreRequestOverride: PetCoreRequestOverride? = nil,
        initialPetStudioCodexAvailability: PetStudioCodexAvailability = .checking,
        appUpdater: AppUpdateController? = nil,
        productConvergenceSleeper: @escaping ProductConvergenceSleeper = { duration in
            try await Task.sleep(for: duration)
        },
        productConvergenceNoticePreferences: ProductConvergenceNoticePreferences =
            ProductConvergenceNoticePreferences(),
        productConvergenceManifest: RuntimeReleaseManifest? =
            PetCoreRuntimeContract.requiredManifest,
        productConvergenceUpgradeEvidence: @escaping ProductConvergenceUpgradeEvidence = {
            manifest in
            PetCoreRuntimeUpgradeEvidence.hasPriorManagedBuild(
                currentBuildID: manifest.buildID
            )
        }
    ) {
        self.client = client
        overlayController = PetOverlayController()
        self.bootstrapHooks = bootstrapHooks
        self.diagnostics = diagnostics
        bundledPetSeederOverride = bundledPetSeeder
        self.bundledPetSeedSleeper = bundledPetSeedSleeper
        self.initialAppearanceFallbackSleeper = initialAppearanceFallbackSleeper
        self.overlayPlacementRetrySleeper = overlayPlacementRetrySleeper
        self.overlayPlacementJournalStore = overlayPlacementJournalStore
        self.agentSessionRouteOpener = agentSessionRouteOpener
        self.runtimeHandoffIfNeeded = runtimeHandoffIfNeeded
        self.controlCenterWindowProvider = controlCenterWindowProvider
        self.controlCenterApplicationActivator = controlCenterApplicationActivator
        self.applicationAppearanceApplier = applicationAppearanceApplier
        self.applicationLanguageApplier = applicationLanguageApplier
        self.overlayPresenter = overlayPresenter
        self.overlayKeyboardFocusHandler = overlayKeyboardFocusHandler
            ?? Self.defaultOverlayKeyboardFocusHandler
        self.petCoreRequestOverride = petCoreRequestOverride
        petStudioCodexAvailability = initialPetStudioCodexAvailability
        self.appUpdater = appUpdater ?? AppUpdateController(
            automaticChecksEnabled: false,
            diagnostics: diagnostics
        )
        self.productConvergenceSleeper = productConvergenceSleeper
        self.productConvergenceNoticePreferences = productConvergenceNoticePreferences
        self.productConvergenceManifest = productConvergenceManifest
        self.productConvergenceUpgradeEvidence = productConvergenceUpgradeEvidence
        configureConnectionsModel()
    }

    private func configureConnectionsModel() {
        connectionsModel.configure(
            request: { [weak self] method, params, timeout in
                guard let self else {
                    throw AgentConnectionOperationExecutionError(.transportUnavailable)
                }
                return try await self.requestPetCore(
                    method: method,
                    params: params,
                    timeout: timeout
                )
            },
            operationIsAvailable: { [weak self] in
                guard let self else { return false }
                return self.productConvergenceTask == nil
            },
            statusSink: { [weak self] status in
                self?.statusText = status
            },
            failureSink: { [weak self] operation, reason in
                self?.finishStartupConnectionCheckIfNeeded(
                    operation: operation,
                    result: .failure(reason)
                )
                self?.diagnostics.log(
                    .error,
                    category: "connections",
                    event: "connection_operation_failed",
                    metadata: [
                        "operation": .string(operation.kind.rawValue),
                        "reason": .string(reason.rawValue),
                        "source_count": .integer(Int64(operation.sources.count)),
                    ]
                )
            },
            checkedSink: { [weak self] sources in
                self?.finishStartupConnectionCheckIfNeeded(
                    checkedSources: sources
                )
                self?.reconcileProductConvergenceConnectorAttention(
                    afterChecking: sources
                )
            },
            refreshAfterMutationFailure: { [weak self] in
                _ = await self?.refresh()
            }
        )
        connectionsModelObservation = connectionsModel.objectWillChange.sink {
            [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var connections: [AgentConnectionStatus] {
        get { connectionsModel.connections }
        set { connectionsModel.replaceConnections(newValue) }
    }

    var connectionOperationState: AgentConnectionOperationState {
        connectionsModel.operationState
    }

    var activePet: PetSummary? {
        pets.first(where: \.active)
    }

    func petSummary(id: String?) -> PetSummary? {
        guard let id, !id.isEmpty else { return nil }
        return pets.first { $0.id == id }
    }

    var interfaceLocaleIdentifier: String {
        APCLocalization.resolvedInterfaceLocaleIdentifier(
            interfaceLanguage: behavior.interfaceLanguage
        )
    }

    private var hasProtectedUserWork: Bool {
        let diagnosticsBusy = switch diagnosticsExportState {
        case .exporting, .saving:
            true
        case .idle, .ready, .succeeded, .failed, .saveFailed:
            false
        }
        return generationSession.isActive
            || connectionOperationState.isRunning
            || isImportingPetpack
            || !petOperationIDs.isEmpty
            || diagnosticsBusy
            || inFlightProtectedMutationCount > 0
            || pendingBehaviorMutationCount > 0
            || overlayPlacementSaveTask != nil
            || overlayPlacementAuthority.pending != nil
            || overlayPlacementPreviewDriver.hasPending
            || overlayDisplayWidthCommitTask != nil
            || overlayPetDragInProgress
            || runtimeBootstrapSlot.isRunning
            || serviceRecoverySlot.isRunning
    }

    private var isSafeForProductConvergence: Bool {
        !hasProtectedUserWork
    }

    var isSafeForAppUpdateHandoff: Bool {
        isSafeForProductConvergence && productConvergenceTask == nil
    }

    var shouldBlockForAppUpdateConvergence: Bool {
        guard !hasLoadedStateSnapshot else { return false }
        return switch appUpdateConvergenceState {
        case .waitingForActiveWork, .updating:
            true
        case .idle, .completed, .needsAttention:
            false
        }
    }

    var onboardingCompanionCandidates: [PetSummary] {
        let candidates = Dictionary(
            pets
                .filter(\.isIncludedCompanionCandidate)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return PetSummary.includedCompanionIDs.compactMap {
            candidates[$0]
        }
    }

    var shouldPresentOnboarding: Bool {
        guard !onboardingDismissedForCurrentLaunch,
              let onboarding
        else {
            return false
        }
        return !onboarding.progress.stage.isTerminal
    }

    var onboardingAvailability: OnboardingFlowAvailability {
        petCoreOperationalState == .online ? .ready : .serviceUnavailable
    }

    /// Compatibility projection for older callers. The typed operation state
    /// remains the single source of truth for serialization and failure UI.
    var connectionOperationSources: Set<AgentSource> {
        connectionsModel.operationSources
    }

    var canStartConnectionOperation: Bool {
        connectionsModel.canStartOperation
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
            .filter {
                !overlayDismissedBubbleEventIDs.contains(OverlaySessionContent.stableID(
                    source: $0.source,
                    sessionID: $0.sessionID ?? $0.event.sessionID,
                    anonymousSessionAlias: $0.anonymousSessionAlias,
                    fallbackEventID: $0.event.id
                ))
            }
            .map(\.event)
    }

    /// Everything the bubble projection reads. Comparing this is far cheaper
    /// than rebuilding the projection, which localizes and normalizes text for
    /// every session.
    private struct OverlayBubbleProjectionInputs: Equatable {
        let statusBubbleVisible: Bool
        let sessions: [ActiveAgentState]
        let omittedCount: Int
        let dismissedSessionIDs: Set<String>
        let groupExpansionOverrides: [AgentSource: Bool]
        let groupSessionsByAgent: Bool
        let standaloneSessionOrder: [String]
        let standaloneStackExpanded: Bool
        let sessionGroupDisplay: SessionGroupDisplay
        let navigationNotices: [String: OverlaySessionNavigationNoticeRecord]
        let projectionIdentities: [String: OverlaySessionProjectionIdentity]
    }

    private var currentOverlayBubbleProjectionInputs: OverlayBubbleProjectionInputs {
        OverlayBubbleProjectionInputs(
            statusBubbleVisible: overlayVisibility.statusBubbleVisible,
            sessions: activeAgentSessions,
            omittedCount: activeAgentSessionsOmittedCount,
            dismissedSessionIDs: overlayDismissedBubbleEventIDs,
            groupExpansionOverrides: overlayAgentGroupExpansionOverrides,
            groupSessionsByAgent: behavior.groupSessionsByAgent,
            standaloneSessionOrder: overlayStandaloneSessionOrder,
            standaloneStackExpanded: overlayStandaloneStackIsExpanded,
            sessionGroupDisplay: behavior.sessionGroupDisplay,
            navigationNotices: overlaySessionNavigationNotices,
            projectionIdentities: overlaySessionProjectionIdentities
        )
    }

    /// Memoizes the projection so the several reads that happen inside a single
    /// SwiftUI pass — bubble contents, availability, session count, keyboard
    /// focus — share one build instead of repeating it. Purely derived state,
    /// so nothing is published when the cache is refreshed.
    var overlayAvailableBubbleContents: [OverlayBubbleContent] {
        let inputs = currentOverlayBubbleProjectionInputs
        if let cached = overlayBubbleProjectionCache, cached.inputs == inputs {
            return cached.contents
        }
        let contents = buildOverlayAvailableBubbleContents(inputs)
        overlayBubbleProjectionCache = (inputs, contents)
        return contents
    }

    private func buildOverlayAvailableBubbleContents(
        _ inputs: OverlayBubbleProjectionInputs
    ) -> [OverlayBubbleContent] {
        guard inputs.statusBubbleVisible else { return [] }
        var contents = OverlayBubbleProjection.contents(
            states: inputs.sessions,
            omittedCount: inputs.omittedCount,
            dismissedSessionIDs: inputs.dismissedSessionIDs,
            groupSessionsByAgent: inputs.groupSessionsByAgent,
            standaloneSessionOrder: inputs.standaloneSessionOrder,
            standaloneStackExpanded: inputs.standaloneStackExpanded,
            isExpanded: { source in
                inputs.groupExpansionOverrides[source]
                    ?? (inputs.sessionGroupDisplay == .expanded)
            }
        )
        for contentIndex in contents.indices {
            for sessionIndex in contents[contentIndex].sessions.indices {
                let session = contents[contentIndex].sessions[sessionIndex]
                guard let record = inputs.navigationNotices[session.id],
                      record.identity == inputs.projectionIdentities[session.id]
                else { continue }
                contents[contentIndex].sessions[sessionIndex].navigationNotice = record.notice
            }
        }
        return contents
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

    var overlayStandaloneStackIsExpanded: Bool {
        overlayStandaloneStackExpansionOverride
            ?? (behavior.sessionGroupDisplay == .expanded)
    }

    var canStartGeneration: Bool {
        canStartNewGenerationWork
            && petStudioCodexAvailability.permitsGeneration
            && !generationSession.isActive
            && GenerationPromptPolicy.isValid(descriptionText)
    }

    var generationStartBlockingDetail: String? {
        guard !canStartGeneration else { return nil }
        guard canStartNewGenerationWork else {
            return APCLocalization.text(.appUpdateConvergenceMakerBlocked)
        }
        if generationSession.isActive {
            return generationStateTitle
        }
        switch petStudioCodexAvailability {
        case .checking:
            return APCLocalization.text(.studioCodexCheckingDetail)
        case .missing:
            return APCLocalization.text(.studioCodexMissingDetail)
        case .unavailable:
            return APCLocalization.text(.studioCodexUnavailableDetail)
        case .available:
            return GenerationPromptPolicy.isValid(descriptionText)
                ? nil
                : APCLocalization.text(.studioDescriptionRequired)
        }
    }

    var generationStartPresentationDetail: String {
        generationStartBlockingDetail
            ?? APCLocalization.text(.studioWelcomeDetail)
    }

    var canStartNewGenerationWork: Bool {
        guard productConvergenceTask == nil else { return false }
        return switch appUpdateConvergenceState {
        case .idle, .completed:
            true
        case let .needsAttention(.connectors(issues)):
            !issues.contains { $0.source == .codex }
        case .needsAttention(.bundledPets), .needsAttention(.service):
            false
        case .waitingForActiveWork, .updating:
            false
        }
    }

    /// Continuing the one preserved Studio job is different from starting new
    /// protected work. An update waiting for that job to finish must not make
    /// the job impossible to resume; the convergence task will keep waiting
    /// for the resumed generation to reach a terminal state.
    private var canResumeExistingGenerationWork: Bool {
        return switch appUpdateConvergenceState {
        case .idle, .completed, .waitingForActiveWork:
            true
        case let .needsAttention(.connectors(issues)):
            !issues.contains { $0.source == .codex }
        case .needsAttention(.bundledPets), .needsAttention(.service), .updating:
            false
        }
    }

    var canClearStudioForm: Bool {
        !generationSession.isActive
            && (
                descriptionText != AIPetMakerDefaults.descriptionText
                    || selectedStyle != AIPetMakerDefaults.style
                    || selectedQuality != AIPetMakerDefaults.quality
                    || !referenceImages.isEmpty
                    || referenceImageIssue != nil
                    || referenceReselectionCount != 0
                    || !generationReplyText.isEmpty
            )
    }

    var isWaitingForGenerationInput: Bool {
        generationSession.state == .waitingForInput
    }

    var canSendGenerationReply: Bool {
        generationSession.canSendReply
    }

    var canRetryGeneration: Bool {
        generationSession.canRetry
            && petStudioCodexAvailability.permitsGeneration
            && referenceReselectionCount == 0
            && (generationSession.operation == .modify
                || !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var canResumeGeneration: Bool {
        generationSession.canResume
            && canResumeExistingGenerationWork
            && petStudioCodexAvailability.permitsGeneration
            && referenceReselectionCount == 0
    }

    var canResumeSelectedGenerationHistory: Bool {
        guard let detail = generationHistoryDetail,
              detail.found,
              let jobID = detail.jobID,
              jobID == selectedGenerationHistoryJobID,
              detail.capabilities?.canResume == true
        else { return false }
        return canResumeExistingGenerationWork
            && petStudioCodexAvailability.permitsGeneration
    }

    var canCopySelectedGenerationHistoryBrief: Bool {
        guard !generationSession.isActive,
              let detail = selectedGenerationHistoryDetail,
              let description = detail.description,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              detail.quality?.isStudioSupported == true
        else { return false }
        return detail.style != nil
    }

    var canRetrySelectedGenerationHistory: Bool {
        guard canCopySelectedGenerationHistoryBrief,
              canStartNewGenerationWork,
              petStudioCodexAvailability.permitsGeneration,
              let status = selectedGenerationHistoryDetail?.status
        else { return false }
        return switch status {
        case .failed:
            selectedGenerationHistoryDetail?.recoverable != true
        case .completed, .canceled:
            false
        case .pending, .running, .waitingForUser:
            false
        }
    }

    var selectedGenerationHistoryResultPet: PetSummary? {
        petSummary(id: selectedGenerationHistoryDetail?.resultPetID)
    }

    var selectedGenerationHistoryResultPetIsActive: Bool {
        selectedGenerationHistoryResultPet?.active == true
    }

    var selectedGenerationHistoryDetail: GenerationStudioHistoryDetail? {
        guard let generationHistoryDetail,
              generationHistoryDetail.found,
              generationHistoryDetail.jobID == selectedGenerationHistoryJobID
        else { return nil }
        return generationHistoryDetail
    }

    var generationStateTitle: String {
        if generationSession.operation == .modify {
            return switch generationSession.state {
            case .idle: "尚未开始"
            case .starting: "正在启动修改"
            case .running: "正在修改"
            case .waitingForInput: "修改等待补充信息"
            case .paused: "修改已中断，等待继续"
            case .recoverableFailed: "修改失败，可继续"
            case .cancelling: "正在取消修改"
            case .cancelCleanup: "正在清理修改会话"
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
        case .paused: "已中断，等待继续"
        case .recoverableFailed: "生成失败，可继续"
        case .cancelling: "正在取消"
        case .cancelCleanup: "正在清理会话"
        case .succeeded: "生成完成"
        case .failed: "生成失败"
        case .cancelled: "已取消"
        }
    }

    func setMainWindowPresenter(_ presenter: @escaping () -> Void) {
        controlCenterPresentationCoordinator.installPresenter(presenter)
    }

    func registerControlCenterWindow(_ window: NSWindow) {
        controlCenterPresentationCoordinator.register(window)
    }

    func presentManualAppInstallation(_ request: AppManualInstallationRequest) {
        manualAppInstallationRequest = request
        appUpdater.dismissSheet()
        presentMainWindow(checkRuntimeHandoff: false)
    }

    func dismissManualAppInstallation() {
        manualAppInstallationRequest = nil
    }

    func presentDeferredAppUpdateHandoff() {
        appUpdateConvergenceState = .waitingForActiveWork
        presentMainWindow(checkRuntimeHandoff: false)
    }

    func presentFailedAppUpdateHandoff(_ request: AppManualInstallationRequest) {
        if appUpdateConvergenceState == .waitingForActiveWork {
            appUpdateConvergenceState = .idle
        }
        presentManualAppInstallation(request)
    }

    func dismissAppUpdateConvergenceNotice() {
        if let buildID = productConvergenceManifest?.buildID {
            productConvergenceNoticePreferences.acknowledge(buildID: buildID)
        }
        appUpdateConvergenceState = .idle
    }

    func retryProductConvergence() {
        guard productConvergenceTask == nil,
              let manifest = productConvergenceManifest
        else { return }
        appUpdateConvergenceState = .updating
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let bundledPetsReady = await self.performBundledPetSeed()
            if bundledPetsReady {
                _ = await self.refresh()
            }
            await self.performProductConvergence(
                manifest: manifest,
                force: true,
                bundledPetsReady: bundledPetsReady
            )
            self.productConvergenceTask = nil
        }
        productConvergenceTask = task
    }

    func beginManualAppUpdateDownload(_ release: AppReleaseUpdate) {
        guard NSWorkspace.shared.open(release.asset.downloadURL) else {
            diagnostics.log(
                .error,
                category: "update",
                event: "release_download_open_failed",
                metadata: ["version": .string(release.version.description)]
            )
            appUpdater.reportDownloadOpenFailure()
            return
        }
        let installationRequest = AppManualInstallationRequest(
            origin: .updateDownload,
            version: release.version.description,
            candidateBundlePath: nil
        )
        manualAppInstallationRequest = installationRequest
        appUpdater.dismissSheet()
    }

    func checkForAppUpdatesManually() {
        appUpdater.checkManually()
        presentMainWindow()
    }

    func presentAvailableAppUpdate() {
        appUpdater.presentAvailableUpdate()
        presentMainWindow()
    }

    func presentMainWindow() {
        presentMainWindow(checkRuntimeHandoff: true)
    }

    private func presentMainWindow(checkRuntimeHandoff: Bool) {
        controlCenterPresentationCoordinator.requestPresentation(
            checkRuntimeHandoff: checkRuntimeHandoff
        )
        diagnostics.log(
            .debug,
            category: "lifecycle",
            event: "control_center_presentation_requested",
            metadata: [
                "phase": .string(
                    controlCenterPresentationCoordinator.phase.diagnosticValue
                ),
                "runtime_handoff_checked": .bool(checkRuntimeHandoff),
            ]
        )
    }

    func presentAgentSession(
        source: AgentSource?,
        sessionID: String? = nil,
        navigation: AgentSessionNavigation = AgentSessionNavigation()
    ) async -> AgentSessionOpenOutcome {
        guard source != nil else {
            presentMainWindow()
            return .openedAgentHost
        }
        guard let route = AgentSessionRouter.route(
            source: source,
            sessionID: sessionID,
            navigation: navigation
        ) else {
            return .failed(.applicationUnavailable)
        }
        let outcome = await agentSessionRouteOpener(route)
        if !outcome.didOpen,
           let fallback = AgentSessionRouter.hostFallbackRoute(
               source: source,
               navigation: navigation
           ),
           fallback != route {
            return await agentSessionRouteOpener(fallback)
        }
        return outcome
    }

    func activateOverlaySession(_ session: OverlaySessionContent) {
        let capturedIdentity = overlaySessionProjectionIdentities[session.id]
            ?? OverlaySessionProjectionIdentity(
                eventID: session.eventID,
                acknowledgementID: session.acknowledgementID
            )
        let actionSession = currentOverlayActionSession(
            stableID: session.id,
            identity: capturedIdentity
        ) ?? session
        guard actionSession.canOpen else {
            setOverlaySessionNavigationNotice(
                .unavailable,
                sessionID: actionSession.id,
                identity: capturedIdentity
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await presentAgentSession(
                source: actionSession.source,
                sessionID: actionSession.sessionID,
                navigation: actionSession.navigation
            )
            guard overlaySessionProjectionIsCurrent(
                sessionID: actionSession.id,
                identity: capturedIdentity
            ) else {
                return
            }
            let reachedRequestedDestination: Bool
            switch outcome {
            case .openedExactSession:
                reachedRequestedDestination = true
            case .openedAgentHost:
                reachedRequestedDestination = actionSession.navigationCapability != .exactSession
                if !reachedRequestedDestination {
                    setOverlaySessionNavigationNotice(
                        .degradedToHost,
                        sessionID: actionSession.id,
                        identity: capturedIdentity
                    )
                }
            case .failed:
                reachedRequestedDestination = false
                setOverlaySessionNavigationNotice(
                    .failed,
                    sessionID: actionSession.id,
                    identity: capturedIdentity
                )
            }
            guard reachedRequestedDestination else {
                return
            }
            clearOverlaySessionNavigationNotice(
                sessionID: actionSession.id,
                identity: capturedIdentity
            )
            if actionSession.dismissesAfterActivation {
                guard await acknowledgeOverlaySession(
                    acknowledgementID: capturedIdentity.acknowledgementID
                ),
                      overlaySessionProjectionIsCurrent(
                          sessionID: actionSession.id,
                          identity: capturedIdentity
                      )
                else {
                    return
                }
                dismissOverlayBubble(eventID: actionSession.id)
            }
        }
    }

    private func currentOverlayActionSession(
        stableID: String,
        identity: OverlaySessionProjectionIdentity
    ) -> OverlaySessionContent? {
        activeAgentSessions.lazy
            .map(OverlaySessionContent.init(state:))
            .first { candidate in
                candidate.id == stableID
                    && candidate.eventID == identity.eventID
                    && candidate.acknowledgementID == identity.acknowledgementID
            }
    }

    private func overlaySessionProjectionIsCurrent(
        sessionID: String,
        identity: OverlaySessionProjectionIdentity
    ) -> Bool {
        overlaySessionProjectionIdentities[sessionID] == identity
    }

    private func setOverlaySessionNavigationNotice(
        _ notice: OverlaySessionNavigationNotice,
        sessionID: String,
        identity: OverlaySessionProjectionIdentity
    ) {
        overlaySessionNavigationNotices[sessionID] =
            OverlaySessionNavigationNoticeRecord(
                identity: identity,
                notice: notice
            )
        overlayController.updateLayout(animateBubble: true)
    }

    private func clearOverlaySessionNavigationNotice(
        sessionID: String,
        identity: OverlaySessionProjectionIdentity
    ) {
        guard overlaySessionNavigationNotices[sessionID]?.identity == identity
        else { return }
        guard overlaySessionNavigationNotices.removeValue(
            forKey: sessionID
        ) != nil else { return }
        overlayController.updateLayout(animateBubble: true)
    }

    private func reconcileOverlaySessionNavigationNotices() {
        guard !overlaySessionNavigationNotices.isEmpty else { return }
        overlaySessionNavigationNotices = overlaySessionNavigationNotices.filter {
            sessionID, record in
            overlaySessionProjectionIdentities[sessionID] == record.identity
        }
    }

    private func acknowledgeOverlaySession(
        acknowledgementID: String?
    ) async -> Bool {
        guard let acknowledgementID else {
            return true
        }
        do {
            let result = try await requestPetCore(
                method: "agent.session.acknowledge",
                params: ["acknowledgement_id": acknowledgementID]
            )
            guard let result = result as? [String: Any],
                  result["acknowledged"] as? Bool == true,
                  result["acknowledgement_id"] as? String == acknowledgementID
            else {
                throw PetCoreClientError.invalidResponse
            }
            return true
        } catch {
            return false
        }
    }

    private static func openAgentSessionRoute(
        _ route: AgentSessionOpenRoute
    ) async -> AgentSessionOpenOutcome {
        let workspace = NSWorkspace.shared
        switch route {
        case let .url(url):
            return workspace.open(url)
                ? .openedExactSession
                : .failed(.urlOpenRejected)
        case let .application(bundleIdentifiers, paths):
            return await openAgentApplication(
                bundleIdentifiers: bundleIdentifiers,
                paths: paths,
                workspace: workspace
            )
        }
    }

    private static func openAgentApplication(
        bundleIdentifiers: [String],
        paths: [String],
        workspace: NSWorkspace
    ) async -> AgentSessionOpenOutcome {
        if let running = workspace.runningApplications
            .filter({ application in
                application.bundleIdentifier.map(bundleIdentifiers.contains) == true
                    && !application.isTerminated
            })
            .sorted(by: { ($0.isActive ? 1 : 0) > ($1.isActive ? 1 : 0) })
            .first,
           running.activate(options: [])
        {
            return .openedAgentHost
        }
        let applicationURL = bundleIdentifiers.lazy
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            .first
            ?? paths
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        guard let applicationURL else {
            return .failed(.applicationUnavailable)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            workspace.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { @Sendable application, error in
                continuation.resume(returning:
                    application != nil && error == nil
                        ? .openedAgentHost
                        : .failed(.applicationLaunchFailed)
                )
            }
        }
    }

    static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        ControlCenterPresentationCoordinator.isCandidate(
            window,
            identifier: controlCenterWindowIdentifier
        )
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
        return await runtimeBootstrapSlot.run { [weak self] in
            await self?.performRuntimeBootstrap(startMode: startMode) ?? false
        }
    }

    private func performRuntimeBootstrap(
        startMode: RuntimeBootstrapStartMode
    ) async -> Bool {
        diagnostics.log(.info, category: "service", event: "petcore_bootstrap_started")
        if let manifest = productConvergenceManifest,
           manifest.releaseChannel == "release",
           productConvergenceUpgradeEvidence(manifest),
           !productConvergenceNoticePreferences.hasAcknowledged(
               buildID: manifest.buildID
           )
        {
            appUpdateConvergenceState = .updating
        }
        setServiceChecking()
        // Bound appearance hydration from bootstrap start. Runtime replacement
        // and rollback can take much longer, so the already-visible system
        // appearance must remain the explicit fallback while they run.
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
            if appUpdateConvergenceState == .waitingForActiveWork {
                appUpdateConvergenceState = .updating
            }
            setServiceOnline()
            runtimeBootstrapRetryTask?.cancel()
            runtimeBootstrapRetryTask = nil
            runtimeBootstrapRetryDelaySeconds = 2
            await prepareInitialAppearance()
            await bootstrapHooks.onReady(self)
            if bootstrapHooks.requiresAuthoritativeSnapshotOnReady,
               (!hasLoadedStateSnapshot || petCoreOperationalState != .online)
            {
                diagnostics.log(
                    .error,
                    category: "service",
                    event: "petcore_bootstrap_snapshot_not_ready",
                    throttleKey: "petcore_bootstrap_snapshot_not_ready",
                    minimumInterval: 30
                )
                runtimeBootstrapCompleted = false
                runtimeBootstrapRequiresFullRecovery = true
                setServiceFailure(
                    "本地服务尚未返回完整状态",
                    status: "PetCore 状态同步失败",
                    operationalState: .offline
                )
                resolveInitialAppearanceAsUnavailable()
                scheduleRuntimeBootstrapRetry()
                return false
            }
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
        case let .deferred(reason):
            diagnostics.log(
                .notice,
                category: "update",
                event: "runtime_update_deferred_for_active_work"
            )
            appUpdateConvergenceState = .waitingForActiveWork
            setServiceChecking()
            setServiceStatusText(reason)
            runtimeBootstrapRequiresFullRecovery = false
            runtimeBootstrapRetryDelaySeconds = 2
            resolveInitialAppearanceAsUnavailable()
            scheduleRuntimeBootstrapRetry()
            return false
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
            // The publication order is deliberate: every window appearance
            // observer sees behavior, revision, and AppKit appearance as one
            // fully prepared initial presentation state.
            authoritativeBehavior = versioned.behavior
            behavior = versioned.behavior
            behaviorRevision = versioned.revision
            applyCurrentPresentation()
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
        guard snapshotReady else {
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.waitForStateChange()
            }
        }
        scheduleProductConvergence(bundledPetsReady: bundledPetsReady)
        scheduleStartupConnectionCheck()
        appUpdater.checkAutomaticallyIfDue()
    }

    /// Runs one authoritative five-Agent runtime check for this App process.
    /// Product convergence retains priority because it may refresh the same
    /// managed host artifacts; the startup check begins as soon as that flow
    /// and any user-started connection operation release the shared gate.
    func scheduleStartupConnectionCheck() {
        guard startupConnectionCheckState == .idle else { return }
        startupConnectionCheckState = .waiting
        startupConnectionCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.productConvergenceTask == nil,
                   self.connectionsModel.canStartOperation
                {
                    self.startupConnectionCheckState = .checking
                    self.connectionsModel.checkAll()
                    self.startupConnectionCheckTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.startupConnectionCheckTask = nil
        }
    }

    @discardableResult
    func scheduleProductConvergence(
        force: Bool = false,
        bundledPetsReady: Bool = true
    ) -> Task<Void, Never>? {
        guard productConvergenceTask == nil,
              let manifest = productConvergenceManifest
        else { return productConvergenceTask }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performProductConvergence(
                manifest: manifest,
                force: force,
                bundledPetsReady: bundledPetsReady
            )
            self.productConvergenceTask = nil
        }
        productConvergenceTask = task
        return task
    }

    private func performProductConvergence(
        manifest: RuntimeReleaseManifest,
        force: Bool,
        bundledPetsReady: Bool
    ) async {
        guard bundledPetsReady else {
            finishProductConvergenceAttention(
                attention: .bundledPets,
                failure: "bundled_pet_verification_incomplete"
            )
            return
        }
        scheduleProductConvergenceVisibility()
        do {
            let priorReceipt = try await productConvergenceReceipt()
            if !force, priorReceipt?.exactlyMatches(manifest: manifest) == true {
                finishProductConvergenceSuccess(
                    manifest: manifest,
                    presentsCompletion: productConvergenceUpgradeEvidence(manifest)
                )
                return
            }
            let presentsCompletion = (
                priorReceipt.map { $0.buildID != manifest.buildID } ?? false
            ) || productConvergenceUpgradeEvidence(manifest)

            try await waitForProductConvergenceSafePoint()
            if appUpdateConvergenceState == .waitingForActiveWork {
                appUpdateConvergenceState = .updating
            }
            let refreshValue = try await requestPetCore(
                method: "connections.refresh_installed",
                timeout: .seconds(180)
            )
            let report: ProductConnectorRefreshReport = try decodeProductConvergenceValue(
                refreshValue
            )
            guard report.isExactlyConverged else {
                let issues = report.attentionIssues
                finishProductConvergenceAttention(
                    attention: issues.isEmpty ? .service : .connectors(issues),
                    failure: issues.isEmpty
                        ? "managed_connector_report_inconsistent"
                        : "managed_connector_verification_incomplete"
                )
                _ = await refreshSnapshotAfterProductConvergence()
                return
            }

            let reportValue = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(report)
            )
            let receiptValue = try await requestPetCore(
                method: "product.convergence.update",
                params: [
                    "schema_version": ProductConvergenceReceipt.schemaVersion,
                    "build_id": manifest.buildID,
                    "app_version": manifest.appVersion,
                    "connector_report": reportValue,
                ]
            )
            let receipt: ProductConvergenceReceipt = try decodeProductConvergenceValue(
                receiptValue
            )
            guard receipt.exactlyMatches(manifest: manifest, report: report) else {
                throw PetCoreClientError.invalidResponse
            }

            guard await refreshSnapshotAfterProductConvergence() else {
                finishProductConvergenceAttention(
                    attention: .service,
                    failure: "authoritative_snapshot_refresh_failed"
                )
                return
            }
            finishProductConvergenceSuccess(
                manifest: manifest,
                presentsCompletion: presentsCompletion
            )
        } catch is CancellationError {
            productConvergenceVisibilityTask?.cancel()
            productConvergenceVisibilityTask = nil
        } catch {
            finishProductConvergenceAttention(
                attention: .service,
                failure: "convergence_rpc_failed",
                error: error
            )
        }
    }

    private func productConvergenceReceipt() async throws -> ProductConvergenceReceipt? {
        let value = try await requestPetCore(method: "product.convergence.get")
        guard !(value is NSNull) else { return nil }
        return try decodeProductConvergenceValue(value)
    }

    private func waitForProductConvergenceSafePoint() async throws {
        while !Task.isCancelled {
            if !isSafeForProductConvergence {
                publishProductConvergenceWaiting()
                try await productConvergenceSleeper(.seconds(1))
                continue
            }
            let value = try await requestPetCore(method: "product.convergence.preflight")
            let preflight: ProductConvergencePreflight = try decodeProductConvergenceValue(value)
            guard !preflight.safe else { return }
            publishProductConvergenceWaiting()
            try await productConvergenceSleeper(.seconds(1))
        }
        throw CancellationError()
    }

    private func scheduleProductConvergenceVisibility() {
        productConvergenceVisibilityTask?.cancel()
        let sleeper = productConvergenceSleeper
        productConvergenceVisibilityTask = Task { @MainActor [weak self] in
            do {
                try await sleeper(.seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.productConvergenceTask != nil,
                  self.appUpdateConvergenceState != .waitingForActiveWork
            else { return }
            self.appUpdateConvergenceState = .updating
        }
    }

    private func publishProductConvergenceWaiting() {
        productConvergenceVisibilityTask?.cancel()
        productConvergenceVisibilityTask = nil
        appUpdateConvergenceState = .waitingForActiveWork
    }

    private func finishProductConvergenceSuccess(
        manifest: RuntimeReleaseManifest,
        presentsCompletion: Bool
    ) {
        productConvergenceVisibilityTask?.cancel()
        productConvergenceVisibilityTask = nil
        if presentsCompletion,
           manifest.releaseChannel == "release",
           !productConvergenceNoticePreferences.hasAcknowledged(
               buildID: manifest.buildID
           )
        {
            appUpdateConvergenceState = .completed(version: manifest.appVersion)
        } else {
            appUpdateConvergenceState = .idle
        }
        diagnostics.log(
            .notice,
            category: "update",
            event: "product_convergence_completed",
            metadata: [
                "build_id": .string(manifest.buildID),
                "version": .string(manifest.appVersion)
            ]
        )
    }

    private func finishProductConvergenceAttention(
        attention: AppUpdateConvergenceAttention,
        failure: String,
        error: Error? = nil
    ) {
        productConvergenceVisibilityTask?.cancel()
        productConvergenceVisibilityTask = nil
        appUpdateConvergenceState = .needsAttention(attention)
        var metadata: [String: AppDiagnosticMetadataValue] = [
            "failure": .string(failure),
            "sources": .string(attention.sources.map(\.rawValue).joined(separator: ","))
        ]
        if let error {
            metadata["error_type"] = .string(String(describing: type(of: error)))
        }
        diagnostics.log(
            .error,
            category: "update",
            event: "product_convergence_needs_attention",
            metadata: metadata,
            throttleKey: "product_convergence_needs_attention",
            minimumInterval: 30
        )
    }

    private func refreshSnapshotAfterProductConvergence() async -> Bool {
        do {
            try await bootstrapHooks.refreshSnapshot(self)
            return true
        } catch {
            diagnostics.logFailure(
                error,
                category: "update",
                event: "product_convergence_snapshot_refresh_failed",
                throttleKey: "product_convergence_snapshot_refresh_failed",
                minimumInterval: 30
            )
            return false
        }
    }

    private func decodeProductConvergenceValue<Value: Decodable>(
        _ value: Any
    ) throws -> Value {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw PetCoreClientError.invalidResponse
        }
        return try JSONDecoder().decode(
            Value.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }

    /// Converges the closed, content-pinned App inventory before the first
    /// state snapshot is presented. PetCore preserves ordinary same-ID pets
    /// and appends a revision only for an identity it previously marked as
    /// bundled when the release digest changes.
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
            let response = try BundledPetInventory.validatedSeedResponse(result)
            let installedCount = response.outcomes.lazy.filter {
                $0.status == .installed
            }.count
            let revisedCount = response.outcomes.lazy.filter {
                $0.status == .installedNewRevision
            }.count
            diagnostics.log(
                .info,
                category: "library",
                event: "bundled_pet_seed_completed",
                metadata: [
                    "inventory_count": .integer(Int64(BundledPetInventory.fileNames.count)),
                    "installed_count": .integer(Int64(installedCount)),
                    "revised_count": .integer(Int64(revisedCount))
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
                if snapshotReady {
                    scheduleProductConvergence(bundledPetsReady: true)
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
        if let bootstrapping = await runtimeBootstrapSlot.joinExisting() {
            runtimeBootstrapRetryTask?.cancel()
            runtimeBootstrapRetryTask = nil
            return bootstrapping
        }
        if runtimeBootstrapRequiresFullRecovery {
            runtimeBootstrapRetryTask?.cancel()
            runtimeBootstrapRetryTask = nil
            return await runRuntimeBootstrapIfNeeded(startMode: .recover)
        }
        if let recovered = await serviceRecoverySlot.joinExisting() {
            return recovered
        }

        return await serviceRecoverySlot.run { [weak self] in
            await self?.runServiceRecovery() ?? false
        }
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
        case let .deferred(reason):
            appUpdateConvergenceState = .waitingForActiveWork
            setServiceChecking()
            setServiceStatusText(reason)
            runtimeBootstrapCompleted = false
            runtimeBootstrapRequiresFullRecovery = true
            runtimeBootstrapRetryDelaySeconds = 2
            scheduleRuntimeBootstrapRetry()
            return false
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

    func waitForStateChange() async {
        // The daemon revision wakes this request immediately. Active work uses
        // a one-second hydration budget so an asynchronous host display read
        // becomes visible promptly; idle waits remain long to avoid decoding
        // and republishing unchanged full snapshots.
        let timeoutMs = Self.stateWaitTimeoutMilliseconds(
            generationIsActive: generationSession.isActive,
            hasActiveAgentState: activeAgentState != nil
        )
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
            if hasProtectedUserWork,
               (try? await requestPetCore(
                   method: "petcore.health",
                   timeout: .seconds(2)
               )) != nil
            {
                diagnostics.log(
                    .info,
                    category: "service",
                    event: "petcore_state_wait_deferred_during_protected_work",
                    metadata: [:]
                )
                setServiceOnline()
                return
            }
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
        let reconnected = petCoreOperationalState != .online
        lastServiceFailureCode = .none
        petCoreOperationalState = .online
        var nextRuntimeInfo = petCoreRuntimeInfo
        nextRuntimeInfo.markRunning()
        if petCoreRuntimeInfo != nextRuntimeInfo {
            petCoreRuntimeInfo = nextRuntimeInfo
        }
        setServiceStatusText("本地服务运行中")
        if reconnected {
            resumePendingOverlayPlacementSaveIfNeeded(reason: .reconnect)
        }
    }

    // The service-status family below stays intentionally zh-pinned: the
    // mirror predicate classifies daemon-produced Chinese failure reasons by
    // prefix, so localizing only the App-side copy would make mirroring
    // locale-dependent. Type the daemon reasons before localizing this family.
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
        let isBootstrapSnapshot = !hasLoadedStateSnapshot
        let previousOverlayBubbleLayout = OverlayBubbleLayoutSignature(
            contents: overlayBubbleContents,
            bubbleDismissed: overlayBubbleDismissed
        )
        let data = try JSONSerialization.data(withJSONObject: result)
        let snapshot = try JSONDecoder().decode(StateSnapshot.self, from: data)
        guard let overlayPlacementRevision = OverlayPlacementRevisionCodec.parse(
            snapshot.overlayPlacementRevision
        ) else {
            throw PetCoreClientError.invalidResponse
        }
        authoritativeBehavior = snapshot.behavior
        if let snapshotOnboarding = snapshot.onboarding,
           onboarding != snapshotOnboarding {
            onboarding = snapshotOnboarding
        }
        if let activeGeneration = snapshot.activeGeneration {
            reconcileActiveGeneration(activeGeneration)
        }
        let previousSessionGroupDisplay = behavior.sessionGroupDisplay
        let previousGroupSessionsByAgent = behavior.groupSessionsByAgent
        let previousBubbleFontScale = behavior.bubbleFontScale
        let previousAppearanceTheme = behavior.appearanceTheme
        let previousInterfaceLanguage = behavior.interfaceLanguage
        let behaviorChanged = behavior != snapshot.behavior
        if behaviorChanged {
            behavior = snapshot.behavior
            if behavior.sessionGroupDisplay != previousSessionGroupDisplay
                || behavior.groupSessionsByAgent != previousGroupSessionsByAgent
            {
                overlayAgentGroupExpansionOverrides.removeAll()
                overlayStandaloneStackExpansionOverride = nil
                overlayStandaloneStackDisclosureDirection = .expanding
            }
        }
        behaviorRevision = snapshot.behaviorRevision ?? behaviorRevision
        if behavior.appearanceTheme != previousAppearanceTheme
            || initialAppearanceReadiness != .authoritative
        {
            applyCurrentAppearance()
        }
        if behavior.interfaceLanguage != previousInterfaceLanguage
            || initialAppearanceReadiness != .authoritative
        {
            applyCurrentLanguage()
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
        overlaySessionProjectionIdentities = Dictionary(
            nextActiveAgentSessions.map { state in
                (
                    OverlaySessionContent.stableID(
                        source: state.source,
                        sessionID: state.sessionID ?? state.event.sessionID,
                        anonymousSessionAlias: state.anonymousSessionAlias,
                        fallbackEventID: state.event.id
                    ),
                    OverlaySessionProjectionIdentity(
                        eventID: state.event.id,
                        acknowledgementID: state.acknowledgementID
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let nextActiveAgentSessionsOmittedCount = max(
            0,
            snapshot.activeAgentSessionsOmittedCount ?? 0
        )
        let activeSessionsChanged = !activeStatesHaveSamePresentation(
            activeAgentSessions,
            nextActiveAgentSessions
        )
        reconcileOverlayStandaloneSessionOrder(with: nextActiveAgentSessions)
        if activeSessionsChanged {
            activeAgentSessions = nextActiveAgentSessions
        }
        reconcileOverlaySessionNavigationNotices()
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
        let nextReopenIDBySession = Dictionary(
            nextActiveAgentSessions.map { state in
                (
                    OverlaySessionContent.stableID(
                        source: state.source,
                        sessionID: state.sessionID ?? state.event.sessionID,
                        anonymousSessionAlias: state.anonymousSessionAlias,
                        fallbackEventID: state.event.id
                    ),
                    OverlaySessionContent.reopenID(for: state)
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let newlyActivatedDismissalIDs = OverlayPresentedAgentState.newlyActivatedDismissalIDs(
            activeSessions: nextActiveAgentSessions,
            lastReopenIDBySession: overlayLastReopenIDBySession
        )
        let hasNewOverlayActivation = !newlyActivatedDismissalIDs.isEmpty
        if snapshot.behavior.enabled {
            var nextDismissedBubbleEventIDs = overlayDismissedBubbleEventIDs
            nextDismissedBubbleEventIDs.subtract(newlyActivatedDismissalIDs)
            if overlayDismissedBubbleEventIDs != nextDismissedBubbleEventIDs {
                overlayDismissedBubbleEventIDs = nextDismissedBubbleEventIDs
            }
        }
        // A projected-session gap is not evidence of new work. Preserve each
        // session's last activation identity until that same session returns
        // with a genuinely different one.
        overlayLastReopenIDBySession.merge(nextReopenIDBySession) {
            _, latest in latest
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
        applyOverlayPlacement(
            snapshotPlacement,
            remoteRevision: overlayPlacementRevision,
            remoteIntent: snapshot.overlayPlacementIntent
        )
        syncOverlayVisibilityForBehavior()
        let overlayBubbleLayoutChanged = previousOverlayBubbleLayout
            != OverlayBubbleLayoutSignature(
                contents: overlayBubbleContents,
                bubbleDismissed: overlayBubbleDismissed
            )
        if overlayBubbleLayoutChanged
            || overlayVisibilityChanged
            || behavior.groupSessionsByAgent != previousGroupSessionsByAgent
            || behavior.sessionGroupDisplay != previousSessionGroupDisplay
            || behavior.bubbleFontScale != previousBubbleFontScale
        {
            overlayController.updateLayout()
        }
        if initialAppearanceReadiness != .authoritative {
            resolveInitialAppearanceAsAuthoritative()
        }
        if !hasLoadedStateSnapshot {
            hasLoadedStateSnapshot = true
        }
        resumePendingOverlayPlacementSaveIfNeeded(
            reason: isBootstrapSnapshot ? .bootstrap : .ordinarySnapshot
        )
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
            && selectedStyle == AIPetMakerDefaults.style
            && selectedQuality == AIPetMakerDefaults.quality
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
        guard !generationSession.isActive, quality.isStudioSupported else { return }
        recordMakerUserMutation()
        selectedQuality = quality
    }

    func refreshPetStudioCodexAvailability() async {
        if generationSession.isActive {
            petStudioCodexAvailability = .available
            return
        }
        guard petStudioCodexAvailability != .available else { return }
        petStudioCodexAvailability = .checking
        do {
            let result = try await requestPetCore(method: "codex.app_server.probe")
            guard let payload = result as? [String: Any] else {
                petStudioCodexAvailability = .unavailable
                return
            }
            if payload["initialized"] as? Bool == true {
                petStudioCodexAvailability = .available
                return
            }
            let errorInfo = payload["error_info"] as? [String: Any]
            let kind = errorInfo?["kind"] as? String
            petStudioCodexAvailability = payload["mode"] as? String == "missing"
                || kind == "not_configured"
                ? .missing
                : .unavailable
        } catch {
            petStudioCodexAvailability = .unavailable
            diagnostics.logFailure(
                error,
                category: "generation",
                event: "pet_studio_codex_probe_failed",
                throttleKey: "pet_studio_codex_probe_failed",
                minimumInterval: 30
            )
        }
    }

    func startGeneration() {
        guard canStartNewGenerationWork else {
            statusText = APCLocalization.text(.appUpdateConvergenceMakerBlocked)
            return
        }
        guard canStartGeneration else {
            statusText = generationSession.isActive
                ? generationStateTitle
                : petStudioGenerationBlockedStatus
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
        guard canStartNewGenerationWork else {
            statusText = APCLocalization.text(.appUpdateConvergenceMakerBlocked)
            return
        }
        guard !pet.isBundled else {
            statusText = "App 内置宠物不可原地修改；请导出并使用新的宠物 ID 创建副本"
            return
        }
        guard pet.quality.isStudioSupported else {
            statusText = APCLocalization.text(.studioHighQualityUnsupported)
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
        guard petStudioCodexAvailability.permitsGeneration else {
            selection = .maker
            statusText = petStudioGenerationBlockedStatus
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
                await selectAcceptedGenerationHistoryJobAndWait(jobID)
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
        clearGenerationHistorySelection()
        makerDraftIsActive = true
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
        selectedStyle = AIPetMakerDefaults.style
        selectedQuality = AIPetMakerDefaults.quality
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
        descriptionText = AIPetMakerDefaults.descriptionText
        selectedStyle = AIPetMakerDefaults.style
        selectedQuality = AIPetMakerDefaults.quality
        referenceImages.removeAll()
        referenceReselectionCount = 0
        reselectedReferenceImagePaths.removeAll()
        referenceImageIssue = MakerReferenceImagePolicy.issue(for: referenceImages)
        generationReplyText = ""
        selection = .maker
        statusText = "可以开始制作新宠物"
    }

    func retryGeneration() {
        guard canStartNewGenerationWork else {
            statusText = APCLocalization.text(.appUpdateConvergenceMakerBlocked)
            return
        }
        guard petStudioCodexAvailability.permitsGeneration else {
            statusText = petStudioGenerationBlockedStatus
            return
        }
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

    func resumeGeneration() {
        guard canStartNewGenerationWork else {
            statusText = APCLocalization.text(.appUpdateConvergenceMakerBlocked)
            return
        }
        guard petStudioCodexAvailability.permitsGeneration else {
            statusText = petStudioGenerationBlockedStatus
            return
        }
        guard canResumeGeneration,
              let jobID = generationSession.jobID
        else {
            statusText = generationSession.isActive
                ? generationStateTitle
                : APCLocalization.text(.studioResumeUnavailable)
            return
        }
        let previousState = generationSession.state
        let instruction = generationReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = reduceGeneration(.resumeRequested)
        statusText = APCLocalization.text(.studioResumeStarting)

        Task {
            do {
                var parameters: [String: Any] = [
                    "job_id": jobID,
                    "request_id": UUID().uuidString,
                ]
                if !instruction.isEmpty {
                    parameters["instruction"] = instruction
                }
                let result = try await requestPetCore(
                    method: "generation.resume",
                    params: parameters
                )
                guard let object = result as? [String: Any],
                      let resumedJobID = object["job_id"] as? String,
                      resumedJobID == jobID
                else {
                    throw PetCoreClientError.invalidResponse
                }
                _ = reduceGeneration(.startAccepted(
                    jobID: resumedJobID,
                    baselineRevisionID: object["baseline_revision_id"] as? String
                ))
                generationReplyText = ""
                statusText = APCLocalization.text(.studioResumeAccepted)
            } catch {
                _ = reduceGeneration(.resumeFailed(restoring: previousState))
                statusText = APCLocalization.format(
                    .studioResumeFailedFormat,
                    error.localizedDescription
                )
            }
        }
    }

    private func beginGeneration(
        with form: GenerationForm,
        initialMessage: String,
        retryOfJobID: String? = nil,
        operation: GenerationOperation = .create,
        resultPetID: String? = nil,
        baselineRevisionID: String? = nil
    ) {
        guard canStartNewGenerationWork else {
            statusText = APCLocalization.text(.appUpdateConvergenceMakerBlocked)
            return
        }
        guard petStudioCodexAvailability.permitsGeneration else {
            statusText = petStudioGenerationBlockedStatus
            return
        }
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
                await selectAcceptedGenerationHistoryJobAndWait(jobID)
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

    private var petStudioGenerationBlockedStatus: String {
        generationStartBlockingDetail
            ?? APCLocalization.text(.studioDescriptionRequired)
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
                resultMetadata: snapshot.resultMetadata,
                heartbeatAt: snapshot.heartbeatAt
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
        resultMetadata: GenerationResultMetadata? = nil,
        heartbeatAt: String? = nil
    ) async {
        if let heartbeatAt {
            _ = reduceGeneration(.heartbeatReceived(heartbeatAt))
        }
        if let resultMetadata, !resultMetadata.isEmpty {
            _ = reduceGeneration(.resultMetadataReceived(resultMetadata))
        }
        let previousState = generationSession.state
        let effects = reduceGeneration(.messagesReceived(messages, revision: revision))
        if previousState != generationSession.state {
            notifyForGenerationTransition(
                from: previousState,
                to: generationSession.state,
                messages: messages
            )
        }
        if let jobID = generationSession.jobID,
           selectedGenerationHistoryJobID == jobID {
            generationHistoryMessages = messages.filter {
                $0.kind != "generation_heartbeat" && $0.kind != "jsonl_diagnostic"
            }
            if previousState != generationSession.state {
                await refreshGenerationHistory()
                await loadGenerationHistoryDetail(jobID: jobID)
            }
        }
        if effects.contains(.refreshSnapshot) {
            await refresh()
        }
    }

    private func notifyForGenerationTransition(
        from previousState: GenerationSessionState,
        to state: GenerationSessionState,
        messages: [GenerationMessage]
    ) {
        guard previousState != state,
              let jobID = generationSession.jobID,
              !(NSApp.isActive
                  && selection == .maker
                  && selectedGenerationHistoryJobID == jobID)
        else { return }
        let notification: (String, String)? = switch state {
        case .waitingForInput:
            (
                APCLocalization.text(.studioNotificationWaitingTitle),
                messages.last(where: { $0.kind == "input_request" })?.content
                    ?? APCLocalization.text(.studioNotificationWaitingBody)
            )
        case .paused:
            (
                APCLocalization.text(.studioNotificationPausedTitle),
                generationSession.pauseReason
                    ?? APCLocalization.text(.studioNotificationPausedBody)
            )
        case .recoverableFailed:
            (
                APCLocalization.text(.studioNotificationRecoverableTitle),
                generationSession.pauseReason
                    ?? APCLocalization.text(.studioNotificationRecoverableBody)
            )
        case .succeeded:
            (
                APCLocalization.text(.studioNotificationCompletedTitle),
                APCLocalization.text(.studioNotificationCompletedBody)
            )
        case .failed:
            (
                APCLocalization.text(.studioNotificationFailedTitle),
                APCLocalization.text(.studioNotificationFailedBody)
            )
        case .idle, .starting, .running, .cancelling, .cancelCleanup, .cancelled:
            nil
        }
        guard let notification else { return }
        MakerNotificationCoordinator.shared.notify(
            jobID: jobID,
            state: state,
            title: notification.0,
            body: notification.1
        )
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
                    params: [
                        "job_id": generationJobID,
                        "content": content,
                        "request_id": UUID().uuidString,
                    ]
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

    func refreshGenerationHistory(limit: Int = 24) async {
        generationHistoryListSequence &+= 1
        let sequence = generationHistoryListSequence
        generationHistoryIsLoading = true
        generationHistoryLoadFailed = false
        do {
            let result = try await requestPetCore(
                method: "generation.history.list",
                params: ["limit": min(max(limit, 1), 32)]
            )
            let data = try JSONSerialization.data(withJSONObject: result)
            let snapshot = try JSONDecoder().decode(
                GenerationStudioHistorySnapshot.self,
                from: data
            )
            guard sequence == generationHistoryListSequence else { return }
            generationHistorySnapshot = snapshot
            if let selectedGenerationHistoryJobID,
               !snapshot.jobs.contains(where: { $0.jobID == selectedGenerationHistoryJobID }) {
                if generationHistorySelectionIntentJobID != selectedGenerationHistoryJobID {
                    clearGenerationHistorySelection()
                }
            } else if let generationHistorySelectionIntentJobID,
                      snapshot.jobs.contains(where: {
                          $0.jobID == generationHistorySelectionIntentJobID
                      }) {
                self.generationHistorySelectionIntentJobID = nil
            }
        } catch {
            guard sequence == generationHistoryListSequence else { return }
            generationHistoryLoadFailed = true
            diagnostics.logFailure(
                error,
                category: "generation",
                event: "generation_history_list_failed",
                throttleKey: "generation_history_list_failed",
                minimumInterval: 10
            )
        }
        guard sequence == generationHistoryListSequence else { return }
        generationHistoryIsLoading = false
        generationHistoryHasLoaded = true
    }

    func selectGenerationHistoryJob(_ jobID: String) {
        guard generationHistorySnapshot.jobs.contains(where: { $0.jobID == jobID }) else {
            return
        }
        generationHistorySelectionIntentJobID = nil
        activateGenerationHistorySelection(jobID)
        Task { [weak self] in
            guard let self else { return }
            async let detail: Void = loadGenerationHistoryDetail(jobID: jobID)
            async let messages: Void = loadGenerationHistoryMessages(jobID: jobID)
            _ = await (detail, messages)
        }
    }

    func selectGenerationHistoryJobAndWait(_ jobID: String) async {
        guard generationHistorySnapshot.jobs.contains(where: { $0.jobID == jobID }) else {
            return
        }
        generationHistorySelectionIntentJobID = nil
        activateGenerationHistorySelection(jobID)
        async let detail: Void = loadGenerationHistoryDetail(jobID: jobID)
        async let messages: Void = loadGenerationHistoryMessages(jobID: jobID)
        _ = await (detail, messages)
    }

    /// Selects the exact job acknowledged by PetCore immediately, without
    /// waiting for the eventually consistent history list to expose it.
    private func selectAcceptedGenerationHistoryJobAndWait(_ jobID: String) async {
        generationHistorySelectionIntentJobID = jobID
        activateGenerationHistorySelection(jobID)
        async let history: Void = refreshGenerationHistory()
        async let detail: Void = loadGenerationHistoryDetail(jobID: jobID)
        async let messages: Void = loadGenerationHistoryMessages(jobID: jobID)
        _ = await (history, detail, messages)
    }

    private func activateGenerationHistorySelection(_ jobID: String) {
        if selectedGenerationHistoryJobID != jobID {
            generationReplyText = ""
        }
        generationHistoryDetailSequence &+= 1
        generationHistoryMessagesSequence &+= 1
        selectedGenerationHistoryJobID = jobID
        makerDraftIsActive = false
        generationHistoryDetail = nil
        generationHistoryMessages = []
        generationHistoryMessagesHasMore = false
        generationHistoryDetailIsLoading = false
        generationHistoryMessagesIsLoading = false
    }

    func clearGenerationHistorySelection() {
        generationHistoryDetailSequence &+= 1
        generationHistoryMessagesSequence &+= 1
        generationHistorySelectionIntentJobID = nil
        selectedGenerationHistoryJobID = nil
        generationHistoryDetail = nil
        generationHistoryMessages = []
        generationHistoryMessagesHasMore = false
        generationHistoryDetailIsLoading = false
        generationHistoryMessagesIsLoading = false
        generationReplyText = ""
    }

    func loadGenerationHistoryDetail(jobID: String) async {
        generationHistoryDetailSequence &+= 1
        let sequence = generationHistoryDetailSequence
        generationHistoryDetailIsLoading = true
        generationHistoryLoadFailed = false
        do {
            let result = try await requestPetCore(
                method: "generation.history.detail",
                params: ["job_id": jobID],
                timeout: .seconds(15)
            )
            let data = try JSONSerialization.data(withJSONObject: result)
            let detail = try JSONDecoder().decode(
                GenerationStudioHistoryDetail.self,
                from: data
            )
            guard sequence == generationHistoryDetailSequence,
                  selectedGenerationHistoryJobID == jobID
            else { return }
            generationHistoryDetail = detail.found ? detail : nil
            generationHistoryLoadFailed = !detail.found
        } catch {
            guard sequence == generationHistoryDetailSequence,
                  selectedGenerationHistoryJobID == jobID
            else { return }
            generationHistoryLoadFailed = true
            diagnostics.logFailure(
                error,
                category: "generation",
                event: "generation_history_detail_failed",
                throttleKey: "generation_history_detail_failed",
                minimumInterval: 10
            )
        }
        guard sequence == generationHistoryDetailSequence,
              selectedGenerationHistoryJobID == jobID
        else { return }
        generationHistoryDetailIsLoading = false
    }

    func loadGenerationHistoryMessages(
        jobID: String,
        beforeSequence: UInt64? = nil,
        limit: Int = 50
    ) async {
        generationHistoryMessagesSequence &+= 1
        let sequence = generationHistoryMessagesSequence
        generationHistoryMessagesIsLoading = true
        defer {
            if sequence == generationHistoryMessagesSequence {
                generationHistoryMessagesIsLoading = false
            }
        }
        var params: [String: Any] = [
            "job_id": jobID,
            "limit": min(max(limit, 1), 200),
        ]
        if let beforeSequence {
            params["before_sequence"] = beforeSequence
        }
        do {
            let result = try await requestPetCore(
                method: "generation.messages.list",
                params: params,
                timeout: .seconds(15)
            )
            let data = try JSONSerialization.data(withJSONObject: result)
            let page = try JSONDecoder().decode(GenerationMessagesPage.self, from: data)
            guard sequence == generationHistoryMessagesSequence,
                  selectedGenerationHistoryJobID == jobID,
                  page.jobID == jobID
            else { return }
            if beforeSequence == nil {
                generationHistoryMessages = page.messages
            } else {
                let currentIDs = Set(generationHistoryMessages.map(\.id))
                generationHistoryMessages = page.messages.filter { !currentIDs.contains($0.id) }
                    + generationHistoryMessages
            }
            generationHistoryMessagesHasMore = page.hasMore
        } catch {
            guard sequence == generationHistoryMessagesSequence,
                  selectedGenerationHistoryJobID == jobID
            else { return }
            diagnostics.logFailure(
                error,
                category: "generation",
                event: "generation_history_messages_failed",
                throttleKey: "generation_history_messages_failed",
                minimumInterval: 5
            )
        }
    }

    func loadOlderGenerationHistoryMessages() async {
        guard generationHistoryMessagesHasMore,
              !generationHistoryMessagesIsLoading,
              let jobID = selectedGenerationHistoryJobID,
              let before = generationHistoryMessages.first?.sequence
        else { return }
        await loadGenerationHistoryMessages(jobID: jobID, beforeSequence: before)
    }

    func prepareMakerWorkspace() async {
        await refreshGenerationHistory()
        if let selectedGenerationHistoryJobID,
           generationHistorySelectionIntentJobID == selectedGenerationHistoryJobID {
            async let detail: Void = loadGenerationHistoryDetail(
                jobID: selectedGenerationHistoryJobID
            )
            async let messages: Void = loadGenerationHistoryMessages(
                jobID: selectedGenerationHistoryJobID
            )
            _ = await (detail, messages)
            return
        }
        if let selectedGenerationHistoryJobID,
           generationHistorySnapshot.jobs.contains(where: {
               $0.jobID == selectedGenerationHistoryJobID
           }) {
            await selectGenerationHistoryJobAndWait(selectedGenerationHistoryJobID)
            return
        }
        if let unfinished = generationHistorySnapshot.jobs.first(where: {
            makerHistoryJobIsUnfinished($0)
        }) {
            await selectGenerationHistoryJobAndWait(unfinished.jobID)
            return
        }
        if makerDraftIsActive { return }
        if let mostRecent = generationHistorySnapshot.jobs.first {
            await selectGenerationHistoryJobAndWait(mostRecent.jobID)
            return
        }
        beginMakerDraft()
    }

    func refreshMakerAfterLifecycleEvent() async {
        // didBecomeActive is also delivered during the first launch, before a
        // clean-home PetCore has necessarily finished staging its runtime and
        // seeding bundled pets. Join that single bootstrap pipeline instead of
        // issuing an early snapshot request that briefly marks the service
        // offline and starts a duplicate recovery path.
        guard await runRuntimeBootstrapIfNeeded(startMode: .ensureRunning) else {
            return
        }
        _ = await refresh()
        await refreshGenerationHistory()
        guard let jobID = selectedGenerationHistoryJobID,
              generationHistorySnapshot.jobs.contains(where: { $0.jobID == jobID })
        else { return }
        async let detail: Void = loadGenerationHistoryDetail(jobID: jobID)
        async let messages: Void = loadGenerationHistoryMessages(jobID: jobID)
        _ = await (detail, messages)
    }

    func beginMakerDraft() {
        let unfinishedExists = generationHistorySnapshot.jobs.contains {
            makerHistoryJobIsUnfinished($0)
        }
        guard !unfinishedExists else {
            statusText = APCLocalization.text(.studioWorkspaceActiveTaskBlocksNew)
            return
        }
        clearGenerationHistorySelection()
        showNewPetDraft()
        makerDraftIsActive = true
    }

    func discardMakerDraft() {
        guard makerDraftIsActive else { return }
        clearStudioForm()
        _ = reduceGeneration(.reset)
        makerDraftIsActive = false
        clearGenerationHistorySelection()
        if let mostRecent = generationHistorySnapshot.jobs.first {
            selectGenerationHistoryJob(mostRecent.jobID)
        }
    }

    private func makerHistoryJobIsUnfinished(_ job: GenerationStudioHistoryRecord) -> Bool {
        if job.cancellationPending == true { return true }
        if let capabilities = job.capabilities {
            return capabilities.canCancel || capabilities.canReply || capabilities.canResume
        }
        return job.status == .pending
            || job.status == .running
            || job.status == .waitingForUser
            || (job.status == .failed && job.recoverable == true)
    }

    @discardableResult
    func copySelectedGenerationHistoryBriefToNewDraft() -> Bool {
        guard canCopySelectedGenerationHistoryBrief,
              let detail = selectedGenerationHistoryDetail,
              let form = generationHistoryDraft(from: detail)
        else {
            statusText = APCLocalization.text(.studioHistoryCopyBriefUnavailable)
            return false
        }

        recordMakerUserMutation()
        _ = reduceGeneration(.reset)
        applyGenerationHistoryDraft(
            form,
            referenceReselectionCount: detail.referenceCount
        )
        clearGenerationHistorySelection()
        makerDraftIsActive = true
        generationReplyText = ""
        selection = .maker
        statusText = detail.referenceCount > 0
            ? APCLocalization.format(
                .studioHistoryCopyBriefReferencesNoticeFormat,
                detail.referenceCount
            )
            : APCLocalization.text(.studioHistoryCopyBriefSuccess)
        return true
    }

    func retrySelectedGenerationHistory() {
        guard canRetrySelectedGenerationHistory,
              let detail = selectedGenerationHistoryDetail,
              let jobID = detail.jobID,
              let status = detail.status,
              let operation = detail.operation,
              let form = generationHistoryDraft(from: detail)
        else {
            statusText = APCLocalization.text(.studioHistoryRetryUnavailable)
            return
        }
        guard detail.referenceCount == 0 else {
            statusText = APCLocalization.format(
                .studioHistoryCopyBriefReferencesNoticeFormat,
                detail.referenceCount
            )
            return
        }

        recordMakerUserMutation()
        let state = restoredGenerationState(
            status: status,
            messages: detail.progressMessages
        )
        _ = reduceGeneration(.restore(GenerationSessionRestore(
            state: state,
            jobID: jobID,
            submittedForm: form,
            messages: detail.progressMessages,
            progress: detail.progressMessages.last?.progress ?? 1,
            messageRevision: "",
            operation: operation,
            resultPetID: detail.resultPetID,
            resultRevisionID: detail.revisionID,
            validationSummary: detail.validationSummary,
            referenceReselectionCount: detail.referenceCount
        )))
        applyGenerationHistoryDraft(
            form,
            referenceReselectionCount: detail.referenceCount
        )
        generationReplyText = ""
        selection = .maker
        let initialMessage = operation == .modify
            ? APCLocalization.text(.studioMessageRetryModify)
            : APCLocalization.format(
                .studioMessageRetryCreateFormat,
                APCLocalizedPresentation.styleTitle(selectedStyle)
            )
        beginGeneration(
            with: form,
            initialMessage: initialMessage,
            retryOfJobID: jobID,
            operation: operation,
            resultPetID: detail.resultPetID
        )
        statusText = APCLocalization.text(
            operation == .modify
                ? .studioHistoryRetryStartingModify
                : .studioHistoryRetryStartingCreate
        )
    }

    @discardableResult
    func deleteGenerationHistory(jobID: String) async -> Bool {
        guard !jobID.isEmpty,
              generationHistoryDeleteInFlightJobID == nil
        else { return false }

        generationHistoryDeleteInFlightJobID = jobID
        generationHistoryMutationError = nil
        defer { generationHistoryDeleteInFlightJobID = nil }

        let jobsBeforeDeletion = generationHistorySnapshot.jobs
        let deletedIndex = jobsBeforeDeletion.firstIndex { $0.jobID == jobID }
        let deletedSelection = selectedGenerationHistoryJobID == jobID
        let expectedResultPetID = jobsBeforeDeletion.first {
            $0.jobID == jobID
        }?.resultPetID

        do {
            let result = try await requestPetCore(
                method: "generation.history.delete",
                params: ["job_id": jobID],
                timeout: .seconds(15)
            )
            let data = try JSONSerialization.data(withJSONObject: result)
            let receipt = try JSONDecoder().decode(
                GenerationStudioHistoryDeleteReceipt.self,
                from: data
            )
            let deletedStatusIsTerminal = switch receipt.deletedStatus {
            case .completed, .failed, .canceled:
                true
            case .pending, .running, .waitingForUser:
                false
            }
            guard receipt.ok,
                  receipt.jobID == jobID,
                  deletedStatusIsTerminal,
                  receipt.deletedMessageCount >= 0,
                  receipt.retryChildrenRelinked >= 0,
                  !receipt.stateRevision.isEmpty,
                  expectedResultPetID.map({ $0 == receipt.retainedResultPetID }) ?? true
            else {
                throw NSError(
                    domain: "AgentPetCompanion.GenerationHistoryDelete",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: APCLocalization.text(
                            .studioHistoryDeleteInvalidResponse
                        ),
                    ]
                )
            }

            generationHistoryListSequence &+= 1
            generationHistoryDetailSequence &+= 1
            var localSnapshot = generationHistorySnapshot
            localSnapshot.jobs.removeAll { $0.jobID == jobID }
            generationHistorySnapshot = localSnapshot
            generationHistoryHasLoaded = true
            if deletedSelection {
                clearGenerationHistorySelection()
            }

            await refreshGenerationHistory()

            if deletedSelection, selectedGenerationHistoryJobID == nil {
                let remainingJobs = generationHistorySnapshot.jobs
                let preferredIndex = min(
                    deletedIndex ?? 0,
                    max(remainingJobs.count - 1, 0)
                )
                if remainingJobs.indices.contains(preferredIndex) {
                    let nextJobID = remainingJobs[preferredIndex].jobID
                    await selectGenerationHistoryJobAndWait(nextJobID)
                }
            }

            statusText = APCLocalization.text(
                generationHistoryLoadFailed
                    ? .studioHistoryDeleteRefreshWarning
                    : .studioHistoryDeleteSuccess
            )
            return true
        } catch {
            let message = error.localizedDescription
            generationHistoryMutationError = message
            statusText = APCLocalization.format(
                .studioHistoryDeleteFailedFormat,
                message
            )
            diagnostics.logFailure(
                error,
                category: "generation",
                event: "generation_history_delete_failed",
                throttleKey: "generation_history_delete_failed",
                minimumInterval: 5
            )
            return false
        }
    }

    @discardableResult
    func showSelectedGenerationHistoryResultPetInLibrary() async -> Bool {
        guard let pet = selectedGenerationHistoryResultPet else {
            statusText = APCLocalization.text(.studioHistoryResultPetMissing)
            return false
        }
        guard await activatePetAndWait(pet) else { return false }
        selection = .library
        return true
    }

    private func generationHistoryDraft(
        from detail: GenerationStudioHistoryDetail
    ) -> GenerationForm? {
        guard let description = detail.description,
              let style = detail.style,
              let quality = detail.quality,
              quality.isStudioSupported,
              GenerationPromptPolicy.isValid(description)
        else { return nil }
        return GenerationForm(
            description: GenerationPromptPolicy.truncate(description),
            style: style,
            quality: quality,
            referenceImages: []
        )
    }

    private func applyGenerationHistoryDraft(
        _ form: GenerationForm,
        referenceReselectionCount: Int
    ) {
        descriptionText = form.description
        selectedStyle = StylePreset(rawValue: form.style) ?? .unspecified
        selectedQuality = form.quality
        referenceImages = []
        self.referenceReselectionCount = min(
            MakerReferenceImagePolicy.maximumCount,
            max(0, referenceReselectionCount)
        )
        reselectedReferenceImagePaths.removeAll()
        referenceImageIssue = self.referenceReselectionCount > 0
            ? .reselectionRequired(self.referenceReselectionCount)
            : nil
    }

    func openGenerationHistorySession() {
        guard generationHistoryDetail?.capabilities?.canOpenSession == true,
              let session = generationHistoryDetail?.session,
              session.availability == .available,
              session.canOpen,
              let url = AgentSessionDeepLink.url(
                  source: .codex,
                  sessionID: session.routableSessionID
              )
        else {
            statusText = APCLocalization.text(.studioHistorySessionUnavailable)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await agentSessionRouteOpener(.url(url))
            statusText = outcome.didOpen
                ? APCLocalization.text(.studioHistorySessionOpened)
                : APCLocalization.text(.studioHistorySessionOpenFailed)
        }
    }

    func resumeSelectedGenerationHistory() {
        guard canResumeSelectedGenerationHistory,
              let jobID = generationHistoryDetail?.jobID
        else {
            statusText = generationSession.isActive
                ? generationStateTitle
                : APCLocalization.text(.studioResumeUnavailable)
            return
        }
        recordMakerUserMutation()
        let instruction = generationReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        statusText = APCLocalization.text(.studioResumeStarting)

        Task {
            do {
                var parameters: [String: Any] = [
                    "job_id": jobID,
                    "request_id": UUID().uuidString,
                ]
                if !instruction.isEmpty {
                    parameters["instruction"] = instruction
                }
                let result = try await requestPetCore(
                    method: "generation.resume",
                    params: parameters
                )
                guard let object = result as? [String: Any],
                      object["job_id"] as? String == jobID
                else {
                    throw PetCoreClientError.invalidResponse
                }

                // The resumed job is now the authoritative latest job. Read
                // its complete recovery projection so selecting an older
                // history row replaces the currently displayed terminal job
                // without inventing a form or dropping its message history.
                let latestResult = try await requestPetCore(method: "generation.latest")
                let data = try JSONSerialization.data(withJSONObject: latestResult)
                let snapshot = try JSONDecoder().decode(
                    LatestGenerationSessionSnapshot.self,
                    from: data
                )
                guard snapshot.jobID == jobID,
                      let restore = GenerationSessionRestore(snapshot: snapshot)
                else {
                    throw PetCoreClientError.invalidResponse
                }
                let sanitizedRestore = sanitizedGenerationRestore(restore)
                _ = reduceGeneration(.restore(sanitizedRestore))
                applyRestoredGenerationForm(
                    sanitizedRestore.submittedForm,
                    referenceReselectionCount: sanitizedRestore.referenceReselectionCount
                )
                generationReplyText = ""
                selection = .maker
                statusText = APCLocalization.text(.studioResumeAccepted)
                await refreshGenerationHistory()
                await loadGenerationHistoryDetail(jobID: jobID)
                await loadGenerationHistoryMessages(jobID: jobID)
            } catch {
                statusText = APCLocalization.format(
                    .studioResumeFailedFormat,
                    error.localizedDescription
                )
            }
        }
    }

    func sendSelectedGenerationHistoryReply() {
        let content = generationReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty,
              let detail = selectedGenerationHistoryDetail,
              detail.capabilities?.canReply == true,
              let jobID = detail.jobID
        else { return }
        generationReplyText = ""
        Task {
            do {
                _ = try await requestPetCore(
                    method: "generation.reply",
                    params: [
                        "job_id": jobID,
                        "content": content,
                        "request_id": UUID().uuidString,
                    ]
                )
                await refreshGenerationHistory()
                await loadGenerationHistoryDetail(jobID: jobID)
                await loadGenerationHistoryMessages(jobID: jobID)
                await refreshGenerationSessionAfterExternalAction(jobID: jobID)
            } catch {
                generationReplyText = content
                statusText = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelSelectedGenerationHistory() {
        guard let detail = selectedGenerationHistoryDetail,
              detail.capabilities?.canCancel == true,
              let jobID = detail.jobID
        else { return }
        statusText = "正在取消生成"
        Task {
            do {
                _ = try await requestPetCore(
                    method: "generation.cancel",
                    params: ["job_id": jobID],
                    timeout: .seconds(15)
                )
                await refreshGenerationHistory()
                await loadGenerationHistoryDetail(jobID: jobID)
                await loadGenerationHistoryMessages(jobID: jobID)
                await refreshGenerationSessionAfterExternalAction(jobID: jobID)
            } catch {
                statusText = "取消失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshGenerationSessionAfterExternalAction(jobID: String) async {
        do {
            let result = try await requestPetCore(method: "generation.latest")
            let data = try JSONSerialization.data(withJSONObject: result)
            let snapshot = try JSONDecoder().decode(
                LatestGenerationSessionSnapshot.self,
                from: data
            )
            guard snapshot.jobID == jobID,
                  let restore = GenerationSessionRestore(snapshot: snapshot)
            else { return }
            _ = reduceGeneration(.restore(sanitizedGenerationRestore(restore)))
        } catch {
            diagnostics.logFailure(
                error,
                category: "generation",
                event: "generation_selected_action_refresh_failed",
                throttleKey: "generation_selected_action_refresh_failed",
                minimumInterval: 5
            )
        }
    }

    func fetchPetHistory(
        for pet: PetSummary,
        limit: Int = 16
    ) async throws -> PetHistorySnapshot {
        let boundedLimit = min(max(limit, 1), 32)
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
        applyBehaviorProjection(next)
        behaviorMutationSequence &+= 1
        enqueueBehaviorPatch(
            patch,
            mutationSequence: behaviorMutationSequence
        )
    }

    func waitForBehaviorPersistence() async {
        _ = await behaviorMutationTask?.value
    }

    private func enqueueBehaviorPatch(
        _ patch: BehaviorSettingsPatch,
        mutationSequence: UInt64
    ) {
        let predecessor = behaviorMutationTask
        pendingBehaviorMutationCount += 1
        behaviorMutationTask = Task { [weak self] in
            _ = await predecessor?.value
            guard let self else { return }
            await persistBehaviorPatch(
                patch,
                mutationSequence: mutationSequence
            )
            pendingBehaviorMutationCount = max(
                0,
                pendingBehaviorMutationCount - 1
            )
        }
    }

    private func persistBehaviorPatch(
        _ patch: BehaviorSettingsPatch,
        mutationSequence: UInt64
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
                authoritativeBehavior = updated.behavior
                if mutationSequence == behaviorMutationSequence {
                    applyBehaviorProjection(updated.behavior)
                }
                statusText = "设置已保存"
                return
            } catch let error as PetCoreClientError
                where attempt == 0
                    && error.rpcMessage?.contains("behavior revision conflict") == true {
                do {
                    try await refreshSnapshot()
                } catch {
                    statusText = "设置冲突且刷新失败：\(error.localizedDescription)"
                    if mutationSequence == behaviorMutationSequence {
                        applyBehaviorProjection(authoritativeBehavior)
                    }
                    return
                }
            } catch {
                statusText = "设置保存失败：\(error.localizedDescription)"
                do {
                    try await refreshSnapshot()
                } catch {}
                if mutationSequence == behaviorMutationSequence {
                    applyBehaviorProjection(authoritativeBehavior)
                }
                return
            }
        }
    }

    private func applyBehaviorProjection(_ next: BehaviorSettings) {
        let appearanceChanged = behavior.appearanceTheme != next.appearanceTheme
        let languageChanged = behavior.interfaceLanguage != next.interfaceLanguage
        let groupSessionsByAgentChanged = behavior.groupSessionsByAgent != next.groupSessionsByAgent
        let sessionGroupDisplayChanged = behavior.sessionGroupDisplay != next.sessionGroupDisplay
        // A different text tier changes measured bubble heights, so the panel
        // has to be resized rather than left holding stale geometry.
        let bubbleFontScaleChanged = behavior.bubbleFontScale != next.bubbleFontScale
        behavior = next
        if appearanceChanged {
            applyCurrentAppearance()
        }
        if languageChanged {
            applyCurrentLanguage()
        }
        if groupSessionsByAgentChanged || sessionGroupDisplayChanged {
            overlayAgentGroupExpansionOverrides.removeAll()
            overlayStandaloneStackExpansionOverride = nil
            overlayStandaloneStackDisclosureDirection = .expanding
        }
        if groupSessionsByAgentChanged || sessionGroupDisplayChanged || bubbleFontScaleChanged {
            overlayController.updateLayout()
        }
        syncOverlayVisibilityForBehavior()
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

    private func applyCurrentLanguage() {
        applicationLanguageApplier(behavior.interfaceLanguage)
    }

    private func applyCurrentPresentation() {
        applyCurrentLanguage()
        applyCurrentAppearance()
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

    func setAttentionPreset(_ preset: AttentionPreset) {
        guard preset != .custom else { return }
        updateBehavior(behavior.applyingAttentionPreset(preset))
    }

    func activatePet(_ pet: PetSummary) {
        Task {
            _ = await activatePetAndWait(pet)
        }
    }

    /// Shared activation path for the Library, Maker result, and onboarding.
    /// Callers that must sequence another durable mutation can await the real
    /// PetCore activation result instead of inferring success from local state.
    @discardableResult
    func activatePetAndWait(_ pet: PetSummary) async -> Bool {
        if pets.first(where: { $0.id == pet.id })?.active == true || pet.active {
            return true
        }
        guard !petOperationIDs.contains(pet.id) else { return false }
        petOperationIDs.insert(pet.id)
        statusText = "正在启用 \(pet.name)"
        defer { petOperationIDs.remove(pet.id) }
        return await finishPetActivation(
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

    @discardableResult
    func finishPetActivation(
        _ pet: PetSummary,
        activate: @MainActor () async throws -> Void,
        refreshSnapshot: @MainActor () async throws -> Void,
        recoverSnapshot: @MainActor () async -> Void
    ) async -> Bool {
        do {
            try await activate()
        } catch {
            statusText = "启用失败：\(error.localizedDescription)"
            await recoverSnapshot()
            return false
        }

        // A successful pet.activate response means PetCore has committed the
        // exclusive active-pet transaction. Reflect that committed result
        // before requesting the broader snapshot so a transient refresh
        // failure cannot put the Enable button back and invite another click.
        applyCommittedPetActivation(pet.id)

        do {
            try await refreshSnapshot()
            statusText = "已启用 \(pet.name)"
        } catch {
            statusText = "已启用 \(pet.name)，但状态刷新失败：\(error.localizedDescription)"
            await recoverSnapshot()
        }
        return true
    }

    private func applyCommittedPetActivation(_ petID: String) {
        guard pets.contains(where: { $0.id == petID }) else { return }
        let nextPets = pets.map { pet in
            var nextPet = pet
            nextPet.active = pet.id == petID
            return nextPet
        }
        guard nextPets != pets else { return }
        pets = nextPets
    }

    func dismissOnboardingForCurrentLaunch() {
        onboardingDismissedForCurrentLaunch = true
        onboardingOperationFailure = nil
    }

    func retryOnboardingService() {
        onboardingOperationFailure = nil
        Task { [weak self] in
            _ = await self?.recoverServiceConnection()
        }
    }

    func restoreIncludedCompanions() {
        Task {
            _ = await restoreIncludedCompanionsAndWait()
        }
    }

    /// Re-runs the signed inventory ensure operation without replacing an
    /// existing same-ID pet, then requires an authoritative snapshot proving
    /// both stable companion identities are selectable.
    @discardableResult
    func restoreIncludedCompanionsAndWait() async -> Bool {
        guard includedCompanionRestoreState != .restoring,
              onboardingAvailability == .ready
        else {
            if onboardingAvailability != .ready {
                includedCompanionRestoreState = .failed
            }
            return false
        }

        includedCompanionRestoreState = .restoring
        let seeded = await performBundledPetSeed()
        guard seeded, await refresh() else {
            includedCompanionRestoreState = .failed
            return false
        }

        let restoredIDs = Set(onboardingCompanionCandidates.map(\.id))
        guard restoredIDs == Set(PetSummary.includedCompanionIDs) else {
            diagnostics.log(
                .error,
                category: "library",
                event: "included_companion_restore_incomplete",
                metadata: [
                    "restored_count": .integer(Int64(restoredIDs.count))
                ]
            )
            includedCompanionRestoreState = .failed
            return false
        }

        includedCompanionRestoreState = .restored
        statusText = "已恢复 App 随附桌宠"
        return true
    }

    @discardableResult
    func confirmOnboardingPet(_ candidate: PetSummary) async -> Bool {
        guard !onboardingMutationInFlight,
              onboardingAvailability == .ready,
              let current = onboarding,
              current.progress.stage == .choosePet,
              let pet = onboardingCompanionCandidates.first(where: {
                  $0.id == candidate.id
              }),
              petAssetWarningIndex[pet.id] == nil
        else {
            if onboardingAvailability != .ready {
                onboardingOperationFailure = .serviceUnavailable
            }
            return false
        }

        onboardingMutationInFlight = true
        onboardingOperationFailure = nil
        defer { onboardingMutationInFlight = false }

        guard await activatePetAndWait(pet) else {
            onboardingOperationFailure = .petActivation
            return false
        }
        return await persistOnboardingTransition(
            from: current,
            to: .connectAgents
        )
    }

    func petAssetRepairState(for petID: String) -> PetAssetRepairState {
        petAssetRepairStates[petID] ?? .idle
    }

    func repairPetAssets(_ pet: PetSummary) {
        Task {
            _ = await repairPetAssetsAndWait(pet)
        }
    }

    /// Forces package validation and atomic cover/frame re-extraction even
    /// when PetCore has cached an unchanged invalid fingerprint.
    @discardableResult
    func repairPetAssetsAndWait(_ candidate: PetSummary) async -> Bool {
        guard onboardingAvailability == .ready,
              petAssetRepairState(for: candidate.id) != .repairing,
              !petOperationIDs.contains(candidate.id),
              let pet = pets.first(where: { $0.id == candidate.id })
        else {
            petAssetRepairStates[candidate.id] = .failed
            return false
        }

        petAssetRepairStates[pet.id] = .repairing
        petOperationIDs.insert(pet.id)
        statusText = "正在重新校验并提取 \(pet.name) 的资源"
        defer {
            petOperationIDs.remove(pet.id)
        }

        do {
            let value = try await requestPetCore(
                method: "pet.assets.repair",
                params: ["id": pet.id],
                timeout: .seconds(120)
            )
            guard JSONSerialization.isValidJSONObject(value) else {
                throw PetCoreClientError.invalidResponse
            }
            let outcome = try JSONDecoder().decode(
                PetAssetRepairOutcome.self,
                from: JSONSerialization.data(withJSONObject: value)
            )
            guard outcome.pet.id == pet.id,
                  outcome.warning?.petId == nil
                    || outcome.warning?.petId == pet.id
            else {
                throw PetCoreClientError.invalidResponse
            }

            try await refreshSnapshot()
            let repaired = outcome.warning == nil
                && petAssetWarningIndex[pet.id] == nil
            petAssetRepairStates[pet.id] = repaired ? .repaired : .failed
            statusText = repaired
                ? "已恢复 \(pet.name) 的预览资源"
                : "\(pet.name) 的资源仍需处理"
            return repaired
        } catch {
            petAssetRepairStates[pet.id] = .failed
            statusText = "资源恢复失败：\(error.localizedDescription)"
            diagnostics.logFailure(
                error,
                category: "library",
                event: "pet_asset_repair_failed",
                metadata: ["pet_id": .string(pet.id)]
            )
            _ = await refresh()
            return false
        }
    }

    @discardableResult
    func advanceOnboarding(to nextStage: OnboardingStage) async -> Bool {
        guard !onboardingMutationInFlight,
              onboardingAvailability == .ready,
              let current = onboarding,
              current.progress.stage.canAdvance(to: nextStage)
        else {
            if onboardingAvailability != .ready {
                onboardingOperationFailure = .serviceUnavailable
            }
            return false
        }

        onboardingMutationInFlight = true
        onboardingOperationFailure = nil
        defer { onboardingMutationInFlight = false }
        return await persistOnboardingTransition(from: current, to: nextStage)
    }

    private func persistOnboardingTransition(
        from current: VersionedOnboardingProgress,
        to nextStage: OnboardingStage
    ) async -> Bool {
        let nextProgress = OnboardingProgress(stage: nextStage)
        do {
            let progressData = try JSONEncoder().encode(nextProgress)
            let progressObject = try JSONSerialization.jsonObject(with: progressData)
            let result = try await requestPetCore(
                method: "onboarding.update",
                params: [
                    "expected_revision": current.revision,
                    "progress": progressObject,
                ]
            )
            let resultData = try JSONSerialization.data(withJSONObject: result)
            let updated = try JSONDecoder().decode(
                VersionedOnboardingProgress.self,
                from: resultData
            )
            guard updated.progress == nextProgress,
                  let previousRevision = UInt64(current.revision),
                  let updatedRevision = UInt64(updated.revision),
                  updatedRevision > previousRevision
            else {
                onboardingOperationFailure = .requestRejected
                return false
            }

            if nextStage == .completed {
                // Completion atomically enables the pet in PetCore. Publish
                // the terminal scene only with the authoritative behavior
                // snapshot so the onboarding cannot disappear while the
                // desktop pet still looks disabled.
                do {
                    try await refreshSnapshot()
                    return onboarding?.progress.stage == .completed
                } catch {
                    onboardingOperationFailure = .serviceUnavailable
                    return false
                }
            }

            onboarding = updated
            return true
        } catch let error as PetCoreClientError
            where error.rpcMessage?.contains("onboarding revision conflict") == true {
            do {
                try await refreshSnapshot()
                if onboarding?.progress.stage == nextStage {
                    return true
                }
            } catch {
                onboardingOperationFailure = .serviceUnavailable
                return false
            }
            onboardingOperationFailure = .revisionConflict
            return false
        } catch {
            onboardingOperationFailure = onboardingAvailability == .ready
                ? .requestRejected
                : .serviceUnavailable
            return false
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
        petpackImportProgress = PetLibraryImportProgress(
            phase: .importing,
            totalCount: urls.count,
            completedCount: 0,
            importedCount: 0,
            currentFileName: urls.first?.lastPathComponent
        )
        statusText = urls.count == 1 ? "正在导入本 App .petpack" : "正在导入 \(urls.count) 个本 App .petpack"
        petpackImportTask = Task {
            defer {
                petpackImportProgress = nil
                isImportingPetpack = false
                petpackImportTask = nil
            }
            var importedCount = 0
            var failures: [PetLibraryImportFailure] = []

            for (fileIndex, url) in urls.enumerated() {
                petpackImportProgress = PetLibraryImportProgress(
                    phase: .importing,
                    totalCount: urls.count,
                    completedCount: fileIndex,
                    importedCount: importedCount,
                    currentFileName: url.lastPathComponent
                )
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
                    failures.append(.requestFailure(at: url, error: error))
                }
                petpackImportProgress = PetLibraryImportProgress(
                    phase: .importing,
                    totalCount: urls.count,
                    completedCount: fileIndex + 1,
                    importedCount: importedCount,
                    currentFileName: fileIndex + 1 < urls.count
                        ? urls[fileIndex + 1].lastPathComponent
                        : nil
                )
            }

            if importedCount > 0 {
                petpackImportProgress = PetLibraryImportProgress(
                    phase: .refreshingLibrary,
                    totalCount: urls.count,
                    completedCount: urls.count,
                    importedCount: importedCount,
                    currentFileName: nil
                )
                do {
                    try await refreshSnapshot()
                    selection = .library
                } catch {
                    await refresh()
                }
            }

            if failures.isEmpty {
                petLibraryNotice = .importSuccess(importedCount: importedCount)
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
        connectionsModel.repair(source)
    }

    func refreshPortableMakerSkillStatus() async {
        guard !portableMakerSkillOperation.isBusy else { return }
        portableMakerSkillOperation = .checking
        portableMakerSkillFailure = nil
        defer { portableMakerSkillOperation = .idle }
        do {
            portableMakerSkillStatus = try await requestPortableMakerSkill(
                method: "portable_skill.status"
            )
        } catch {
            portableMakerSkillFailure = .load
        }
    }

    func installPortableMakerSkill() async {
        guard !portableMakerSkillOperation.isBusy else { return }
        portableMakerSkillOperation = .installing
        portableMakerSkillFailure = nil
        defer { portableMakerSkillOperation = .idle }
        do {
            portableMakerSkillStatus = try await requestPortableMakerSkill(
                method: "portable_skill.install"
            )
        } catch {
            portableMakerSkillFailure = .install
        }
    }

    func uninstallPortableMakerSkill() async {
        guard !portableMakerSkillOperation.isBusy else { return }
        portableMakerSkillOperation = .uninstalling
        portableMakerSkillFailure = nil
        defer { portableMakerSkillOperation = .idle }
        do {
            portableMakerSkillStatus = try await requestPortableMakerSkill(
                method: "portable_skill.uninstall"
            )
        } catch {
            portableMakerSkillFailure = .uninstall
        }
    }

    private func requestPortableMakerSkill(
        method: String
    ) async throws -> PortableMakerSkillStatus {
        let result = try await requestPetCore(
            method: method,
            timeout: .seconds(180)
        )
        let data = try JSONSerialization.data(withJSONObject: result)
        let status = try JSONDecoder().decode(PortableMakerSkillStatus.self, from: data)
        guard status.schemaVersion == "apc.portable-skill-status.v1",
              status.name == "agent-pet-maker",
              status.targetDisplayPath == "~/agent/skills/agent-pet-maker"
        else {
            throw PetCoreClientError.invalidResponse
        }
        return status
    }

    func repairConnections(_ sources: [AgentSource]) {
        connectionsModel.repair(sources)
    }

    func uninstallConnection(_ source: AgentSource) {
        connectionsModel.uninstall(source)
    }

    func uninstallConnections(_ sources: [AgentSource]) {
        connectionsModel.uninstall(sources)
    }

    func checkConnection(_ source: AgentSource) {
        connectionsModel.check(source)
    }

    func checkConnections(_ sources: [AgentSource]) {
        connectionsModel.check(sources)
    }

    func checkAllConnections() {
        connectionsModel.checkAll()
    }

    func requestAutomaticConnectionCheckOnFirstPresentation() {
        connectionsModel.requestAutomaticCheckOnFirstPresentation()
    }

    static func connectionOperationParameters(
        source: AgentSource? = nil
    ) -> [String: String] {
        ConnectionsModel.operationParameters(source: source)
    }

    func sendConnectionTestEvent(_ source: AgentSource) {
        connectionsModel.sendTestEvent(source)
    }

    func retryConnectionOperation() {
        connectionsModel.retry()
    }

    func dismissConnectionOperationNotice() {
        connectionsModel.dismissNotice()
    }

    static func connectionOperationFailureReason(
        for error: Error
    ) -> AgentConnectionOperationFailureReason {
        ConnectionsModel.failureReason(for: error)
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
        overlayPetDragPresentationCenter = nil
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
        if !rect(
            overlayScreenVisibleFrame,
            nearlyEquals: targetVisibleFrame
        ) {
            overlayScreenVisibleFrame = targetVisibleFrame
        }
        overlayPetScreenCenter = OverlayGeometry.clampedPetScreenCenter(
            proposedCenter,
            displayWidthPt: overlayDisplayWidthPt,
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
            commitCurrentOverlayPlacement(
                interactionID: UUID()
            )
        } else {
            overlayController.updateLayoutDuringInteraction()
        }
    }

    func beginOverlayPetDrag(interactionID: UUID) {
        guard overlayDragInteractionID == nil else { return }
        overlayLostMouseUpFallbackTask?.cancel()
        overlayLostMouseUpFallbackTask = nil
        overlayDragInteractionID = interactionID
        if overlayPetDragInProgress != true {
            overlayPetDragInProgress = true
            overlayController.updateLayoutDuringInteraction()
            overlayController.refreshPointerPassthrough()
        }
    }

    /// Applies the direct-manipulation presentation position without changing
    /// the persistent placement contract. The drag view supplies a hard-clamped
    /// absolute anchor and coalesces high-frequency samples to display ticks.
    func presentOverlayPetDrag(
        at presentationCenter: CGPoint,
        visibleFrame: CGRect?,
        interactionID: UUID
    ) {
        guard overlayDragInteractionID == interactionID else { return }
        if overlayLostMouseUpFallbackTask != nil {
            OverlayInteractionTelemetry.shared.fallback(
                .fallbackSuppressed,
                interactionID: interactionID
            )
        }
        overlayLostMouseUpFallbackTask?.cancel()
        overlayLostMouseUpFallbackTask = nil
        if let visibleFrame,
           !visibleFrame.isEmpty,
           !rect(overlayScreenVisibleFrame, nearlyEquals: visibleFrame)
        {
            overlayScreenVisibleFrame = visibleFrame
        }
        overlayPetDragPresentationCenter = presentationCenter
        overlayPetPositionInitialized = true
        overlayController.presentPetDrag(
            at: presentationCenter,
            visibleFrame: visibleFrame ?? overlayScreenVisibleFrame
        )
    }

    func commitOverlayPetDrag(
        at presentationCenter: CGPoint,
        visibleFrame: CGRect?,
        interactionID: UUID
    ) {
        guard overlayDragInteractionID == interactionID else { return }

        let targetScreen = screen(matchingVisibleFrame: visibleFrame)
            ?? screen(containing: presentationCenter)
            ?? screen(containing: overlayPetScreenCenter)
            ?? NSScreen.main
        let targetVisibleFrame = targetScreen?.visibleFrame
            ?? visibleFrame
            ?? overlayScreenVisibleFrame
        guard !targetVisibleFrame.isEmpty else {
            overlayPetScreenCenter = presentationCenter
            overlayPetDragPresentationCenter = nil
            overlayDragInteractionID = nil
            overlayPetDragInProgress = false
            commitCurrentOverlayPlacement(
                interactionID: interactionID
            )
            return
        }
        let movementFrame = OverlayGeometry.petMovementFrame(
            screenFrame: targetScreen?.frame ?? targetVisibleFrame,
            visibleFrame: targetVisibleFrame
        )
        let targetDisplayWidthPt = pendingDisplayWidthPt
            ?? overlayDisplayWidthPt
        var targetCenter = CGPoint(
            x: OverlayPlacementCanonicalization.cgFloatCoordinate(
                presentationCenter.x
            ),
            y: OverlayPlacementCanonicalization.cgFloatCoordinate(
                presentationCenter.y
            )
        )
        if targetDisplayWidthPt != overlayDisplayWidthPt {
            targetCenter = OverlayGeometry.bottomAnchoredCenter(
                from: targetCenter,
                currentDisplayWidthPt: overlayDisplayWidthPt,
                proposedDisplayWidthPt: targetDisplayWidthPt
            )
            targetCenter = OverlayPetDragGeometry.clampedCenter(
                targetCenter,
                displayWidthPt: targetDisplayWidthPt,
                visibleFrame: movementFrame,
                clickMenuEnabled: behavior.clickMenu,
                petVisualEnvelope: overlayPetVisualEnvelope
            )
        }

        overlayPetScreenCenter = targetCenter
        overlayDisplayWidthPt = targetDisplayWidthPt
        pendingDisplayWidthPt = nil
        overlayPetDragPresentationCenter = nil
        overlayDragInteractionID = nil
        overlayPetDragInProgress = false
        overlayScreenVisibleFrame = targetVisibleFrame
        overlayPetPositionInitialized = true
        overlayController.updateDisplayWidth(targetDisplayWidthPt)
        diagnostics.log(
            .info,
            category: "overlay",
            event: "overlay_position_committed",
            metadata: ["committed": .bool(true)]
        )
        commitCurrentOverlayPlacement(
            interactionID: interactionID
        )
    }

    func endOverlayPetDrag(interactionID: UUID?) {
        if let interactionID,
           overlayDragInteractionID != nil,
           overlayDragInteractionID != interactionID {
            return
        }
        if let interactionID, overlayLostMouseUpFallbackTask != nil {
            OverlayInteractionTelemetry.shared.fallback(
                .fallbackSuppressed,
                interactionID: interactionID
            )
        }
        overlayLostMouseUpFallbackTask?.cancel()
        overlayLostMouseUpFallbackTask = nil
        overlayDragInteractionID = nil
        overlayController.endPetDragInteraction(interactionID)
        if overlayPetDragInProgress {
            overlayPetDragInProgress = false
            overlayController.updateLayoutDuringInteraction()
            overlayController.refreshPointerPassthrough()
        }
    }

    func ensureOverlayPetPosition(in visibleFrame: CGRect) {
        guard !visibleFrame.isEmpty else { return }
        guard overlayPetDragPresentationCenter == nil else { return }
        if overlayPetPositionInitialized {
            let targetScreen = screen(matchingVisibleFrame: visibleFrame)
                ?? screen(containing: overlayPetScreenCenter)
            let movementFrame = OverlayGeometry.petMovementFrame(
                screenFrame: targetScreen?.frame ?? visibleFrame,
                visibleFrame: targetScreen?.visibleFrame ?? visibleFrame
            )
            overlayPetScreenCenter = OverlayGeometry.clampedPetScreenCenter(
                overlayPetScreenCenter,
                displayWidthPt: overlayDisplayWidthPt,
                visibleFrame: movementFrame,
                clickMenuEnabled: behavior.clickMenu,
                petVisualEnvelope: overlayPetVisualEnvelope
            )
        } else {
            overlayPetScreenCenter = OverlayGeometry.defaultPetScreenCenter(
                in: visibleFrame,
                displayWidthPt: overlayDisplayWidthPt
            )
            overlayPetPositionInitialized = true
        }
    }

    func previewOverlayDisplayWidthPt(_ proposed: CGFloat) {
        let target = OverlayGeometry.clampedDisplayWidthPt(proposed)
        pendingDisplayWidthPt = target
        scheduleOverlayDisplayWidthCommit()
        guard !overlayPetDragInProgress else { return }
        let targetScreen = screen(containing: overlayPetScreenCenter)
            ?? NSScreen.main
        let cadence = OverlayDisplayRefreshCadence.resolved(for: targetScreen)
        overlayPlacementPreviewDriver.submit(
            target,
            targetDisplayID: cadence.displayID,
            screen: targetScreen,
            fallbackCadence: cadence
        ) { [weak self] target in
            guard let self, !self.overlayPetDragInProgress else { return }
            let center = self.previewCenter(forDisplayWidthPt: target)
            self.overlayController.previewDisplayWidth(
                target,
                petScreenCenter: center
            )
        }
    }

    func commitOverlayDisplayWidthPt(_ proposed: CGFloat? = nil) {
        if let proposed {
            pendingDisplayWidthPt = OverlayGeometry.clampedDisplayWidthPt(
                proposed
            )
        }
        overlayDisplayWidthCommitTask?.cancel()
        overlayDisplayWidthCommitTask = nil
        overlayDisplayWidthCommitDeadline = nil
        overlayPlacementPreviewDriver.cancelPending()
        guard !overlayPetDragInProgress,
              let target = pendingDisplayWidthPt else {
            return
        }
        pendingDisplayWidthPt = nil
        applyCommittedDisplayWidthPt(
            target,
            interactionID: UUID()
        )
    }

    func resetOverlayDisplayWidthPt() {
        previewOverlayDisplayWidthPt(
            OverlayGeometry.defaultDisplayWidthPt
        )
        commitOverlayDisplayWidthPt(
            OverlayGeometry.defaultDisplayWidthPt
        )
    }

    private func scheduleOverlayDisplayWidthCommit() {
        overlayDisplayWidthCommitDeadline =
            ProcessInfo.processInfo.systemUptime + 0.150
        guard overlayDisplayWidthCommitTask == nil else { return }
        overlayDisplayWidthCommitTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let deadline = self.overlayDisplayWidthCommitDeadline else {
                    self.overlayDisplayWidthCommitTask = nil
                    return
                }
                let delay = max(
                    0,
                    deadline - ProcessInfo.processInfo.systemUptime
                )
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard let currentDeadline = self.overlayDisplayWidthCommitDeadline else {
                    self.overlayDisplayWidthCommitTask = nil
                    return
                }
                guard currentDeadline
                    <= ProcessInfo.processInfo.systemUptime + 0.000_001 else {
                    continue
                }
                self.overlayDisplayWidthCommitTask = nil
                self.overlayDisplayWidthCommitDeadline = nil
                self.commitOverlayDisplayWidthPt()
                return
            }
        }
    }

    private func previewCenter(forDisplayWidthPt displayWidthPt: CGFloat) -> CGPoint {
        let proposed = OverlayGeometry.bottomAnchoredCenter(
            from: overlayPetScreenCenter,
            currentDisplayWidthPt: overlayDisplayWidthPt,
            proposedDisplayWidthPt: displayWidthPt
        )
        let targetScreen = screen(containing: overlayPetScreenCenter)
            ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame
            ?? overlayScreenVisibleFrame
        guard !visibleFrame.isEmpty else { return proposed }
        let movementFrame = OverlayGeometry.petMovementFrame(
            screenFrame: targetScreen?.frame ?? visibleFrame,
            visibleFrame: visibleFrame
        )
        return OverlayPetDragGeometry.clampedCenter(
            proposed,
            displayWidthPt: displayWidthPt,
            visibleFrame: movementFrame,
            clickMenuEnabled: behavior.clickMenu,
            petVisualEnvelope: overlayPetVisualEnvelope
        )
    }

    private func applyCommittedDisplayWidthPt(
        _ proposed: CGFloat,
        interactionID: UUID
    ) {
        let target = OverlayGeometry.clampedDisplayWidthPt(proposed)
        let targetCenter = previewCenter(forDisplayWidthPt: target)
        let widthChanged = target != overlayDisplayWidthPt
        let centerChanged = hypot(
            targetCenter.x - overlayPetScreenCenter.x,
            targetCenter.y - overlayPetScreenCenter.y
        ) > 0.01
        overlayDisplayWidthPt = target
        overlayPetScreenCenter = targetCenter
        overlayPetPositionInitialized = true
        overlayController.updateDisplayWidth(target)
        guard widthChanged || centerChanged else { return }
        diagnostics.log(
            .info,
            category: "overlay",
            event: "overlay_display_width_committed",
            metadata: ["display_width_pt": .double(Double(target))]
        )
        commitCurrentOverlayPlacement(
            interactionID: interactionID
        )
    }

    func updateOverlayLayout() {
        overlayController.updateLayout()
    }

    func updateOverlayBubbleAnchorDirection(_ direction: OverlayBubbleAnchorDirection) {
        guard overlayBubbleAnchorDirection != direction else { return }
        overlayBubbleAnchorDirection = direction
    }

    func updateOverlayPetVisualEnvelope(
        _ envelope: OverlayPetVisualEnvelope?,
        petID: String,
        semanticOwnerEntryID: String
    ) {
        guard activePet?.id == petID else { return }
        guard OverlayPetAnimationIdentity.stateEntryID(for: presentedActiveAgentState)
            == semanticOwnerEntryID
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
        semanticOwnerEntryID: String
    ) {
        guard activePet?.id == petID else { return }
        guard OverlayPetAnimationIdentity.stateEntryID(for: presentedActiveAgentState)
            == semanticOwnerEntryID else {
            return
        }
        if let projection = overlayPetFrameHitTestProjection,
           projection.petID == petID,
           projection.semanticOwnerEntryID == semanticOwnerEntryID,
           projection.hitTest == hitTest {
            return
        }
        overlayPetFrameHitTestProjection = OverlayPetFrameHitTestProjection(
            hitTest: hitTest,
            petID: petID,
            semanticOwnerEntryID: semanticOwnerEntryID
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
    /// bubble into a collapsed one. Keyboard focus uses this path so focus
    /// acquisition never hides the content it is about to enter.
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

    func toggleOverlayAgentGroup(_ source: AgentSource) {
        guard behavior.groupSessionsByAgent else { return }
        overlayAgentGroupExpansionOverrides[source] = !overlayAgentGroupIsExpanded(source)
        overlayController.updateLayout(animateBubble: true)
    }

    func toggleOverlayStandaloneStack() {
        guard !behavior.groupSessionsByAgent,
              overlayAvailableBubbleContents.reduce(0, {
                  $0 + $1.representedSessionCount
              }) > 1
        else { return }
        let expands = !overlayStandaloneStackIsExpanded
        overlayStandaloneStackDisclosureDirection = expands ? .expanding : .collapsing
        overlayStandaloneStackExpansionOverride = expands
        overlayController.updateLayout(animateBubble: true)
    }

    var overlayBubbleDisclosureAction: OverlayBubbleDisclosureAction? {
        OverlayBubbleDisclosureAction.resolve(
            groupSessionsByAgent: behavior.groupSessionsByAgent,
            sessionCount: overlayBubbleSessionCount,
            bubbleDismissed: overlayBubbleDismissed,
            standaloneStackExpanded: overlayStandaloneStackIsExpanded,
            standaloneStackDirection: overlayStandaloneStackDisclosureDirection
        )
    }

    /// Moves the pet-side disclosure control by exactly one visual level.
    /// A flat multi-session tray therefore travels through the folded card in
    /// both directions: expanded -> folded -> hidden and hidden -> folded ->
    /// expanded. Pet-body clicks continue to use `toggleOverlayBubble()` and
    /// retain their direct visibility toggle.
    func stepOverlayBubbleDisclosure() {
        guard let action = overlayBubbleDisclosureAction else {
            overlayController.updateLayout()
            return
        }
        let wasDismissed = overlayBubbleDismissed
        switch action {
        case .revealBubble:
            overlayBubbleDismissed = false
        case .revealCollapsedStandaloneStack:
            overlayStandaloneStackDisclosureDirection = .expanding
            overlayStandaloneStackExpansionOverride = false
            overlayBubbleDismissed = false
        case .expandStandaloneStack:
            overlayStandaloneStackDisclosureDirection = .expanding
            overlayStandaloneStackExpansionOverride = true
        case .collapseStandaloneStack:
            overlayStandaloneStackDisclosureDirection = .collapsing
            overlayStandaloneStackExpansionOverride = false
        case .dismissBubble:
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
        overlayController.updateLayout(animateBubble: true)
    }

    private func reconcileOverlayStandaloneSessionOrder(
        with states: [ActiveAgentState]
    ) {
        struct Entry {
            let id: String
            let activationID: String
        }

        let entries = states.map { state in
            let id = OverlaySessionContent.stableID(
                source: state.source,
                sessionID: state.sessionID ?? state.event.sessionID,
                anonymousSessionAlias: state.anonymousSessionAlias,
                fallbackEventID: state.event.id
            )
            // sessionActivatedAt is an epoch boundary, unlike the event ID or
            // event timestamp, which can change on every thinking/tool update.
            return Entry(
                id: id,
                activationID: state.sessionActivatedAt.map { "activation:\($0)" }
                    ?? "legacy"
            )
        }

        let promotions = entries.filter { entry in
            overlayStandaloneSessionActivationIDs[entry.id] != entry.activationID
                || !overlayStandaloneSessionOrder.contains(entry.id)
        }
        let promotedIDs = Set(promotions.map(\.id))
        if !promotedIDs.isEmpty {
            overlayStandaloneSessionOrder.removeAll { promotedIDs.contains($0) }
            // PetCore gives us attention/latest-first. Keep that same reading
            // direction in the App: the folded foreground card is also the
            // first card when the tray expands. A true activation epoch moves
            // once to the front; ordinary event churn keeps the existing slot.
            for entry in promotions.reversed() {
                overlayStandaloneSessionOrder.insert(entry.id, at: 0)
                overlayStandaloneSessionActivationIDs[entry.id] = entry.activationID
            }
        }

        // A missing projected row may be a bounded/transient omission, not a
        // closed session. Retain a small history so it can recover its slot.
        let maximumRememberedSessions = 64
        if overlayStandaloneSessionOrder.count > maximumRememberedSessions {
            let removed = overlayStandaloneSessionOrder.dropFirst(maximumRememberedSessions)
            overlayStandaloneSessionOrder = Array(
                overlayStandaloneSessionOrder.prefix(maximumRememberedSessions)
            )
            for id in removed {
                overlayStandaloneSessionActivationIDs[id] = nil
            }
        }
    }

    func dismissOverlayBubble(eventID: String) {
        overlayDismissedBubbleEventIDs.insert(eventID)
        overlayController.updateLayout(animateBubble: true)
    }

    func dismissOverlayBubble(eventIDs: [String]) {
        overlayDismissedBubbleEventIDs.formUnion(eventIDs)
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

    func observeOverlayPrimaryButton(isDown: Bool) {
        guard !isDown,
              let interactionID = overlayDragInteractionID else {
            if isDown {
                overlayLostMouseUpFallbackTask?.cancel()
                overlayLostMouseUpFallbackTask = nil
            }
            return
        }
        guard overlayLostMouseUpFallbackTask == nil else { return }
        OverlayInteractionTelemetry.shared.fallback(
            .fallbackArmed,
            interactionID: interactionID
        )
        overlayLostMouseUpFallbackTask = Task { @MainActor [weak self] in
            // Give the normal DragView mouseUp finalizer one main-runloop
            // opportunity before treating this as lost pointer capture.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.overlayLostMouseUpFallbackTask = nil
            guard self.overlayDragInteractionID == interactionID else { return }
            OverlayInteractionTelemetry.shared.fallback(
                .fallbackFired,
                interactionID: interactionID
            )
            self.cancelOverlayPointerInteractions()
        }
    }

    func cancelOverlayPointerInteractions() {
        guard overlayPetDragInProgress else { return }
        overlayLostMouseUpFallbackTask?.cancel()
        overlayLostMouseUpFallbackTask = nil
        let interactionID = overlayDragInteractionID
        if let interactionID,
           let interruptedDragCenter = overlayPetDragPresentationCenter {
            commitOverlayPetDrag(
                at: interruptedDragCenter,
                visibleFrame: overlayScreenVisibleFrame,
                interactionID: interactionID
            )
        } else {
            endOverlayPetDrag(interactionID: interactionID)
            if let interactionID {
                OverlayInteractionTelemetry.shared.finish(
                    interactionID: interactionID,
                    result: .suppressed
                )
            }
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
        panel.allowedContentTypes = [.png, .jpeg, .webP]

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

    private func applyOverlayPlacement(
        _ placement: OverlayPlacement,
        remoteRevision: UInt64,
        remoteIntent: OverlayPlacementRemoteIntent?
    ) {
        guard let normalized = normalizedOverlayPlacement(placement) else {
            return
        }
        if !overlayPlacementAuthority.bootstrapCompleted {
            let journal = loadOverlayPlacementJournalOnce()
            if let journal,
               let recovered = normalizedOverlayPlacement(journal.placement) {
                if remoteIntent != nil,
                   journal.baseRemoteRevision < remoteRevision {
                    // A newer explicit PetCore intent wins over work recovered
                    // from an older App process. Its consume commit atomically
                    // replaces the stale journal entry below.
                } else if remoteIntent == nil,
                          OverlayPlacementCanonicalization.areEquivalent(
                              placement,
                              journal.placement
                          ) {
                    _ = overlayPlacementAuthority.bootstrap(
                        normalized,
                        remoteRevision: remoteRevision
                    )
                    applyPresentedOverlayPlacement(normalized)
                    removeOverlayPlacementJournalIfMatching(journal)
                    if !OverlayPlacementCanonicalization.areEquivalent(
                        normalized,
                        placement
                    ) {
                        commitCurrentOverlayPlacement(interactionID: UUID())
                    }
                    return
                } else {
                    _ = overlayPlacementAuthority.bootstrap(
                        normalized,
                        remoteRevision: remoteRevision
                    )
                    applyPresentedOverlayPlacement(recovered)
                    let replay = overlayPlacementAuthority.commitLocal(
                        recovered,
                        interactionID: UUID()
                    )
                    enqueueOverlayPlacementCommit(replay)
                    return
                }
            }
            _ = overlayPlacementAuthority.bootstrap(
                normalized,
                remoteRevision: remoteRevision
            )
            applyPresentedOverlayPlacement(normalized)
            if !OverlayPlacementCanonicalization.areEquivalent(
                normalized,
                placement
            ) || remoteIntent != nil {
                commitCurrentOverlayPlacement(interactionID: UUID())
            }
            return
        }
        guard overlayPlacementAuthority.allowsRemote(
            normalized,
            remoteRevision: remoteRevision,
            intent: remoteIntent
        ) else {
            return
        }
        _ = overlayPlacementAuthority.applyRemote(
            normalized,
            remoteRevision: remoteRevision,
            intent: remoteIntent
        )
        applyPresentedOverlayPlacement(normalized)
        if remoteIntent != nil {
            commitCurrentOverlayPlacement(interactionID: UUID())
        }
    }

    private func normalizedOverlayPlacement(
        _ placement: OverlayPlacement
    ) -> OverlayPlacement? {
        let persistedCenter = CGPoint(x: placement.x, y: placement.y)
        let screen = screen(matchingDisplayID: placement.displayId)
            ?? screen(containing: persistedCenter)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame
            ?? (overlayScreenVisibleFrame.isEmpty ? .zero : overlayScreenVisibleFrame)
        guard !visibleFrame.isEmpty else { return nil }

        let targetDisplayWidthPt =
            OverlayGeometry.resolvedInitialDisplayWidthPt(
            persistedDisplayWidthPt: CGFloat(placement.displayWidthPt),
            hasPersistedPosition: persistedCenter != .zero
        )

        let normalizedCenter: CGPoint
        if persistedCenter == .zero {
            normalizedCenter = OverlayGeometry.defaultPetScreenCenter(
                in: visibleFrame,
                displayWidthPt: targetDisplayWidthPt
            )
        } else {
            let movementFrame = OverlayGeometry.petMovementFrame(
                screenFrame: screen?.frame ?? visibleFrame,
                visibleFrame: visibleFrame
            )
            normalizedCenter = OverlayGeometry.clampedPetScreenCenter(
                persistedCenter,
                displayWidthPt: targetDisplayWidthPt,
                visibleFrame: movementFrame,
                clickMenuEnabled: behavior.clickMenu,
                petVisualEnvelope: overlayPetVisualEnvelope
            )
        }
        return OverlayPlacement(
            x: Double(normalizedCenter.x),
            y: Double(normalizedCenter.y),
            displayWidthPt: Double(targetDisplayWidthPt),
            displayId: currentDisplayID(for: normalizedCenter)
        )
    }

    private func applyPresentedOverlayPlacement(
        _ placement: OverlayPlacement
    ) {
        overlayDisplayWidthPt = CGFloat(placement.displayWidthPt)
        overlayPetScreenCenter = CGPoint(x: placement.x, y: placement.y)
        overlayPetDragPresentationCenter = nil
        overlayPetPositionInitialized = true
        if let screen = screen(matchingDisplayID: placement.displayId)
            ?? screen(containing: overlayPetScreenCenter) {
            overlayScreenVisibleFrame = screen.visibleFrame
        }
        overlayController.updateDisplayWidth(overlayDisplayWidthPt)
    }

    private func commitCurrentOverlayPlacement(interactionID: UUID) {
        let placement = currentOverlayPlacement()
        if let pending = overlayPlacementAuthority.pending,
           OverlayPlacementCanonicalization.areEquivalent(
               pending.placement,
               placement
           ) {
            OverlayInteractionTelemetry.shared.finish(
                interactionID: interactionID,
                result: .success
            )
            return
        }
        let commit = overlayPlacementAuthority.commitLocal(
            placement,
            interactionID: interactionID
        )
        enqueueOverlayPlacementCommit(commit)
    }

    private func enqueueOverlayPlacementCommit(
        _ commit: OverlayPlacementCommit
    ) {
        OverlayInteractionTelemetry.shared.commitQueued(
            interactionID: commit.interactionID
        )
        saveOverlayPlacementJournal(commit)
        startOverlayPlacementSaveWorkerIfNeeded(reason: .newLocalCommit)
    }

    private func startOverlayPlacementSaveWorkerIfNeeded(
        reason: OverlayPlacementSaveResumeReason
    ) {
        guard overlayPlacementSaveTask == nil,
              let pending = overlayPlacementAuthority.pending else { return }
        if overlayPlacementExhaustedGeneration == pending.localRevision {
            guard reason.mayResumeExhaustedGeneration else { return }
            overlayPlacementExhaustedGeneration = nil
        } else if reason == .newLocalCommit {
            overlayPlacementExhaustedGeneration = nil
        }
        overlayPlacementSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            workerLoop: while !Task.isCancelled,
                  let commit = self.overlayPlacementAuthority.pending {
                let outcome = await self.saveOverlayPlacement(commit)
                switch outcome {
                case .converged, .superseded:
                    if self.overlayPlacementAuthority.pending == nil {
                        self.overlayPlacementSaveNeedsAttention = false
                    }
                    continue workerLoop
                case let .exhausted(generation):
                    if self.overlayPlacementAuthority.pending?.localRevision
                        == generation {
                        self.overlayPlacementExhaustedGeneration =
                            generation
                        self.overlayPlacementSaveNeedsAttention = true
                    }
                    break workerLoop
                case .cancelled:
                    break workerLoop
                }
            }
            self.overlayPlacementSaveTask = nil
        }
    }

    private func resumePendingOverlayPlacementSaveIfNeeded(
        reason: OverlayPlacementSaveResumeReason
    ) {
        guard overlayPlacementSaveTask == nil,
              overlayPlacementAuthority.pending != nil else { return }
        startOverlayPlacementSaveWorkerIfNeeded(reason: reason)
    }

    func retryPendingOverlayPlacementSave() {
        resumePendingOverlayPlacementSaveIfNeeded(reason: .explicitRetry)
    }

    private func saveOverlayPlacement(
        _ initialCommit: OverlayPlacementCommit
    ) async -> OverlayPlacementSaveRunOutcome {
        let retryDelays: [Duration] = [
            .zero,
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
        ]
        let telemetryInteractionID = initialCommit.interactionID
        let saveStartedAt = ProcessInfo.processInfo.systemUptime
        func superseded() -> OverlayPlacementSaveRunOutcome {
            OverlayInteractionTelemetry.shared.finish(
                interactionID: telemetryInteractionID,
                result: .stale
            )
            return .superseded
        }
        func cancelled() -> OverlayPlacementSaveRunOutcome {
            OverlayInteractionTelemetry.shared.finish(
                interactionID: telemetryInteractionID,
                result: .suppressed
            )
            return .cancelled
        }
        var commit = initialCommit
        for attempt in retryDelays.indices {
            guard !Task.isCancelled else { return cancelled() }
            guard overlayPlacementAuthority.pending?.localRevision
                == commit.localRevision else { return superseded() }
            let delay = retryDelays[attempt]
            if delay != .zero {
                do {
                    try await overlayPlacementRetrySleeper(delay)
                } catch {
                    return cancelled()
                }
            }
            guard !Task.isCancelled,
                  overlayPlacementAuthority.pending?.localRevision
                    == commit.localRevision else { return superseded() }
            let attemptStartedAt = ProcessInfo.processInfo.systemUptime
            do {
                let data = try JSONEncoder().encode(commit.placement)
                guard var object = try JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any] else {
                    throw PetCoreClientError.invalidResponse
                }
                object["expected_revision"] = String(commit.baseRemoteRevision)
                OverlayInteractionTelemetry.shared.requestAttempt(
                    interactionID: telemetryInteractionID,
                    attempt: attempt + 1
                )
                let result = try await requestPetCore(
                    method: "overlay.placement.update",
                    params: object
                )
                let response = try OverlayPlacementUpdateResponse(result: result)
                guard overlayPlacementAuthority.pending?.localRevision
                    == commit.localRevision else { return superseded() }
                guard response.ok else {
                    guard response.conflict else {
                        throw PetCoreClientError.invalidResponse
                    }
                    OverlayInteractionTelemetry.shared.requestResult(
                        interactionID: telemetryInteractionID,
                        attempt: attempt + 1,
                        result: .conflict
                    )
                    if response.intent != nil {
                        guard let normalized = normalizedOverlayPlacement(
                            response.placement
                        ),
                        let consume = overlayPlacementAuthority
                            .supersedeWithExplicitRemote(
                                normalized,
                                remoteRevision: response.placementRevision,
                                interactionID: UUID()
                            ) else {
                            return superseded()
                        }
                        applyPresentedOverlayPlacement(normalized)
                        saveOverlayPlacementJournal(consume)
                        commit = consume
                        continue
                    }
                    let reconciliation = overlayPlacementAuthority
                        .reconcileOrdinaryConflict(
                            for: commit,
                            actualPlacement: response.placement,
                            remoteRevision: response.placementRevision
                        )
                    switch reconciliation {
                    case .acknowledged:
                        removeOverlayPlacementJournalIfMatching(
                            journalEntry(for: commit)
                        )
                        OverlayInteractionTelemetry.shared.finish(
                            interactionID: telemetryInteractionID,
                            result: .success
                        )
                        return .converged
                    case let .retry(rebased):
                        saveOverlayPlacementJournal(rebased)
                        commit = rebased
                        continue
                    case .stale:
                        removeOverlayPlacementJournalIfMatching(
                            journalEntry(for: commit)
                        )
                        return superseded()
                    }
                }
                guard response.intent == nil,
                      OverlayPlacementCanonicalization.areEquivalent(
                          response.placement,
                          commit.placement
                      ) else {
                    throw PetCoreClientError.invalidResponse
                }
                OverlayInteractionTelemetry.shared.requestResult(
                    interactionID: telemetryInteractionID,
                    attempt: attempt + 1,
                    result: .success
                )
                let reconciliation = overlayPlacementAuthority.acknowledge(
                    commit,
                    remoteRevision: response.placementRevision
                )
                switch reconciliation {
                case .acknowledged:
                    removeOverlayPlacementJournalIfMatching(
                        journalEntry(for: commit)
                    )
                    OverlayInteractionTelemetry.shared.finish(
                        interactionID: telemetryInteractionID,
                        result: .success
                    )
                    return .converged
                case let .retry(rebased):
                    removeOverlayPlacementJournalIfMatching(
                        journalEntry(for: commit)
                    )
                    saveOverlayPlacementJournal(rebased)
                    commit = rebased
                case .stale:
                    removeOverlayPlacementJournalIfMatching(
                        journalEntry(for: commit)
                    )
                    return superseded()
                }
            } catch {
                OverlayInteractionTelemetry.shared.requestResult(
                    interactionID: telemetryInteractionID,
                    attempt: attempt + 1,
                    result: .transportFailure
                )
                overlayPlacementAuthority.failCommit(commit)
                diagnostics.log(
                    .warning,
                    category: "overlay",
                    event: "placement_save_failed",
                    metadata: [
                        "attempt": .integer(Int64(attempt + 1)),
                        "duration_bucket": .string(
                            OverlayInteractionDurationBucket(
                                milliseconds: (
                                    ProcessInfo.processInfo.systemUptime
                                        - attemptStartedAt
                                ) * 1_000
                            ).rawValue
                        ),
                        "generation_category": .string("current"),
                        "result_kind": .string("transport_or_protocol_failure"),
                    ]
                )
            }
        }
        if Task.isCancelled { return cancelled() }
        OverlayInteractionTelemetry.shared.finish(
            interactionID: telemetryInteractionID,
            result: .exhausted
        )
        diagnostics.log(
            .warning,
            category: "overlay",
            event: "placement_save_exhausted",
            metadata: [
                "attempt": .integer(Int64(retryDelays.count)),
                "duration_bucket": .string(
                    OverlayInteractionDurationBucket(
                        milliseconds: (
                            ProcessInfo.processInfo.systemUptime
                                - saveStartedAt
                        ) * 1_000
                    ).rawValue
                ),
                "generation_category": .string("current"),
                "result_kind": .string("exhausted"),
            ]
        )
        return .exhausted(generation: commit.localRevision)
    }

    private func loadOverlayPlacementJournalOnce()
        -> OverlayPlacementJournalEntry? {
        guard !overlayPlacementJournalDidLoad else { return nil }
        overlayPlacementJournalDidLoad = true
        do {
            return try overlayPlacementJournalStore.load()
        } catch {
            logOverlayPlacementJournalFailure("load", error: error)
            return nil
        }
    }

    private func saveOverlayPlacementJournal(
        _ commit: OverlayPlacementCommit
    ) {
        do {
            try overlayPlacementJournalStore.save(journalEntry(for: commit))
        } catch {
            logOverlayPlacementJournalFailure("save", error: error)
        }
    }

    private func removeOverlayPlacementJournalIfMatching(
        _ entry: OverlayPlacementJournalEntry
    ) {
        do {
            try overlayPlacementJournalStore.removeIfMatching(entry)
        } catch {
            logOverlayPlacementJournalFailure("remove", error: error)
        }
    }

    private func journalEntry(
        for commit: OverlayPlacementCommit
    ) -> OverlayPlacementJournalEntry {
        OverlayPlacementJournalEntry(
            interactionID: commit.interactionID,
            localRevision: commit.localRevision,
            placement: commit.placement,
            baseRemoteRevision: commit.baseRemoteRevision
        )
    }

    private func logOverlayPlacementJournalFailure(
        _ operation: String,
        error: Error
    ) {
        diagnostics.log(
            .warning,
            category: "overlay",
            event: "placement_journal_failed",
            metadata: [
                "operation": .string(operation),
                "error": .string(String(describing: error)),
            ]
        )
    }

    private func reconcileProductConvergenceConnectorAttention(
        afterChecking checkedSources: Set<AgentSource>
    ) {
        guard productConvergenceTask == nil,
              case let .needsAttention(.connectors(attentionIssues)) =
                appUpdateConvergenceState
        else { return }

        let resolvedSources: Set<AgentSource> = Set(connections.lazy.compactMap {
            status -> AgentSource? in
            guard checkedSources.contains(status.source),
                  ProductConvergenceConnectionRecoveryPolicy.resolvesAttention(status)
            else { return nil }
            return status.source
        })
        guard !resolvedSources.isEmpty else { return }

        let remainingIssues = attentionIssues.filter {
            !resolvedSources.contains($0.source)
        }
        let fullyResolved = remainingIssues.isEmpty
        appUpdateConvergenceState = fullyResolved
            ? .idle
            : .needsAttention(.connectors(remainingIssues))
        diagnostics.log(
            .notice,
            category: "update",
            event: "product_convergence_attention_reconciled_by_runtime_check",
            metadata: [
                "resolved_sources": .string(
                    resolvedSources
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { $0.rawValue }
                        .joined(separator: ",")
                ),
                "remaining_sources": .string(
                    remainingIssues.map { $0.source.rawValue }.joined(separator: ",")
                ),
            ]
        )
        if fullyResolved {
            scheduleProductConvergence(force: true)
        }
    }

    private enum StartupConnectionCheckResult {
        case success
        case failure(AgentConnectionOperationFailureReason)
    }

    private func finishStartupConnectionCheckIfNeeded(
        checkedSources: Set<AgentSource>
    ) {
        guard checkedSources == Set(AgentSource.allCases) else { return }
        finishStartupConnectionCheckIfNeeded(
            operation: AgentConnectionOperation(
                kind: .check,
                sources: AgentSource.allCases
            ),
            result: .success
        )
    }

    private func finishStartupConnectionCheckIfNeeded(
        operation: AgentConnectionOperation,
        result: StartupConnectionCheckResult
    ) {
        guard startupConnectionCheckState != .idle,
              operation.kind == .check,
              operation.sources == AgentSource.allCases
        else { return }

        startupConnectionCheckTask?.cancel()
        startupConnectionCheckTask = nil

        switch result {
        case .success:
            startupConnectionCheckState = .completed
        case let .failure(reason):
            startupConnectionCheckState = .failed(reason)
        }
    }

    func applyAuthoritativeConnectionSnapshot(_ snapshotConnections: [AgentConnectionStatus]) {
        connectionsModel.replaceConnections(snapshotConnections)
    }

    private func currentOverlayPlacement() -> OverlayPlacement {
        OverlayPlacement(
            x: Double(overlayPetScreenCenter.x),
            y: Double(overlayPetScreenCenter.y),
            displayWidthPt: Double(overlayDisplayWidthPt),
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
        let protectsHandoff = Self.isProtectedMutationRPC(method)
        if protectsHandoff {
            inFlightProtectedMutationCount += 1
        }
        defer {
            if protectsHandoff {
                inFlightProtectedMutationCount = max(
                    0,
                    inFlightProtectedMutationCount - 1
                )
            }
        }
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
            let result = try PetCoreClient.decodeResult(from: responseData)
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
            return result
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
        if method == "generation.history.list" || method == "generation.history.detail" {
            return false
        }
        return method.hasPrefix("generation.")
            || method.hasPrefix("pet.")
            || method.hasPrefix("petpack.")
            || method.hasPrefix("connections.")
            || method == "portable_skill.install"
            || method == "portable_skill.uninstall"
            || method == "behavior.patch"
            || method == "onboarding.update"
            || method == "overlay.placement.update"
            || method == "agent.session.acknowledge"
            || method == "diagnostics.export"
            || method == "product.convergence.update"
    }

    private static func isProtectedMutationRPC(_ method: String) -> Bool {
        switch method {
        case "behavior.patch",
             "onboarding.update",
             "overlay.placement.update",
             "agent.session.acknowledge",
             "pet.activate",
             "pet.delete",
             "pet.assets.repair",
             "petpack.import",
             "petpack.seed_bundled",
             "generation.start",
             "generation.retry",
             "generation.resume",
             "generation.edit",
             "generation.reply",
             "generation.cancel",
             "generation.history.delete",
             "connections.repair",
             "connections.uninstall",
             "connections.refresh_installed",
             "portable_skill.install",
             "portable_skill.uninstall",
             "product.convergence.update":
            true
        default:
            false
        }
    }

    private static func isPollingRPC(_ method: String) -> Bool {
        method == "state.wait" || method == "generation.messages.wait"
    }
}

private struct OverlayPlacementUpdateResponse {
    let ok: Bool
    let conflict: Bool
    let placement: OverlayPlacement
    let placementRevision: UInt64
    let intent: OverlayPlacementRemoteIntent?

    init(result: Any) throws {
        guard let object = result as? [String: Any],
              let ok = object["ok"] as? Bool,
              let encodedRevision = object["overlay_placement_revision"] as? String,
              let placementRevision = OverlayPlacementRevisionCodec.parse(
                  encodedRevision
              ),
              let placementObject = object["overlay_placement"] as? [String: Any],
              object.keys.contains("overlay_placement_intent") else {
            throw PetCoreClientError.invalidResponse
        }
        let placementData = try JSONSerialization.data(
            withJSONObject: placementObject
        )
        placement = try JSONDecoder().decode(
            OverlayPlacement.self,
            from: placementData
        )
        self.placementRevision = placementRevision
        self.ok = ok
        conflict = object["conflict"] as? Bool ?? false
        if object["overlay_placement_intent"] is NSNull {
            intent = nil
        } else if let encodedIntent = object["overlay_placement_intent"] as? String,
                  let decodedIntent = OverlayPlacementRemoteIntent(
                    rawValue: encodedIntent
                  ) {
            intent = decodedIntent
        } else {
            throw PetCoreClientError.invalidResponse
        }

        if ok {
            guard !conflict,
                  object["revision"] is String else {
                throw PetCoreClientError.invalidResponse
            }
        } else {
            guard conflict,
                  object["revision"] == nil else {
                throw PetCoreClientError.invalidResponse
            }
        }
    }
}

private struct StateSnapshot: Codable {
    var revision: String?
    var changed: Bool?
    var behavior: BehaviorSettings
    var behaviorRevision: String?
    var onboarding: VersionedOnboardingProgress?
    var overlayPlacement: OverlayPlacement?
    var overlayPlacementRevision: String
    var overlayPlacementIntent: OverlayPlacementRemoteIntent?
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
        case onboarding
        case overlayPlacement = "overlay_placement"
        case overlayPlacementRevision = "overlay_placement_revision"
        case overlayPlacementIntent = "overlay_placement_intent"
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
    var heartbeatAt: String?
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
        case heartbeatAt = "heartbeat_at"
        case messages
        case resultPetID = "result_pet_id"
        case revisionID = "revision_id"
        case validationSummary = "validation_summary"
    }
}
