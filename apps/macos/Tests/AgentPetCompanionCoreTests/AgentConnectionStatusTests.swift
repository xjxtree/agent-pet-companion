import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct AgentConnectionStatusTests {
    @Test
    func legacyPayloadDefaultsNewVerificationAndCapabilityFields() throws {
        let data = Data(
            #"{"source":"codex","items":[],"install_paths":[],"check_mode":"runtime"}"#.utf8
        )

        let status = try JSONDecoder().decode(AgentConnectionStatus.self, from: data)

        #expect(status.verification.status == .unverified)
        #expect(status.verification.title == AgentVerification.pending.title)
        #expect(status.verification.detail == AgentVerification.pending.detail)
        #expect(status.verification.lastVerifiedAt == nil)
        #expect(!status.capabilities.hasReportedCapabilities)
        #expect(status.capabilities.auditedEvents.isEmpty)
        #expect(status.capabilities.subscribedEvents.isEmpty)
        #expect(status.capabilities.repairableConnectorIssue == nil)
        #expect(status.capabilities.managedPathConflict == nil)
        #expect(status.capabilities.canUninstallManagedConnector == nil)
    }

    @Test
    func verificationAndCapabilitiesDecodeFromCurrentPayload() throws {
        let data = Data(
            #"""
            {
              "source": "claude_code",
              "items": [],
              "install_paths": ["/tmp/settings.json"],
              "connector_installed": true,
              "check_mode": "runtime",
              "checked_at": "2026-07-17T09:30:00Z",
              "verification": {
                "status": "action_required",
                "title": "需要启用 Hooks",
                "detail": "已检测到配置，但尚未收到真实 Hook。",
                "last_verified_at": "2026-07-16T08:20:30.125Z",
                "last_event": "SessionStart",
                "action_detail": "在 Claude Code 中检查 /hooks，然后运行一次任务。",
                "checked_cwd": "/tmp/current-project"
              },
              "capabilities": {
                "contract_version": "claude-hooks-v5",
                "audited_events": ["SessionStart", "PreToolUse", "WorktreeCreate"],
                "subscribed_events": ["SessionStart", "PreToolUse", "PostToolUse"],
                "mapped_information": ["会话生命周期", "工具名称与执行状态"],
                "privacy_exclusions": ["工具输入与输出", "认证信息"],
                "repairable_connector_issue": true,
                "managed_path_conflict": false,
                "can_uninstall_managed_connector": true
              }
            }
            """#.utf8
        )

        let status = try JSONDecoder().decode(AgentConnectionStatus.self, from: data)

        #expect(status.verification.status == .actionRequired)
        #expect(status.verification.status.requiresUserAction)
        #expect(status.verification.status.title == "需操作")
        #expect(status.verification.lastVerifiedAt == "2026-07-16T08:20:30.125Z")
        #expect(status.verification.lastEvent == "SessionStart")
        #expect(status.verification.actionDetail?.contains("/hooks") == true)
        #expect(status.verification.checkedCWD == "/tmp/current-project")
        #expect(status.capabilities.contractVersion == "claude-hooks-v5")
        #expect(status.capabilities.auditedEvents.count == 3)
        #expect(status.capabilities.subscribedEvents.count == 3)
        #expect(status.capabilities.mappedInformation == ["会话生命周期", "工具名称与执行状态"])
        #expect(status.capabilities.privacyExclusions == ["工具输入与输出", "认证信息"])
        #expect(status.capabilities.repairableConnectorIssue == true)
        #expect(status.capabilities.managedPathConflict == false)
        #expect(status.capabilities.canUninstallManagedConnector == true)
        #expect(status.hasRepairableConnectorIssue)
        #expect(!status.hasManagedPathConflict)
        #expect(status.canUninstallManagedConnector)
        #expect(status.capabilities.hasReportedCapabilities)
    }

    @Test
    func newFieldsEncodeWithSnakeCaseContractKeys() throws {
        let status = AgentConnectionStatus(
            source: .pi,
            items: [],
            installPaths: [],
            verification: AgentVerification(
                status: .verified,
                title: "已收到真实事件",
                detail: "Pi 已加载 Extension。",
                lastVerifiedAt: "2026-07-17T09:40:00Z",
                lastEvent: "tool_execution_start",
                checkedCWD: "/tmp/pi-project"
            ),
            capabilities: AgentConnectorCapabilities(
                contractVersion: "pi-extension-v7",
                auditedEvents: ["session_start", "context"],
                subscribedEvents: ["session_start"],
                mappedInformation: ["会话状态"],
                privacyExclusions: ["工具输出"],
                repairableConnectorIssue: false,
                managedPathConflict: true,
                canUninstallManagedConnector: false
            )
        )

        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        )
        let verification = try #require(object["verification"] as? [String: Any])
        let capabilities = try #require(object["capabilities"] as? [String: Any])

        #expect(verification["last_verified_at"] as? String == "2026-07-17T09:40:00Z")
        #expect(verification["last_event"] as? String == "tool_execution_start")
        #expect(verification["checked_cwd"] as? String == "/tmp/pi-project")
        #expect(capabilities["contract_version"] as? String == "pi-extension-v7")
        #expect((capabilities["audited_events"] as? [String]) == ["session_start", "context"])
        #expect((capabilities["subscribed_events"] as? [String]) == ["session_start"])
        #expect(capabilities["repairable_connector_issue"] as? Bool == false)
        #expect(capabilities["managed_path_conflict"] as? Bool == true)
        #expect(capabilities["can_uninstall_managed_connector"] as? Bool == false)
    }

    @Test
    func unknownFutureVerificationStatusFallsBackToUnverified() throws {
        let data = Data(#""queued_for_agent""#.utf8)
        let status = try JSONDecoder().decode(AgentVerificationStatus.self, from: data)

        #expect(status == .unverified)
    }

    @Test
    func checkItemDecodesTypedRowRecoveryAndSafelyDowngradesLegacyOrUnknownValues() throws {
        let current = try JSONDecoder().decode(
            ConnectionCheckItem.self,
            from: Data(
                #"{"code":"managed_connector","name":"renamed","status":"missing","detail":"technical","recovery_action":"confirm_managed_repair"}"#.utf8
            )
        )
        #expect(current.code == .managedConnector)
        #expect(current.recoveryAction == .confirmManagedRepair)

        let legacy = try JSONDecoder().decode(
            ConnectionCheckItem.self,
            from: Data(
                #"{"name":"legacy","status":"needs_fix","detail":"legacy"}"#.utf8
            )
        )
        #expect(legacy.code == .unknown)
        #expect(legacy.recoveryAction == nil)

        let future = try JSONDecoder().decode(
            ConnectionCheckItem.self,
            from: Data(
                #"{"code":"future_policy","name":"future","status":"needs_fix","detail":"future","recovery_action":"delete_or_overwrite"}"#.utf8
            )
        )
        #expect(future.code == .unknown)
        #expect(future.recoveryAction == .recheck)

        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        #expect(encoded["code"] as? String == "managed_connector")
        #expect(encoded["recovery_action"] as? String == "confirm_managed_repair")

        let claudePolicy = try JSONDecoder().decode(
            ConnectionCheckItem.self,
            from: Data(
                #"{"code":"claude_hooks_policy","name":"renamed","status":"needs_fix","detail":"technical","recovery_action":"recheck"}"#.utf8
            )
        )
        #expect(claudePolicy.code == .claudeHooksPolicy)
        #expect(claudePolicy.recoveryAction == .recheck)
    }

    @Test
    func legacyHumanCopyCannotAuthorizeRepairOrUninstall() {
        let status = AgentConnectionStatus(
            source: .codex,
            items: [
                ConnectionCheckItem(
                    name: "Agent Pet Maker Skill",
                    status: .needsFix,
                    detail: "已安装，但内容与当前连接器契约不一致。"
                )
            ],
            installPaths: ["/tmp/codex/plugins/agent-pet-companion"]
        )

        #expect(!status.hasRepairableConnectorIssue)
        #expect(!status.hasInstalledConnectorArtifacts)
        #expect(!status.canUninstallManagedConnector)
    }

    @Test
    func projectDirectoryAccessIssueAloneIsNotARepairableConnectorIssue() {
        let status = AgentConnectionStatus(
            source: .codex,
            items: [
                ConnectionCheckItem(
                    name: "检查目录访问",
                    status: .needsFix,
                    detail: "Agent 无法访问当前项目目录。"
                )
            ],
            installPaths: ["/tmp/codex/plugins/agent-pet-companion"]
        )

        #expect(!status.hasRepairableConnectorIssue)
    }

    @Test
    func foreignCanonicalConnectorPathIsBlockingButNotOneClickRepairable() {
        let status = AgentConnectionStatus(
            source: .opencode,
            items: [
                ConnectionCheckItem(
                    name: "Plugin 路径冲突",
                    status: .needsFix,
                    detail: "目标路径属于用户文件，一键修复不会覆盖。"
                )
            ],
            installPaths: ["/tmp/opencode/plugins"]
        )

        #expect(!status.hasRepairableConnectorIssue)
        #expect(!status.hasInstalledConnectorArtifacts)
        #expect(status.blockingItems.count == 1)
    }

    @Test
    func anyManagedPathConflictSuppressesRepairEvenWhenAnotherArtifactIsMissing() {
        let status = AgentConnectionStatus(
            source: .claudeCode,
            items: [
                ConnectionCheckItem(
                    name: "连接器目录路径冲突",
                    status: .needsFix,
                    detail: "管理根是符号链接。"
                ),
                ConnectionCheckItem(
                    name: "事件通道",
                    status: .missing,
                    detail: "helper 缺失。"
                )
            ],
            installPaths: ["/tmp/claude-code"],
            connectorInstalled: true,
            capabilities: AgentConnectorCapabilities(
                contractVersion: "claude-v-next",
                subscribedEvents: [],
                mappedInformation: [],
                privacyExclusions: [],
                repairableConnectorIssue: true,
                managedPathConflict: true,
                canUninstallManagedConnector: true
            )
        )

        #expect(!status.hasRepairableConnectorIssue)
        #expect(status.hasManagedPathConflict)
        #expect(!status.canUninstallManagedConnector)
    }

    @Test
    func partialTypedCapabilityCannotAuthorizeManagedMutation() {
        let status = AgentConnectionStatus(
            source: .opencode,
            items: [],
            installPaths: ["/tmp/opencode"],
            connectorInstalled: true,
            capabilities: AgentConnectorCapabilities(
                contractVersion: "partial-v1",
                subscribedEvents: [],
                mappedInformation: [],
                privacyExclusions: [],
                repairableConnectorIssue: true,
                managedPathConflict: nil,
                canUninstallManagedConnector: true
            )
        )

        #expect(!status.hasRepairableConnectorIssue)
        #expect(!status.canUninstallManagedConnector)
    }

    @Test
    func typedManagementCapabilitiesAreUnaffectedByHumanCopy() {
        func status(name: String, detail: String) -> AgentConnectionStatus {
            AgentConnectionStatus(
                source: .codex,
                items: [
                    ConnectionCheckItem(
                        name: name,
                        status: .needsFix,
                        detail: detail
                    )
                ],
                installPaths: ["/tmp/codex/plugins/agent-pet-companion"],
                connectorInstalled: true,
                capabilities: AgentConnectorCapabilities(
                    contractVersion: "codex-v-next",
                    subscribedEvents: [],
                    mappedInformation: [],
                    privacyExclusions: [],
                    repairableConnectorIssue: false,
                    managedPathConflict: false,
                    canUninstallManagedConnector: true
                )
            )
        }

        let legacyLooking = status(
            name: "Agent Pet Maker Skill",
            detail: "已安装旧版本，待更新"
        )
        let renamed = status(
            name: "Managed component v2 conflict-ish copy",
            detail: "Arbitrary future localization"
        )

        #expect(legacyLooking.hasRepairableConnectorIssue == renamed.hasRepairableConnectorIssue)
        #expect(legacyLooking.hasManagedPathConflict == renamed.hasManagedPathConflict)
        #expect(legacyLooking.canUninstallManagedConnector == renamed.canUninstallManagedConnector)
        #expect(!renamed.hasRepairableConnectorIssue)
        #expect(!renamed.hasManagedPathConflict)
        #expect(renamed.canUninstallManagedConnector)
    }
}
