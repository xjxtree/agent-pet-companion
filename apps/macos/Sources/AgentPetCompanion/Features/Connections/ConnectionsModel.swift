import AgentPetCompanionCore
import Foundation

@MainActor
final class ConnectionsModel: ObservableObject {
    typealias Request = @MainActor (
        _ method: String,
        _ params: Any,
        _ timeout: Duration?
    ) async throws -> Any
    typealias Availability = @MainActor () -> Bool
    typealias StatusSink = @MainActor (String) -> Void
    typealias FailureSink = @MainActor (
        AgentConnectionOperation,
        AgentConnectionOperationFailureReason
    ) -> Void
    typealias CheckedSink = @MainActor (Set<AgentSource>) -> Void
    typealias RefreshAfterMutationFailure = @MainActor () async -> Void

    @Published private(set) var connections: [AgentConnectionStatus] = []
    @Published private(set) var operationState = AgentConnectionOperationState.idle
    @Published private(set) var updateAttentionSources: [AgentSource] = []

    private var request: Request = { _, _, _ in
        throw AgentConnectionOperationExecutionError(.transportUnavailable)
    }
    private var operationIsAvailable: Availability = { true }
    private var statusSink: StatusSink = { _ in }
    private var failureSink: FailureSink = { _, _ in }
    private var checkedSink: CheckedSink = { _ in }
    private var refreshAfterMutationFailure: RefreshAfterMutationFailure = {}
    private var operationGate = AgentConnectionOperationGate()
    private var operationTask: Task<Void, Never>?
    private var automaticCheckRequested = false
    private var automaticCheckTask: Task<Void, Never>?

    var operationSources: Set<AgentSource> {
        Set(operationState.runningOperation?.sources ?? [])
    }

    var canStartOperation: Bool {
        !operationState.isRunning && operationIsAvailable()
    }

    func configure(
        request: @escaping Request,
        operationIsAvailable: @escaping Availability,
        statusSink: @escaping StatusSink,
        failureSink: @escaping FailureSink,
        checkedSink: @escaping CheckedSink,
        refreshAfterMutationFailure: @escaping RefreshAfterMutationFailure
    ) {
        self.request = request
        self.operationIsAvailable = operationIsAvailable
        self.statusSink = statusSink
        self.failureSink = failureSink
        self.checkedSink = checkedSink
        self.refreshAfterMutationFailure = refreshAfterMutationFailure
    }

    func replaceConnections(_ snapshot: [AgentConnectionStatus]) {
        let sorted = Self.sorted(snapshot)
        if connections != sorted {
            connections = sorted
        }
    }

    func applyUpdateAttention(_ attention: AppUpdateConvergenceAttention?) {
        let sources = attention?.sources ?? []
        if updateAttentionSources != sources {
            updateAttentionSources = sources
        }
    }

    func repair(_ source: AgentSource) {
        launch(.init(kind: .repair, sources: [source]))
    }

    func repair(_ sources: [AgentSource]) {
        launch(.init(kind: .repair, sources: sources))
    }

    func uninstall(_ source: AgentSource) {
        launch(.init(kind: .uninstall, sources: [source]))
    }

    func uninstall(_ sources: [AgentSource]) {
        launch(.init(kind: .uninstall, sources: sources))
    }

    func check(_ source: AgentSource) {
        launch(.init(kind: .check, sources: [source]))
    }

    func check(_ sources: [AgentSource]) {
        launch(.init(kind: .check, sources: sources))
    }

    func checkAll() {
        launch(.init(kind: .check, sources: AgentSource.allCases))
    }

    func sendTestEvent(_ source: AgentSource) {
        launch(.init(kind: .test, sources: [source]))
    }

    func retry() {
        guard let failure = operationState.failedOperation else { return }
        launch(failure.operation)
    }

    func dismissNotice() {
        guard !operationState.isRunning else { return }
        operationState = .idle
    }

    /// Defers the one automatic full check until the startup light snapshot is
    /// complete and the serialized operation gate is available.
    func requestAutomaticCheckOnFirstPresentation() {
        guard !automaticCheckRequested else { return }
        automaticCheckRequested = true
        automaticCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.hasLoadedAllSources, self.canStartOperation {
                    let alreadyCurrent = self.hasCurrentRuntimeStatusForEverySource
                    self.automaticCheckTask = nil
                    if !alreadyCurrent {
                        self.checkAll()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.automaticCheckTask = nil
        }
    }

    static func operationParameters(
        source: AgentSource? = nil
    ) -> [String: String] {
        source.map { ["source": $0.rawValue] } ?? [:]
    }

    static func failureReason(
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
            case .rpcError, .rpcErrorResponse:
                .rejected
            }
        }
        if error is PetCoreTransportError {
            return .transportUnavailable
        }
        return .unknown
    }

    private var hasLoadedAllSources: Bool {
        AgentSource.allCases.allSatisfy { source in
            connections.contains(where: { $0.source == source })
        }
    }

    private var hasCurrentRuntimeStatusForEverySource: Bool {
        AgentSource.allCases.allSatisfy { source in
            connections.first(where: { $0.source == source })?.checkMode == .runtime
        }
    }

    private func launch(_ operation: AgentConnectionOperation) {
        guard canStartOperation,
              let permit = operationGate.begin(operation)
        else { return }
        operationState = .running(operation)
        statusSink(startedStatus(operation))
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let completion = try await self.perform(operation)
                self.operationGate.finish(permit)
                self.operationState = .succeeded(operation)
                self.statusSink(completion)
            } catch {
                self.operationGate.finish(permit)
                let reason = Self.failureReason(for: error)
                self.failureSink(operation, reason)
                self.operationState = .failed(.init(
                    operation: operation,
                    reason: reason
                ))
                self.statusSink(self.failurePrefix(operation))
                if operation.kind == .repair || operation.kind == .uninstall {
                    await self.refreshAfterMutationFailure()
                }
            }
            self.operationTask = nil
        }
    }

    private func perform(_ operation: AgentConnectionOperation) async throws -> String {
        switch operation.kind {
        case .check:
            return try await performCheck(operation.sources)
        case .test:
            guard let source = operation.sources.first else {
                throw AgentConnectionOperationExecutionError(.invalidRequest)
            }
            let result = try await request(
                "connections.test",
                ["source": source.rawValue],
                .seconds(3)
            )
            guard (result as? [String: Any])?["ok"] as? Bool == true else {
                throw AgentConnectionOperationExecutionError(.rejected)
            }
            return "\(source.title) 本地连接测试通过"
        case .repair:
            return try await performRepair(operation.sources)
        case .uninstall:
            return try await performUninstall(operation.sources)
        }
    }

    private func performCheck(_ sources: [AgentSource]) async throws -> String {
        if sources == AgentSource.allCases {
            let result = try await request(
                "connections.check",
                Self.operationParameters(),
                nil
            )
            let data = try JSONSerialization.data(withJSONObject: result)
            replaceConnections(try JSONDecoder().decode([AgentConnectionStatus].self, from: data))
            checkedSink(Set(sources))
            return APCLocalization.text(.connectionsCheckDoneAll)
        }
        for source in sources {
            let result = try await request(
                "connections.check",
                Self.operationParameters(source: source),
                nil
            )
            try updateStatus(from: result)
        }
        checkedSink(Set(sources))
        return sources.count == 1
            ? APCLocalization.format(.connectionsCheckDoneOneFormat, sources[0].title)
            : APCLocalization.format(.connectionsCheckDoneCountFormat, sources.count)
    }

    private func performRepair(_ sources: [AgentSource]) async throws -> String {
        var repaired: [String] = []
        var pending: [String] = []
        var failed: [String] = []
        for source in sources {
            do {
                let result = try await request(
                    "connections.repair",
                    Self.operationParameters(source: source),
                    nil
                )
                let status = try updateStatus(from: result)
                if status.blockingItems.isEmpty {
                    repaired.append(source.shortTitle)
                } else {
                    pending.append(source.shortTitle)
                }
            } catch {
                failed.append(source.shortTitle)
            }
        }
        replaceConnections(connections)
        if !failed.isEmpty {
            throw AgentConnectionOperationExecutionError(.partialFailure)
        }
        return pending.isEmpty
            ? APCLocalization.format(.connectionsRepairDoneFormat, repaired.joined(separator: "、"))
            : APCLocalization.format(.connectionsRepairPendingFormat, pending.joined(separator: "、"))
    }

    private func performUninstall(_ sources: [AgentSource]) async throws -> String {
        var uninstalled: [String] = []
        var pending: [String] = []
        var failed: [String] = []
        for source in sources {
            do {
                let result = try await request(
                    "connections.uninstall",
                    ["source": source.rawValue],
                    nil
                )
                let status = try updateStatus(from: result)
                if status.hasInstalledConnectorArtifacts {
                    pending.append(source.shortTitle)
                } else {
                    uninstalled.append(source.shortTitle)
                }
            } catch {
                failed.append(source.shortTitle)
            }
        }
        replaceConnections(connections)
        if !failed.isEmpty {
            throw AgentConnectionOperationExecutionError(.partialFailure)
        }
        return pending.isEmpty
            ? APCLocalization.format(.connectionsUninstallDoneFormat, uninstalled.joined(separator: "、"))
            : APCLocalization.format(.connectionsUninstallPendingFormat, pending.joined(separator: "、"))
    }

    @discardableResult
    private func updateStatus(from result: Any) throws -> AgentConnectionStatus {
        let data = try JSONSerialization.data(withJSONObject: result)
        let status = try JSONDecoder().decode(AgentConnectionStatus.self, from: data)
        replaceConnections(connections.filter { $0.source != status.source } + [status])
        return status
    }

    private static func sorted(
        _ values: [AgentConnectionStatus]
    ) -> [AgentConnectionStatus] {
        values.sorted {
            let lhs = AgentSource.allCases.firstIndex(of: $0.source) ?? 0
            let rhs = AgentSource.allCases.firstIndex(of: $1.source) ?? 0
            return lhs < rhs
        }
    }

    private func startedStatus(_ operation: AgentConnectionOperation) -> String {
        let names = operation.sources.map(\.shortTitle).joined(separator: "、")
        return switch operation.kind {
        case .check: "正在检查 \(names)"
        case .test: "正在测试 \(names) 的 PetCore 通道"
        case .repair: "正在修复 \(names)"
        case .uninstall: "正在卸载 \(names)"
        }
    }

    private func failurePrefix(_ operation: AgentConnectionOperation) -> String {
        switch operation.kind {
        case .check: "连接检查失败"
        case .test: "通道自检失败"
        case .repair: "连接修复失败"
        case .uninstall: "连接卸载失败"
        }
    }
}
