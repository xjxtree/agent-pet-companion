import AgentPetCompanionCore
import Foundation

enum ProductConnectorRefreshStatus: String, Codable, Equatable, Sendable {
    case skippedNotManaged = "skipped_not_managed"
    case current
    case updated
    case pendingHost = "pending_host"
    case conflict
    case failed
}

struct ProductConnectorRefreshResult: Codable, Equatable, Sendable {
    let source: AgentSource
    let status: ProductConnectorRefreshStatus
    let managed: Bool
    let refreshed: Bool
    let ok: Bool
    let verified: Bool
    let expectedVersion: String?
    let activeVersion: String?
    let expectedSkillsSHA256: String?
    let activeSkillsSHA256: String?
    let expectedContentSHA256: String?
    let managedSourceContentSHA256: String?
    let activeContentSHA256: String?
    let detail: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case source
        case status
        case managed
        case refreshed
        case ok
        case verified
        case expectedVersion = "expected_version"
        case activeVersion = "active_version"
        case expectedSkillsSHA256 = "expected_skills_sha256"
        case activeSkillsSHA256 = "active_skills_sha256"
        case expectedContentSHA256 = "expected_content_sha256"
        case managedSourceContentSHA256 = "managed_source_content_sha256"
        case activeContentSHA256 = "active_content_sha256"
        case detail
        case error
    }

    var isExactlyConverged: Bool {
        if !managed {
            return status == .skippedNotManaged && ok && !verified
        }
        guard ok, verified, status == .current || status == .updated else {
            return false
        }
        guard source == .codex else {
            return expectedVersion != nil
                && activeVersion == expectedVersion
                && expectedSkillsSHA256 == nil
                && activeSkillsSHA256 == nil
                && expectedContentSHA256 == nil
                && managedSourceContentSHA256 == nil
                && activeContentSHA256 == nil
        }
        return expectedVersion != nil
            && activeVersion == expectedVersion
            && Self.isSHA256(expectedSkillsSHA256)
            && activeSkillsSHA256 == expectedSkillsSHA256
            && Self.isSHA256(expectedContentSHA256)
            && managedSourceContentSHA256 == expectedContentSHA256
            && activeContentSHA256 == expectedContentSHA256
    }

    private static func isSHA256(_ value: String?) -> Bool {
        value?.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }
}

struct ProductConnectorRefreshReport: Codable, Equatable, Sendable {
    let ok: Bool
    let results: [ProductConnectorRefreshResult]

    var isExactlyConverged: Bool {
        ok
            && results.map(\.source) == AgentSource.allCases
            && results.allSatisfy(\.isExactlyConverged)
    }

    var attentionIssues: [ProductConnectorConvergenceIssue] {
        AgentSource.allCases.compactMap { source in
            guard let result = results.first(where: { $0.source == source }) else {
                return ProductConnectorConvergenceIssue(
                    source: source,
                    reason: .verificationIncomplete
                )
            }
            guard !result.isExactlyConverged else { return nil }
            let reason: ProductConnectorConvergenceIssueReason = switch result.status {
            case .conflict:
                .managedPathConflict
            case .pendingHost:
                .hostUnavailable
            case .failed:
                .refreshFailed
            case .skippedNotManaged, .current, .updated:
                .verificationIncomplete
            }
            return ProductConnectorConvergenceIssue(source: source, reason: reason)
        }
    }
}

enum ProductConnectorConvergenceIssueReason: String, Equatable, Sendable {
    case managedPathConflict
    case hostUnavailable
    case refreshFailed
    case verificationIncomplete
}

struct ProductConnectorConvergenceIssue: Equatable, Sendable {
    let source: AgentSource
    let reason: ProductConnectorConvergenceIssueReason
}

struct ProductConvergenceReceiptSummary: Codable, Equatable, Sendable {
    let totalSources: UInt
    let managedSources: UInt
    let verifiedSources: UInt
    let skippedSources: UInt
    let reportSHA256: String
    let codexSkillsSHA256: String?
    let codexContentSHA256: String?

    enum CodingKeys: String, CodingKey {
        case totalSources = "total_sources"
        case managedSources = "managed_sources"
        case verifiedSources = "verified_sources"
        case skippedSources = "skipped_sources"
        case reportSHA256 = "report_sha256"
        case codexSkillsSHA256 = "codex_skills_sha256"
        case codexContentSHA256 = "codex_content_sha256"
    }
}

struct ProductConvergenceReceipt: Codable, Equatable, Sendable {
    static let schemaVersion = "apc.product-convergence-receipt.v1"

    let schemaVersion: String
    let buildID: String
    let appVersion: String
    let completedAt: String
    let connectorReportSummary: ProductConvergenceReceiptSummary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case buildID = "build_id"
        case appVersion = "app_version"
        case completedAt = "completed_at"
        case connectorReportSummary = "connector_report_summary"
    }

    func exactlyMatches(
        manifest: RuntimeReleaseManifest,
        report: ProductConnectorRefreshReport? = nil
    ) -> Bool {
        guard schemaVersion == Self.schemaVersion,
              buildID == manifest.buildID,
              appVersion == manifest.appVersion,
              connectorReportSummary.totalSources == UInt(AgentSource.allCases.count),
              connectorReportSummary.managedSources
                + connectorReportSummary.skippedSources
                == connectorReportSummary.totalSources,
              connectorReportSummary.verifiedSources
                == connectorReportSummary.managedSources,
              Self.isSHA256(connectorReportSummary.reportSHA256),
              Self.isRFC3339(completedAt)
        else { return false }

        guard let report else { return true }
        let managedCount = report.results.lazy.filter(\.managed).count
        let verifiedCount = report.results.lazy.filter(\.verified).count
        let skippedCount = report.results.lazy.filter {
            !$0.managed && $0.status == .skippedNotManaged
        }.count
        guard connectorReportSummary.managedSources == UInt(managedCount),
              connectorReportSummary.verifiedSources == UInt(verifiedCount),
              connectorReportSummary.skippedSources == UInt(skippedCount)
        else { return false }

        if let codex = report.results.first(where: { $0.source == .codex }),
           codex.managed
        {
            return connectorReportSummary.codexSkillsSHA256
                    == codex.activeSkillsSHA256
                && connectorReportSummary.codexContentSHA256
                    == codex.activeContentSHA256
        }
        return connectorReportSummary.codexSkillsSHA256 == nil
            && connectorReportSummary.codexContentSHA256 == nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func isRFC3339(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil {
            return true
        }
        return ISO8601DateFormatter().date(from: value) != nil
    }
}

struct ProductConvergencePreflight: Codable, Equatable, Sendable {
    let safe: Bool
    let activeGeneration: Bool
    let activeGenerationStatus: String?
    let connectionOperationActive: Bool
    let runtimeReplacementSafe: Bool?

    enum CodingKeys: String, CodingKey {
        case safe
        case activeGeneration = "active_generation"
        case activeGenerationStatus = "active_generation_status"
        case connectionOperationActive = "connection_operation_active"
        case runtimeReplacementSafe = "runtime_replacement_safe"
    }

    init(
        safe: Bool,
        activeGeneration: Bool,
        activeGenerationStatus: String? = nil,
        connectionOperationActive: Bool,
        runtimeReplacementSafe: Bool? = nil
    ) {
        self.safe = safe
        self.activeGeneration = activeGeneration
        self.activeGenerationStatus = activeGenerationStatus
        self.connectionOperationActive = connectionOperationActive
        self.runtimeReplacementSafe = runtimeReplacementSafe
    }
}

/// A manual runtime check may prove that a connector which failed the
/// post-update refresh is now exact and healthy (for example after its host
/// finishes reloading). This narrows the in-memory attention banner, after
/// which AppStore reruns the authoritative four-source convergence flow. The
/// runtime check itself never fabricates a convergence receipt.
enum ProductConvergenceConnectionRecoveryPolicy {
    static func resolvesAttention(_ status: AgentConnectionStatus) -> Bool {
        status.checkMode == .runtime
            && status.connectorInstalled == true
            && status.verification.status == .verified
            && !status.capabilities.contractVersion.isEmpty
            && status.items.contains {
                $0.code == .managedConnector && $0.status == .ok
            }
            && status.items.allSatisfy {
                $0.status == .ok || $0.status == .notRequired
            }
    }
}

@MainActor
final class ProductConvergenceNoticePreferences {
    private static let acknowledgedBuildKey =
        "dev.agentpet.companion.update.convergence.acknowledged-build"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasAcknowledged(buildID: String) -> Bool {
        defaults.string(forKey: Self.acknowledgedBuildKey) == buildID
    }

    func acknowledge(buildID: String) {
        defaults.set(buildID, forKey: Self.acknowledgedBuildKey)
    }
}
