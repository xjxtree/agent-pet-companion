import AgentPetCompanionCore
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct AppStoreBootstrapHooks {
    typealias EnsureRunning = @Sendable () async -> ServiceStartResult
    typealias Recover = @Sendable () async -> ServiceStartResult
    typealias RefreshSnapshot = @MainActor (AppStore) async throws -> Void
    typealias OnReady = @MainActor (AppStore) async -> Void

    let ensureRunning: EnsureRunning
    let recover: Recover
    let refreshSnapshot: RefreshSnapshot
    let onReady: OnReady
}

enum AgentSessionDeepLink {
    static func url(source: AgentSource?, sessionID: String?) -> URL? {
        guard source == .codex else { return nil }
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              sessionID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              })
        else {
            return nil
        }
        return URL(string: "codex://threads/\(sessionID)")
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
           let deepLink = AgentSessionDeepLink.url(source: source, sessionID: sessionID)
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

@MainActor
final class AppStore: ObservableObject {
    @Published var selection: NavigationSection = .studio
    @Published var studioTab: StudioTab = .new
    @Published private(set) var descriptionText = PetStudioDefaults.descriptionText
    @Published private(set) var selectedStyle: StylePreset = .semiRealistic
    @Published private(set) var selectedQuality: QualityLevel = .high
    @Published private(set) var referenceImages: [String] = []
    @Published var behavior = BehaviorSettings()
    @Published private(set) var activeAgentState: ActiveAgentState?
    @Published private(set) var activeAgentSessions: [ActiveAgentState] = []
    @Published private(set) var overlayVisibility = OverlayVisibility()
    @Published var pets: [PetSummary] = []
    @Published private(set) var petAssetWarningIndex = PetAssetWarningIndex()
    @Published var events: [AgentEvent] = []
    @Published var recentEvents: [AgentEvent] = []
    @Published var connections: [AgentConnectionStatus] = []
    @Published private(set) var generationSession = GenerationSession()
    @Published var generationReplyText = ""
    @Published var statusText = "正在初始化"
    @Published var serviceStatusText = "正在初始化"
    @Published var overlayScale = OverlayGeometry.defaultScale
    @Published var overlayVisible = true
    @Published var overlayScreenFrame = CGRect(x: 780, y: 140, width: 704, height: 640)
    @Published var overlayScreenVisibleFrame = NSScreen.main?.visibleFrame ?? .zero
    @Published var overlayPetScreenCenter = CGPoint.zero
    private(set) var overlayPetVisualEnvelope: OverlayPetVisualEnvelope?
    @Published var overlayBubbleDismissed = false
    @Published var overlayDismissedBubbleEventIDs: Set<String> = []
    @Published var overlayPointerNearPet = false
    @Published var overlayPetDragInProgress = false
    @Published var overlayResizeInProgress = false
    @Published var petOperationIDs: Set<String> = []
    @Published var isImportingPetpack = false
    @Published var connectionOperationSources: Set<AgentSource> = []

    private let client: PetCoreClient
    private let overlayController: PetOverlayController
    private let bootstrapHooks: AppStoreBootstrapHooks
    private var refreshTask: Task<Void, Never>?
    private var overlayPetPositionInitialized = false
    private var overlayPlacementLoaded = false
    private var isApplyingOverlayPlacement = false
    private var overlayPlacementSaveTask: Task<Void, Never>?
    private var stateRevision = ""
    private var behaviorRevision = "0"
    private var overlayKnownEventIDs: Set<String> = []
    private var overlayAwaitingVisibilityRestore = false
    private var behaviorMutationTask: Task<Void, Never>?
    private var mainWindowPresenter: (() -> Void)?
    private var pendingMainWindowPresentation = false
    private var generationMessagesTask: Task<Void, Never>?
    private var runtimeBootstrapCompleted = false
    private var runtimeBootstrapRetryTask: Task<Void, Never>?
    private var runtimeBootstrapRetryDelaySeconds: UInt64 = 2
    private var recoverySequence: UInt64 = 0
    private var serviceRecovery: (id: UInt64, task: Task<Bool, Never>)?

    init() {
        let processManager = PetCoreProcessManager()
        let bootstrapCoordinator = PetCoreAppBootstrapCoordinator(
            ensureRunning: { await processManager.ensureRunning() }
        )
        client = PetCoreClient()
        overlayController = PetOverlayController()
        bootstrapHooks = AppStoreBootstrapHooks(
            ensureRunning: { await bootstrapCoordinator.ensureRunning() },
            recover: { await bootstrapCoordinator.recover() },
            refreshSnapshot: { store in try await store.refreshSnapshot() },
            onReady: { store in await store.completeRuntimeBootstrap() }
        )
    }

    init(
        client: PetCoreClient = PetCoreClient(),
        bootstrapHooks: AppStoreBootstrapHooks
    ) {
        self.client = client
        overlayController = PetOverlayController()
        self.bootstrapHooks = bootstrapHooks
    }

    var activePet: PetSummary? {
        pets.first(where: \.active)
    }

    var activeOverlayEvent: AgentEvent? {
        activeAgentState?.event
    }

    var activeAgentEventText: String {
        activeOverlayEvent.map { "\($0.source.title) · \($0.title)" } ?? "暂无活跃 Agent 事件"
    }

    var overlayBubbleEvents: [AgentEvent] {
        activeAgentSessions
            .map(\.event)
            .filter { !overlayDismissedBubbleEventIDs.contains($0.id) }
    }

    var overlayBubbleContents: [OverlayBubbleContent] {
        guard overlayVisibility.statusBubbleVisible, !overlayBubbleDismissed else {
            return []
        }
        let visibleStates = activeAgentSessions.filter {
            !overlayDismissedBubbleEventIDs.contains($0.event.id)
        }
        let grouped = AgentSource.allCases.compactMap { source -> OverlayBubbleContent? in
            let states = visibleStates.filter { $0.source == source }
            return states.isEmpty ? nil : OverlayBubbleContent(source: source, states: states)
        }
        if !grouped.isEmpty {
            return grouped
        }
        return activeAgentState == nil && activeAgentSessions.isEmpty ? [.idle] : []
    }

    var canStartGeneration: Bool {
        !generationSession.isActive
            && !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isWaitingForGenerationInput: Bool {
        generationSession.state == .waitingForInput
    }

    var canSendGenerationReply: Bool {
        generationSession.canSendReply
    }

    var canRetryGeneration: Bool {
        generationSession.canRetry
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
        presenter()
        NSApp?.activate(ignoringOtherApps: true)
    }

    func presentMainWindow() {
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
        guard let application = NSApp,
              let window = application.windows.first(where: Self.isMainWindowCandidate)
        else {
            return false
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        isMainWindowCandidate(
            isPanel: window is NSPanel,
            level: window.level,
            styleMask: window.styleMask
        )
    }

    static func isMainWindowCandidate(
        isPanel: Bool,
        level: NSWindow.Level,
        styleMask: NSWindow.StyleMask
    ) -> Bool {
        !isPanel && level == .normal && styleMask.contains(.titled)
    }

    func bootstrapIfNeeded() async {
        guard !runtimeBootstrapCompleted else { return }
        setServiceStatus("正在检查本地服务版本与兼容性")
        switch await bootstrapHooks.ensureRunning() {
        case .alreadyHealthy, .started:
            setServiceStatus("本地服务运行中")
            guard !runtimeBootstrapCompleted else { return }
            runtimeBootstrapCompleted = true
            runtimeBootstrapRetryTask?.cancel()
            runtimeBootstrapRetryTask = nil
            runtimeBootstrapRetryDelaySeconds = 2
            await bootstrapHooks.onReady(self)
        case let .failed(reason):
            setServiceStatus(reason)
            scheduleRuntimeBootstrapRetry()
        }
    }

    private func scheduleRuntimeBootstrapRetry() {
        guard !runtimeBootstrapCompleted, runtimeBootstrapRetryTask == nil else { return }
        let delay = runtimeBootstrapRetryDelaySeconds
        runtimeBootstrapRetryDelaySeconds = min(delay * 2, 30)
        runtimeBootstrapRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.runtimeBootstrapRetryTask = nil
            await self.bootstrapIfNeeded()
        }
    }

    private func completeRuntimeBootstrap() async {
        overlayController.show(store: self)
        await refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.waitForStateChange()
            }
        }
    }

    func refresh() async {
        do {
            try await bootstrapHooks.refreshSnapshot(self)
            setServiceStatus("本地服务运行中")
        } catch {
            setServiceStatus("本地服务未连接")
            _ = await recoverServiceConnection()
        }
    }

    func recoverServiceConnection() async -> Bool {
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
        switch await bootstrapHooks.recover() {
        case .alreadyHealthy, .started:
            do {
                try await bootstrapHooks.refreshSnapshot(self)
                setServiceStatus("本地服务运行中")
                return true
            } catch {
                setServiceStatus("本地服务未连接")
                return false
            }
        case let .failed(reason):
            setServiceStatus(reason)
            return false
        }
    }

    private func refreshSnapshot() async throws {
        let result = try await requestPetCore(method: "state.snapshot")
        try applyStateSnapshot(result)
        setServiceStatus("本地服务运行中")
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
            setServiceStatus("本地服务运行中")
        } catch {
            setServiceStatus("本地服务未连接")
            if !(await recoverServiceConnection()) {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func setServiceStatus(_ value: String) {
        let shouldMirrorToStatus = statusText == serviceStatusText
            || statusText == "正在初始化"
            || statusText.hasPrefix("本地服务")
        serviceStatusText = value
        if shouldMirrorToStatus {
            statusText = value
        }
    }

    private func applyStateSnapshot(_ result: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: result)
        let snapshot = try JSONDecoder().decode(StateSnapshot.self, from: data)
        if let activeGeneration = snapshot.activeGeneration {
            reconcileActiveGeneration(activeGeneration)
        }
        let previousBehaviorEnabled = behavior.enabled
        let previousActiveEventID = activeAgentState?.event.id
        var nextEventIDs = Set(snapshot.events.map(\.id))
        if let activeEventID = snapshot.activeAgentState?.event.id {
            nextEventIDs.insert(activeEventID)
        }
        behavior = snapshot.behavior
        behaviorRevision = snapshot.behaviorRevision ?? behaviorRevision
        activeAgentState = snapshot.activeAgentState
        activeAgentSessions = snapshot.activeAgentSessions
            ?? snapshot.activeAgentState.map { [$0] }
            ?? []
        nextEventIDs.formUnion(activeAgentSessions.map(\.event.id))
        overlayVisibility = snapshot.overlayVisibility ?? OverlayVisibility(
            petVisible: snapshot.behavior.enabled,
            statusBubbleVisible: snapshot.behavior.enabled
                && snapshot.behavior.statusBubble
                && (!activeAgentSessions.isEmpty
                    || (!snapshot.behavior.autoHide && snapshot.activeAgentState == nil))
        )
        pets = snapshot.pets
        petAssetWarningIndex = PetAssetWarningIndex(snapshot.petAssetWarnings ?? [])
        events = snapshot.events
        let restoringOverlayVisibility = overlayAwaitingVisibilityRestore
        let hasNewOverlayEvent = !nextEventIDs.isSubset(of: overlayKnownEventIDs)
        if !snapshot.behavior.enabled {
            overlayAwaitingVisibilityRestore = true
            overlayKnownEventIDs.formUnion(nextEventIDs)
        } else if restoringOverlayVisibility, nextEventIDs.isEmpty {
            // PetCore can publish enabled=true before active session arbitration catches up.
            // Preserve manual dismissal state until the restored session set arrives.
        } else {
            overlayDismissedBubbleEventIDs.formIntersection(nextEventIDs)
            overlayKnownEventIDs = nextEventIDs
            overlayAwaitingVisibilityRestore = false
        }
        if hasNewOverlayEvent {
            overlayBubbleDismissed = false
        }
        if previousBehaviorEnabled,
           snapshot.behavior.enabled,
           !restoringOverlayVisibility,
           previousActiveEventID != activeAgentState?.event.id
        {
            overlayBubbleDismissed = false
        }
        recentEvents = snapshot.recentEvents ?? snapshot.events
        connections = mergedConnectionSnapshot(snapshot.connections)
        sortConnections()
        stateRevision = snapshot.revision ?? stateRevision
        let snapshotPlacement = snapshot.overlayPlacement ?? OverlayPlacement()
        if !overlayPlacementLoaded {
            applyOverlayPlacement(snapshotPlacement)
        } else if shouldApplyRemoteOverlayPlacement(snapshotPlacement) {
            applyOverlayPlacement(snapshotPlacement)
        }
        syncOverlayVisibilityForBehavior()
    }

    private func reconcileActiveGeneration(_ snapshot: ActiveGenerationSnapshot) {
        let previousJobID = generationSession.jobID
        _ = reduceGeneration(.restore(GenerationSessionRestore(snapshot: snapshot)))
        if previousJobID != snapshot.jobID {
            generationReplyText = ""
        }
    }

    func updateGenerationDescription(_ value: String) {
        guard !generationSession.isActive else { return }
        descriptionText = value
    }

    func selectGenerationStyle(_ style: StylePreset) {
        guard !generationSession.isActive else { return }
        selectedStyle = style
    }

    func selectGenerationQuality(_ quality: QualityLevel) {
        guard !generationSession.isActive else { return }
        selectedQuality = quality
    }

    func startGeneration() {
        guard canStartGeneration else {
            statusText = generationSession.isActive ? generationStateTitle : "请先填写宠物描述"
            return
        }
        let description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let form = GenerationForm(
            description: description,
            style: selectedStyle.rawValue,
            quality: selectedQuality,
            referenceImages: referenceImages
        )
        beginGeneration(with: form, initialMessage: "按表单创建一个\(selectedStyle.rawValue)桌宠。")
    }

    func startPetEdit(_ pet: PetSummary, instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            statusText = "请先填写希望如何修改宠物"
            return
        }
        guard instruction.count <= 8_000 else {
            statusText = "宠物修改要求不能超过 8000 个字符"
            return
        }
        guard !generationSession.isActive else {
            statusText = "请先完成或取消当前 AI 制作任务"
            return
        }

        let form = GenerationForm(
            description: "修改现有宠物“\(pet.name)”。用户要求：\(instruction)",
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
            petID: pet.id
        ))
        generationReplyText = ""
        selection = .studio
        studioTab = .new
        statusText = "正在建立 \(pet.name) 的修改会话"

        Task {
            do {
                let result = try await requestPetCore(
                    method: "generation.edit",
                    params: ["pet_id": pet.id, "instruction": instruction]
                )
                guard let dict = result as? [String: Any],
                      let jobID = dict["job_id"] as? String,
                      !jobID.isEmpty
                else {
                    throw PetCoreClientError.invalidResponse
                }
                _ = reduceGeneration(.startAccepted(jobID: jobID))
                statusText = "正在修改 \(pet.name)"
            } catch {
                let failure = GenerationMessage(
                    role: "assistant",
                    content: "修改启动失败：\(error.localizedDescription)",
                    progress: 1,
                    createdAt: "",
                    kind: "generation_failed"
                )
                _ = reduceGeneration(.startFailed(message: failure))
                statusText = "修改启动失败：\(error.localizedDescription)"
            }
        }
    }

    func clearStudioForm() {
        guard !generationSession.isActive else {
            statusText = "活动任务使用已提交表单，完成或取消后才能清空草稿"
            return
        }
        descriptionText = PetStudioDefaults.descriptionText
        referenceImages.removeAll()
        generationReplyText = ""
        statusText = "已清空新建表单"
    }

    func retryGeneration() {
        guard let form = generationSession.submittedForm else {
            startGeneration()
            return
        }
        guard generationSession.canRetry else {
            statusText = generationSession.isActive ? generationStateTitle : "当前会话不可重试"
            return
        }
        let modifying = generationSession.operation == .modify
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
            startPetEdit(pet, instruction: instruction)
            return
        }
        beginGeneration(
            with: form,
            initialMessage: modifying
                ? "重试上一轮宠物修改，并继续保留同一宠物 ID。"
                : "重试上一份表单创建一个\(form.style)桌宠。",
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
        resultPetID: String? = nil
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
                petID: resultPetID
            ))
        } else {
            _ = reduceGeneration(.startRequested(form: form, initialMessage: initialUserMessage))
        }
        generationReplyText = ""
        studioTab = .new

        Task {
            do {
                let formData = try JSONEncoder().encode(form)
                let formObject = try JSONSerialization.jsonObject(with: formData)
                let result: Any
                if let retryOfJobID {
                    result = try await requestPetCore(
                        method: "generation.retry",
                        params: [
                            "job_id": retryOfJobID,
                            "form": formObject
                        ]
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
                _ = reduceGeneration(.startAccepted(jobID: jobID))
            } catch {
                let action = operation == .modify ? "修改" : "生成"
                let failure = GenerationMessage(
                    role: "assistant",
                    content: "\(action)启动失败：\(error.localizedDescription)",
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
            await applyGenerationMessages(snapshot.messages, revision: snapshot.revision)
            return generationSession.isActive && generationSession.jobID == jobID
        } catch {
            statusText = "生成消息暂不可用"
            try? await Task.sleep(for: .seconds(1))
            return generationSession.isActive && generationSession.jobID == jobID
        }
    }

    private func applyGenerationMessages(
        _ messages: [GenerationMessage],
        revision: String? = nil
    ) async {
        let effects = reduceGeneration(.messagesReceived(messages, revision: revision))
        if effects.contains(.refreshSnapshot) {
            await refresh()
        }
        if generationSession.state == .succeeded {
            studioTab = .library
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

    func openGenerationHistory(for pet: PetSummary) {
        statusText = "正在打开 \(pet.name) 的生成会话"
        Task {
            do {
                let result = try await requestPetCore(
                    method: "generation.for_pet",
                    params: ["pet_id": pet.id]
                )
                let data = try JSONSerialization.data(withJSONObject: result)
                let history = try JSONDecoder().decode(GenerationHistory.self, from: data)
                guard history.found, let jobID = history.jobId else {
                    statusText = if pet.origin == .externalImport {
                        "\(pet.name) 是外部导入宠物，没有关联的 App 内生成会话"
                    } else {
                        "\(pet.name) 没有关联的生成会话"
                    }
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
                    resultPetID: history.resultPetId
                )
                _ = reduceGeneration(.restore(restore))
                generationReplyText = ""
                selection = .studio
                studioTab = .new
                statusText = "已打开 \(pet.name) 的生成会话"
            } catch {
                statusText = "打开生成会话失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func reduceGeneration(
        _ action: GenerationSessionAction
    ) -> GenerationSessionEffects {
        var next = generationSession
        let effects = next.reduce(action)
        generationSession = next
        if effects.contains(.stopMessageStream) {
            generationMessagesTask?.cancel()
        }
        if effects.contains(.startMessageStream), let jobID = generationSession.jobID {
            startGenerationMessageStream(jobID: jobID)
        }
        return effects
    }

    private func restoredGenerationState(
        status: String?,
        messages: [GenerationMessage]
    ) -> GenerationSessionState {
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
        return switch status {
        case "pending": .starting
        case "running": .running
        case "waiting_for_user": .waitingForInput
        case "completed": .succeeded
        case "failed": .failed
        case "canceled", "cancelled": .cancelled
        default: .idle
        }
    }

    func updateBehavior(_ next: BehaviorSettings) {
        let patch = BehaviorSettingsPatch(from: behavior, to: next)
        guard !patch.isEmpty else { return }
        behavior = next
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
                    behavior = updated.behavior
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
        overlayVisibility = OverlayVisibility(
            petVisible: behavior.enabled,
            statusBubbleVisible: behavior.enabled
                && behavior.statusBubble
                && (!activeAgentSessions.isEmpty || (!behavior.autoHide && activeAgentState == nil))
        )
        overlayVisible = overlayVisibility.petVisible
        overlayController.setVisible(overlayVisibility.petVisible)
        overlayController.updateLayout()
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
        let urls = panel.urls.filter { PetpackImportPolicy.acceptsFileName($0.lastPathComponent) }
        guard !urls.isEmpty else {
            statusText = "\(APCLocalization.text(.errorPetpackImportFailed))：\(APCLocalization.text(.libraryImportMessage))"
            return
        }

        isImportingPetpack = true
        statusText = urls.count == 1 ? "正在导入本 App .petpack" : "正在导入 \(urls.count) 个本 App .petpack"
        Task {
            defer { isImportingPetpack = false }
            var importedCount = 0
            var failures: [String] = []

            for url in urls {
                do {
                    _ = try await requestPetCore(
                        method: "petpack.import",
                        params: ["path": url.standardizedFileURL.path]
                    )
                    importedCount += 1
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }

            if importedCount > 0 {
                do {
                    try await refreshSnapshot()
                    studioTab = .library
                } catch {
                    await refresh()
                }
            }

            if failures.isEmpty {
                statusText = importedCount == 1 ? "已导入本 App .petpack" : "已导入 \(importedCount) 个本 App .petpack"
            } else if importedCount > 0 {
                statusText = "已导入 \(importedCount) 个，\(failures.count) 个失败：\(failures[0])"
            } else {
                statusText = "导入失败：\(failures.first ?? "请选择有效的本 App .petpack")"
            }
        }
    }

    func exportPet(_ pet: PetSummary) {
        let panel = NSSavePanel()
        panel.title = "导出本 App .petpack"
        panel.prompt = "导出"
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

    func repairConnection(_ source: AgentSource) {
        connectionOperationSources.insert(source)
        statusText = "正在修复 \(source.title)"
        Task {
            defer { connectionOperationSources.remove(source) }
            do {
                let result = try await requestPetCore(method: "connections.repair", params: ["source": source.rawValue])
                let status = try updateConnectionStatus(from: result)
                let unresolvedCount = unresolvedConnectionItemCount(status)
                statusText = unresolvedCount == 0
                    ? "\(source.title) 修复完成"
                    : "\(source.title) 修复已执行，仍有 \(unresolvedCount) 项待处理"
            } catch {
                statusText = "\(source.title) 修复失败：\(error.localizedDescription)"
                await refresh()
            }
        }
    }

    func repairConnections(_ sources: [AgentSource]) {
        let uniqueSources = AgentSource.allCases.filter { sources.contains($0) }
        guard !uniqueSources.isEmpty else {
            statusText = "没有需要修复的连接"
            return
        }
        for source in uniqueSources {
            connectionOperationSources.insert(source)
        }
        statusText = "正在修复 \(uniqueSources.count) 个 Agent 连接"
        Task {
            defer {
                for source in uniqueSources {
                    connectionOperationSources.remove(source)
                }
            }

            var repaired: [String] = []
            var pending: [String] = []
            var failed: [String] = []
            for source in uniqueSources {
                do {
                    let result = try await requestPetCore(method: "connections.repair", params: ["source": source.rawValue])
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
            if failed.isEmpty && pending.isEmpty {
                statusText = "连接修复完成：\(repaired.joined(separator: "、"))"
            } else if failed.isEmpty {
                statusText = "修复已执行，仍需处理：\(pending.joined(separator: "、"))"
            } else {
                statusText = "部分连接修复失败：\(failed.joined(separator: "、"))"
                await refresh()
            }
        }
    }

    func uninstallConnection(_ source: AgentSource) {
        connectionOperationSources.insert(source)
        statusText = "正在卸载 \(source.title)"
        Task {
            defer { connectionOperationSources.remove(source) }
            do {
                let result = try await requestPetCore(method: "connections.uninstall", params: ["source": source.rawValue])
                try updateConnectionStatus(from: result)
                statusText = "\(source.title) 已卸载"
            } catch {
                statusText = "\(source.title) 卸载失败：\(error.localizedDescription)"
                await refresh()
            }
        }
    }

    func uninstallConnections(_ sources: [AgentSource]) {
        let uniqueSources = AgentSource.allCases.filter { sources.contains($0) }
        guard !uniqueSources.isEmpty else {
            statusText = "没有可卸载的连接"
            return
        }
        for source in uniqueSources {
            connectionOperationSources.insert(source)
        }
        statusText = "正在卸载 \(uniqueSources.count) 个 Agent 连接"
        Task {
            defer {
                for source in uniqueSources {
                    connectionOperationSources.remove(source)
                }
            }

            var uninstalled: [String] = []
            var failed: [String] = []
            for source in uniqueSources {
                do {
                    let result = try await requestPetCore(
                        method: "connections.uninstall",
                        params: ["source": source.rawValue]
                    )
                    try updateConnectionStatus(from: result)
                    uninstalled.append(source.shortTitle)
                } catch {
                    failed.append(source.shortTitle)
                }
            }
            sortConnections()
            if failed.isEmpty {
                statusText = "连接卸载完成：\(uninstalled.joined(separator: "、"))"
            } else {
                statusText = "部分连接卸载失败：\(failed.joined(separator: "、"))"
                await refresh()
            }
        }
    }

    func checkConnection(_ source: AgentSource) {
        connectionOperationSources.insert(source)
        statusText = "正在检查 \(source.title)"
        Task {
            defer { connectionOperationSources.remove(source) }
            do {
                let result = try await requestPetCore(method: "connections.check", params: ["source": source.rawValue])
                try updateConnectionStatus(from: result)
                statusText = "\(source.title) 检查完成"
            } catch {
                statusText = "连接检查失败：\(error.localizedDescription)"
            }
        }
    }

    func checkAllConnections() {
        let sources = AgentSource.allCases
        for source in sources {
            connectionOperationSources.insert(source)
        }
        statusText = "正在检查 \(sources.count) 个 Agent 连接"
        Task {
            defer {
                for source in sources {
                    connectionOperationSources.remove(source)
                }
            }
            do {
                let result = try await requestPetCore(method: "connections.check")
                let data = try JSONSerialization.data(withJSONObject: result)
                connections = try JSONDecoder().decode([AgentConnectionStatus].self, from: data)
                sortConnections()
                statusText = "连接检查完成"
            } catch {
                statusText = "连接检查失败：\(error.localizedDescription)"
            }
        }
    }

    func sendConnectionTestEvent(_ source: AgentSource) {
        connectionOperationSources.insert(source)
        statusText = "正在测试 \(source.title) 的 PetCore 通道"
        Task {
            defer { connectionOperationSources.remove(source) }
            do {
                let result = try await requestPetCore(
                    method: "connections.test",
                    params: ["source": source.rawValue]
                )
                let ok = (result as? [String: Any])?["ok"] as? Bool ?? false
                await refresh()
                statusText = ok
                    ? "\(source.title) PetCore 通道自检通过（诊断事件不触发桌宠）"
                    : "\(source.title) PetCore 通道自检未通过"
            } catch {
                statusText = "\(source.title) PetCore 通道自检失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleOverlay() {
        var next = behavior
        next.enabled.toggle()
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
        guard (activeOverlayEvent?.id ?? "idle") == stateEntryID else { return }
        guard overlayPetVisualEnvelope != envelope else { return }
        overlayPetVisualEnvelope = envelope
        let visibleFrame = screen(containing: overlayPetScreenCenter)?.visibleFrame
            ?? overlayScreenVisibleFrame
        ensureOverlayPetPosition(in: visibleFrame)
        overlayController.updateLayoutDuringInteraction()
    }

    func toggleOverlayBubble() {
        if overlayBubbleContents.isEmpty {
            overlayBubbleDismissed = false
            overlayDismissedBubbleEventIDs.removeAll()
        } else {
            overlayBubbleDismissed = true
        }
        overlayController.updateLayout()
    }

    func dismissOverlayBubble(eventID: String) {
        if eventID == OverlayBubbleContent.idle.id {
            overlayBubbleDismissed = true
        } else {
            overlayDismissedBubbleEventIDs.insert(eventID)
        }
        overlayController.updateLayout()
    }

    func dismissOverlayBubble(eventIDs: [String]) {
        if eventIDs == OverlayBubbleContent.idle.eventIDs {
            overlayBubbleDismissed = true
        } else {
            overlayDismissedBubbleEventIDs.formUnion(eventIDs)
        }
        overlayController.updateLayout()
    }

    func dismissAllOverlayBubbles() {
        overlayBubbleDismissed = true
        overlayController.updateLayout()
    }

    func setOverlayPointerNearPet(_ value: Bool) {
        if overlayPointerNearPet != value {
            overlayPointerNearPet = value
            overlayController.refreshPointerPassthrough()
        }
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
        panel.title = "选择参考图"
        panel.prompt = "选择"
        panel.message = "选择用于角色形象或风格参考的图片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK else { return }
        addReferenceImageURLs(panel.urls)
    }

    func addReferenceImageURLs(_ urls: [URL]) {
        guard !generationSession.isActive else {
            statusText = "活动任务的参考图已冻结"
            return
        }
        var existing = Set(referenceImages)
        let imagePaths = urls
            .filter(Self.isSupportedImageURL)
            .map { $0.standardizedFileURL.path }
        var addedCount = 0

        for path in imagePaths where !existing.contains(path) {
            referenceImages.append(path)
            existing.insert(path)
            addedCount += 1
        }

        if imagePaths.isEmpty {
            statusText = "请选择图片文件"
        } else if addedCount == 0 {
            statusText = "参考图已在列表中"
        } else {
            statusText = "已添加 \(addedCount) 张参考图"
        }
    }

    func removeReferenceImage(_ path: String) {
        guard !generationSession.isActive else {
            statusText = "活动任务的参考图已冻结"
            return
        }
        referenceImages.removeAll { $0 == path }
        statusText = "已移除参考图"
    }

    private static func isSupportedImageURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path)
        else {
            return false
        }
        let fileExtension = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .image) {
            return true
        }
        return ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp"].contains(fileExtension)
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

    private func mergedConnectionSnapshot(_ snapshotConnections: [AgentConnectionStatus]) -> [AgentConnectionStatus] {
        let existingRuntime = Dictionary(
            uniqueKeysWithValues: connections
                .filter { $0.checkMode == .runtime }
                .map { ($0.source, $0) }
        )

        return snapshotConnections.map { incoming in
            let lightCheckFoundNoIssues = incoming.checkMode == .light
                && incoming.blockingItems.isEmpty
            if lightCheckFoundNoIssues, let runtime = existingRuntime[incoming.source] {
                return runtime
            }
            return incoming
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
        timeout: Duration = .seconds(5)
    ) async throws -> Any {
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
            throw PetCoreClientError.rpcError(String(describing: error["message"] ?? "Unknown PetCore error"))
        }
        return object["result"] ?? NSNull()
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
}
