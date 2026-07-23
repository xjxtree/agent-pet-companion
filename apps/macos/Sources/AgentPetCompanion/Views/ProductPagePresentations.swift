import AgentPetCompanionCore
import Foundation

struct PetLibraryProductPresentation: Equatable {
    let primaryAction: PetLibraryPrimaryAction
    let primaryActionIsEnabled: Bool

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
            primaryAction = resultPetAvailable ? .usePet : .unavailable
            secondaryActions = resultPetAvailable ? [.continueEditing] : []
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
    let primaryAction: AgentConnectionPrimaryAction
    let technicalItems: [AgentConnectionTechnicalItem]
    let hasCurrentTypedSnapshot: Bool
    let canRepairManagedConnector: Bool
    let canUninstall: Bool

    init(
        source: AgentSource,
        status: AgentConnectionStatus?,
        operationState: AgentConnectionOperationState
    ) {
        self.source = source
        let projectedItems = Self.projectedTechnicalItems(status?.items ?? [])
        technicalItems = projectedItems
        hasCurrentTypedSnapshot = status.map(Self.hasCurrentTypedSnapshot) ?? false
        canUninstall = status?.canUninstallManagedConnector == true

        let blockingItems = projectedItems.filter(\.status.isBlocking)
        let everyBlockingItemAuthorizesManagedRepair = !blockingItems.isEmpty
            && blockingItems.allSatisfy {
                $0.recoveryAction == .confirmManagedRepair
            }
        canRepairManagedConnector = status?.hasRepairableConnectorIssue == true
            && everyBlockingItemAuthorizesManagedRepair

        if case let .running(operation) = operationState,
           operation.sources.contains(source) {
            health = .checking
            primaryAction = .unavailable
            return
        }

        if case let .failed(failure) = operationState,
           failure.operation.sources.contains(source) {
            health = status == nil ? .unavailable : .needsRepair
            primaryAction = .retry
            return
        }

        guard let status else {
            health = .checking
            primaryAction = .unavailable
            return
        }

        guard hasCurrentTypedSnapshot else {
            health = .checking
            primaryAction = .verify
            return
        }

        if Self.agentIsUnavailable(in: projectedItems) {
            health = .unavailable
            primaryAction = .verify
            return
        }

        if !blockingItems.isEmpty {
            health = .needsRepair
            if canRepairManagedConnector {
                primaryAction = status.hasInstalledConnectorArtifacts ? .repair : .connect
            } else {
                primaryAction = .verify
            }
            return
        }

        if status.verification.status.requiresUserAction {
            health = .needsRepair
            primaryAction = .verify
            return
        }

        if projectedItems.contains(where: {
            $0.status == .unverified || $0.code == .unknown
        }) || status.verification.status == .unverified {
            health = .needsRepair
            primaryAction = .verify
            return
        }

        health = .connected
        primaryAction = .verify
    }

    private static func hasCurrentTypedSnapshot(
        _ status: AgentConnectionStatus
    ) -> Bool {
        status.checkMode == .runtime
            && status.connectorInstalled != nil
            && !status.capabilities.contractVersion.isEmpty
            && status.capabilities.repairableConnectorIssue != nil
            && status.capabilities.managedPathConflict != nil
            && status.capabilities.canUninstallManagedConnector != nil
            && !projectedTechnicalItems(status.items).isEmpty
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
        _ items: [ConnectionCheckItem]
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
                recoveryAction: item.recoveryAction
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
}

struct AgentConnectionTechnicalItem: Equatable {
    let code: ConnectionCheckCode
    let status: CheckStatus
    let recoveryAction: ConnectionCheckRecoveryKind?

    init(_ item: ConnectionCheckItem) {
        code = item.code
        status = item.status
        recoveryAction = item.recoveryAction
    }

    init(
        code: ConnectionCheckCode,
        status: CheckStatus,
        recoveryAction: ConnectionCheckRecoveryKind?
    ) {
        self.code = code
        self.status = status
        self.recoveryAction = recoveryAction
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
