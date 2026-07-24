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
        guard source == .codex else { return true }
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

    var attentionSources: [AgentSource] {
        AgentSource.allCases.filter { source in
            guard let result = results.first(where: { $0.source == source }) else {
                return true
            }
            return !result.isExactlyConverged
        }
    }
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
    let connectionOperationActive: Bool

    enum CodingKeys: String, CodingKey {
        case safe
        case activeGeneration = "active_generation"
        case connectionOperationActive = "connection_operation_active"
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
