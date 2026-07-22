import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct AgentConnectionsTests {
    @Test
    func layoutKeepsFourAgentsInOneStableSplitOrCompactMode() {
        #expect(
            AgentConnectionsCatalog.sources
                == [.codex, .claudeCode, .pi, .opencode]
        )
        #expect(AgentConnectionsLayout.mode(for: .allColumns) == .split)
        #expect(AgentConnectionsLayout.mode(for: .sidebarAndContent) == .split)
        #expect(AgentConnectionsLayout.mode(for: .singleContent) == .compact)
        #expect(AgentConnectionsLayout.listWidth == 190)
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
        let state = AgentConnectionOperationState.failed(failure)
        #expect(state.failedOperation == failure)
        #expect(!state.isRunning)
    }

    @Test
    func connectionOperationNormalizesSourcesToTheProductOrder() {
        let operation = AgentConnectionOperation(
            kind: .repair,
            sources: [.opencode, .codex, .opencode, .pi]
        )
        #expect(operation.sources == [.codex, .pi, .opencode])
    }

    @MainActor
    @Test
    func operationFailuresNeverExposeRawErrorTextAcrossLocales() {
        let raw = "失败 /Users/alice/private token-command --secret"
        let reason = AppStore.connectionOperationFailureReason(
            for: PetCoreClientError.rpcError(raw)
        )
        #expect(reason == .rejected)

        let english = AgentConnectionsPresentation.operationFailureDetail(
            reason,
            locale: "en"
        )
        let chinese = AgentConnectionsPresentation.operationFailureDetail(
            reason,
            locale: "zh-Hans"
        )
        #expect(!english.contains(raw))
        #expect(!english.contains("/Users/"))
        #expect(!english.contains("失败"))
        #expect(chinese != english)
    }

    @Test
    func overallHealthUsesOnlyTypedStatusFields() {
        #expect(AgentConnectionsPresentation.health(for: nil) == .pending)
        #expect(
            AgentConnectionsPresentation.health(
                for: makeStatus(checkMode: .light)
            ) == .lightCheck
        )
        #expect(
            AgentConnectionsPresentation.health(
                for: makeStatus(items: [item(.needsFix)])
            ) == .needsAttention(1)
        )
        #expect(
            AgentConnectionsPresentation.health(
                for: makeStatus(verification: verification(.actionRequired))
            ) == .actionRequired
        )
        #expect(
            AgentConnectionsPresentation.health(
                for: makeStatus(items: [item(.unverified)])
            ) == .unverified
        )
        #expect(
            AgentConnectionsPresentation.health(
                for: makeStatus(items: [item(.unsupported)])
            ) == .limited
        )
        #expect(
            AgentConnectionsPresentation.health(
                for: makeStatus(items: [item(.ok)])
            ) == .healthy
        )
    }

    @Test
    func renamedHumanCopyDoesNotChangeHealthOrItemPresentation() {
        let chinese = item(.missing, name: "事件回传", detail: "未检测到")
        let renamed = item(.missing, name: "Event callback v2", detail: "Unavailable")
        let chineseStatus = makeStatus(items: [chinese])
        let renamedStatus = makeStatus(items: [renamed])

        #expect(
            AgentConnectionsPresentation.health(for: chineseStatus)
                == AgentConnectionsPresentation.health(for: renamedStatus)
        )
        #expect(
            AgentConnectionsPresentation.itemTone(for: chinese, checkMode: .runtime)
                == AgentConnectionsPresentation.itemTone(for: renamed, checkMode: .runtime)
        )
        #expect(
            AgentConnectionsPresentation.itemTitle(for: chinese, checkMode: .runtime)
                == AgentConnectionsPresentation.itemTitle(for: renamed, checkMode: .runtime)
        )
    }

    @Test
    func stableCheckCodeLocalizesRowsWithoutRenderingPetCoreChineseCopy() {
        let item = ConnectionCheckItem(
            code: "agent_cli",
            name: "检查 Agent 命令",
            status: .needsFix,
            detail: "任意中文技术输出"
        )

        #expect(AgentConnectionsPresentation.itemDisplayName(
            for: item,
            locale: "en"
        ) == "Agent CLI")
        let englishDetail = AgentConnectionsPresentation.itemDisplayDetail(
            for: item,
            locale: "en"
        )
        #expect(englishDetail.contains("selected agent command"))
        #expect(!englishDetail.contains("Needs repair"))
        #expect(!englishDetail.contains(item.detail))

        let renamed = ConnectionCheckItem(
            code: "agent_cli",
            name: "Agent executable v3",
            status: .needsFix,
            detail: "renamed backend guidance"
        )
        #expect(AgentConnectionsPresentation.itemDisplayDetail(
            for: renamed,
            locale: "en"
        ) == englishDetail)

        #expect(AgentConnectionsPresentation.itemDisplayName(
            for: item,
            locale: "zh-Hans"
        ) == "Agent CLI")

        let legacy = ConnectionCheckItem(
            name: "任意旧名称",
            status: .unverified,
            detail: "任意旧详情"
        )
        #expect(AgentConnectionsPresentation.itemDisplayName(
            for: legacy,
            locale: "en"
        ) == "Connection Check")

        let channelTest = ConnectionCheckItem(
            code: "channel_test",
            name: "renamed local probe",
            status: .ok,
            detail: "raw probe output"
        )
        let channelDetail = AgentConnectionsPresentation.itemDisplayDetail(
            for: channelTest,
            locale: "en"
        )
        #expect(channelDetail.contains("does not verify a real agent task"))
        #expect(!channelDetail.contains(channelTest.detail))

        let claudePolicy = ConnectionCheckItem(
            code: "claude_hooks_policy",
            name: "renamed backend policy row",
            status: .needsFix,
            detail: "backend-only policy detail",
            recoveryAction: .recheck
        )
        #expect(AgentConnectionsPresentation.itemDisplayName(
            for: claudePolicy,
            locale: "en"
        ) == "Claude Hooks Policy")
        let englishPolicyDetail = AgentConnectionsPresentation.itemDisplayDetail(
            for: claudePolicy,
            locale: "en"
        )
        #expect(englishPolicyDetail.contains("disableAllHooks"))
        #expect(englishPolicyDetail.contains("allowManagedHooksOnly"))
        #expect(englishPolicyDetail.contains("managed policy"))
        #expect(englishPolicyDetail.contains("contact your administrator"))
        #expect(!englishPolicyDetail.contains("Install or Repair"))
        #expect(!englishPolicyDetail.contains(claudePolicy.detail))

        #expect(AgentConnectionsPresentation.itemDisplayName(
            for: claudePolicy,
            locale: "zh-Hans"
        ) == "Claude Hooks 策略")
        let chinesePolicyDetail = AgentConnectionsPresentation.itemDisplayDetail(
            for: claudePolicy,
            locale: "zh-Hans"
        )
        #expect(chinesePolicyDetail.contains("disableAllHooks"))
        #expect(chinesePolicyDetail.contains("allowManagedHooksOnly"))
        #expect(chinesePolicyDetail.contains("管理策略"))
        #expect(chinesePolicyDetail.contains("联系管理员"))
        #expect(!chinesePolicyDetail.contains("安装或修复"))
        #expect(!chinesePolicyDetail.contains(claudePolicy.detail))

        let stableCodes = [
            "agent_cli", "event_cli", "agent_version",
            "managed_connector", "host_runtime", "host_verification", "event_delivery",
            "channel_test", "app_server", "host_server", "claude_hooks_policy"
        ]
        let descriptions = stableCodes.map { code in
            AgentConnectionsPresentation.itemDisplayDetail(
                for: ConnectionCheckItem(
                    code: code,
                    name: "renamed \(code)",
                    status: .ok,
                    detail: "ignored"
                ),
                locale: "en"
            )
        }
        #expect(Set(descriptions).count == stableCodes.count)
    }

    @Test
    func legacyProjectCheckIsNotPartOfTheAgentScopedPresentation() {
        let projectCheck = item(
            .needsFix,
            code: "project_directory",
            recovery: .chooseProjectDirectory
        )
        let agentCheck = item(.ok, code: "agent_cli")
        let status = makeStatus(items: [projectCheck, agentCheck])

        #expect(AgentConnectionsPresentation.displayItems(in: status) == [agentCheck])
    }

    @Test
    func lightCheckPresentationNeverClaimsRuntimeVerification() {
        let located = item(.ok)
        #expect(
            AgentConnectionsPresentation.itemTitle(for: located, checkMode: .light)
                == "已定位"
        )
        #expect(
            AgentConnectionsPresentation.itemTone(for: located, checkMode: .light)
                == .neutral
        )
        #expect(
            AgentConnectionsPresentation.itemTitle(for: located, checkMode: .runtime)
                == CheckStatus.ok.title
        )
    }

    @Test
    func typedCheckStatesRemainVisuallyDistinct() {
        let missing = item(.missing)
        let repair = item(.needsFix)
        let unverified = item(.unverified)
        let unsupported = item(.unsupported)

        #expect(
            AgentConnectionsPresentation.itemTone(for: missing, checkMode: .runtime)
                == .destructive
        )
        #expect(
            AgentConnectionsPresentation.itemTone(for: repair, checkMode: .runtime)
                == .warning
        )
        #expect(
            AgentConnectionsPresentation.itemSystemImage(for: unverified, checkMode: .runtime)
                != AgentConnectionsPresentation.itemSystemImage(for: unsupported, checkMode: .runtime)
        )
        #expect(
            AgentConnectionsPresentation.itemTitle(for: unverified, checkMode: .runtime)
                != AgentConnectionsPresentation.itemTitle(for: unsupported, checkMode: .runtime)
        )
    }

    @Test
    func recoveryActionsUseTypedCodesAndStatusesWithoutParsingHumanCopy() throws {
        let status = makeStatus(source: .pi)

        let legacyDirectory = try #require(AgentConnectionsPresentation.recoveryAction(
            for: item(
                .needsFix,
                code: "project_directory",
                name: "renamed folder check",
                detail: "arbitrary backend guidance",
                recovery: .chooseProjectDirectory
            ),
            in: status
        ))
        #expect(legacyDirectory.kind == .recheck)
        #expect(legacyDirectory.source == .pi)
        #expect(legacyDirectory.operation == AgentConnectionOperation(
            kind: .check,
            sources: [.pi]
        ))

        let generic = try #require(AgentConnectionsPresentation.recoveryAction(
            for: item(
                .missing,
                code: "agent_cli",
                name: "修复并测试通道",
                detail: "choose a directory and repair immediately",
                recovery: .recheck
            ),
            in: status
        ))
        #expect(generic.kind == .recheck)
        #expect(generic.operation == AgentConnectionOperation(kind: .check, sources: [.pi]))

        for terminalStatus in [CheckStatus.ok, .notRequired, .unsupported] {
            #expect(AgentConnectionsPresentation.recoveryAction(
                for: item(
                    terminalStatus,
                    code: "project_directory",
                    recovery: .chooseProjectDirectory
                ),
                in: status
            ) == nil)
        }
    }

    @Test
    func managedRepairRequiresAnExplicitTypedCapabilityAndNeverBypassesConfirmation() throws {
        let repairable = makeStatus(
            source: .opencode,
            capabilities: capabilities(repairable: true, conflict: false)
        )
        let action = try #require(AgentConnectionsPresentation.recoveryAction(
            for: item(
                .missing,
                code: "managed_connector",
                recovery: .confirmManagedRepair
            ),
            in: repairable
        ))
        #expect(action.kind == .confirmManagedRepair)
        #expect(action.source == .opencode)
        #expect(action.operation == nil)

        let unreported = makeStatus(source: .opencode)
        #expect(AgentConnectionsPresentation.recoveryAction(
            for: item(
                .missing,
                code: "managed_connector",
                name: "please repair this managed connector",
                detail: "repairable",
                recovery: .confirmManagedRepair
            ),
            in: unreported
        )?.kind == .recheck)

        let explicitlyNotRepairable = makeStatus(
            source: .opencode,
            capabilities: capabilities(repairable: false, conflict: false)
        )
        #expect(AgentConnectionsPresentation.recoveryAction(
            for: item(
                .needsFix,
                code: "managed_connector",
                recovery: .confirmManagedRepair
            ),
            in: explicitlyNotRepairable
        )?.kind == .recheck)

        let missingConflictCapability = makeStatus(
            source: .opencode,
            capabilities: capabilities(repairable: true, conflict: nil)
        )
        #expect(AgentConnectionsPresentation.recoveryAction(
            for: item(
                .needsFix,
                code: "managed_connector",
                recovery: .confirmManagedRepair
            ),
            in: missingConflictCapability
        )?.kind == .recheck)

        let conflict = makeStatus(
            source: .opencode,
            capabilities: capabilities(repairable: true, conflict: true)
        )
        #expect(AgentConnectionsPresentation.recoveryAction(
            for: item(
                .needsFix,
                code: "managed_connector",
                recovery: .confirmManagedRepair
            ),
            in: conflict
        )?.kind == .recheck)
    }

    @Test
    func claudePolicyFailureNeverBorrowsTheConnectorWideRepairCapability() throws {
        let status = makeStatus(
            source: .claudeCode,
            items: [
                item(
                    .missing,
                    code: "managed_connector",
                    name: "事件通道",
                    recovery: .confirmManagedRepair
                ),
                item(
                    .needsFix,
                    code: "claude_hooks_policy",
                    name: "Claude Hooks Policy",
                    recovery: .recheck
                )
            ],
            capabilities: capabilities(repairable: true, conflict: false)
        )

        let connector = try #require(AgentConnectionsPresentation.recoveryAction(
            for: status.items[0],
            in: status
        ))
        let policy = try #require(AgentConnectionsPresentation.recoveryAction(
            for: status.items[1],
            in: status
        ))

        #expect(connector.kind == .confirmManagedRepair)
        #expect(policy.kind == .recheck)
        #expect(policy.operation == AgentConnectionOperation(
            kind: .check,
            sources: [.claudeCode]
        ))

        let renamedPolicy = item(
            .needsFix,
            code: "claude_hooks_policy",
            name: "Enterprise policy vNext",
            detail: "arbitrary localized guidance",
            recovery: .recheck
        )
        #expect(AgentConnectionsPresentation.recoveryAction(
            for: renamedPolicy,
            in: status
        ) == policy)

        let legacyWithoutRowRecovery = item(
            .needsFix,
            code: "managed_connector",
            name: "Legacy connector-looking policy"
        )
        #expect(AgentConnectionsPresentation.recoveryAction(
            for: legacyWithoutRowRecovery,
            in: status
        )?.kind == .recheck)

        let unknownRecovery = try JSONDecoder().decode(
            ConnectionCheckItem.self,
            from: Data(
                #"{"code":"managed_connector","name":"future","status":"needs_fix","detail":"future","recovery_action":"future_mutation"}"#.utf8
            )
        )
        #expect(AgentConnectionsPresentation.recoveryAction(
            for: unknownRecovery,
            in: status
        )?.kind == .recheck)
    }

    @Test
    func eventChannelRecoveryRoutesTheSelectedSourceToTheExistingTestOperation() throws {
        let status = makeStatus(source: .claudeCode)

        for code in ["event_delivery", "channel_test"] {
            let action = try #require(AgentConnectionsPresentation.recoveryAction(
                for: item(.unverified, code: code, recovery: .testChannel),
                in: status
            ))
            #expect(action.kind == .testChannel)
            #expect(action.operation == AgentConnectionOperation(
                kind: .test,
                sources: [.claudeCode]
            ))
        }

        let eventCLI = try #require(AgentConnectionsPresentation.recoveryAction(
            for: item(.missing, code: "event_cli", recovery: .recheck),
            in: status
        ))
        #expect(eventCLI.kind == .recheck)
        #expect(eventCLI.operation == AgentConnectionOperation(
            kind: .check,
            sources: [.claudeCode]
        ))
    }

    @Test
    func recoveryButtonPresentationKeepsBusyAndAccessibilityContractsTyped() throws {
        let action = try #require(AgentConnectionsPresentation.recoveryAction(
            for: item(.unverified, code: "event_delivery", recovery: .testChannel),
            in: makeStatus(source: .pi)
        ))
        let checkItem = item(.unverified, code: "event_delivery", recovery: .testChannel)
        let enabled = AgentConnectionsPresentation.recoveryButtonPresentation(
            for: action,
            item: checkItem,
            itemIndex: 3,
            busy: false,
            locale: "en"
        )
        #expect(enabled.title == "Test Channel")
        #expect(enabled.accessibilityLabel.contains("Pi"))
        #expect(enabled.accessibilityLabel.contains("Event Delivery"))
        #expect(enabled.accessibilityLabel.contains("Test Channel"))
        #expect(enabled.hint == "Tests only the local diagnostic event path; it does not mark a real agent as verified.")
        #expect(enabled.systemImage == "play.circle")
        #expect(enabled.accessibilityIdentifier == "connections.detail.check-action.test-channel.pi.3")
        #expect(enabled.isEnabled)

        let busy = AgentConnectionsPresentation.recoveryButtonPresentation(
            for: action,
            item: checkItem,
            itemIndex: 3,
            busy: true,
            locale: "en"
        )
        #expect(!busy.isEnabled)
        #expect(busy.hint == "Wait for the current connection operation to finish.")
        #expect(busy.accessibilityIdentifier == enabled.accessibilityIdentifier)
    }

    @Test
    func repeatedRecoveryButtonsHaveRotorDistinctLabels() throws {
        let status = makeStatus(source: .claudeCode)
        let firstItem = item(
            .needsFix,
            code: "host_verification",
            recovery: .recheck
        )
        let secondItem = item(
            .unverified,
            code: "host_verification",
            recovery: .recheck
        )
        let firstAction = try #require(AgentConnectionsPresentation.recoveryAction(
            for: firstItem,
            in: status
        ))
        let secondAction = try #require(AgentConnectionsPresentation.recoveryAction(
            for: secondItem,
            in: status
        ))
        let first = AgentConnectionsPresentation.recoveryButtonPresentation(
            for: firstAction,
            item: firstItem,
            itemIndex: 4,
            busy: false,
            locale: "en"
        )
        let second = AgentConnectionsPresentation.recoveryButtonPresentation(
            for: secondAction,
            item: secondItem,
            itemIndex: 5,
            busy: false,
            locale: "en"
        )

        #expect(first.title == second.title)
        #expect(first.accessibilityLabel != second.accessibilityLabel)
        #expect(first.accessibilityLabel.contains("Host Verification"))
        #expect(first.accessibilityLabel.contains(first.title))
        #expect(first.accessibilityLabel.contains("Claude Code"))
    }

    private func makeStatus(
        source: AgentSource = .codex,
        checkMode: ConnectionCheckMode = .runtime,
        items: [ConnectionCheckItem] = [],
        verification: AgentVerification? = nil,
        capabilities: AgentConnectorCapabilities = .empty
    ) -> AgentConnectionStatus {
        AgentConnectionStatus(
            source: source,
            items: items,
            installPaths: [],
            connectorInstalled: false,
            checkMode: checkMode,
            verification: verification ?? self.verification(.verified),
            capabilities: capabilities
        )
    }

    private func item(
        _ status: CheckStatus,
        code: String? = nil,
        name: String = "arbitrary-check",
        detail: String = "arbitrary-detail",
        recovery: ConnectionCheckRecoveryKind? = nil
    ) -> ConnectionCheckItem {
        ConnectionCheckItem(
            code: code,
            name: name,
            status: status,
            detail: detail,
            recoveryAction: recovery
        )
    }

    private func capabilities(
        repairable: Bool?,
        conflict: Bool?
    ) -> AgentConnectorCapabilities {
        AgentConnectorCapabilities(
            contractVersion: "typed-test-v1",
            subscribedEvents: [],
            mappedInformation: [],
            privacyExclusions: [],
            repairableConnectorIssue: repairable,
            managedPathConflict: conflict,
            canUninstallManagedConnector: false
        )
    }

    private func verification(_ status: AgentVerificationStatus) -> AgentVerification {
        AgentVerification(
            status: status,
            title: "verification-title",
            detail: "verification-detail"
        )
    }
}
