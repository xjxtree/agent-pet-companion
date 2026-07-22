import AgentPetCompanionCore
import AppKit
import CryptoKit
import Darwin
import Foundation
import OSLog

enum AppDiagnosticLogLevel: String, Codable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

enum AppDiagnosticRetentionPolicy {
    static func lifecycleDate(creationDate: Date?, modificationDate: Date?) -> Date? {
        creationDate ?? modificationDate
    }

    static func isExpired(
        creationDate: Date?,
        modificationDate: Date?,
        referenceDate: Date,
        retentionInterval: TimeInterval
    ) -> Bool {
        guard let date = lifecycleDate(
            creationDate: creationDate,
            modificationDate: modificationDate
        ) else { return false }
        return date < referenceDate.addingTimeInterval(-retentionInterval)
    }
}

enum AppDiagnosticMetadataValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int64)
    case double(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        }
    }

    fileprivate var summary: String {
        switch self {
        case let .string(value): value
        case let .bool(value): String(value)
        case let .integer(value): String(value)
        case let .double(value): String(format: "%.3f", value)
        }
    }
}

enum AppDiagnosticRedactor {
    private static let redacted = "<redacted>"
    private static let sensitiveKeyFragments = [
        "authorization", "cookie", "credential", "cwd", "detail", "home", "message",
        "name", "password", "path", "prompt", "secret", "session_id", "title", "token",
        "user_content"
    ]
    private static let sensitiveIdentifierKeys = [
        "address", "computer", "email", "event_id", "host", "hostname", "id", "instance_id",
        "ip", "ip_address", "job_id", "peer", "pet_id", "run_id", "session_id", "turn_id",
        "user", "username"
    ]
    private static let sensitiveIdentityKeySegments: Set<String> = [
        "address", "computer", "email", "host", "hostname", "ip", "peer", "user", "username"
    ]

    static func sanitize(
        metadata: [String: AppDiagnosticMetadataValue]
    ) -> [String: AppDiagnosticMetadataValue] {
        metadata.sorted(by: { $0.key < $1.key }).prefix(64).reduce(into: [:]) { result, pair in
            let (key, value) = pair
            let normalizedKey = safeKey(key)
            if isSensitiveKey(normalizedKey) {
                result[normalizedKey] = .string(redacted)
                return
            }
            switch value {
            case let .string(string):
                result[normalizedKey] = .string(safeString(string))
            case .bool, .integer, .double:
                result[normalizedKey] = value
            }
        }
    }

    static func sanitizeLegacyLog(_ value: String, homeURL: URL) -> String {
        let literalReplacements = [
            homeURL.standardizedFileURL.path,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        ].filter { !$0.isEmpty }
        var result = ""
        let rawLines = value.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in rawLines.enumerated() {
            var line = String(rawLine)
            let containsPrivateRoot = literalReplacements.contains { line.contains($0) }
            let containsPathAssignment = line.range(
                of: #"(?i)\b(cwd|path|home|apc_home)\s*[:=]\s*[\"'(\[]?(?:~/|/)"#,
                options: .regularExpression
            ) != nil
            let containsAbsolutePath = line.range(
                of: #"(?:^|[\s=:"'(\[])(?:~/|/(?!/))[^\r\n]*"#,
                options: .regularExpression
            ) != nil
            let containsSensitiveMarker = line.range(
                of: #"(?i)\b(address|authorization|bearer|computer|cookie|credential|email|host|hostname|ip|password|passwd|peer|secret|session[_-]?id|token|api[_-]?key|user|username)\b"#,
                options: .regularExpression
            ) != nil
            let containsIdentityAssignment = line.range(
                of: #"(?i)(?:^|[^a-z0-9])(?:[a-z0-9]+[_-])*(?:address|computer|email|host|hostname|ip|peer|user|username)(?:[_-][a-z0-9]+)*\s*[:=]"#,
                options: .regularExpression
            ) != nil
            let containsIdentityValue = line.range(
                of: #"(?i)(?:\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|\b[a-z0-9][a-z0-9-]{0,62}\.local\b)"#,
                options: .regularExpression
            ) != nil || containsIPAddress(line)
            if containsSensitiveMarker || containsIdentityAssignment || containsIdentityValue {
                line = "<redacted>"
            } else if containsPrivateRoot || containsPathAssignment || containsAbsolutePath {
                line = "<redacted-path>"
            } else {
                line = sanitizeLegacyNonPathLine(line)
            }
            result += line
            if index + 1 < rawLines.count { result += "\n" }
        }
        return result
    }

    private static func sanitizeLegacyNonPathLine(_ value: String) -> String {
        var result = value
        let patterns: [(String, String)] = [
            (#"(?i)\b(authorization|password|passwd|secret|token|cookie|api[_-]?key)\b\s*[:=]\s*[^\s,;]+"#, "$1=<redacted>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            (#"https?://[^\s\"']+"#, "<url>"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted>"),
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "<redacted>"),
            (#"\b[A-Za-z0-9_+\-/=]{48,}\b"#, "<redacted>"),
        ]
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    static func sanitizeStructuredLog(_ data: Data) -> Data {
        let allowedTopLevelKeys: Set<String> = [
            "category", "component", "event", "fields", "level", "metadata", "process",
            "schema_version", "target", "timestamp"
        ]
        var output = Data()
        for rawLine in data.split(separator: 0x0A) {
            guard !rawLine.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(rawLine)),
                  let dictionary = object as? [String: Any],
                  isValidDiagnosticRecord(dictionary)
            else { continue }
            let sanitized = dictionary.reduce(into: [String: Any]()) { result, pair in
                let key = safeKey(pair.key)
                guard allowedTopLevelKeys.contains(key), !isSensitiveKey(key) else { return }
                result[key] = sanitizeJSONValue(pair.value, key: key, depth: 0)
            }
            guard JSONSerialization.isValidJSONObject(sanitized),
                  var line = try? JSONSerialization.data(
                      withJSONObject: sanitized,
                      options: [.sortedKeys, .withoutEscapingSlashes]
                  )
            else { continue }
            line.append(0x0A)
            output.append(line)
        }
        return output
    }

    private static func isValidDiagnosticRecord(_ value: [String: Any]) -> Bool {
        guard value["schema_version"] as? String == "apc.diagnostic-log.v1",
              let timestamp = value["timestamp"] as? String,
              timestamp.range(
                  of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
                  options: .regularExpression
              ) != nil,
              let process = value["process"] as? String,
              ["app", "petcore"].contains(process),
              let level = value["level"] as? String,
              ["debug", "info", "notice", "warning", "error"].contains(level),
              let category = value["category"] as? String,
              category.range(of: #"^[a-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil,
              let event = value["event"] as? String,
              event.range(of: #"^[a-z0-9_.-]{1,96}$"#, options: .regularExpression) != nil,
              value["metadata"] is [String: Any]
        else { return false }
        return true
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        if sensitiveIdentifierKeys.contains(lowercased) { return true }
        let segments = lowercased.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if segments.contains(where: sensitiveIdentityKeySegments.contains) { return true }
        return sensitiveKeyFragments.contains { lowercased.contains($0) }
    }

    private static func safeKey(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        let normalized = value.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let result = String(normalized.prefix(64))
        return result.isEmpty ? "unknown" : result
    }

    private static func safeString(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let containsSensitiveAssignment = flattened.range(
            of: #"(?i)\b(address|authorization|bearer|computer|cookie|credential|cwd|email|home|host|hostname|ip|message|password|path|peer|prompt|secret|session_id|token|user|username)\b\s*[:=]"#,
            options: .regularExpression
        ) != nil || flattened.range(
            of: #"(?i)(?:^|[^a-z0-9])(?:[a-z0-9]+[_-])*(?:address|computer|email|host|hostname|ip|peer|user|username)(?:[_-][a-z0-9]+)*\s*[:=]"#,
            options: .regularExpression
        ) != nil
        let containsAbsolutePath = flattened.range(
            of: #"(?:^|[\s=:"'(\[])(?:~/|/(?!/))[^\r\n]*"#,
            options: .regularExpression
        ) != nil
        let containsEmail = flattened.range(
            of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: .regularExpression
        ) != nil
        let containsUUID = flattened.range(
            of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            options: .regularExpression
        ) != nil
        let containsLongOpaqueValue = flattened.range(
            of: #"\b[A-Za-z0-9_+\-/=]{48,}\b"#,
            options: .regularExpression
        ) != nil
        let containsIPAddress = containsIPAddress(flattened)
        let containsLocalHostname = flattened.range(
            of: #"(?i)\b[a-z0-9][a-z0-9-]{0,62}\.local\b"#,
            options: .regularExpression
        ) != nil
        if flattened.hasPrefix("/")
            || flattened.hasPrefix("~/")
            || flattened.contains("/Users/")
            || flattened.contains("://")
            || containsSensitiveAssignment
            || containsAbsolutePath
            || containsEmail
            || containsUUID
            || containsLongOpaqueValue
            || containsIPAddress
            || containsLocalHostname
        {
            return redacted
        }
        return String(flattened.prefix(256))
    }

    private static func containsIPAddress(_ value: String) -> Bool {
        if value.range(
            of: #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        let candidateCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        for candidate in value.components(separatedBy: candidateCharacters.inverted)
            where !candidate.isEmpty
        {
            var ipv4 = in_addr()
            if candidate.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
            var ipv6 = in6_addr()
            if candidate.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return true }
        }
        return false
    }

    private static func sanitizeJSONValue(_ value: Any, key: String, depth: Int) -> Any {
        if isSensitiveKey(key) { return redacted }
        guard depth < 6 else { return redacted }
        switch value {
        case let string as String:
            return safeString(string)
        case let number as NSNumber:
            return number
        case let dictionary as [String: Any]:
            return dictionary.sorted(by: { $0.key < $1.key }).prefix(128)
                .reduce(into: [String: Any]()) { result, pair in
                let nestedKey = safeKey(pair.key)
                guard !isSensitiveKey(nestedKey) else { return }
                result[nestedKey] = sanitizeJSONValue(
                    pair.value,
                    key: nestedKey,
                    depth: depth + 1
                )
            }
        case let array as [Any]:
            return array.prefix(64).map {
                sanitizeJSONValue($0, key: key, depth: depth + 1)
            }
        default:
            return redacted
        }
    }
}

private struct AppDiagnosticLogRecord: Codable, Sendable {
    let schemaVersion: String
    let timestamp: String
    let process: String
    let level: AppDiagnosticLogLevel
    let category: String
    let event: String
    let metadata: [String: AppDiagnosticMetadataValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp
        case process
        case level
        case category
        case event
        case metadata
    }
}

final class AppDiagnostics: @unchecked Sendable {
    static let schemaVersion = "apc.diagnostic-log.v1"
    private static let maximumThrottleKeys = 128
    private static let throttleKeyRetention: TimeInterval = 86_400
    static let shared = AppDiagnostics(
        homeURL: AppDiagnosticPaths.defaultHomeURL(),
        enabled: !CommandLine.arguments.contains("--run-ui-validation")
    )
    static let disabled = AppDiagnostics(homeURL: nil, enabled: false)

    let homeURL: URL?
    let logURL: URL?

    private let enabled: Bool
    private let maximumFileBytes: Int
    private let backupCount: Int
    private let retentionDays: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var started = false
    private var lastEmissionByKey: [String: Date] = [:]
    private var storageAvailable = false

    init(
        homeURL: URL?,
        enabled: Bool,
        maximumFileBytes: Int = 2 * 1_024 * 1_024,
        backupCount: Int = 4,
        retentionDays: Int = 14,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.homeURL = homeURL?.standardizedFileURL
        self.enabled = enabled && homeURL != nil
        self.maximumFileBytes = max(1_024, maximumFileBytes)
        self.backupCount = max(0, backupCount)
        self.retentionDays = max(1, retentionDays)
        self.now = now
        logURL = homeURL?.standardizedFileURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("app.jsonl")
        if self.enabled {
            lock.lock()
            storageAvailable = prepareStorageLocked(referenceDate: now())
            if storageAvailable, let homeURL = self.homeURL {
                AppDiagnosticOfflineExporter.maintainArtifacts(
                    homeURL: homeURL,
                    referenceDate: now()
                )
            }
            lock.unlock()
        }
    }

    var trackedThrottleKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastEmissionByKey.count
    }

    @MainActor
    func startSession() {
        guard enabled else { return }
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        log(
            .notice,
            category: "lifecycle",
            event: "app_session_started",
            metadata: AppDiagnosticEnvironment.launchMetadata()
        )
    }

    func log(
        _ level: AppDiagnosticLogLevel,
        category: String,
        event: String,
        metadata: [String: AppDiagnosticMetadataValue] = [:],
        throttleKey: String? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        guard enabled else { return }
        let timestamp = now()
        let safeCategory = String(category.lowercased().prefix(64))
        let safeEvent = String(event.lowercased().prefix(96))
        let safeMetadata = AppDiagnosticRedactor.sanitize(metadata: metadata)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = AppDiagnosticLogRecord(
            schemaVersion: Self.schemaVersion,
            timestamp: formatter.string(from: timestamp),
            process: "app",
            level: level,
            category: safeCategory,
            event: safeEvent,
            metadata: safeMetadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)

        lock.lock()
        if let throttleKey, minimumInterval > 0,
           let previous = lastEmissionByKey[throttleKey],
           timestamp.timeIntervalSince(previous) >= 0,
           timestamp.timeIntervalSince(previous) < minimumInterval
        {
            lock.unlock()
            return
        }
        if let throttleKey {
            let cutoff = timestamp.addingTimeInterval(-Self.throttleKeyRetention)
            lastEmissionByKey = lastEmissionByKey.filter { $0.value >= cutoff }
            if lastEmissionByKey[throttleKey] == nil,
               lastEmissionByKey.count >= Self.maximumThrottleKeys,
               let oldest = lastEmissionByKey.min(by: { $0.value < $1.value })?.key
            {
                lastEmissionByKey.removeValue(forKey: oldest)
            }
            lastEmissionByKey[throttleKey] = timestamp
        }
        storageAvailable = prepareStorageLocked(referenceDate: timestamp)
        if storageAvailable {
            guard data.count <= maximumFileBytes,
                  rotateIfNeededLocked(nextRecordBytes: data.count, referenceDate: timestamp),
                  appendLocked(data)
            else {
                storageAvailable = false
                lock.unlock()
                mirrorToUnifiedLog(
                    level: level,
                    category: safeCategory,
                    event: safeEvent,
                    metadata: safeMetadata
                )
                return
            }
        }
        lock.unlock()

        mirrorToUnifiedLog(
            level: level,
            category: safeCategory,
            event: safeEvent,
            metadata: safeMetadata
        )
    }

    func logFailure(
        _ error: Error,
        category: String,
        event: String,
        metadata: [String: AppDiagnosticMetadataValue] = [:],
        throttleKey: String? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        var safeMetadata = metadata
        let nsError = error as NSError
        safeMetadata["error_type"] = .string(String(reflecting: type(of: error)))
        safeMetadata["error_domain"] = .string(nsError.domain)
        safeMetadata["error_code"] = .integer(Int64(nsError.code))
        log(
            .error,
            category: category,
            event: event,
            metadata: safeMetadata,
            throttleKey: throttleKey,
            minimumInterval: minimumInterval
        )
    }

    private func prepareStorageLocked(referenceDate: Date) -> Bool {
        guard let homeURL, let logURL else { return false }
        let logsURL = logURL.deletingLastPathComponent()
        do {
            try ensurePrivateDirectory(homeURL, createIfMissing: true)
            try ensurePrivateDirectory(logsURL, createIfMissing: true)
            removeExpiredFilesLocked(referenceDate: referenceDate)
            return true
        } catch {
            return false
        }
    }

    private func removeExpiredFilesLocked(referenceDate: Date) {
        guard logURL != nil else { return }
        let cutoff = referenceDate.addingTimeInterval(-Double(retentionDays) * 86_400)
        let backups = backupCount > 0 ? (1 ... backupCount).map(backupURL) : []
        for url in backups {
            guard isRegularFileWithoutFollowingLinks(url),
                  let lifecycleDate = fileLifecycleDate(url),
                  lifecycleDate < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func rotateIfNeededLocked(nextRecordBytes: Int, referenceDate: Date) -> Bool {
        guard let logURL else { return false }
        var status = stat()
        let currentBytes: Int
        if lstat(logURL.path, &status) == 0 {
            guard isRegularFileWithoutFollowingLinks(logURL) else { return false }
            currentBytes = Int(status.st_size)
        } else {
            guard errno == ENOENT else { return false }
            currentBytes = 0
        }
        let cutoff = referenceDate.addingTimeInterval(-Double(retentionDays) * 86_400)
        let isOlderThanRetention = fileLifecycleDate(logURL).map { $0 < cutoff } ?? false
        guard currentBytes > 0,
              currentBytes + nextRecordBytes > maximumFileBytes || isOlderThanRetention
        else { return true }
        do {
            if backupCount > 0 {
                let oldestBackupURL = backupURL(backupCount)
                if pathEntryExists(oldestBackupURL) {
                    guard isRegularFileWithoutFollowingLinks(oldestBackupURL) else { return false }
                    try FileManager.default.removeItem(at: oldestBackupURL)
                }
                if backupCount > 1 {
                    for index in stride(from: backupCount - 1, through: 1, by: -1) {
                        let source = backupURL(index)
                        guard pathEntryExists(source) else { continue }
                        guard isRegularFileWithoutFollowingLinks(source),
                              !pathEntryExists(backupURL(index + 1))
                        else { return false }
                        try FileManager.default.moveItem(at: source, to: backupURL(index + 1))
                    }
                }
                guard isRegularFileWithoutFollowingLinks(logURL),
                      !pathEntryExists(backupURL(1))
                else { return false }
                try FileManager.default.moveItem(at: logURL, to: backupURL(1))
            } else {
                guard isRegularFileWithoutFollowingLinks(logURL) else { return false }
                try FileManager.default.removeItem(at: logURL)
            }
            return true
        } catch {
            return false
        }
    }

    private func appendLocked(_ data: Data) -> Bool {
        guard let logURL else { return false }
        let descriptor = Darwin.open(
            logURL.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else { return false }
        return data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private func backupURL(_ index: Int) -> URL {
        guard let logURL else { return URL(fileURLWithPath: "/dev/null") }
        return logURL.deletingLastPathComponent()
            .appendingPathComponent("app.\(index).jsonl")
    }

    private func fileLifecycleDate(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return AppDiagnosticRetentionPolicy.lifecycleDate(
            creationDate: attributes[.creationDate] as? Date,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private func mirrorToUnifiedLog(
        level: AppDiagnosticLogLevel,
        category: String,
        event: String,
        metadata: [String: AppDiagnosticMetadataValue]
    ) {
        let logger = Logger(subsystem: "dev.agentpet.companion", category: category)
        let summary = metadata.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value.summary)" }
            .joined(separator: " ")
        switch level {
        case .debug:
            logger.debug("\(event, privacy: .public) \(summary, privacy: .private)")
        case .info:
            logger.info("\(event, privacy: .public) \(summary, privacy: .private)")
        case .notice:
            logger.notice("\(event, privacy: .public) \(summary, privacy: .private)")
        case .warning:
            logger.warning("\(event, privacy: .public) \(summary, privacy: .private)")
        case .error:
            logger.error("\(event, privacy: .public) \(summary, privacy: .private)")
        }
    }
}

enum AppDiagnosticPaths {
    static func defaultHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["APC_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("AgentPetCompanion", isDirectory: true)
            .standardizedFileURL
    }

    static func diagnosticExportsURL(homeURL: URL) -> URL {
        homeURL.standardizedFileURL
            .appendingPathComponent("diagnostic-exports", isDirectory: true)
    }
}

struct AppDiagnosticEnvironment: Codable, Equatable, Sendable {
    static let schemaVersion = "apc.app-environment.v1"

    struct AppInfo: Codable, Equatable, Sendable {
        let version: String
        let build: String
        let buildID: String
        let channel: String
        let bundleID: String
    }

    struct DeviceInfo: Codable, Equatable, Sendable {
        let operatingSystem: String
        let operatingSystemVersion: String
        let operatingSystemBuild: String
        let architecture: String
        let translated: Bool
        let processorCount: Int
        let physicalMemoryBytes: UInt64
        let locale: String
        let timezone: String
        let screens: [ScreenInfo]
        let accessibility: AccessibilityInfo
    }

    struct ScreenInfo: Codable, Equatable, Sendable {
        let widthPixels: Int
        let heightPixels: Int
        let scale: Double
    }

    struct AccessibilityInfo: Codable, Equatable, Sendable {
        let reduceMotion: Bool
        let reduceTransparency: Bool
        let voiceOverEnabled: Bool
    }

    struct BehaviorInfo: Codable, Equatable, Sendable {
        let enabled: Bool
        let statusBubble: Bool
        let appearanceTheme: String
        let bubbleTransparency: Double
        let clickMenu: Bool
        let mousePassthrough: Bool
        let autoHide: Bool
        let sessionMessageTimeoutMinutes: Int
        let sessionGroupDisplay: String
        let fpsProfile: String
        let sources: [String: Bool]
        let events: [String: Bool]
    }

    struct RuntimeInfo: Codable, Equatable, Sendable {
        let petCorePhase: String
        let petCoreVersion: String?
        let petCoreAppBuild: String?
        let petCoreBuildID: String?
        let petCoreRPCProtocol: String?
        let releaseChannel: String?
        let databaseSchemaRange: String?
        let lastServiceFailureCode: String
        let activePetPresent: Bool
        let petCount: Int
        let activeAgentSource: String?
        let activeAgentState: String?
        let activeSessionCount: Int
        let recentEventCount: Int
        let generationState: String
        let overlayVisible: Bool
    }

    struct ConnectionInfo: Codable, Equatable, Sendable {
        let source: String
        let checkMode: String
        let connectorInstalled: Bool?
        let blockingCount: Int
        let unverifiedCount: Int
        let unsupportedCount: Int
    }

    let schemaVersion: String
    let capturedAt: String
    let app: AppInfo
    let device: DeviceInfo
    let behavior: BehaviorInfo
    let runtime: RuntimeInfo
    let connections: [ConnectionInfo]

    @MainActor
    static func capture(store: AppStore, bundle: Bundle = .main) -> Self {
        let behavior = store.behavior
        return Self(
            schemaVersion: schemaVersion,
            capturedAt: timestamp(),
            app: appInfo(bundle: bundle),
            device: deviceInfo(),
            behavior: BehaviorInfo(
                enabled: behavior.enabled,
                statusBubble: behavior.statusBubble,
                appearanceTheme: behavior.appearanceTheme.rawValue,
                bubbleTransparency: behavior.bubbleTransparency,
                clickMenu: behavior.clickMenu,
                mousePassthrough: behavior.mousePassthrough,
                autoHide: behavior.autoHide,
                sessionMessageTimeoutMinutes: behavior.sessionMessageTimeoutMinutes,
                sessionGroupDisplay: behavior.sessionGroupDisplay.rawValue,
                fpsProfile: behavior.fpsProfile.rawValue,
                sources: Dictionary(uniqueKeysWithValues: behavior.sources.map { ($0.key.rawValue, $0.value) }),
                events: Dictionary(uniqueKeysWithValues: behavior.events.map { ($0.key.rawValue, $0.value) })
            ),
            runtime: RuntimeInfo(
                petCorePhase: phaseName(store.petCoreRuntimeInfo.phase),
                petCoreVersion: sanitizedRuntimeToken(store.petCoreRuntimeInfo.version),
                petCoreAppBuild: sanitizedRuntimeToken(store.petCoreRuntimeInfo.appBuild),
                petCoreBuildID: sanitizedRuntimeToken(store.petCoreRuntimeInfo.buildID),
                petCoreRPCProtocol: sanitizedRuntimeToken(store.petCoreRuntimeInfo.rpcProtocol),
                releaseChannel: sanitizedRuntimeToken(store.petCoreRuntimeInfo.releaseChannel),
                databaseSchemaRange: sanitizedRuntimeToken(
                    store.petCoreRuntimeInfo.databaseSchemaRange,
                    permitsRangeDash: true
                ),
                lastServiceFailureCode: store.lastServiceFailureCode.rawValue,
                activePetPresent: store.activePet != nil,
                petCount: store.pets.count,
                activeAgentSource: store.activeAgentState?.source.rawValue,
                activeAgentState: sanitizedPetState(store.activeAgentState?.state),
                activeSessionCount: store.activeAgentSessions.count,
                recentEventCount: store.recentEvents.count,
                generationState: store.generationSession.state.rawValue,
                overlayVisible: store.overlayVisible
            ),
            connections: store.connections.map { status in
                ConnectionInfo(
                    source: status.source.rawValue,
                    checkMode: status.checkMode.rawValue,
                    connectorInstalled: status.connectorInstalled,
                    blockingCount: status.blockingItems.count,
                    unverifiedCount: status.unverifiedItems.count,
                    unsupportedCount: status.unsupportedItems.count
                )
            }
        )
    }

    static func sanitizedRuntimeToken(
        _ value: String?,
        permitsRangeDash: Bool = false
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = permitsRangeDash
            ? #"^[A-Za-z0-9._+:-–]{1,128}$"#
            : #"^[A-Za-z0-9._+:-]{1,128}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil ? trimmed : nil
    }

    static func sanitizedPetState(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed: Set<String> = [
            "idle", "thinking", "start", "working", "tool", "waiting", "review", "done", "failed"
        ]
        return allowed.contains(value) ? value : nil
    }

    func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppDiagnosticArchiveError.invalidEnvironment
        }
        return object
    }

    func encoded(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    @MainActor
    static func launchMetadata(bundle: Bundle = .main) -> [String: AppDiagnosticMetadataValue] {
        let app = appInfo(bundle: bundle)
        let device = deviceInfo()
        return [
            "app_version": .string(app.version),
            "app_build": .string(app.build),
            "build_id": .string(app.buildID),
            "channel": .string(app.channel),
            "bundle_id": .string(app.bundleID),
            "os_version": .string(device.operatingSystemVersion),
            "os_build": .string(device.operatingSystemBuild),
            "architecture": .string(device.architecture),
            "translated": .bool(device.translated),
            "processor_count": .integer(Int64(device.processorCount)),
            "physical_memory_bytes": .integer(Int64(clamping: device.physicalMemoryBytes)),
            "locale": .string(device.locale),
            "timezone": .string(device.timezone),
            "screen_count": .integer(Int64(device.screens.count)),
            "reduce_motion": .bool(device.accessibility.reduceMotion),
            "reduce_transparency": .bool(device.accessibility.reduceTransparency),
            "voice_over": .bool(device.accessibility.voiceOverEnabled)
        ]
    }

    private static func appInfo(bundle: Bundle) -> AppInfo {
        let manifest = PetCoreRuntimeContract.requiredManifest
        return AppInfo(
            version: string(bundle, "CFBundleShortVersionString") ?? manifest?.appVersion ?? "development",
            build: string(bundle, "CFBundleVersion") ?? manifest?.appBuild ?? "development",
            buildID: string(bundle, "APCBuildID") ?? manifest?.buildID ?? "development",
            channel: string(bundle, "APCReleaseChannel") ?? manifest?.releaseChannel ?? "develop",
            bundleID: bundle.bundleIdentifier ?? "dev.agentpet.companion"
        )
    }

    @MainActor
    private static func deviceInfo() -> DeviceInfo {
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        let workspace = NSWorkspace.shared
        return DeviceInfo(
            operatingSystem: "macOS",
            operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemBuild: sysctlString("kern.osversion") ?? "unknown",
            architecture: architecture,
            translated: isTranslated,
            processorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            screens: NSScreen.screens.map { screen in
                ScreenInfo(
                    widthPixels: Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                    heightPixels: Int((screen.frame.height * screen.backingScaleFactor).rounded()),
                    scale: screen.backingScaleFactor
                )
            },
            accessibility: AccessibilityInfo(
                reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                voiceOverEnabled: workspace.isVoiceOverEnabled
            )
        )
    }

    private static func string(_ bundle: Bundle, _ key: String) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func phaseName(_ phase: PetCoreRuntimePhase) -> String {
        switch phase {
        case .checking: "checking"
        case .running: "running"
        case .failed: "failed"
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(
            decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

struct AppDiagnosticRPCExportResult: Decodable, Equatable, Sendable {
    let path: String
    let fileName: String
    let fileCount: Int
    let archiveBytes: Int

    enum CodingKeys: String, CodingKey {
        case path
        case fileName = "file_name"
        case fileCount = "file_count"
        case archiveBytes = "archive_bytes"
    }

    static func decode(_ value: Any) throws -> Self {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

enum AppDiagnosticArchiveError: Error {
    case invalidEnvironment
    case invalidArchive
    case unsafeArchive
    case archiveTooLarge
    case archiverFailed
}

enum AppDiagnosticArchiveSecurity {
    static let maximumArchiveBytes = 128 * 1_024 * 1_024

    static func validateTemporaryArchive(
        _ archiveURL: URL,
        homeURL: URL,
        expectedFileName: String? = nil,
        expectedBytes: Int? = nil
    ) throws -> URL {
        let archive = archiveURL.standardizedFileURL
        let exports = AppDiagnosticPaths.diagnosticExportsURL(homeURL: homeURL).standardizedFileURL
        guard isPrivateDirectory(exports) else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        guard archive.isFileURL,
              archive.pathExtension.lowercased() == "zip",
              expectedFileName.map({ $0 == archive.lastPathComponent }) ?? true,
              archive.deletingLastPathComponent() == exports,
              exports.resolvingSymlinksInPath() == exports,
              archive.resolvingSymlinksInPath() == archive
        else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        var status = stat()
        guard lstat(archive.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & 0o077 == 0,
              status.st_size > 0,
              expectedBytes.map({ $0 == Int(status.st_size) }) ?? true
        else {
            throw AppDiagnosticArchiveError.invalidArchive
        }
        guard status.st_size <= maximumArchiveBytes else {
            throw AppDiagnosticArchiveError.archiveTooLarge
        }
        try validateZIPSignatures(archive, expectedStatus: status)
        return archive
    }

    static func install(_ sourceURL: URL, at destinationURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let destination = destinationURL.standardizedFileURL
            let parent = destination.deletingLastPathComponent()
            let temporary = parent.appendingPathComponent(".apc-diagnostics-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }

            if fileManager.fileExists(atPath: destination.path) {
                var status = stat()
                guard lstat(destination.path, &status) == 0,
                      status.st_mode & S_IFMT == S_IFREG,
                      status.st_uid == getuid(),
                      status.st_nlink == 1
                else {
                    throw AppDiagnosticArchiveError.unsafeArchive
                }
            }
            try copyRegularArchive(sourceURL, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try finalizeInstalledArchive(destination)
        }.value
    }

    private static func finalizeInstalledArchive(_ destination: URL) throws {
        let chmodResult = chmod(destination.path, 0o600)
        let chmodError = errno
        var status = stat()
        guard lstat(destination.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1
        else { throw AppDiagnosticArchiveError.unsafeArchive }
        if chmodResult == 0 {
            guard status.st_mode & 0o077 == 0 else {
                throw AppDiagnosticArchiveError.unsafeArchive
            }
        } else {
            // User-selected removable volumes may not implement POSIX modes. Internal
            // staging remains strict; the final destination still must be a regular,
            // singly linked file owned by the current user.
            guard chmodError == ENOTSUP || chmodError == EOPNOTSUPP || chmodError == EINVAL else {
                throw AppDiagnosticArchiveError.unsafeArchive
            }
        }
    }

    private static func copyRegularArchive(_ sourceURL: URL, to destinationURL: URL) throws {
        var sourceStatus = stat()
        guard lstat(sourceURL.path, &sourceStatus) == 0,
              sourceStatus.st_mode & S_IFMT == S_IFREG,
              sourceStatus.st_uid == getuid(),
              sourceStatus.st_nlink == 1,
              sourceStatus.st_size > 0,
              sourceStatus.st_size <= maximumArchiveBytes
        else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        let source = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard source >= 0 else { throw AppDiagnosticArchiveError.unsafeArchive }
        defer { Darwin.close(source) }
        var openedStatus = stat()
        guard fstat(source, &openedStatus) == 0,
              openedStatus.st_dev == sourceStatus.st_dev,
              openedStatus.st_ino == sourceStatus.st_ino,
              openedStatus.st_nlink == 1
        else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }

        let destination = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destination >= 0 else { throw AppDiagnosticArchiveError.unsafeArchive }
        defer { Darwin.close(destination) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var totalBytes = 0
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw AppDiagnosticArchiveError.invalidArchive
            }
            totalBytes += count
            guard totalBytes <= maximumArchiveBytes else {
                throw AppDiagnosticArchiveError.archiveTooLarge
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination,
                        bytes.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                }
                guard written > 0 else {
                    if errno == EINTR { continue }
                    throw AppDiagnosticArchiveError.invalidArchive
                }
                offset += written
            }
        }
        guard totalBytes > 0 else { throw AppDiagnosticArchiveError.invalidArchive }
        var destinationStatus = stat()
        guard fchmod(destination, S_IRUSR | S_IWUSR) == 0,
              fsync(destination) == 0,
              fstat(destination, &destinationStatus) == 0,
              destinationStatus.st_mode & S_IFMT == S_IFREG,
              destinationStatus.st_uid == getuid(),
              destinationStatus.st_nlink == 1,
              destinationStatus.st_mode & 0o077 == 0
        else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
    }

    private static func validateZIPSignatures(_ archiveURL: URL, expectedStatus: stat) throws {
        let descriptor = Darwin.open(archiveURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AppDiagnosticArchiveError.invalidArchive }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == expectedStatus.st_dev,
              openedStatus.st_ino == expectedStatus.st_ino,
              openedStatus.st_nlink == 1,
              openedStatus.st_size == expectedStatus.st_size
        else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }

        var localHeader = [UInt8](repeating: 0, count: 4)
        guard pread(descriptor, &localHeader, localHeader.count, 0) == localHeader.count,
              localHeader == [0x50, 0x4B, 0x03, 0x04]
        else {
            throw AppDiagnosticArchiveError.invalidArchive
        }
        let maximumEOCDSearchBytes = 65_557
        let tailSize = min(Int(openedStatus.st_size), maximumEOCDSearchBytes)
        var tail = [UInt8](repeating: 0, count: tailSize)
        let tailOffset = openedStatus.st_size - off_t(tailSize)
        guard pread(descriptor, &tail, tail.count, tailOffset) == tail.count else {
            throw AppDiagnosticArchiveError.invalidArchive
        }
        let signature = Data([0x50, 0x4B, 0x05, 0x06])
        guard Data(tail).range(of: signature, options: .backwards) != nil else {
            throw AppDiagnosticArchiveError.invalidArchive
        }
    }
}

enum AppDiagnosticOfflineExporter {
    private static let manifestSchemaVersion = "apc.diagnostics-bundle.v1"
    private static let environmentSchemaVersion = "apc.diagnostic-environment.v1"
    private static let privacyProfile = "apc.diagnostic-redaction.v1"
    private static let maximumSourceBytes = 4 * 1_024 * 1_024
    private static let maximumLegacyBytes = 2 * 1_024 * 1_024
    private static let maximumIncludedLogBytes = 32 * 1_024 * 1_024

    private struct ManifestFile: Codable, Equatable, Sendable {
        let name: String
        let sourceBytes: Int
        let includedBytes: Int
        let truncated: Bool
        let sha256: String
    }

    private enum OmissionReason: String, Codable, Sendable {
        case aggregateLimit = "aggregate_limit"
        case expired
        case invalidJSON = "invalid_json"
        case noCompleteRecords = "no_complete_records"
        case readFailed = "read_failed"
        case unsafeFile = "unsafe_file"
    }

    private struct ManifestOmittedFile: Codable, Equatable, Sendable {
        let name: String
        let reason: OmissionReason
    }

    private struct ExportManifest: Encodable, Sendable {
        let schemaVersion: String
        let createdAt: String
        let mode: String
        let privacyProfile: String
        let logSchemaVersion: String
        let logCurrentMaxBytes: Int
        let logBackupCount: Int
        let logRetentionDays: Int
        let runtimeManifest: RuntimeReleaseManifest?
        let files: [ManifestFile]
        let omittedFiles: [ManifestOmittedFile]
    }

    private struct CopiedLogs: Sendable {
        var files: [ManifestFile]
        var omittedFiles: [ManifestOmittedFile]
    }

    static func makeArchive(
        environment: AppDiagnosticEnvironment,
        homeURL: URL
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try await makeArchiveOffMainActor(environment: environment, homeURL: homeURL)
        }.value
    }

    private static func makeArchiveOffMainActor(
        environment: AppDiagnosticEnvironment,
        homeURL: URL
    ) async throws -> URL {
        let fileManager = FileManager.default
        let exportsURL = AppDiagnosticPaths.diagnosticExportsURL(homeURL: homeURL)
        try ensurePrivateDirectory(homeURL.standardizedFileURL, createIfMissing: true)
        try ensurePrivateDirectory(exportsURL, createIfMissing: true)
        maintainArtifacts(homeURL: homeURL, referenceDate: Date())

        let workURL = exportsURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = workURL.appendingPathComponent("AgentPetCompanion-Diagnostics", isDirectory: true)
        let stagedLogsURL = bundleURL.appendingPathComponent("logs", isDirectory: true)
        let archiveURL = exportsURL.appendingPathComponent("offline-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: workURL) }
        try ensurePrivateDirectory(workURL, createIfMissing: true)
        try ensurePrivateDirectory(bundleURL, createIfMissing: true)
        try ensurePrivateDirectory(stagedLogsURL, createIfMissing: true)

        let copiedLogs = try copyAllowedLogs(
            from: homeURL.appendingPathComponent("logs", isDirectory: true),
            to: stagedLogsURL,
            homeURL: homeURL
        )
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let environmentObject: [String: Any] = [
            "schema_version": environmentSchemaVersion,
            "created_at": createdAt,
            "app": try environment.jsonObject(),
            "petcore": [
                "available": false,
                "capture_mode": "offline_fallback"
            ]
        ]
        let environmentData = try JSONSerialization.data(
            withJSONObject: environmentObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try write(environmentData, to: bundleURL.appendingPathComponent("environment.json"))
        let readme = """
        Agent Pet Companion diagnostics / 诊断日志

        This archive contains bounded App and PetCore logs plus a sanitized environment snapshot.
        It excludes prompts, message contents, file contents, credentials, pet assets, databases, and the full process environment.

        此压缩包仅包含受限大小的 App、PetCore 日志和脱敏环境快照；不包含提示词、消息或文件内容、凭据、宠物资源、数据库及完整环境变量。
        """
        let readmeData = Data(readme.utf8)
        try write(readmeData, to: bundleURL.appendingPathComponent("README.txt"))
        let fixedFiles = [
            manifestFile(name: "environment.json", data: environmentData),
            manifestFile(name: "README.txt", data: readmeData)
        ]
        let manifest = ExportManifest(
            schemaVersion: manifestSchemaVersion,
            createdAt: createdAt,
            mode: "offline_fallback",
            privacyProfile: privacyProfile,
            logSchemaVersion: AppDiagnostics.schemaVersion,
            logCurrentMaxBytes: 2 * 1_024 * 1_024,
            logBackupCount: 4,
            logRetentionDays: 14,
            runtimeManifest: PetCoreRuntimeContract.requiredManifest,
            files: fixedFiles + copiedLogs.files,
            omittedFiles: copiedLogs.omittedFiles
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.keyEncodingStrategy = .convertToSnakeCase
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try manifestEncoder.encode(manifest)
        try write(manifestData, to: bundleURL.appendingPathComponent("manifest.json"))

        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--norsrc", "--keepParent", bundleURL.path, archiveURL.path],
            timeout: .seconds(30),
            outputLimit: 16 * 1_024
        )
        guard result.termination == .exited(status: 0) else {
            throw AppDiagnosticArchiveError.archiverFailed
        }
        guard chmod(archiveURL.path, 0o600) == 0 else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        return try AppDiagnosticArchiveSecurity.validateTemporaryArchive(
            archiveURL,
            homeURL: homeURL
        )
    }

    private static func copyAllowedLogs(
        from logsURL: URL,
        to destinationURL: URL,
        homeURL: URL
    ) throws -> CopiedLogs {
        guard isPrivateDirectory(logsURL) else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        var copied: [ManifestFile] = []
        var omitted: [ManifestOmittedFile] = []
        var remainingIncludedBytes = maximumIncludedLogBytes
        for name in allowedLogNames() {
            let source = logsURL.appendingPathComponent(name)
            guard pathEntryExists(source) else { continue }
            guard source.deletingLastPathComponent().standardizedFileURL
                == logsURL.standardizedFileURL,
                isRegularFileWithoutFollowingLinks(source)
            else {
                omitted.append(ManifestOmittedFile(name: name, reason: .unsafeFile))
                continue
            }
            guard remainingIncludedBytes > 0 else {
                omitted.append(ManifestOmittedFile(name: name, reason: .aggregateLimit))
                continue
            }
            let isLegacy = isLegacyLogName(name)
            let sourceLimit = isLegacy ? maximumLegacyBytes : maximumSourceBytes
            var status = stat()
            guard lstat(source.path, &status) == 0, status.st_size >= 0 else {
                omitted.append(ManifestOmittedFile(name: name, reason: .readFailed))
                continue
            }
            if isPetCoreStructuredLogName(name), isExpiredLog(source, referenceDate: Date()) {
                omitted.append(ManifestOmittedFile(name: name, reason: .expired))
                continue
            }
            let sourceBytes = Int(status.st_size)
            let data: Data
            do {
                data = try tailData(
                    at: source,
                    limit: sourceLimit
                )
            } catch {
                omitted.append(ManifestOmittedFile(name: name, reason: .readFailed))
                continue
            }
            var truncated = sourceBytes > sourceLimit
            var output: Data
            if isLegacy {
                let text = String(decoding: data, as: UTF8.self)
                output = Data(AppDiagnosticRedactor.sanitizeLegacyLog(text, homeURL: homeURL).utf8)
            } else {
                let lineCounts = structuredLineCounts(data)
                if !data.isEmpty, lineCounts.valid == 0 {
                    omitted.append(ManifestOmittedFile(name: name, reason: .invalidJSON))
                    continue
                }
                truncated = truncated || lineCounts.invalid > 0
                output = AppDiagnosticRedactor.sanitizeStructuredLog(data)
            }
            if output.count > remainingIncludedBytes {
                output = completeLinePrefix(output, maximumBytes: remainingIncludedBytes)
                truncated = true
            }
            if sourceBytes > 0, output.isEmpty {
                omitted.append(ManifestOmittedFile(name: name, reason: .noCompleteRecords))
                continue
            }
            let destination = destinationURL.appendingPathComponent(name)
            try write(output, to: destination)
            copied.append(ManifestFile(
                name: "logs/\(name)",
                sourceBytes: sourceBytes,
                includedBytes: output.count,
                truncated: truncated,
                sha256: sha256(output)
            ))
            remainingIncludedBytes -= output.count
        }
        return CopiedLogs(files: copied, omittedFiles: omitted)
    }

    private static func allowedLogNames() -> [String] {
        var names = [
            "app.jsonl",
            "petcore.jsonl",
            "petcore-launch.log",
            "petcore.launchd.out.log",
            "petcore.launchd.err.log"
        ]
        for index in 1 ... 4 {
            names.append("app.\(index).jsonl")
            names.append("petcore.\(index).jsonl")
        }
        names.append("petcore-launch.1.log")
        names.append("petcore-launch.2.log")
        return names
    }

    private static func isLegacyLogName(_ name: String) -> Bool {
        [
            "petcore-launch.log",
            "petcore-launch.1.log",
            "petcore-launch.2.log",
            "petcore.launchd.out.log",
            "petcore.launchd.err.log"
        ].contains(name)
    }

    private static func isPetCoreStructuredLogName(_ name: String) -> Bool {
        name == "petcore.jsonl"
            || (1 ... 4).contains(where: { name == "petcore.\($0).jsonl" })
    }

    private static func isExpiredLog(_ url: URL, referenceDate: Date) -> Bool {
        guard let lifecycleDate = fileLifecycleDate(url) else { return false }
        return lifecycleDate < referenceDate.addingTimeInterval(-14 * 86_400)
    }

    private static func manifestFile(name: String, data: Data) -> ManifestFile {
        ManifestFile(
            name: name,
            sourceBytes: data.count,
            includedBytes: data.count,
            truncated: false,
            sha256: sha256(data)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func structuredLineCounts(_ data: Data) -> (valid: Int, invalid: Int) {
        var valid = 0
        var invalid = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            var candidate = Data(line)
            candidate.append(0x0A)
            if !AppDiagnosticRedactor.sanitizeStructuredLog(candidate).isEmpty {
                valid += 1
            } else {
                invalid += 1
            }
        }
        return (valid, invalid)
    }

    private static func completeLinePrefix(_ data: Data, maximumBytes: Int) -> Data {
        guard maximumBytes > 0 else { return Data() }
        guard data.count > maximumBytes else { return data }
        let prefix = data.prefix(maximumBytes)
        guard let newline = prefix.lastIndex(of: 0x0A) else { return Data() }
        return Data(prefix[...newline])
    }

    private static func tailData(
        at url: URL,
        limit: Int
    ) throws -> Data {
        var beforeOpen = stat()
        guard lstat(url.path, &beforeOpen) == 0,
              beforeOpen.st_mode & S_IFMT == S_IFREG,
              beforeOpen.st_uid == getuid(),
              beforeOpen.st_nlink == 1
        else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AppDiagnosticArchiveError.unsafeArchive }
        defer { Darwin.close(descriptor) }
        var afterOpen = stat()
        guard fstat(descriptor, &afterOpen) == 0,
              afterOpen.st_dev == beforeOpen.st_dev,
              afterOpen.st_ino == beforeOpen.st_ino,
              afterOpen.st_mode & S_IFMT == S_IFREG,
              afterOpen.st_uid == getuid(),
              afterOpen.st_nlink == 1
        else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        let size = max(0, Int(afterOpen.st_size))
        let readBytes = min(size, limit)
        let offset = max(0, size - readBytes)
        var data = Data(count: readBytes)
        let bytesRead = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var total = 0
            while total < bytes.count {
                let count = pread(
                    descriptor,
                    baseAddress.advanced(by: total),
                    bytes.count - total,
                    off_t(offset + total)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                total += count
            }
            return total
        }
        guard bytesRead == readBytes else { throw AppDiagnosticArchiveError.unsafeArchive }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        var status = stat()
        guard chmod(url.path, 0o600) == 0,
              lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & 0o077 == 0
        else {
            try? FileManager.default.removeItem(at: url)
            throw AppDiagnosticArchiveError.unsafeArchive
        }
    }

    static func maintainArtifacts(homeURL: URL, referenceDate: Date = Date()) {
        let exportsURL = AppDiagnosticPaths.diagnosticExportsURL(homeURL: homeURL)
        guard isPrivateDirectory(exportsURL) else { return }
        removeExpiredExportArtifacts(in: exportsURL, referenceDate: referenceDate)
    }

    private enum ExportArtifactKind {
        case completed
        case temporaryDirectory
        case temporaryFile
    }

    private static func exportArtifactKind(_ name: String) -> ExportArtifactKind? {
        if name.range(
            of: #"^AgentPetCompanion-Diagnostics-[0-9]{8}T[0-9]{6,18}Z(?:-[0-9]{1,4}|-overflow)?\.zip$"#,
            options: .regularExpression
        ) != nil || name.range(
            of: #"^offline-[0-9A-Fa-f-]{36}\.zip$"#,
            options: .regularExpression
        ) != nil {
            return .completed
        }
        if name.range(
            of: #"^\.diagnostic-export-[A-Za-z0-9._-]{1,128}$"#,
            options: .regularExpression
        ) != nil {
            return .temporaryFile
        }
        if name.range(
            of: #"^\.staging-[0-9A-Fa-f-]{36}$"#,
            options: .regularExpression
        ) != nil {
            return .temporaryDirectory
        }
        return nil
    }

    private static func removeExpiredExportArtifacts(in exportsURL: URL, referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-86_400)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: exportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        var retainedArchives: [(url: URL, modifiedAt: Date, bytes: Int)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard let kind = exportArtifactKind(name),
                  let modifiedAt = fileLifecycleDate(entry)
            else { continue }
            var status = stat()
            guard lstat(entry.path, &status) == 0,
                  status.st_uid == getuid()
            else { continue }

            switch kind {
            case .completed:
                guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { continue }
                if modifiedAt < cutoff {
                    try? FileManager.default.removeItem(at: entry)
                } else {
                    retainedArchives.append((entry, modifiedAt, max(0, Int(status.st_size))))
                }
            case .temporaryFile:
                guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { continue }
                if modifiedAt < cutoff { try? FileManager.default.removeItem(at: entry) }
            case .temporaryDirectory:
                guard status.st_mode & S_IFMT == S_IFDIR,
                      status.st_nlink >= 1,
                      status.st_mode & 0o077 == 0
                else { continue }
                if modifiedAt < cutoff { try? FileManager.default.removeItem(at: entry) }
            }
        }

        var retainedBytes = 0
        for (index, archive) in retainedArchives
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .enumerated()
        {
            retainedBytes += max(0, archive.bytes)
            if index >= 3 || retainedBytes > AppDiagnosticArchiveSecurity.maximumArchiveBytes {
                try? FileManager.default.removeItem(at: archive.url)
            }
        }
    }
}

enum AppLegacyLogMaintenance {
    private static let maximumBytes = 1 * 1_024 * 1_024
    private static let retentionInterval: TimeInterval = 14 * 86_400

    static func maintain(logsURL: URL, referenceDate: Date = Date()) throws {
        try ensurePrivateDirectory(logsURL.deletingLastPathComponent(), createIfMissing: true)
        try ensurePrivateDirectory(logsURL, createIfMissing: true)
        try rotateDirectLogIfNeeded(
            logsURL.appendingPathComponent("petcore-launch.log"),
            referenceDate: referenceDate
        )
        for name in ["petcore.launchd.out.log", "petcore.launchd.err.log"] {
            let url = logsURL.appendingPathComponent(name)
            guard pathEntryExists(url) else { continue }
            guard isRegularFileWithoutFollowingLinks(url) else {
                throw AppDiagnosticArchiveError.unsafeArchive
            }
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw AppDiagnosticArchiveError.unsafeArchive
            }
            guard chmod(url.path, 0o600) == 0 else {
                throw AppDiagnosticArchiveError.unsafeArchive
            }
            if status.st_size > maximumBytes {
                // Preserve the newest complete lines from legacy launchd output. Maintenance
                // runs after bootout, and the migrated property list sends future bootstrap
                // output to /dev/null, so the bounded atomic replacement has no active writer.
                let tail = try boundedTail(of: url, expectedStatus: status)
                try replacePrivately(tail, at: url, expectedStatus: status)
            } else if isExpired(url, referenceDate: referenceDate) {
                try replacePrivately(Data(), at: url, expectedStatus: status)
            }
        }
    }

    static func openSecureAppendHandle(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw AppDiagnosticArchiveError.unsafeArchive }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            Darwin.close(descriptor)
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func appendSecurely(_ data: Data, to url: URL) throws {
        let handle = try openSecureAppendHandle(at: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func boundedTail(of url: URL, expectedStatus: stat) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AppDiagnosticArchiveError.unsafeArchive }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == expectedStatus.st_dev,
              openedStatus.st_ino == expectedStatus.st_ino,
              openedStatus.st_uid == getuid(),
              openedStatus.st_nlink == 1,
              openedStatus.st_mode & S_IFMT == S_IFREG
        else { throw AppDiagnosticArchiveError.unsafeArchive }

        let fileBytes = max(0, Int(openedStatus.st_size))
        let readBytes = min(fileBytes, maximumBytes)
        let offset = max(0, fileBytes - readBytes)
        var data = Data(count: readBytes)
        let bytesRead = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var total = 0
            while total < bytes.count {
                let count = pread(
                    descriptor,
                    baseAddress.advanced(by: total),
                    bytes.count - total,
                    off_t(offset + total)
                )
                guard count > 0 else { break }
                total += count
            }
            return total
        }
        guard bytesRead == readBytes else { throw AppDiagnosticArchiveError.unsafeArchive }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
            data = Data(data[data.index(after: newline)...])
        }
        if data.last != 0x0A {
            guard let newline = data.lastIndex(of: 0x0A) else { return Data() }
            data = Data(data[...newline])
        }
        return data
    }

    private static func replacePrivately(
        _ data: Data,
        at url: URL,
        expectedStatus: stat
    ) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".legacy-log-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw AppDiagnosticArchiveError.unsafeArchive }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        let wroteAllBytes = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAllBytes, fsync(descriptor) == 0 else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        var currentStatus = stat()
        guard lstat(url.path, &currentStatus) == 0,
              currentStatus.st_dev == expectedStatus.st_dev,
              currentStatus.st_ino == expectedStatus.st_ino,
              currentStatus.st_size == expectedStatus.st_size,
              currentStatus.st_uid == getuid(),
              currentStatus.st_nlink == 1,
              currentStatus.st_mode & S_IFMT == S_IFREG,
              Darwin.rename(temporaryURL.path, url.path) == 0
        else { throw AppDiagnosticArchiveError.unsafeArchive }
        shouldRemoveTemporary = false
    }

    private static func rotateDirectLogIfNeeded(_ logURL: URL, referenceDate: Date) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            try createPrivateFile(logURL)
            return
        }
        guard isRegularFileWithoutFollowingLinks(logURL) else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        guard chmod(logURL.path, 0o600) == 0 else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        var status = stat()
        guard lstat(logURL.path, &status) == 0 else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        guard status.st_size >= maximumBytes || isExpired(logURL, referenceDate: referenceDate)
        else {
            removeExpiredBackups(for: logURL, referenceDate: referenceDate)
            return
        }

        let first = backupURL(for: logURL, index: 1)
        let second = backupURL(for: logURL, index: 2)
        if fileManager.fileExists(atPath: second.path) {
            guard isRegularFileWithoutFollowingLinks(second) else {
                throw AppDiagnosticArchiveError.unsafeArchive
            }
            try fileManager.removeItem(at: second)
        }
        if fileManager.fileExists(atPath: first.path) {
            guard isRegularFileWithoutFollowingLinks(first) else {
                throw AppDiagnosticArchiveError.unsafeArchive
            }
            try fileManager.moveItem(at: first, to: second)
        }
        try fileManager.moveItem(at: logURL, to: first)
        try createPrivateFile(logURL)
        removeExpiredBackups(for: logURL, referenceDate: referenceDate)
    }

    private static func removeExpiredBackups(for logURL: URL, referenceDate: Date) {
        for index in 1 ... 2 {
            let url = backupURL(for: logURL, index: index)
            guard isRegularFileWithoutFollowingLinks(url),
                  isExpired(url, referenceDate: referenceDate)
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isExpired(_ url: URL, referenceDate: Date) -> Bool {
        guard let lifecycleDate = fileLifecycleDate(url) else { return false }
        return lifecycleDate < referenceDate.addingTimeInterval(-retentionInterval)
    }

    private static func backupURL(for logURL: URL, index: Int) -> URL {
        logURL.deletingLastPathComponent()
            .appendingPathComponent("petcore-launch.\(index).log")
    }

    private static func createPrivateFile(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw AppDiagnosticArchiveError.unsafeArchive }
        var status = stat()
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & 0o077 == 0
        else {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: url)
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        Darwin.close(descriptor)
    }
}

private func pathEntryExists(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
}

private func fileLifecycleDate(_ url: URL) -> Date? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return nil
    }
    return AppDiagnosticRetentionPolicy.lifecycleDate(
        creationDate: attributes[.creationDate] as? Date,
        modificationDate: attributes[.modificationDate] as? Date
    )
}

private func isRegularFileWithoutFollowingLinks(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
        && status.st_mode & S_IFMT == S_IFREG
        && status.st_uid == getuid()
        && status.st_nlink == 1
}

private func isPrivateDirectory(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.standardizedFileURL.path, &status) == 0
        && status.st_mode & S_IFMT == S_IFDIR
        && status.st_uid == getuid()
        && status.st_nlink >= 1
        && status.st_mode & 0o077 == 0
}

private func ensurePrivateDirectory(_ url: URL, createIfMissing: Bool) throws {
    let directory = url.standardizedFileURL
    var status = stat()
    if lstat(directory.path, &status) != 0 {
        guard errno == ENOENT, createIfMissing else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard lstat(directory.path, &status) == 0 else {
            throw AppDiagnosticArchiveError.unsafeArchive
        }
    }
    guard status.st_mode & S_IFMT == S_IFDIR,
          status.st_uid == getuid(),
          status.st_nlink >= 1,
          chmod(directory.path, 0o700) == 0,
          lstat(directory.path, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_uid == getuid(),
          status.st_nlink >= 1,
          status.st_mode & 0o077 == 0
    else {
        throw AppDiagnosticArchiveError.unsafeArchive
    }
}
