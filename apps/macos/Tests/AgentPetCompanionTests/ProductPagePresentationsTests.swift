import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Product page presentations")
struct ProductPagePresentationsTests {
    @Test
    func libraryPrimaryActionDependsOnSelectionStateNotCopy() {
        let active = pet(id: "active", active: true)
        let inactive = pet(id: "inactive", active: false)

        let empty = PetLibraryProductPresentation(
            pets: [],
            selectedPet: nil
        )
        let validInactive = PetLibraryProductPresentation(
            pets: [active, inactive],
            selectedPet: inactive
        )
        let unavailableInactive = PetLibraryProductPresentation(
            pets: [active, inactive],
            selectedPet: inactive,
            selectedPetCanBeUsed: false
        )
        let activeSelection = PetLibraryProductPresentation(
            pets: [active, inactive],
            selectedPet: active
        )

        #expect(empty.primaryAction == .createPet)
        #expect(!empty.presentsHeroUseAction)
        #expect(validInactive.primaryAction == .usePet)
        #expect(validInactive.primaryActionIsEnabled)
        #expect(validInactive.presentsHeroUseAction)
        #expect(!unavailableInactive.primaryActionIsEnabled)
        #expect(!unavailableInactive.presentsHeroUseAction)
        #expect(activeSelection.primaryAction == .unavailable)
        #expect(!activeSelection.presentsHeroUseAction)
    }

    @Test
    func makerPhaseAndPrimaryActionCoverEverySessionState() {
        let cases: [(GenerationSession, PetMakerPhase, PetMakerPrimaryAction)] = [
            (.init(state: .idle), .describe, .createPet),
            (
                .init(state: .starting, jobID: "job"),
                .createTogether,
                .cancel
            ),
            (
                .init(state: .running, jobID: "job"),
                .createTogether,
                .cancel
            ),
            (
                .init(state: .waitingForInput, jobID: "job"),
                .createTogether,
                .sendReply
            ),
            (
                .init(state: .cancelling, jobID: "job"),
                .createTogether,
                .unavailable
            ),
            (
                .init(state: .succeeded, jobID: "job", resultPetID: "pet"),
                .result,
                .usePet
            ),
            (
                .init(
                    state: .failed,
                    jobID: "job",
                    submittedForm: generationForm
                ),
                .createTogether,
                .retry
            ),
            (
                .init(
                    state: .cancelled,
                    jobID: "job",
                    submittedForm: generationForm
                ),
                .createTogether,
                .retry
            ),
        ]

        for (session, phase, action) in cases {
            let presentation = PetMakerProductPresentation(
                session: session,
                resultPetAvailable: session.state == .succeeded
            )
            #expect(presentation.phase == phase)
            #expect(presentation.primaryAction == action)
        }

        let missingResult = PetMakerProductPresentation(
            session: .init(
                state: .succeeded,
                jobID: "job",
                resultPetID: "pet_missing"
            ),
            resultPetAvailable: false
        )
        #expect(missingResult.primaryAction == .unavailable)
        #expect(missingResult.secondaryActions.isEmpty)

        let previewNeedsRepair = PetMakerProductPresentation(
            session: .init(
                state: .succeeded,
                jobID: "job",
                resultPetID: "pet_result"
            ),
            resultPetAvailable: true,
            resultPreviewAvailable: false
        )
        #expect(previewNeedsRepair.phase == .result)
        #expect(previewNeedsRepair.primaryAction == .unavailable)
        #expect(previewNeedsRepair.secondaryActions.isEmpty)

        let reselect = PetMakerProductPresentation(
            session: .init(
                state: .failed,
                jobID: "job",
                submittedForm: generationForm
            ),
            resultPetAvailable: false,
            referenceReselectionCount: 2
        )
        #expect(reselect.primaryAction == .reselectReferences)
    }

    @Test
    func connectionPresentationUsesTypedAuthorityAndHidesProjectChecks() {
        let project = item(code: .projectDirectory, status: .missing)
        let runtime = ConnectionCheckItem(
            code: .hostRuntime,
            name: "/Applications/private/runtime",
            status: .ok,
            detail: "build-id secret-local-runtime"
        )
        let connector = item(
            code: .managedConnector,
            status: .missing,
            recovery: .confirmManagedRepair
        )
        let status = connectionStatus(
            items: [project, runtime, connector],
            installed: false,
            repairable: true,
            conflict: false
        )
        let presentation = AgentConnectionProductPresentation(
            source: .codex,
            status: status,
            operationState: .idle
        )

        #expect(presentation.health == .needsRepair)
        #expect(presentation.primaryAction == .connect)
        #expect(presentation.technicalItems.map(\.code) == [
            .hostVerification,
            .managedConnector,
        ])
        #expect(!String(describing: presentation).contains("/Applications/private"))
        #expect(!String(describing: presentation).contains("secret-local-runtime"))
        #expect(!presentation.canUninstall)

        let denied = AgentConnectionProductPresentation(
            source: .codex,
            status: connectionStatus(
                items: [connector],
                installed: true,
                repairable: nil,
                conflict: nil
            ),
            operationState: .idle
        )
        #expect(denied.primaryAction == .verify)
    }

    @Test
    func connectionOperationStateProducesCheckingOrTypedRetry() {
        let operation = AgentConnectionOperation(kind: .check, sources: [.codex])
        let running = AgentConnectionProductPresentation(
            source: .codex,
            status: nil,
            operationState: .running(operation)
        )
        let failed = AgentConnectionProductPresentation(
            source: .codex,
            status: nil,
            operationState: .failed(.init(
                operation: operation,
                reason: .transportUnavailable
            ))
        )

        #expect(running.health == .checking)
        #expect(running.primaryAction == .unavailable)
        #expect(failed.health == .notChecked)
        #expect(failed.primaryAction == .retry)
    }

    @Test
    func diagnosticsAggregateEveryOperationalState() {
        #expect(ServiceDiagnosticsProductPresentation(
            operationalState: .online
        ).primaryAction == .refresh)
        #expect(ServiceDiagnosticsProductPresentation(
            operationalState: .checking
        ).health == .checking)
        #expect(ServiceDiagnosticsProductPresentation(
            operationalState: .recovering
        ).primaryAction == .unavailable)
        #expect(ServiceDiagnosticsProductPresentation(
            operationalState: .offline
        ).primaryAction == .recover)
        #expect(ServiceDiagnosticsProductPresentation(
            operationalState: .runtimeMismatch
        ).health == .needsRecovery)
        #expect(ServiceDiagnosticsProductPresentation(
            operationalState: .error
        ).primaryAction == .retry)
    }

    private func pet(id: String, active: Bool) -> PetSummary {
        PetSummary(
            id: id,
            name: id,
            style: "modern",
            quality: .standard,
            renderSize: RenderSize(width: 192, height: 208),
            petpackPath: "/tmp/\(id).petpack",
            coverPath: "/tmp/\(id).png",
            active: active,
            createdAt: "2026-07-23T00:00:00Z"
        )
    }

    private var generationForm: GenerationForm {
        GenerationForm(
            description: "Pet",
            style: "modern",
            quality: .standard,
            referenceImages: []
        )
    }

    private func item(
        code: ConnectionCheckCode,
        status: CheckStatus,
        recovery: ConnectionCheckRecoveryKind? = nil
    ) -> ConnectionCheckItem {
        ConnectionCheckItem(
            code: code,
            name: "arbitrary",
            status: status,
            detail: "arbitrary",
            recoveryAction: recovery
        )
    }

    private func connectionStatus(
        items: [ConnectionCheckItem],
        installed: Bool,
        repairable: Bool?,
        conflict: Bool?
    ) -> AgentConnectionStatus {
        AgentConnectionStatus(
            source: .codex,
            items: items,
            installPaths: [],
            connectorInstalled: installed,
            verification: AgentVerification(
                status: .verified,
                title: "arbitrary",
                detail: "arbitrary"
            ),
            capabilities: AgentConnectorCapabilities(
                contractVersion: "typed-test-v1",
                subscribedEvents: [],
                mappedInformation: [],
                privacyExclusions: [],
                repairableConnectorIssue: repairable,
                managedPathConflict: conflict,
                canUninstallManagedConnector: false
            )
        )
    }
}
