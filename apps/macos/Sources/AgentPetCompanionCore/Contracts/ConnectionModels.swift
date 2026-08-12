import Foundation

public enum ConnectionCheckCode: String, Codable, Hashable, Sendable {
    case agentCLI = "agent_cli"
    case eventCLI = "event_cli"
    case projectDirectory = "project_directory"
    case agentVersion = "agent_version"
    case managedConnector = "managed_connector"
    case claudeHooksPolicy = "claude_hooks_policy"
    case hostRuntime = "host_runtime"
    case hostVerification = "host_verification"
    case eventDelivery = "event_delivery"
    case channelTest = "channel_test"
    case appServer = "app_server"
    case hostServer = "host_server"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ConnectionCheckRecoveryKind: String, Codable, Hashable, Sendable {
    case chooseProjectDirectory = "choose_project_directory"
    case confirmManagedRepair = "confirm_managed_repair"
    case testChannel = "test_channel"
    case recheck

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Future values must never acquire mutation authority in an older App.
        self = Self(rawValue: try container.decode(String.self)) ?? .recheck
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ConnectionCheckItem: Codable, Hashable, Sendable {
    public var code: ConnectionCheckCode
    public var name: String
    public var status: CheckStatus
    public var detail: String
    public var recoveryAction: ConnectionCheckRecoveryKind?

    public init(
        code: ConnectionCheckCode = .unknown,
        name: String,
        status: CheckStatus,
        detail: String,
        recoveryAction: ConnectionCheckRecoveryKind? = nil
    ) {
        self.code = code
        self.name = name
        self.status = status
        self.detail = detail
        self.recoveryAction = recoveryAction
    }

    public init(
        code: String?,
        name: String,
        status: CheckStatus,
        detail: String,
        recoveryAction: ConnectionCheckRecoveryKind? = nil
    ) {
        self.init(
            code: code.flatMap(ConnectionCheckCode.init(rawValue:)) ?? .unknown,
            name: name,
            status: status,
            detail: detail,
            recoveryAction: recoveryAction
        )
    }

    enum CodingKeys: String, CodingKey {
        case code
        case name
        case status
        case detail
        case recoveryAction = "recovery_action"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(ConnectionCheckCode.self, forKey: .code) ?? .unknown
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(CheckStatus.self, forKey: .status)
        detail = try container.decode(String.self, forKey: .detail)
        recoveryAction = try container.decodeIfPresent(
            ConnectionCheckRecoveryKind.self,
            forKey: .recoveryAction
        )
    }
}

public enum CheckStatus: String, Codable, Hashable, Sendable {
    case ok
    case needsFix = "needs_fix"
    case missing
    case unverified
    case unsupported
    case notRequired = "not_required"

    public var title: String {
        switch self {
        case .ok: "正常"
        case .needsFix: "需修复"
        case .missing: "未检测到"
        case .unverified: "未验证"
        case .unsupported: "暂不支持"
        case .notRequired: "非必需"
        }
    }

    public var isBlocking: Bool {
        self == .needsFix || self == .missing
    }
}

public enum AgentExtensionKind: String, Codable, Hashable, Sendable {
    case connector
    case plugin
    case hostExtension = "extension"
    case package
    case skill
    case hook
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AgentExtensionOwnership: String, Codable, Hashable, Sendable {
    case appManaged = "app_managed"
    case userManaged = "user_managed"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentManagedComponent: Codable, Hashable, Sendable {
    public var kind: AgentExtensionKind
    public var name: String
    public var ownership: AgentExtensionOwnership
    public var status: CheckStatus
    public var expectedVersion: String?
    public var activeVersion: String?
    public var contentMatches: Bool?

    public init(
        kind: AgentExtensionKind,
        name: String,
        ownership: AgentExtensionOwnership,
        status: CheckStatus,
        expectedVersion: String? = nil,
        activeVersion: String? = nil,
        contentMatches: Bool? = nil
    ) {
        self.kind = kind
        self.name = name
        self.ownership = ownership
        self.status = status
        self.expectedVersion = expectedVersion
        self.activeVersion = activeVersion
        self.contentMatches = contentMatches
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case name
        case ownership
        case status
        case expectedVersion = "expected_version"
        case activeVersion = "active_version"
        case contentMatches = "content_matches"
    }
}

public enum ConnectionCheckMode: String, Codable, Hashable, Sendable {
    case light
    case runtime

    public var title: String {
        switch self {
        case .light: "轻量定位"
        case .runtime: "完整检查"
        }
    }
}

public enum AgentVerificationStatus: String, Codable, Hashable, Sendable {
    case verified
    case actionRequired = "action_required"
    case unverified
    case notRequired = "not_required"

    public var title: String {
        switch self {
        case .verified: "已验证"
        case .actionRequired: "需操作"
        case .unverified: "待验证"
        case .notRequired: "无需验证"
        }
    }

    public var requiresUserAction: Bool {
        self == .actionRequired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unverified
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentVerification: Codable, Hashable, Sendable {
    public var status: AgentVerificationStatus
    public var title: String
    public var detail: String
    public var lastVerifiedAt: String?
    public var lastEvent: String?
    public var actionDetail: String?
    public var checkedCWD: String?

    public init(
        status: AgentVerificationStatus,
        title: String,
        detail: String,
        lastVerifiedAt: String? = nil,
        lastEvent: String? = nil,
        actionDetail: String? = nil,
        checkedCWD: String? = nil
    ) {
        self.status = status
        self.title = title
        self.detail = detail
        self.lastVerifiedAt = lastVerifiedAt
        self.lastEvent = lastEvent
        self.actionDetail = actionDetail
        self.checkedCWD = checkedCWD
    }

    public static let pending = AgentVerification(
        status: .unverified,
        title: "Agent 侧验证待检查",
        detail: "当前 PetCore 尚未返回 Agent 侧真实触发的验证信息。"
    )

    enum CodingKeys: String, CodingKey {
        case status
        case title
        case detail
        case lastVerifiedAt = "last_verified_at"
        case lastEvent = "last_event"
        case actionDetail = "action_detail"
        case checkedCWD = "checked_cwd"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(AgentVerificationStatus.self, forKey: .status) ?? .unverified
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.pending.title
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? Self.pending.detail
        lastVerifiedAt = try container.decodeIfPresent(String.self, forKey: .lastVerifiedAt)
        lastEvent = try container.decodeIfPresent(String.self, forKey: .lastEvent)
        actionDetail = try container.decodeIfPresent(String.self, forKey: .actionDetail)
        checkedCWD = try container.decodeIfPresent(String.self, forKey: .checkedCWD)
    }
}

public struct AgentConnectorCapabilities: Codable, Hashable, Sendable {
    public var contractVersion: String
    public var auditedEvents: [String]
    public var subscribedEvents: [String]
    public var mappedInformation: [String]
    public var privacyExclusions: [String]
    public var repairableConnectorIssue: Bool?
    public var canRepairManagedConnector: Bool?
    public var managedPathConflict: Bool?
    public var canUninstallManagedConnector: Bool?
    public var managedComponents: [AgentManagedComponent]

    public init(
        contractVersion: String,
        auditedEvents: [String] = [],
        subscribedEvents: [String],
        mappedInformation: [String],
        privacyExclusions: [String],
        repairableConnectorIssue: Bool? = nil,
        canRepairManagedConnector: Bool? = nil,
        managedPathConflict: Bool? = nil,
        canUninstallManagedConnector: Bool? = nil,
        managedComponents: [AgentManagedComponent] = []
    ) {
        self.contractVersion = contractVersion
        self.auditedEvents = auditedEvents
        self.subscribedEvents = subscribedEvents
        self.mappedInformation = mappedInformation
        self.privacyExclusions = privacyExclusions
        self.repairableConnectorIssue = repairableConnectorIssue
        self.canRepairManagedConnector = canRepairManagedConnector
        self.managedPathConflict = managedPathConflict
        self.canUninstallManagedConnector = canUninstallManagedConnector
        self.managedComponents = managedComponents
    }

    public static let empty = AgentConnectorCapabilities(
        contractVersion: "",
        auditedEvents: [],
        subscribedEvents: [],
        mappedInformation: [],
        privacyExclusions: []
    )

    public var hasReportedCapabilities: Bool {
        !contractVersion.isEmpty
            || !auditedEvents.isEmpty
            || !subscribedEvents.isEmpty
            || !mappedInformation.isEmpty
            || !privacyExclusions.isEmpty
            || repairableConnectorIssue != nil
            || canRepairManagedConnector != nil
            || managedPathConflict != nil
            || canUninstallManagedConnector != nil
            || !managedComponents.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case auditedEvents = "audited_events"
        case subscribedEvents = "subscribed_events"
        case mappedInformation = "mapped_information"
        case privacyExclusions = "privacy_exclusions"
        case repairableConnectorIssue = "repairable_connector_issue"
        case canRepairManagedConnector = "can_repair_managed_connector"
        case managedPathConflict = "managed_path_conflict"
        case canUninstallManagedConnector = "can_uninstall_managed_connector"
        case managedComponents = "managed_components"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decodeIfPresent(String.self, forKey: .contractVersion) ?? ""
        auditedEvents = try container.decodeIfPresent([String].self, forKey: .auditedEvents) ?? []
        subscribedEvents = try container.decodeIfPresent([String].self, forKey: .subscribedEvents) ?? []
        mappedInformation = try container.decodeIfPresent([String].self, forKey: .mappedInformation) ?? []
        privacyExclusions = try container.decodeIfPresent([String].self, forKey: .privacyExclusions) ?? []
        repairableConnectorIssue = try container.decodeIfPresent(Bool.self, forKey: .repairableConnectorIssue)
        canRepairManagedConnector = try container.decodeIfPresent(
            Bool.self,
            forKey: .canRepairManagedConnector
        )
        managedPathConflict = try container.decodeIfPresent(Bool.self, forKey: .managedPathConflict)
        canUninstallManagedConnector = try container.decodeIfPresent(
            Bool.self,
            forKey: .canUninstallManagedConnector
        )
        managedComponents = try container.decodeIfPresent(
            [AgentManagedComponent].self,
            forKey: .managedComponents
        ) ?? []
    }
}

public struct AgentConnectionStatus: Codable, Identifiable, Hashable, Sendable {
    public var id: AgentSource { source }
    public var source: AgentSource
    public var items: [ConnectionCheckItem]
    public var installPaths: [String]
    public var connectorInstalled: Bool?
    public var checkMode: ConnectionCheckMode
    public var checkedAt: String?
    public var verification: AgentVerification
    public var capabilities: AgentConnectorCapabilities

    public init(
        source: AgentSource,
        items: [ConnectionCheckItem],
        installPaths: [String],
        connectorInstalled: Bool? = nil,
        checkMode: ConnectionCheckMode = .runtime,
        checkedAt: String? = nil,
        verification: AgentVerification = .pending,
        capabilities: AgentConnectorCapabilities = .empty
    ) {
        self.source = source
        self.items = items
        self.installPaths = installPaths
        self.connectorInstalled = connectorInstalled
        self.checkMode = checkMode
        self.checkedAt = checkedAt
        self.verification = verification
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case source
        case items
        case installPaths = "install_paths"
        case connectorInstalled = "connector_installed"
        case checkMode = "check_mode"
        case checkedAt = "checked_at"
        case verification
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(AgentSource.self, forKey: .source)
        items = try container.decode([ConnectionCheckItem].self, forKey: .items)
        installPaths = try container.decode([String].self, forKey: .installPaths)
        connectorInstalled = try container.decodeIfPresent(Bool.self, forKey: .connectorInstalled)
        checkMode = try container.decodeIfPresent(ConnectionCheckMode.self, forKey: .checkMode) ?? .runtime
        checkedAt = try container.decodeIfPresent(String.self, forKey: .checkedAt)
        verification = try container.decodeIfPresent(AgentVerification.self, forKey: .verification) ?? .pending
        capabilities = try container.decodeIfPresent(AgentConnectorCapabilities.self, forKey: .capabilities) ?? .empty
    }

    public var hasInstalledConnectorArtifacts: Bool {
        connectorInstalled ?? false
    }

    public var hasRepairableConnectorIssue: Bool {
        capabilities.repairableConnectorIssue == true
            && capabilities.managedPathConflict == false
    }

    public var hasManagedPathConflict: Bool {
        capabilities.managedPathConflict == true
    }

    public var canRepairManagedConnector: Bool {
        capabilities.canRepairManagedConnector == true
            && capabilities.managedPathConflict == false
    }

    public var canUninstallManagedConnector: Bool {
        capabilities.canUninstallManagedConnector == true
            && capabilities.managedPathConflict == false
    }


    public var blockingItems: [ConnectionCheckItem] {
        items.filter { $0.status.isBlocking }
    }

    public var unverifiedItems: [ConnectionCheckItem] {
        items.filter { $0.status == .unverified }
    }

    public var unsupportedItems: [ConnectionCheckItem] {
        items.filter { $0.status == .unsupported }
    }

}
