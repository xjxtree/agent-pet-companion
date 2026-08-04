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

    @MainActor
    @Test
    func connectionTestIsBoundedAndDoesNotWaitForSnapshotRefresh() async throws {
        var requests: [(source: String, timeout: Duration?)] = []
        var snapshotRefreshCount = 0
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in
                    snapshotRefreshCount += 1
                },
                onReady: { _ in }
            ),
            petCoreRequestOverride: { method, params, timeout in
                #expect(method == "connections.test")
                let source = try #require(
                    (params as? [String: String])?["source"]
                )
                requests.append((source, timeout))
                return ["ok": true]
            },
            productConvergenceManifest: nil
        )

        for source in AgentSource.allCases {
            store.sendConnectionTestEvent(source)
            #expect(
                store.connectionOperationState.runningOperation?.sources
                    == [source]
            )

            for _ in 0 ..< 100
            where store.connectionOperationState.succeededOperation == nil {
                await Task.yield()
            }

            #expect(
                store.connectionOperationState.succeededOperation
                    == AgentConnectionOperation(
                        kind: .test,
                        sources: [source]
                    )
            )
            store.dismissConnectionOperationNotice()
        }

        #expect(requests.map(\.source) == AgentSource.allCases.map(\.rawValue))
        #expect(requests.allSatisfy { $0.timeout == .seconds(3) })
        #expect(snapshotRefreshCount == 0)
        #expect(store.canStartConnectionOperation)
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
    func connectedSnapshotKeepsRoutineActionsInMoreMenu() throws {
        let status = currentStatus(
            items: [
                item(.ok, code: .managedConnector),
                item(.ok, code: .eventDelivery),
                item(.ok, code: .hostVerification),
            ],
            installed: true,
            verification: .verified,
            canUninstall: true
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
        #expect(action.title == "Check Connection")
        #expect(action.isEnabled)

        let layout = AgentConnectionsPresentation.actionLayout(
            for: presentation
        )
        #expect(layout.primaryAction == nil)
        #expect(
            layout.moreActions
                == [.recheck, .sendTestMessage, .setUpAgain, .remove]
        )
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

        let layout = AgentConnectionsPresentation.actionLayout(for: repair)
        #expect(layout.primaryAction == .repair)
        #expect(layout.moreActions == [.recheck, .sendTestMessage])
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
    func unavailableCardsShowOnlyActionableUserGuidance() throws {
        let missingAgent = product(currentStatus(
            source: .claudeCode,
            items: [item(.missing, code: .agentCLI)]
        ))
        #expect(
            AgentConnectionsPresentation.healthTitle(
                for: missingAgent,
                locale: "en"
            ) == "Agent Not Found"
        )
        #expect(
            AgentConnectionsPresentation.healthSummary(
                for: missingAgent,
                operationState: .idle,
                locale: "en"
            ) == "Claude Code was not found on this Mac."
        )
        let install = try #require(
            AgentConnectionsPresentation.userGuidance(
                for: missingAgent,
                locale: "en"
            )
        )
        #expect(install.contains("Claude Code"))
        #expect(install.contains("Install or open"))
        #expect(!install.contains("CLI"))

        let blockedSettings = product(currentStatus(
            source: .claudeCode,
            items: [item(.needsFix, code: .claudeHooksPolicy)]
        ))
        #expect(
            AgentConnectionsPresentation.healthTitle(
                for: blockedSettings,
                locale: "en"
            ) == "Permission Required"
        )
        let settings = try #require(
            AgentConnectionsPresentation.userGuidance(
                for: blockedSettings,
                locale: "en"
            )
        )
        #expect(settings.contains("settings"))
        #expect(settings.contains("Allow Agent Pet Companion"))
        #expect(!settings.contains("Hooks"))
        #expect(!settings.contains("disableAllHooks"))

        let needsRepair = product(currentStatus(
            items: [
                item(
                    .missing,
                    code: .managedConnector,
                    recovery: .confirmManagedRepair
                ),
            ],
            repairable: true
        ))
        #expect(
            AgentConnectionsPresentation.userGuidance(
                for: needsRepair,
                locale: "en"
            ) == "Choose Set Up or Repair below."
        )
    }

    @Test
    func codexHookTrustNamesAuthorizationAndRestartSteps() throws {
        let presentation = product(currentStatus(
            source: .codex,
            items: [
                item(
                    .needsFix,
                    code: .hostVerification,
                    detail: "Codex hooks/list 精确检测：未启用 0、已修改 10、未信任 0（共 10）；App 更新后必须重新审查"
                ),
            ]
        ))

        #expect(presentation.health == .unavailable)
        #expect(
            AgentConnectionsPresentation.healthTitle(
                for: presentation,
                locale: "zh-Hans"
            ) == "需要 Hook 授权"
        )
        #expect(
            AgentConnectionsPresentation.healthSummary(
                for: presentation,
                operationState: .idle,
                locale: "zh-Hans"
            ) == "Codex Hooks 已更新，需要重新审查并授权。"
        )
        let guidance = try #require(
            AgentConnectionsPresentation.userGuidance(
                for: presentation,
                locale: "zh-Hans"
            )
        )
        #expect(guidance.contains("授权 Agent Pet Companion Hooks"))
        #expect(guidance.contains("完全退出并重新打开所有 Codex 窗口"))
        #expect(guidance.contains("重新检查连接"))
        let action = try #require(
            AgentConnectionsPresentation.primaryActionPresentation(
                for: presentation,
                busy: false,
                locale: "zh-Hans"
            )
        )
        #expect(action.accessibilityHint == "完成当前处理指引后，重新检查连接。")
    }

    @Test
    func unavailableReasonsGiveSpecificStatusAndNextAction() throws {
        let update = product(currentStatus(
            source: .pi,
            items: [item(.unsupported, code: .agentVersion)]
        ))
        #expect(
            AgentConnectionsPresentation.healthTitle(
                for: update,
                locale: "en"
            ) == "Update Required"
        )
        #expect(
            AgentConnectionsPresentation.healthSummary(
                for: update,
                operationState: .idle,
                locale: "en"
            ) == "The installed Pi Coding Agent version is not supported."
        )

        let restart = product(currentStatus(
            source: .opencode,
            items: [item(.needsFix, code: .hostServer)]
        ))
        #expect(
            AgentConnectionsPresentation.healthTitle(
                for: restart,
                locale: "en"
            ) == "Restart Required"
        )
        #expect(
            AgentConnectionsPresentation.userGuidance(
                for: restart,
                locale: "en"
            ) == "Fully quit and reopen OpenCode, then check the connection again."
        )

        let eventRuntime = product(currentStatus(
            source: .codex,
            items: [item(.missing, code: .eventCLI)]
        ))
        #expect(
            AgentConnectionsPresentation.healthTitle(
                for: eventRuntime,
                locale: "en"
            ) == "Local Connection Issue"
        )
        #expect(
            AgentConnectionsPresentation.userGuidance(
                for: eventRuntime,
                locale: "en"
            ) == "Open Service & Diagnostics, restore the local service, then check the connection again."
        )
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
                "Connection check finished. The status is up to date."
            ),
            (
                .test,
                "The test message was sent. Run a real Agent task next to confirm the desktop pet responds."
            ),
            (
                .repair,
                "The connection was set up or repaired, then checked again."
            ),
            (
                .uninstall,
                "The connection was removed. The Agent itself was not uninstalled."
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
        #expect(
            AppStore.connectionOperationFailureReason(
                for: PetCoreTransportError.timedOut
            ) == .transportUnavailable
        )
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
    func managedComponentProjectionKeepsOnlyBoundedAppOwnedEvidence() {
        let validPlugin = AgentManagedComponent(
            kind: .plugin,
            name: "agent-pet-companion",
            ownership: .appManaged,
            status: .ok,
            expectedVersion: "0.4.1",
            activeVersion: "0.4.1",
            contentMatches: true
        )
        let validSkill = AgentManagedComponent(
            kind: .skill,
            name: "agent-pet-maker",
            ownership: .appManaged,
            status: .ok,
            expectedVersion: "0.4.1",
            activeVersion: "0.4.1",
            contentMatches: true
        )
        let userManaged = AgentManagedComponent(
            kind: .plugin,
            name: "user-plugin",
            ownership: .userManaged,
            status: .ok
        )
        let presentation = product(currentStatus(
            items: [item(.ok, code: .managedConnector)],
            managedComponents: Array(repeating: userManaged, count: 8) + [
                validPlugin,
                validSkill,
                AgentManagedComponent(
                    kind: .plugin,
                    name: "/Users/alice/private/plugin",
                    ownership: .appManaged,
                    status: .ok
                ),
                AgentManagedComponent(
                    kind: .plugin,
                    name: "invalid-version",
                    ownership: .appManaged,
                    status: .ok,
                    expectedVersion: "1.0/token"
                ),
            ]
        ))

        #expect(presentation.managedComponents == [validPlugin, validSkill])
        #expect(
            AgentConnectionsPresentation.extensionKindTitle(
                validPlugin.kind,
                locale: "en"
            ) == "Plugin"
        )
        #expect(
            AgentConnectionsPresentation.managedComponentStatusTitle(
                validPlugin,
                locale: "en"
            ) == "v0.4.1 · OK"
        )
        #expect(
            AgentConnectionsPresentation.managedComponentVersionDetail(
                validPlugin,
                locale: "en"
            ) == nil
        )
        let ordinaryCopy = [
            AgentConnectionsPresentation.extensionKindTitle(
                validPlugin.kind,
                locale: "en"
            ),
            AgentConnectionsPresentation.managedComponentStatusTitle(
                validPlugin,
                locale: "en"
            ),
        ].joined(separator: " · ")
        #expect(!ordinaryCopy.contains("Expected"))
        #expect(!ordinaryCopy.contains("Active"))
        #expect(!ordinaryCopy.contains("Exact content"))
        #expect(!ordinaryCopy.contains("User managed"))
        #expect(!String(describing: presentation).contains("/Users/"))

        let mismatchedPlugin = AgentManagedComponent(
            kind: .plugin,
            name: "agent-pet-companion",
            ownership: .appManaged,
            status: .needsFix,
            expectedVersion: "0.4.1",
            activeVersion: "0.4.0",
            contentMatches: false
        )
        #expect(
            AgentConnectionsPresentation.managedComponentHasVersionMismatch(
                mismatchedPlugin
            )
        )
        #expect(
            AgentConnectionsPresentation.managedComponentStatusTitle(
                mismatchedPlugin,
                locale: "en"
            ) == "Version mismatch"
        )
        #expect(
            AgentConnectionsPresentation.managedComponentStatusTitle(
                mismatchedPlugin,
                locale: "zh-Hans"
            ) == "版本不匹配"
        )
        #expect(
            AgentConnectionsPresentation.managedComponentVersionDetail(
                mismatchedPlugin,
                locale: "en"
            ) == "Installed v0.4.0 · This App requires v0.4.1"
        )
        #expect(
            AgentConnectionsPresentation.managedComponentVersionDetail(
                mismatchedPlugin,
                locale: "zh-Hans"
            ) == "当前 v0.4.0 · 本 App 需要 v0.4.1"
        )

        let missingPlugin = AgentManagedComponent(
            kind: .plugin,
            name: "agent-pet-companion",
            ownership: .appManaged,
            status: .missing,
            expectedVersion: "0.4.1"
        )
        #expect(
            AgentConnectionsPresentation.managedComponentVersionDetail(
                missingPlugin,
                locale: "zh-Hans"
            ) == "本 App 需要 v0.4.1"
        )

        let internalContractIdentity = AgentManagedComponent(
            kind: .connector,
            name: "agent-pet-companion.ts",
            ownership: .appManaged,
            status: .ok,
            expectedVersion: "pi-extension-0.80.10-events-v11",
            activeVersion: "pi-extension-0.80.10-events-v11",
            contentMatches: true
        )
        #expect(
            AgentConnectionsPresentation.managedComponentStatusTitle(
                internalContractIdentity,
                locale: "en"
            ) == "OK"
        )
        #expect(
            AgentConnectionsPresentation.managedComponentVersionDetail(
                internalContractIdentity,
                locale: "en"
            ) == nil
        )

        let localizedSkillKind = AgentConnectionsPresentation.extensionKindTitle(
            validSkill.kind,
            locale: "zh-Hans"
        )
        #expect(localizedSkillKind == "技能")
        #expect(APCLocalization.text(
            .connectionsManagedComponentsSummary,
            locale: "zh-Hans"
        ).contains("只显示"))
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
            APCLocalization.text(.connectionsRepairAgainHint, locale: "en"),
            APCLocalization.text(.connectionsUninstallHint, locale: "en"),
            APCLocalization.text(.connectionsSuccessCheck, locale: "en"),
            APCLocalization.text(.connectionsSuccessRepair, locale: "en"),
            APCLocalization.text(.connectionsSuccessUninstall, locale: "en"),
        ].joined(separator: " ")

        for forbidden in [
            "Runtime Identity",
            "Renderer",
            "Export Diagnostics",
            "managed connector",
            "managed file",
            "CLI",
            "RPC",
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
        #expect(
            APCLocalization.text(
                .connectionsTestChannel,
                locale: "en"
            ) == "Send Test Message"
        )
        #expect(
            APCLocalization.text(
                .connectionsTestChannel,
                locale: "zh-Hans"
            ) == "发送测试消息"
        )
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
        canUninstall: Bool? = false,
        managedComponents: [AgentManagedComponent] = []
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
                canUninstall: canUninstall,
                managedComponents: managedComponents
            )
        )
    }

    private func item(
        _ status: CheckStatus,
        code: ConnectionCheckCode,
        recovery: ConnectionCheckRecoveryKind? = nil,
        detail: String = "untrusted-detail"
    ) -> ConnectionCheckItem {
        ConnectionCheckItem(
            code: code,
            name: "untrusted-name",
            status: status,
            detail: detail,
            recoveryAction: recovery
        )
    }

    private func capabilities(
        repairable: Bool?,
        canManage: Bool? = true,
        conflict: Bool?,
        canUninstall: Bool?,
        managedComponents: [AgentManagedComponent] = []
    ) -> AgentConnectorCapabilities {
        AgentConnectorCapabilities(
            contractVersion: "typed-test-v1",
            subscribedEvents: [],
            mappedInformation: [],
            privacyExclusions: [],
            repairableConnectorIssue: repairable,
            canRepairManagedConnector: canManage,
            managedPathConflict: conflict,
            canUninstallManagedConnector: canUninstall,
            managedComponents: managedComponents
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
