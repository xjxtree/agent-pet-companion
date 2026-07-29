import AgentPetCompanionCore
import Foundation

struct PetLibraryProductPresentation: Equatable {
    let primaryAction: PetLibraryPrimaryAction
    let primaryActionIsEnabled: Bool

    var presentsHeroUseAction: Bool {
        primaryAction == .usePet && primaryActionIsEnabled
    }

    init(
        pets: [PetSummary],
        selectedPet: PetSummary?,
        selectedPetCanBeUsed: Bool = true
    ) {
        if pets.isEmpty {
            primaryAction = .createPet
            primaryActionIsEnabled = true
        } else if let selectedPet, !selectedPet.active {
            primaryAction = .usePet
            primaryActionIsEnabled = selectedPetCanBeUsed
        } else {
            primaryAction = .unavailable
            primaryActionIsEnabled = false
        }
    }
}

enum PetMakerPhase: Equatable {
    case describe
    case createTogether
    case result
}

struct PetMakerProductPresentation: Equatable {
    let phase: PetMakerPhase
    let primaryAction: PetMakerPrimaryAction
    let secondaryActions: [PetMakerPrimaryAction]

    init(
        session: GenerationSession,
        resultPetAvailable: Bool,
        resultPreviewAvailable: Bool = true,
        referenceReselectionCount: Int = 0
    ) {
        switch session.state {
        case .idle:
            phase = .describe
            primaryAction = .createPet
            secondaryActions = []
        case .starting, .running:
            phase = .createTogether
            primaryAction = session.canCancel ? .cancel : .unavailable
            secondaryActions = []
        case .waitingForInput:
            phase = .createTogether
            primaryAction = session.canSendReply ? .sendReply : .unavailable
            secondaryActions = session.canCancel ? [.cancel] : []
        case .cancelling:
            phase = .createTogether
            primaryAction = .unavailable
            secondaryActions = []
        case .succeeded:
            phase = .result
            primaryAction = resultPetAvailable && resultPreviewAvailable
                ? .usePet
                : .unavailable
            secondaryActions = resultPetAvailable && resultPreviewAvailable
                ? [.continueEditing]
                : []
        case .failed, .cancelled:
            phase = .createTogether
            if !session.canRetry {
                primaryAction = .unavailable
            } else if referenceReselectionCount > 0 {
                primaryAction = .reselectReferences
            } else {
                primaryAction = .retry
            }
            secondaryActions = []
        }
    }
}

struct AgentConnectionProductPresentation: Equatable {
    let source: AgentSource
    let health: AgentConnectionHealthState
    let taskVerification: AgentTaskVerificationState
    let primaryAction: AgentConnectionPrimaryAction
    let technicalItems: [AgentConnectionTechnicalItem]
    let managedComponents: [AgentManagedComponent]
    let hasCurrentTypedSnapshot: Bool
    let canRepairManagedConnector: Bool
    let canManageManagedConnector: Bool
    let canUninstall: Bool

    init(
        source: AgentSource,
        status: AgentConnectionStatus?,
        operationState: AgentConnectionOperationState
    ) {
        self.source = source
        let projectedItems = Self.projectedTechnicalItems(
            status?.items ?? [],
            source: source
        )
        technicalItems = projectedItems
        managedComponents = Self.projectedManagedComponents(
            status?.capabilities.managedComponents ?? []
        )
        hasCurrentTypedSnapshot = status.map(Self.hasCurrentTypedSnapshot) ?? false
        canManageManagedConnector = status?.canRepairManagedConnector == true
        canUninstall = status?.canUninstallManagedConnector == true

        let blockingItems = projectedItems.filter(\.status.isBlocking)
        let hasExecutableManagedRepair = blockingItems.contains {
            $0.code == .managedConnector
                && $0.recoveryAction == .confirmManagedRepair
        }
        let hasIndependentManagedMutationBlocker =
            Self.agentIsUnavailable(in: projectedItems)
            || projectedItems.contains(where: { $0.code == .unknown })
            || blockingItems.contains {
                switch $0.code {
                case .agentCLI, .eventCLI, .claudeHooksPolicy:
                    true
                default:
                    false
                }
            }
        canRepairManagedConnector = status?.hasRepairableConnectorIssue == true
            && hasExecutableManagedRepair
            && !hasIndependentManagedMutationBlocker
        taskVerification = Self.taskVerificationState(
            status: status,
            hasCurrentTypedSnapshot: hasCurrentTypedSnapshot
        )

        if case let .running(operation) = operationState,
           operation.sources.contains(source) {
            health = .checking
            primaryAction = .unavailable
            return
        }

        if case let .failed(failure) = operationState,
           failure.operation.sources.contains(source) {
            health = Self.localHealthState(
                status: status,
                hasCurrentTypedSnapshot: hasCurrentTypedSnapshot,
                projectedItems: projectedItems,
                blockingItems: blockingItems,
                canRepairManagedConnector: canRepairManagedConnector
            )
            primaryAction = .retry
            return
        }

        guard let status else {
            health = .notChecked
            primaryAction = .verify
            return
        }

        guard hasCurrentTypedSnapshot else {
            if canRepairManagedConnector {
                health = .needsRepair
                primaryAction = status.hasInstalledConnectorArtifacts ? .repair : .connect
            } else {
                health = .notChecked
                primaryAction = .verify
            }
            return
        }

        if projectedItems.contains(where: { $0.code == .unknown }) {
            health = .notChecked
            primaryAction = .verify
            return
        }

        if Self.agentIsUnavailable(in: projectedItems) {
            health = .unavailable
            primaryAction = .verify
            return
        }

        if !blockingItems.isEmpty {
            if canRepairManagedConnector {
                health = .needsRepair
                primaryAction = status.hasInstalledConnectorArtifacts ? .repair : .connect
            } else {
                health = .unavailable
                primaryAction = .verify
            }
            return
        }

        health = .connected
        primaryAction = .verify
    }

    private static func localHealthState(
        status: AgentConnectionStatus?,
        hasCurrentTypedSnapshot: Bool,
        projectedItems: [AgentConnectionTechnicalItem],
        blockingItems: [AgentConnectionTechnicalItem],
        canRepairManagedConnector: Bool
    ) -> AgentConnectionHealthState {
        guard status != nil, hasCurrentTypedSnapshot else {
            return .notChecked
        }
        if projectedItems.contains(where: { $0.code == .unknown }) {
            return .notChecked
        }
        if agentIsUnavailable(in: projectedItems) {
            return .unavailable
        }
        if !blockingItems.isEmpty {
            return canRepairManagedConnector ? .needsRepair : .unavailable
        }
        return .connected
    }

    private static func taskVerificationState(
        status: AgentConnectionStatus?,
        hasCurrentTypedSnapshot: Bool
    ) -> AgentTaskVerificationState {
        guard let status, hasCurrentTypedSnapshot else {
            return .notRun
        }
        return switch status.verification.status {
        case .verified:
            .verified
        case .actionRequired, .unverified:
            .awaitingTask
        case .notRequired:
            .notRun
        }
    }

    private static func hasCurrentTypedSnapshot(
        _ status: AgentConnectionStatus
    ) -> Bool {
        status.checkMode == .runtime
            && status.connectorInstalled != nil
            && !status.capabilities.contractVersion.isEmpty
            && status.capabilities.repairableConnectorIssue != nil
            && status.capabilities.canRepairManagedConnector != nil
            && status.capabilities.managedPathConflict != nil
            && status.capabilities.canUninstallManagedConnector != nil
            && !projectedTechnicalItems(
                status.items,
                source: status.source
            ).isEmpty
    }

    private static func agentIsUnavailable(
        in items: [AgentConnectionTechnicalItem]
    ) -> Bool {
        let agentDependencyUnavailable = items.contains {
            ($0.code == .agentCLI || $0.code == .agentVersion)
                && ($0.status == .missing || $0.status == .unsupported)
        }
        if agentDependencyUnavailable {
            return true
        }

        return items.allSatisfy {
            $0.status == .unsupported || $0.status == .notRequired
        }
    }

    private static func projectedTechnicalItems(
        _ items: [ConnectionCheckItem],
        source: AgentSource
    ) -> [AgentConnectionTechnicalItem] {
        // Compatibility-only project checks have no product or accessibility
        // projection. A legacy Agent-host runtime probe is retained only as
        // the safe Host Verification category; its raw name/detail and any
        // App/PetCore runtime identity never cross this presentation layer.
        let safeItems = items.filter {
            $0.code != .projectDirectory
        }

        // PetCore can report one managed-file or host-verification check per
        // artifact. Aggregate duplicate categories so Technical Details stays
        // bounded without weakening the worst typed result.
        let groupedCodes: Set<ConnectionCheckCode> = [
            .managedConnector,
            .hostVerification,
        ]
        var groupedIndexes: [ConnectionCheckCode: Int] = [:]
        var result: [AgentConnectionTechnicalItem] = []

        for item in safeItems {
            let projected = AgentConnectionTechnicalItem(
                code: item.code == .hostRuntime ? .hostVerification : item.code,
                status: item.status,
                recoveryAction: item.recoveryAction,
                evidence: safeTechnicalEvidence(for: item, source: source)
            )
            guard groupedCodes.contains(projected.code) else {
                result.append(projected)
                continue
            }

            if let index = groupedIndexes[projected.code] {
                if projected.status.connectionPriority
                    > result[index].status.connectionPriority {
                    result[index] = projected
                }
            } else {
                groupedIndexes[projected.code] = result.count
                result.append(projected)
            }
        }
        return result
    }

    private static func projectedManagedComponents(
        _ components: [AgentManagedComponent]
    ) -> [AgentManagedComponent] {
        Array(components.lazy.filter { component in
            guard component.ownership == .appManaged,
                  component.kind != .unknown,
                  !component.name.isEmpty,
                  component.name.count <= 80,
                  !component.name.contains("/"),
                  !component.name.contains("\\"),
                  !component.name.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  })
            else { return false }
            return [component.expectedVersion, component.activeVersion]
                .compactMap { $0 }
                .allSatisfy { version in
                    !version.isEmpty
                        && version.count <= 48
                        && version.unicodeScalars.allSatisfy {
                            CharacterSet(
                                charactersIn:
                                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+"
                            ).contains($0)
                        }
                }
        }.prefix(8))
    }

    private static func safeTechnicalEvidence(
        for item: ConnectionCheckItem,
        source: AgentSource
    ) -> AgentConnectionTechnicalEvidence? {
        if item.code == .agentVersion {
            return .agentVersion(
                source: source,
                detected: firstVersionToken(in: item.detail)
            )
        }

        guard source == .codex,
              item.code == .hostVerification,
              item.detail.hasPrefix("Codex hooks/list 精确检测："),
              let counts = codexHookTrustCounts(in: item.detail) else {
            return nil
        }
        return .codexHookTrust(
            disabled: counts[0],
            modified: counts[1],
            untrusted: counts[2],
            total: counts[3]
        )
    }

    private static func firstVersionToken(in detail: String) -> String? {
        let bounded = String(detail.prefix(512))
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,4}(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?)"#
        ),
        let match = expression.firstMatch(
            in: bounded,
            range: NSRange(bounded.startIndex..., in: bounded)
        ),
        let range = Range(match.range(at: 1), in: bounded) else {
            return nil
        }
        return String(bounded[range])
    }

    private static func codexHookTrustCounts(
        in detail: String
    ) -> [Int]? {
        let bounded = String(detail.prefix(512))
        guard let expression = try? NSRegularExpression(
            pattern: #"未启用 ([0-9]{1,3})、已修改 ([0-9]{1,3})、未信任 ([0-9]{1,3})（共 ([0-9]{1,3})）"#
        ),
        let match = expression.firstMatch(
            in: bounded,
            range: NSRange(bounded.startIndex..., in: bounded)
        ) else {
            return nil
        }
        let values = (1...4).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: bounded) else {
                return nil
            }
            return Int(bounded[range])
        }
        return values.count == 4 ? values : nil
    }
}

enum AgentConnectionTechnicalEvidence: Equatable {
    case agentVersion(source: AgentSource, detected: String?)
    case codexHookTrust(
        disabled: Int,
        modified: Int,
        untrusted: Int,
        total: Int
    )
}

struct AgentConnectionTechnicalItem: Equatable {
    let code: ConnectionCheckCode
    let status: CheckStatus
    let recoveryAction: ConnectionCheckRecoveryKind?
    let evidence: AgentConnectionTechnicalEvidence?

    init(_ item: ConnectionCheckItem) {
        code = item.code
        status = item.status
        recoveryAction = item.recoveryAction
        evidence = nil
    }

    init(
        code: ConnectionCheckCode,
        status: CheckStatus,
        recoveryAction: ConnectionCheckRecoveryKind?,
        evidence: AgentConnectionTechnicalEvidence? = nil
    ) {
        self.code = code
        self.status = status
        self.recoveryAction = recoveryAction
        self.evidence = evidence
    }
}

private extension CheckStatus {
    var connectionPriority: Int {
        switch self {
        case .missing: 5
        case .needsFix: 4
        case .unverified: 3
        case .unsupported: 2
        case .ok: 1
        case .notRequired: 0
        }
    }
}

enum ServiceDiagnosticsHealthState: Equatable {
    case checking
    case healthy
    case needsRecovery
    case unavailable
}

struct ServiceDiagnosticsProductPresentation: Equatable {
    let health: ServiceDiagnosticsHealthState
    let primaryAction: ServiceDiagnosticsPrimaryAction

    init(operationalState: PetCoreOperationalState) {
        switch operationalState {
        case .online:
            health = .healthy
            primaryAction = .refresh
        case .checking, .recovering:
            health = .checking
            primaryAction = .unavailable
        case .offline, .runtimeMismatch:
            health = .needsRecovery
            primaryAction = .recover
        case .error:
            health = .unavailable
            primaryAction = .retry
        }
    }
}
