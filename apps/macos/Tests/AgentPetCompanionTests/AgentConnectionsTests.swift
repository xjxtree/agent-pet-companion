import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct AgentConnectionsTests {
    @Test
    func pageKeepsTheFourSupportedAgentsInProductOrder() {
        #expect(
            AgentConnectionsCatalog.sources
                == [.codex, .claudeCode, .pi, .opencode]
        )
    }

    @Test
    func connectionOperationGateSerializesEveryActionKindAndPreservesRetryContext() throws {
        var gate = AgentConnectionOperationGate()
        let check = AgentConnectionOperation(kind: .check, sources: AgentSource.allCases)
        let test = AgentConnectionOperation(kind: .test, sources: [.codex])

        let initialPermit = gate.begin(check)
        let permit = try #require(initialPermit)
        #expect(gate.activeOperation == check)
        #expect(gate.begin(test) == nil)

        gate.finish(permit)
        let nextPermit = gate.begin(test)
        let testPermit = try #require(nextPermit)
        #expect(gate.activeOperation == test)
        gate.finish(testPermit)
        #expect(gate.activeOperation == nil)

        let failure = AgentConnectionOperationFailure(
            operation: .init(kind: .uninstall, sources: [.pi]),
            reason: .partialFailure
        )
        #expect(AgentConnectionOperationState.failed(failure).failedOperation == failure)
    }

    @Test
    func connectedSnapshotHasOneVerifyAction() throws {
        let status = currentStatus(
            items: [
                item(.ok, code: .managedConnector),
                item(.ok, code: .eventDelivery),
                item(.ok, code: .hostVerification),
            ],
            installed: true,
            verification: .verified
        )

        let presentation = product(status)
        #expect(presentation.health == .connected)
        #expect(presentation.taskVerification == .verified)
        #expect(presentation.primaryAction == .verify)
        #expect(presentation.hasCurrentTypedSnapshot)

        let action = try #require(
            AgentConnectionsPresentation.primaryActionPresentation(
                for: presentation,
                busy: false,
                locale: "en"
            )
        )
        #expect(action.action == .verify)
        #expect(action.title == "Verify")
        #expect(action.isEnabled)
    }

    @Test
    func realTaskEvidenceNeverDowngradesHealthyLocalChecksToNeedsRepair() {
        for verification in [
            AgentVerificationStatus.actionRequired,
            .unverified,
        ] {
            let presentation = product(currentStatus(
                items: [
                    item(.ok, code: .managedConnector),
                    item(.ok, code: .eventDelivery),
                ],
                verification: verification
            ))

            #expect(presentation.health == .connected)
            #expect(presentation.taskVerification == .awaitingTask)
            #expect(!presentation.canRepairManagedConnector)
            #expect(presentation.primaryAction == .verify)
        }

        let notRequired = product(currentStatus(
            items: [item(.ok, code: .managedConnector)],
            verification: .notRequired
        ))
        #expect(notRequired.health == .connected)
        #expect(notRequired.taskVerification == .notRun)
    }

    @Test
    func repairableManagedConnectorUsesTypedConnectOrRepairAuthority() {
        let missingConnector = item(
            .missing,
            code: .managedConnector,
            recovery: .confirmManagedRepair
        )

        let connect = product(currentStatus(
            items: [missingConnector],
            installed: false,
            repairable: true
        ))
        #expect(connect.health == .needsRepair)
        #expect(connect.primaryAction == .connect)
        #expect(connect.canRepairManagedConnector)

        let repair = product(currentStatus(
            items: [missingConnector],
            installed: true,
            repairable: true
        ))
        #expect(repair.health == .needsRepair)
        #expect(repair.primaryAction == .repair)
        #expect(repair.canRepairManagedConnector)
    }

    @Test
    func managedSetupEntryPersistsAfterTheConnectorIsHealthy() {
        let healthy = currentStatus(
            source: .codex,
            items: [
                item(.ok, code: .managedConnector),
                item(.ok, code: .eventDelivery),
            ],
            installPaths: ["/managed/codex"],
            installed: true,
            repairable: false,
            canManage: true,
            canUninstall: true
        )
        let presentation = product(healthy)

        #expect(presentation.health == .connected)
        #expect(!presentation.canRepairManagedConnector)
        #expect(presentation.canManageManagedConnector)
        #expect(
            AgentConnectionsPresentation.repairableStatuses(from: [healthy])
                .isEmpty
        )
        #expect(
            AgentConnectionsPresentation.manageableStatuses(from: [healthy])
                .map(\.source) == [.codex]
        )
    }

    @Test
    func hostVerificationAndVersionFollowUpDoNotHideManagedRepair() {
        let presentation = product(currentStatus(
            source: .pi,
            items: [
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
                item(
                    .needsFix,
                    code: .agentVersion,
                    recovery: .recheck
                ),
                item(
                    .needsFix,
                    code: .hostVerification,
                    recovery: .recheck
                ),
            ],
            installed: false,
            repairable: true
        ))

        #expect(presentation.health == .needsRepair)
        #expect(presentation.primaryAction == .connect)
        #expect(presentation.canRepairManagedConnector)
    }

    @Test
    func unavailableAgentDependencyDoesNotOfferManagedMutation() {
        let presentation = product(currentStatus(
            items: [
                item(.missing, code: .agentCLI, recovery: .recheck),
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
            ],
            installed: false,
            repairable: true,
            canManage: false
        ))

        #expect(presentation.health == .unavailable)
        #expect(presentation.primaryAction == .verify)
        #expect(!presentation.canRepairManagedConnector)
        #expect(!presentation.canManageManagedConnector)
    }

    @Test
    func missingEventCLIBlocksManagedMutation() {
        let presentation = product(currentStatus(
            items: [
                item(
                    .missing,
                    code: .eventCLI,
                    recovery: .recheck
                ),
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
            ],
            installed: false,
            repairable: true,
            canManage: false
        ))

        #expect(presentation.health == .unavailable)
        #expect(presentation.primaryAction == .verify)
        #expect(!presentation.canRepairManagedConnector)
        #expect(!presentation.canManageManagedConnector)
    }

    @Test
    func notCheckedAndCheckingRemainDistinct() {
        let noSnapshot = product(nil)
        #expect(noSnapshot.health == .notChecked)
        #expect(noSnapshot.taskVerification == .notRun)
        #expect(noSnapshot.primaryAction == .verify)

        let operation = AgentConnectionOperation(kind: .check, sources: [.codex])
        let running = AgentConnectionProductPresentation(
            source: .codex,
            status: currentStatus(items: [item(.ok, code: .managedConnector)]),
            operationState: .running(operation)
        )
        #expect(running.health == .checking)
        #expect(running.primaryAction == .unavailable)

        let light = product(AgentConnectionStatus(
            source: .codex,
            items: [item(.ok, code: .agentCLI)],
            installPaths: [],
            connectorInstalled: true,
            checkMode: .light,
            verification: verification(.verified),
            capabilities: capabilities(
                repairable: false,
                conflict: false,
                canUninstall: true
            )
        ))
        #expect(light.health == .notChecked)
        #expect(light.taskVerification == .notRun)
        #expect(light.primaryAction == .verify)
    }

    @Test
    func typedLightSnapshotCanOfferManagedSetupWithoutClaimingRuntimeVerification() {
        let presentation = product(AgentConnectionStatus(
            source: .codex,
            items: [
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
                item(
                    .needsFix,
                    code: .hostVerification,
                    recovery: .recheck
                ),
            ],
            installPaths: ["/managed/codex"],
            connectorInstalled: false,
            checkMode: .light,
            verification: verification(.verified),
            capabilities: capabilities(
                repairable: true,
                conflict: false,
                canUninstall: false
            )
        ))

        #expect(!presentation.hasCurrentTypedSnapshot)
        #expect(presentation.taskVerification == .notRun)
        #expect(presentation.health == .needsRepair)
        #expect(presentation.primaryAction == .connect)
        #expect(presentation.canRepairManagedConnector)
    }

    @Test
    func managedPathConflictFailsClosedToVerify() {
        let presentation = product(currentStatus(
            items: [
                item(
                    .needsFix,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
            ],
            installed: true,
            repairable: true,
            canManage: false,
            conflict: true,
            canUninstall: true
        ))

        #expect(presentation.health == .unavailable)
        #expect(presentation.primaryAction == .verify)
        #expect(!presentation.canRepairManagedConnector)
        #expect(!presentation.canUninstall)
    }

    @Test
    func policyRestrictedStateNeverBorrowsConnectorWideRepairCapability() {
        let policyOnly = product(currentStatus(
            source: .claudeCode,
            items: [
                item(
                    .needsFix,
                    code: .claudeHooksPolicy,
                    recovery: .recheck
                ),
            ],
            installed: true,
            repairable: true,
            canManage: false
        ))
        #expect(policyOnly.health == .unavailable)
        #expect(policyOnly.primaryAction == .verify)
        #expect(!policyOnly.canRepairManagedConnector)

        let policyAndConnector = product(currentStatus(
            source: .claudeCode,
            items: [
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
                item(
                    .needsFix,
                    code: .claudeHooksPolicy,
                    recovery: .recheck
                ),
            ],
            installed: true,
            repairable: true,
            canManage: false
        ))
        #expect(policyAndConnector.primaryAction == .verify)
        #expect(policyAndConnector.health == .unavailable)
        #expect(!policyAndConnector.canRepairManagedConnector)
    }

    @Test
    func oneClickSetupUsesTheSameTypedPerAgentRepairBoundary() {
        let repairable = currentStatus(
            source: .codex,
            items: [
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
                item(
                    .needsFix,
                    code: .hostVerification,
                    recovery: .recheck
                ),
            ],
            installPaths: ["/managed/codex"],
            installed: false,
            repairable: true
        )
        let policyBlocked = currentStatus(
            source: .claudeCode,
            items: [
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
                item(
                    .needsFix,
                    code: .claudeHooksPolicy,
                    recovery: .recheck
                ),
            ],
            installPaths: ["/managed/claude"],
            installed: false,
            repairable: true,
            canManage: false
        )

        let eligible = AgentConnectionsPresentation.repairableStatuses(
            from: [policyBlocked, repairable]
        )
        #expect(eligible.map(\.source) == [.codex])

        let message = AgentConnectionsPresentation.managedRepairConfirmationMessage(
            for: eligible,
            locale: "en"
        )
        #expect(message.contains("Codex"))
        #expect(message.contains("/managed/codex"))
        #expect(!message.contains("Claude"))
        #expect(!message.contains("/managed/claude"))
    }

    @Test
    func singleAgentSuccessFeedbackIsSpecificAndDoesNotLeakAcrossRows() {
        for (kind, expected) in [
            (
                AgentConnectionOperationKind.check,
                "Connection check finished. The local health and real-task evidence above are up to date."
            ),
            (
                .test,
                "Local channel test passed. This proves only the on-device CLI, RPC, and event path—not a real Agent task."
            ),
            (
                .repair,
                "The managed connector was installed or repaired and checked again."
            ),
            (
                .uninstall,
                "The App-managed connector files were removed. The Agent itself was not uninstalled."
            ),
        ] {
            let operation = AgentConnectionOperation(
                kind: kind,
                sources: [.codex]
            )
            let state = AgentConnectionOperationState.succeeded(operation)
            #expect(
                AgentConnectionsPresentation.success(
                    for: .codex,
                    in: state
                ) == operation
            )
            #expect(
                AgentConnectionsPresentation.success(for: .pi, in: state)
                    == nil
            )
            #expect(
                AgentConnectionsPresentation.operationSuccessDetail(
                    operation,
                    locale: "en"
                ) == expected
            )
        }

        let bulk = AgentConnectionOperation(
            kind: .repair,
            sources: [.codex, .pi]
        )
        #expect(
            AgentConnectionsPresentation.success(
                for: .codex,
                in: .succeeded(bulk)
            ) == nil
        )
    }

    @Test
    func legacyAndIncompleteSnapshotsCannotClaimConnectedOrMutationAuthority() {
        let legacy = product(AgentConnectionStatus(
            source: .codex,
            items: [item(.ok, code: .managedConnector)],
            installPaths: ["/legacy/managed"],
            connectorInstalled: nil,
            verification: verification(.verified),
            capabilities: .empty
        ))
        #expect(legacy.health == .notChecked)
        #expect(legacy.primaryAction == .verify)
        #expect(!legacy.hasCurrentTypedSnapshot)
        #expect(!legacy.canRepairManagedConnector)
        #expect(!legacy.canUninstall)

        let incomplete = product(currentStatus(items: []))
        #expect(incomplete.health == .notChecked)
        #expect(incomplete.primaryAction == .verify)
        #expect(!incomplete.hasCurrentTypedSnapshot)
    }

    @Test
    func unknownCheckFailsClosedWithoutUsingHumanCopy() {
        let status = currentStatus(items: [
            ConnectionCheckItem(
                code: .unknown,
                name: "Install immediately",
                status: .ok,
                detail: "repairable=true",
                recoveryAction: .confirmManagedRepair
            ),
        ])
        let presentation = product(status)

        #expect(presentation.health == .notChecked)
        #expect(presentation.primaryAction == .verify)
        #expect(!presentation.canRepairManagedConnector)
        #expect(
            AgentConnectionsPresentation.itemDisplayName(
                for: presentation.technicalItems[0],
                locale: "en"
            ) == "Connection Check"
        )
    }

    @MainActor
    @Test
    func failedOperationIsInlineAndRetryableWithoutRawErrorCopy() {
        let failure = AgentConnectionOperationFailure(
            operation: .init(kind: .repair, sources: [.codex]),
            reason: .rejected
        )
        let operationState = AgentConnectionOperationState.failed(failure)
        let presentation = AgentConnectionProductPresentation(
            source: .codex,
            status: currentStatus(items: [item(.ok, code: .managedConnector)]),
            operationState: operationState
        )

        #expect(presentation.health == .connected)
        #expect(presentation.taskVerification == .verified)
        #expect(presentation.primaryAction == .retry)
        #expect(
            AgentConnectionsPresentation.failure(
                for: .codex,
                in: operationState
            ) == failure
        )
        #expect(
            AgentConnectionsPresentation.failure(
                for: .pi,
                in: operationState
            ) == nil
        )

        let raw = "failed /Users/alice/private --token secret"
        let reason = AppStore.connectionOperationFailureReason(
            for: PetCoreClientError.rpcError(raw)
        )
        let copy = AgentConnectionsPresentation.operationFailureDetail(
            reason,
            locale: "en"
        )
        #expect(!copy.contains(raw))
        #expect(!copy.contains("/Users/"))
        #expect(!copy.contains("secret"))
    }

    @Test
    func uninstallRequiresExplicitManagedCapabilityAndNoConflict() {
        let allowed = product(currentStatus(
            items: [item(.ok, code: .managedConnector)],
            installed: true,
            canUninstall: true
        ))
        #expect(allowed.canUninstall)

        let deniedByMissingCapability = product(currentStatus(
            items: [item(.ok, code: .managedConnector)],
            installed: true,
            canUninstall: nil
        ))
        #expect(!deniedByMissingCapability.canUninstall)

        let deniedByConflict = product(currentStatus(
            items: [item(.ok, code: .managedConnector)],
            installed: true,
            conflict: true,
            canUninstall: true
        ))
        #expect(!deniedByConflict.canUninstall)
    }

    @Test
    func technicalProjectionIsBoundedTypedAndHidesForbiddenFields() {
        let managedOK = item(.ok, code: .managedConnector)
        let managedMissing = item(
            .missing,
            code: .managedConnector,
            recovery: .confirmManagedRepair
        )
        let status = currentStatus(
            items: [
                ConnectionCheckItem(
                    code: .projectDirectory,
                    name: "/Users/alice/project",
                    status: .needsFix,
                    detail: "choose_project_directory",
                    recoveryAction: .chooseProjectDirectory
                ),
                ConnectionCheckItem(
                    code: .hostRuntime,
                    name: "Runtime Identity",
                    status: .ok,
                    detail: "build-id secret-runtime"
                ),
                managedOK,
                managedMissing,
                item(.unverified, code: .hostVerification),
                item(.unverified, code: .hostVerification),
                item(.ok, code: .eventDelivery),
                item(.unsupported, code: .appServer),
            ],
            installPaths: ["/Users/alice/project/private"],
            repairable: true
        )
        let presentation = product(status)

        #expect(presentation.technicalItems.map(\.code) == [
            .hostVerification,
            .managedConnector,
            .eventDelivery,
            .appServer,
        ])
        #expect(presentation.technicalItems[1].status == .missing)

        let projectionDescription = String(describing: presentation)
        for forbidden in [
            "/Users/alice/project",
            "Runtime Identity",
            "secret-runtime",
            "choose_project_directory",
        ] {
            #expect(!projectionDescription.contains(forbidden))
        }
    }

    @Test
    func technicalProjectionShowsActionableEvidenceWithoutRawDiagnosticCopy() throws {
        let pi = product(currentStatus(
            source: .pi,
            items: [
                ConnectionCheckItem(
                    code: .agentVersion,
                    name: "Pi version /Users/alice/private",
                    status: .needsFix,
                    detail: "检测到 pi 0.79.9，低于当前连接器最低版本 0.80.10 /Users/alice/private --token secret",
                    recoveryAction: .recheck
                ),
            ]
        ))
        let piItem = try #require(pi.technicalItems.first)
        #expect(
            piItem.evidence
                == .agentVersion(source: .pi, detected: "0.79.9")
        )
        let piCopy = try #require(
            AgentConnectionsPresentation.itemEvidenceDetail(
                for: piItem,
                locale: "zh-Hans"
            )
        )
        #expect(piCopy.contains("0.79.9"))
        #expect(piCopy.contains("0.80.10"))
        #expect(piCopy.contains("更新 Pi Coding Agent"))
        #expect(!piCopy.contains("/Users/"))
        #expect(!piCopy.contains("token"))
        #expect(!piCopy.contains("secret"))

        let codex = product(currentStatus(
            source: .codex,
            items: [
                ConnectionCheckItem(
                    code: .hostVerification,
                    name: "Codex Hook Trust",
                    status: .needsFix,
                    detail: "Codex hooks/list 精确检测：未启用 0、已修改 0、未信任 10（共 10）；/Users/alice/private",
                    recoveryAction: .recheck
                ),
            ]
        ))
        let codexItem = try #require(codex.technicalItems.first)
        #expect(
            codexItem.evidence
                == .codexHookTrust(
                    disabled: 0,
                    modified: 0,
                    untrusted: 10,
                    total: 10
                )
        )
        let codexCopy = try #require(
            AgentConnectionsPresentation.itemEvidenceDetail(
                for: codexItem,
                locale: "zh-Hans"
            )
        )
        #expect(codexCopy.contains("未信任 10"))
        #expect(codexCopy.contains("Codex"))
        #expect(!codexCopy.contains("/Users/"))
    }

    @Test
    func ordinaryAndAccessibilityCopyExcludeRuntimeRendererDiagnosticsAndProjectData() throws {
        let status = currentStatus(
            items: [
                ConnectionCheckItem(
                    code: .managedConnector,
                    name: "Renderer / Runtime Identity",
                    status: .ok,
                    detail: "Export Diagnostics /Users/alice/project"
                ),
            ],
            installPaths: ["/Users/alice/project"],
            verification: .verified
        )
        let presentation = product(status)
        let primary = try #require(
            AgentConnectionsPresentation.primaryActionPresentation(
                for: presentation,
                busy: false,
                locale: "en"
            )
        )
        let ordinaryAndAXCopy = [
            APCLocalization.text(.connectionsPageTitle, locale: "en"),
            APCLocalization.text(.connectionsPageSubtitle, locale: "en"),
            presentation.source.title,
            APCLocalizedPresentation.connectionHealthTitle(
                presentation.health,
                locale: "en"
            ),
            AgentConnectionsPresentation.healthSummary(
                for: presentation,
                operationState: .idle,
                locale: "en"
            ),
            primary.title,
            primary.accessibilityLabel,
            primary.accessibilityHint ?? "",
        ].joined(separator: " ")

        for forbidden in [
            "Runtime Identity",
            "Renderer",
            "Export Diagnostics",
            "/Users/alice/project",
            "project_directory",
            "choose_project_directory",
        ] {
            #expect(!ordinaryAndAXCopy.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test
    func localChannelAndRealTaskValidationUseDistinctTruthfulCopy() {
        let boundary = APCLocalization.text(
            .connectionsValidationBoundary,
            locale: "en"
        )
        let local = APCLocalization.text(
            .connectionsLocalChannelDetail,
            locale: "en"
        )
        let real = AgentConnectionsPresentation.verificationDetail(
            .actionRequired,
            locale: "en"
        )

        #expect(boundary.contains("on-device event path"))
        #expect(boundary.contains("real provider task"))
        #expect(local.contains("does not contact the provider"))
        #expect(local.contains("does not") && local.contains("real Agent task"))
        #expect(real.contains("Run a real task"))
        #expect(real.contains("Verify"))
        #expect(local != real)
    }

    @Test
    func primaryActionsDisableDuringAnotherSerializedOperation() throws {
        let presentation = product(currentStatus(
            items: [item(.ok, code: .managedConnector)]
        ))
        let action = try #require(
            AgentConnectionsPresentation.primaryActionPresentation(
                for: presentation,
                busy: true,
                locale: "en"
            )
        )
        #expect(!action.isEnabled)
        #expect(
            action.accessibilityHint
                == "Wait for the current connection operation to finish."
        )
    }

    private func product(
        _ status: AgentConnectionStatus?,
        operationState: AgentConnectionOperationState = .idle
    ) -> AgentConnectionProductPresentation {
        AgentConnectionProductPresentation(
            source: status?.source ?? .codex,
            status: status,
            operationState: operationState
        )
    }

    private func currentStatus(
        source: AgentSource = .codex,
        items: [ConnectionCheckItem],
        installPaths: [String] = [],
        installed: Bool = true,
        verification: AgentVerificationStatus = .verified,
        repairable: Bool? = false,
        canManage: Bool? = true,
        conflict: Bool? = false,
        canUninstall: Bool? = false
    ) -> AgentConnectionStatus {
        AgentConnectionStatus(
            source: source,
            items: items,
            installPaths: installPaths,
            connectorInstalled: installed,
            checkMode: .runtime,
            verification: self.verification(verification),
            capabilities: capabilities(
                repairable: repairable,
                canManage: canManage,
                conflict: conflict,
                canUninstall: canUninstall
            )
        )
    }

    private func item(
        _ status: CheckStatus,
        code: ConnectionCheckCode,
        recovery: ConnectionCheckRecoveryKind? = nil
    ) -> ConnectionCheckItem {
        ConnectionCheckItem(
            code: code,
            name: "untrusted-name",
            status: status,
            detail: "untrusted-detail",
            recoveryAction: recovery
        )
    }

    private func capabilities(
        repairable: Bool?,
        canManage: Bool? = true,
        conflict: Bool?,
        canUninstall: Bool?
    ) -> AgentConnectorCapabilities {
        AgentConnectorCapabilities(
            contractVersion: "typed-test-v1",
            subscribedEvents: [],
            mappedInformation: [],
            privacyExclusions: [],
            repairableConnectorIssue: repairable,
            canRepairManagedConnector: canManage,
            managedPathConflict: conflict,
            canUninstallManagedConnector: canUninstall
        )
    }

    private func verification(
        _ status: AgentVerificationStatus
    ) -> AgentVerification {
        AgentVerification(
            status: status,
            title: "untrusted-verification-title",
            detail: "untrusted-verification-detail",
            actionDetail: "/Users/alice/project"
        )
    }
}
